import CoreImage
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Metal
import Synchronization
import VideoToolbox

/// Actor/serial-queue owned. Each allocation is consumed into a read-only frame before publication.
final class PixelBufferPool {
    static let defaultAllocationThreshold = 28
    static let defaultMinimumBufferCount = 4

    private let pool: CVMutablePixelBuffer.Pool
    let size: VideoSize
    let format: OSType
    let allocationThreshold: Int

    init(
        size: VideoSize, format: OSType, requirements: [String: any Sendable] = [:],
        allocationThreshold: Int = PixelBufferPool.defaultAllocationThreshold,
        minimumBufferCount: Int = PixelBufferPool.defaultMinimumBufferCount
    ) throws {
        self.size = size
        self.format = format
        self.allocationThreshold = max(1, allocationThreshold)
        var attributes = requirements
        attributes[kCVPixelBufferWidthKey as String] = size.width
        attributes[kCVPixelBufferHeightKey as String] = size.height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = format
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: String]()
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        guard let creation = CVPixelBufferCreationAttributes(CVPixelBufferAttributes(rawAttributes: attributes)) else {
            throw PipelineError(AppText("像素缓冲属性无效", "Invalid pixel buffer attributes."))
        }
        pool = try CVMutablePixelBuffer.Pool(
            pixelBufferAttributes: creation,
            configuration: .init(minimumBufferCount: max(0, minimumBufferCount)))
    }

    func makeMutable() throws -> CVMutablePixelBuffer {
        try pool.makeMutablePixelBuffer(.init(allocationThreshold: allocationThreshold))
    }

    func makeVTFrame(at time: CMTime, hdr10PQ: Bool = false) throws -> VTFrameProcessorFrame {
        let buffer = try makeMutable()
        var output: VTFrameProcessorFrame?
        buffer.withUnsafeBuffer { raw in
            if hdr10PQ {
                PixelConverter.attachHDR10PQ(to: raw)
            } else {
                PixelConverter.attach709(to: raw)
            }
            output = VTFrameProcessorFrame(buffer: raw, presentationTimeStamp: time)
        }
        guard let output else {
            throw PipelineError(
                AppText("VideoToolbox 需要 IOSurface 缓冲", "VideoToolbox requires IOSurface-backed buffers."))
        }
        return output
    }
}

final class PixelConverter {
    let context: CIContext
    static let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let itur2100PQ = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
    static let rec2020 = CGColorSpace(name: CGColorSpace.itur_2020)!

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    static func attach709(to buffer: CVPixelBuffer) {
        // Match CIRenderDestination's explicit profile. Video-only 709 tags let CoreImage
        // infer a different transfer curve, which changed luminance on every round trip.
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, rec709, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    static func attachHDR10PQ(to buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, itur2100PQ, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }

    static func isHDR10PQ(_ buffer: CVPixelBuffer) -> Bool {
        if let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        {
            return true
        }
        if let colorSpace = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil),
            CFEqual(colorSpace, itur2100PQ)
        {
            return true
        }
        return false
    }

    func render(_ image: CIImage, pool: PixelBufferPool, hdr10PQ: Bool = false) throws -> CVReadOnlyPixelBuffer {
        let buffer = try pool.makeMutable()
        try buffer.withUnsafeBuffer { raw in
            // Capture may reuse a directly copied buffer for a Core Image fallback.
            CVBufferRemoveAllAttachments(raw)
            if hdr10PQ {
                Self.attachHDR10PQ(to: raw)
            } else {
                Self.attach709(to: raw)
            }
            // Wait for this conversion before handing the surface to an independent VT queue.
            let destination = CIRenderDestination(pixelBuffer: raw)
            destination.colorSpace = hdr10PQ ? Self.itur2100PQ : Self.rec709
            let task = try context.startTask(toRender: image, to: destination)
            _ = try task.waitUntilCompleted()
        }
        return CVReadOnlyPixelBuffer(buffer)
    }

    func convert(_ frame: VideoFrame, pool: PixelBufferPool, preserveHDR10: Bool = false) throws -> VideoFrame {
        let (format, isHDR10) = frame.pixelBuffer.withUnsafeBuffer {
            (CVPixelBufferGetPixelFormatType($0), preserveHDR10 && Self.isHDR10PQ($0))
        }
        if frame.size == pool.size,
            format == pool.format,
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_32BGRA
        {
            return try copy(frame, pool: pool, hdr10PQ: isHDR10)
        }
        let image = frame.pixelBuffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
        return VideoFrame(
            pixelBuffer: try render(image, pool: pool, hdr10PQ: isHDR10), presentationTime: frame.presentationTime,
            duration: frame.duration, sequence: frame.sequence, arrivalTime: frame.arrivalTime,
            contentRect: frame.contentRect, windowStamp: frame.windowStamp)
    }

    private func copy(_ frame: VideoFrame, pool: PixelBufferPool, hdr10PQ: Bool = false) throws -> VideoFrame {
        let buffer = try pool.makeMutable()
        try frame.pixelBuffer.withUnsafeBuffer { source in
            try buffer.withUnsafeBuffer { destination in
                try Self.copyPlanes(from: source, to: destination)
                Self.replacePropagatedAttachments(from: source, to: destination)
                if hdr10PQ {
                    Self.attachHDR10PQ(to: destination)
                } else {
                    Self.attach709(to: destination)
                }
            }
        }
        return VideoFrame(
            pixelBuffer: CVReadOnlyPixelBuffer(buffer), presentationTime: frame.presentationTime,
            duration: frame.duration, sequence: frame.sequence, arrivalTime: frame.arrivalTime,
            contentRect: frame.contentRect, windowStamp: frame.windowStamp)
    }

    /// Copies a completed mutable/VT output buffer into an owned read-only pool buffer without a Core Image
    /// color round-trip, preserving exact YCbCr/BGRA bytes and HDR10 PQ or Rec.709 color attachments.
    func copyReadOnly(from source: CVPixelBuffer, pool: PixelBufferPool, hdr10PQ: Bool) throws -> CVReadOnlyPixelBuffer
    {
        if CVPixelBufferGetPixelFormatType(source) == pool.format,
            CVPixelBufferGetWidth(source) == pool.size.width,
            CVPixelBufferGetHeight(source) == pool.size.height,
            pool.format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pool.format == kCVPixelFormatType_32BGRA
        {
            let buffer = try pool.makeMutable()
            try buffer.withUnsafeBuffer { destination in
                try Self.copyPlanes(from: source, to: destination)
                Self.replacePropagatedAttachments(from: source, to: destination)
                if hdr10PQ {
                    Self.attachHDR10PQ(to: destination)
                } else {
                    Self.attach709(to: destination)
                }
            }
            return CVReadOnlyPixelBuffer(buffer)
        }
        return try render(CIImage(cvPixelBuffer: source), pool: pool, hdr10PQ: hdr10PQ)
    }

    private static let parallelCopyByteThreshold = 6_000_000
    private static let parallelCopyEnabled = ProcessInfo.processInfo.environment["PLAYGLIDE_PARALLEL_COPY"] != "0"

    /// Copies every active plane byte. Matching strides use one copy per plane, ending at the last row's active bytes.
    /// Large 4K surfaces stripe across four workers to cut uncached UVC DMA IOSurface read latency by ~3×.
    /// When `collectSignature` is true, samples the sparse 32×18 `PictureSignature` from the hot destination buffer
    /// under the same pixel-buffer lock so downstream `ContentDetector` avoids a second lock and memory walk.
    @discardableResult
    static func copyPlanes(
        from source: CVPixelBuffer, to destination: CVPixelBuffer,
        collectSignature: Bool = false, skipRedundantExtendedFill: Bool = false
    ) throws -> PictureSignature? {
        let format = CVPixelBufferGetPixelFormatType(source)
        guard format == CVPixelBufferGetPixelFormatType(destination),
            CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(destination),
            CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(destination)
        else { throw PipelineError(AppText("像素复制的格式或尺寸不一致", "Pixel copy formats or dimensions do not match.")) }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw PipelineError(AppText("无法读取输入像素", "Could not read input pixels."))
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            throw PipelineError(AppText("无法写入处理器像素", "Could not write to the processing buffer."))
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let planar = CVPixelBufferIsPlanar(source)
        let planes = planar ? CVPixelBufferGetPlaneCount(source) : 1
        guard planar == CVPixelBufferIsPlanar(destination), !planar || CVPixelBufferGetPlaneCount(destination) == planes
        else { throw PipelineError(AppText("像素平面布局无效", "Invalid pixel plane layout.")) }
        var layouts: [(src: Int, dst: Int, srcRow: Int, dstRow: Int, bytes: Int, width: Int, height: Int)] = []
        layouts.reserveCapacity(planes)
        var totalBytes = 0
        var hasDestinationRowPadding = false
        for plane in 0..<planes {
            let sourceBase =
                planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source)
            let targetBase =
                planar
                ? CVPixelBufferGetBaseAddressOfPlane(destination, plane) : CVPixelBufferGetBaseAddress(destination)
            let sourceRow =
                planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let targetRow =
                planar
                ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane) : CVPixelBufferGetBytesPerRow(destination)
            let height = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
            let width = planar ? CVPixelBufferGetWidthOfPlane(source, plane) : CVPixelBufferGetWidth(source)
            let bytes = try width * bytesPerPixel(format: format, plane: plane)
            guard let sourceBase, let targetBase, height > 0, sourceRow >= bytes, targetRow >= bytes else {
                throw PipelineError(AppText("像素平面布局无效", "Invalid pixel plane layout."))
            }
            if targetRow > bytes { hasDestinationRowPadding = true }
            layouts.append(
                (
                    src: Int(bitPattern: sourceBase), dst: Int(bitPattern: targetBase),
                    srcRow: sourceRow, dstRow: targetRow, bytes: bytes, width: width, height: height
                ))
            totalBytes += bytes * height
        }
        if parallelCopyEnabled && totalBytes >= parallelCopyByteThreshold {
            let planeLayouts = layouts
            let strips = 4
            DispatchQueue.concurrentPerform(iterations: strips) { strip in
                for layout in planeLayouts {
                    let start = strip * layout.height / strips
                    let end = (strip + 1) * layout.height / strips
                    guard end > start,
                        let sourceBase = UnsafeRawPointer(bitPattern: layout.src),
                        let targetBase = UnsafeMutableRawPointer(bitPattern: layout.dst)
                    else { continue }
                    if layout.srcRow == layout.dstRow {
                        let span =
                            end == layout.height
                            ? (end - start - 1) * layout.srcRow + layout.bytes
                            : (end - start) * layout.srcRow
                        memcpy(
                            targetBase.advanced(by: start * layout.dstRow),
                            sourceBase.advanced(by: start * layout.srcRow), span)
                    } else {
                        for row in start..<end {
                            memcpy(
                                targetBase.advanced(by: row * layout.dstRow),
                                sourceBase.advanced(by: row * layout.srcRow), layout.bytes)
                        }
                    }
                }
            }
        } else {
            for layout in layouts {
                guard let sourceBase = UnsafeRawPointer(bitPattern: layout.src),
                    let targetBase = UnsafeMutableRawPointer(bitPattern: layout.dst)
                else { continue }
                if layout.srcRow == layout.dstRow {
                    memcpy(targetBase, sourceBase, (layout.height - 1) * layout.srcRow + layout.bytes)
                } else {
                    for row in 0..<layout.height {
                        memcpy(
                            targetBase.advanced(by: row * layout.dstRow),
                            sourceBase.advanced(by: row * layout.srcRow), layout.bytes)
                    }
                }
            }
        }
        let signature: PictureSignature?
        if collectSignature, let primary = layouts.first,
            let primaryBase = UnsafeRawPointer(bitPattern: primary.dst)
        {
            let chromaLayout = planar && layouts.count > 1 ? layouts[1] : nil
            let chromaBase = chromaLayout.flatMap { UnsafeRawPointer(bitPattern: $0.dst) }
            signature = ContentDetector.sampleLocked(
                format: format, planar: planar, base: primaryBase, rowStride: primary.dstRow,
                width: primary.width, height: primary.height, chroma: chromaBase,
                chromaWidth: chromaLayout?.width ?? 0, chromaHeight: chromaLayout?.height ?? 0,
                chromaStride: chromaLayout?.dstRow ?? 0)
        } else {
            signature = nil
        }
        var needsExtendedFill = true
        if skipRedundantExtendedFill && !hasDestinationRowPadding {
            var left = 0
            var right = 0
            var top = 0
            var bottom = 0
            CVPixelBufferGetExtendedPixels(destination, &left, &right, &top, &bottom)
            needsExtendedFill = left != 0 || right != 0 || top != 0 || bottom != 0
        }
        if needsExtendedFill {
            CVPixelBufferFillExtendedPixels(destination)
        }
        return signature
    }

    private static func bytesPerPixel(format: OSType, plane: Int) throws -> Int {
        switch format {
        case kCVPixelFormatType_32BGRA: return 4
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return plane == 0 ? 1 : 2
        default:
            throw PipelineError(
                AppText("不支持直接复制的像素格式：\(fourCC(format))", "Unsupported pixel format for direct copy: \(fourCC(format))")
            )
        }
    }

    /// Keeps the source's stated chroma siting and Rec.709 color contract, normalizing UVC
    /// SMPTE-240M-tagged SDR 709 surfaces and filling unstated Rec.709 tags.
    static func adoptRec709Attachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        replacePropagatedAttachments(from: source, to: destination)
        let uvc240M =
            CVBufferCopyAttachment(destination, kCVImageBufferTransferFunctionKey, nil) as? String
            == kCVImageBufferTransferFunction_SMPTE_240M_1995 as String
        if uvc240M {
            attach709(to: destination)
            return
        }
        let defaults: [(CFString, CFTypeRef)] = [
            (kCVImageBufferCGColorSpaceKey, rec709),
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in defaults where CVBufferCopyAttachment(destination, key, nil) == nil {
            CVBufferSetAttachment(destination, key, value, .shouldPropagate)
        }
    }

    static func adoptHDR10PQAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        replacePropagatedAttachments(from: source, to: destination)
        attachHDR10PQ(to: destination)
    }

    private static func replacePropagatedAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        CVBufferRemoveAllAttachments(destination)
        CVBufferPropagateAttachments(source, destination)
    }

    private static let chromaSitings: [String: SIMD2<Float>] = [
        kCVImageBufferChromaLocation_Center as String: SIMD2(0, 0),
        kCVImageBufferChromaLocation_Left as String: SIMD2(0.5, 0),
        kCVImageBufferChromaLocation_TopLeft as String: SIMD2(0.5, 0.5),
        kCVImageBufferChromaLocation_Top as String: SIMD2(0, 0.5),
        kCVImageBufferChromaLocation_BottomLeft as String: SIMD2(0.5, -0.5),
        kCVImageBufferChromaLocation_Bottom as String: SIMD2(0, -0.5),
    ]

    /// Offset, in luma pixels, from a 4:2:0 chroma texel's center to the position its sample represents.
    /// Untagged surfaces are center-sited. Nil means the Metal NV12 paths must not decode this siting.
    static func chromaSitingOffset(top: String?, bottom: String?) -> SIMD2<Float>? {
        if let bottom, bottom != top { return nil }
        guard let top else { return SIMD2(0, 0) }
        return chromaSitings[top]
    }

    static func chromaSitingOffset(of buffer: CVPixelBuffer) -> SIMD2<Float>? {
        chromaSitingOffset(
            top: CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) as? String,
            bottom: CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey, nil) as? String)
    }
}

/// The color contract of one borrowed capture surface.
struct CaptureSurfaceDescription: Equatable, Sendable {
    let size: VideoSize
    let format: OSType
    let primaries: String?
    let transfer: String?
    let matrix: String?
    let chromaLocation: String?
    let bottomChromaLocation: String?
    /// Nil when the surface carries no CGColorSpace.
    let colorSpaceIsRec709: Bool?
    /// True when the surface carries an explicit named CGColorSpace (e.g. sRGB or Display P3).
    let colorSpaceHasExplicitName: Bool
    let fieldCount: Int

    init(_ buffer: CVPixelBuffer) {
        size = VideoSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        format = CVPixelBufferGetPixelFormatType(buffer)
        primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
        transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        chromaLocation = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
        bottomChromaLocation =
            CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey, nil) as? String
        let colorSpace: CGColorSpace? = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil).flatMap {
            CFGetTypeID($0) == CGColorSpace.typeID ? ($0 as! CGColorSpace) : nil
        }
        colorSpaceIsRec709 = colorSpace.map { CFEqual($0, PixelConverter.rec709) }
        colorSpaceHasExplicitName = colorSpace?.name != nil
        fieldCount = (CVBufferCopyAttachment(buffer, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue ?? 1
    }

    /// A progressive SDR Rec.709 (or untagged) surface in a format the pipeline reads directly,
    /// including macOS UVC NV12 capture surfaces tagged with Rec.709 primaries/matrix and SMPTE 240M transfer.
    var copiesWithoutConversion: Bool {
        canCopyDirectly(hdr10PQ: false)
    }

    func canCopyDirectly(hdr10PQ: Bool) -> Bool {
        let planar = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard planar || format == kCVPixelFormatType_32BGRA, fieldCount == 1 else { return false }
        if hdr10PQ {
            guard planar else { return true }
            return PixelConverter.chromaSitingOffset(top: chromaLocation, bottom: bottomChromaLocation) != nil
        }
        guard primaries.map({ $0 == kCVImageBufferColorPrimaries_ITU_R_709_2 as String }) ?? true else {
            return false
        }
        let uvc240M =
            planar && primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String
            && matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
            && transfer == kCVImageBufferTransferFunction_SMPTE_240M_1995 as String
            && (colorSpaceIsRec709 != false || !colorSpaceHasExplicitName)
        guard
            uvc240M
                || (colorSpaceIsRec709 != false
                    && transfer.map({ $0 == kCVImageBufferTransferFunction_ITU_R_709_2 as String }) ?? true)
        else { return false }
        guard planar else { return true }
        return (matrix.map { $0 == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String } ?? true)
            && PixelConverter.chromaSitingOffset(top: chromaLocation, bottom: bottomChromaLocation) != nil
    }

    var summary: AppText {
        let surface = "\(fourCC(format)) \(size)"
        let chinese = "未标注"
        let english = "Untagged"
        return AppText(
            "\(surface) · 原色 \(primaries ?? chinese) · 传递 \(transfer ?? chinese)"
                + " · 矩阵 \(matrix ?? chinese) · 色度 \(chromaLocation ?? chinese)"
                + (colorSpaceIsRec709 == false ? " · 非 709 色彩空间" : ""),
            "\(surface) · Primaries \(primaries ?? english) · Transfer \(transfer ?? english)"
                + " · Matrix \(matrix ?? english) · Chroma \(chromaLocation ?? english)"
                + (colorSpaceIsRec709 == false ? " · Non-709 color space" : ""))
    }
}

/// Owned by one serial capture callback queue or test producer. Returns an owned read-only image
/// before the borrowed source buffer goes back to its producer.
final class CaptureFrameIngest {
    /// Sample the sparse 32×18 `PictureSignature` inline during plane copy and skip redundant
    /// `CVPixelBufferFillExtendedPixels` when rows have no padding (`PLAYGLIDE_INGEST_INLINE_SIGNATURE=0` opts out).
    static var inlineSignatureEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_INGEST_INLINE_SIGNATURE"] != "0"
    }

    enum Mode: String, Sendable {
        case automatic
        case coreImage = "coreimage"

        static let configured =
            Self(rawValue: ProcessInfo.processInfo.environment["PLAYGLIDE_CAPTURE_INGEST"] ?? "") ?? .automatic
    }

    struct Output {
        let pixelBuffer: CVReadOnlyPixelBuffer
        let copied: Bool
        /// Set for the first surface and whenever its color contract changes.
        let changedDescription: CaptureSurfaceDescription?
        let isHDR10PQ: Bool
        let signature: PictureSignature?

        init(
            pixelBuffer: CVReadOnlyPixelBuffer, copied: Bool,
            changedDescription: CaptureSurfaceDescription?, isHDR10PQ: Bool,
            signature: PictureSignature? = nil
        ) {
            self.pixelBuffer = pixelBuffer
            self.copied = copied
            self.changedDescription = changedDescription
            self.isHDR10PQ = isHDR10PQ
            self.signature = signature
        }
    }

    let mode: Mode
    let deduplicatesIdenticalBuffers: Bool
    let colorMode: InputColorMode
    var hdr10PQ: Bool { colorMode == .hdr10PQ }
    private let converter = PixelConverter()
    private var pool: PixelBufferPool?
    private var lastDescription: CaptureSurfaceDescription?
    private var lastOutput:
        (
            buffer: CVReadOnlyPixelBuffer, signature: PictureSignature,
            description: CaptureSurfaceDescription, isHDR10PQ: Bool
        )?

    init(
        mode: Mode = .configured, deduplicatesIdenticalBuffers: Bool = false,
        colorMode: InputColorMode = .sdrRec709
    ) {
        self.mode = mode
        self.deduplicatesIdenticalBuffers = deduplicatesIdenticalBuffers
        self.colorMode = colorMode
    }

    convenience init(mode: Mode = .configured, deduplicatesIdenticalBuffers: Bool = false, hdr10PQ: Bool) {
        self.init(
            mode: mode, deduplicatesIdenticalBuffers: deduplicatesIdenticalBuffers,
            colorMode: hdr10PQ ? .hdr10PQ : .sdrRec709)
    }

    func ingest(
        _ buffer: CVPixelBuffer, collectSignature: Bool = CaptureFrameIngest.inlineSignatureEnabled
    ) throws -> Output {
        let description = CaptureSurfaceDescription(buffer)
        let frameIsHDR10: Bool
        switch colorMode {
        case .sdrRec709: frameIsHDR10 = false
        case .hdr10PQ: frameIsHDR10 = true
        case .automatic: frameIsHDR10 = PixelConverter.isHDR10PQ(buffer)
        }
        if pool?.size != description.size || pool?.format != description.format {
            pool = try PixelBufferPool(size: description.size, format: description.format)
            lastOutput = nil
        }
        guard let pool else { throw PipelineError(AppText("无法分配采集缓冲", "Could not allocate a capture buffer.")) }
        let changed: CaptureSurfaceDescription?
        let directCopy = mode == .automatic && description.canCopyDirectly(hdr10PQ: frameIsHDR10)
        if directCopy {
            let signature = deduplicatesIdenticalBuffers ? ContentDetector.sampleRaw(buffer) : nil
            if deduplicatesIdenticalBuffers, let previous = lastOutput,
                previous.description == description, previous.isHDR10PQ == frameIsHDR10,
                let signature, signature.resembles(previous.signature, size: description.size),
                previous.buffer.withUnsafeBuffer({ ContentDetector.matchesRaw(buffer, $0) })
            {
                // Repeated 30-over-60 frames reuse the last immutable read-only surface directly,
                // avoiding a 12.4 MB 4K copy and allowing ContentDetector to short-circuit by pointer identity.
                return Output(
                    pixelBuffer: previous.buffer, copied: true, changedDescription: nil, isHDR10PQ: frameIsHDR10,
                    signature: previous.signature)
            }
            let output = try pool.makeMutable()
            var effectiveDescription = description
            var inlineSignature: PictureSignature?
            try output.withUnsafeBuffer { destination in
                inlineSignature = try PixelConverter.copyPlanes(
                    from: buffer, to: destination,
                    collectSignature: collectSignature && signature == nil,
                    skipRedundantExtendedFill: collectSignature)
                if frameIsHDR10 {
                    PixelConverter.adoptHDR10PQAttachments(from: buffer, to: destination)
                    effectiveDescription = CaptureSurfaceDescription(destination)
                } else {
                    PixelConverter.adoptRec709Attachments(from: buffer, to: destination)
                }
            }
            changed = effectiveDescription == lastDescription ? nil : effectiveDescription
            lastDescription = effectiveDescription
            let owned = CVReadOnlyPixelBuffer(output)
            let resolvedSignature = signature ?? inlineSignature
            lastOutput =
                deduplicatesIdenticalBuffers ? resolvedSignature.map { (owned, $0, description, frameIsHDR10) } : nil
            return Output(
                pixelBuffer: owned, copied: true, changedDescription: changed, isHDR10PQ: frameIsHDR10,
                signature: resolvedSignature)
        }
        changed = description == lastDescription ? nil : description
        lastDescription = description
        lastOutput = nil
        let pixel = try converter.render(CIImage(cvPixelBuffer: buffer), pool: pool)
        return Output(pixelBuffer: pixel, copied: false, changedDescription: changed, isHDR10PQ: false)
    }
}

/// Coarse color sampling for scene cuts and full-image confirmation for candidate duplicates.
final class ContentDetector {
    private(set) var sceneCut = false
    private(set) var confirmationSeconds: Double?
    private var reference: (buffer: CVReadOnlyPixelBuffer, signature: PictureSignature?)?

    func reset() {
        reference = nil
        sceneCut = false
        confirmationSeconds = nil
    }

    func rebase(to frame: VideoFrame) {
        let buffer = frame.pixelBuffer
        if reference?.buffer !== buffer { reference = (buffer, frame.pictureSignature ?? sample(buffer)) }
    }

    func isDuplicate(_ frame: VideoFrame, confirmDuplicate: Bool = true) -> Bool {
        sceneCut = false
        confirmationSeconds = nil
        let buffer = frame.pixelBuffer
        if reference?.buffer === buffer { return confirmDuplicate }
        let current = frame.pictureSignature ?? sample(buffer)
        let size = buffer.size
        if let current, let reference, let previous = reference.signature, reference.buffer.size == size {
            sceneCut = current.isSceneCut(from: previous)
            if confirmDuplicate, !sceneCut, current.resembles(previous, size: frame.size),
                matches(buffer, reference.buffer)
            {
                return true
            }
        }
        // Keep the last distinct image so consecutive small changes can accumulate past the tolerance.
        reference = (buffer, current)
        return false
    }

    private func matches(_ current: CVReadOnlyPixelBuffer, _ previous: CVReadOnlyPixelBuffer) -> Bool {
        let started = mediaHostTime()
        defer { confirmationSeconds = mediaHostTime() - started }
        return current.withUnsafeBuffer { currentBuffer in
            previous.withUnsafeBuffer { previousBuffer in
                Self.matchesRaw(currentBuffer, previousBuffer)
            }
        }
    }

    private final class AtomicDifferenceCounter: Sendable {
        let count = Atomic<Int>(0)
    }

    static var parallelConfirmationEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_PARALLEL_CONFIRM"] != "0"
    }
    private static let parallelConfirmByteThreshold = 1_048_576

    static func matchesRaw(_ currentBuffer: CVPixelBuffer, _ previousBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(currentBuffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(currentBuffer, .readOnly) }
        guard CVPixelBufferLockBaseAddress(previousBuffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(previousBuffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(currentBuffer)
        guard CVPixelBufferGetPixelFormatType(currentBuffer) == CVPixelBufferGetPixelFormatType(previousBuffer)
        else { return false }
        let planes = planar ? CVPixelBufferGetPlaneCount(currentBuffer) : 1
        let tolerance = SIMD16<UInt8>(repeating: UInt8(PictureSignature.duplicateByteTolerance))
        let limit = PictureSignature.duplicateChangedByteLimit
        var layouts: [(current: Int, previous: Int, row: Int, oldRow: Int, width: Int, height: Int)] = []
        layouts.reserveCapacity(planes)
        var totalBytes = 0
        for plane in 0..<planes {
            let height =
                planar
                ? CVPixelBufferGetHeightOfPlane(currentBuffer, plane) : CVPixelBufferGetHeight(currentBuffer)
            let row =
                planar
                ? CVPixelBufferGetBytesPerRowOfPlane(currentBuffer, plane)
                : CVPixelBufferGetBytesPerRow(currentBuffer)
            let oldRow =
                planar
                ? CVPixelBufferGetBytesPerRowOfPlane(previousBuffer, plane)
                : CVPixelBufferGetBytesPerRow(previousBuffer)
            let width =
                planar
                ? CVPixelBufferGetWidthOfPlane(currentBuffer, plane) * (plane == 0 ? 1 : 2)
                : CVPixelBufferGetWidth(currentBuffer) * 4
            guard row >= width, oldRow >= width,
                let base = planar
                    ? CVPixelBufferGetBaseAddressOfPlane(currentBuffer, plane)
                    : CVPixelBufferGetBaseAddress(currentBuffer),
                let oldBase = planar
                    ? CVPixelBufferGetBaseAddressOfPlane(previousBuffer, plane)
                    : CVPixelBufferGetBaseAddress(previousBuffer)
            else { return false }
            layouts.append(
                (
                    current: Int(bitPattern: base), previous: Int(bitPattern: oldBase),
                    row: row, oldRow: oldRow, width: width, height: height
                ))
            totalBytes += width * height
        }
        if parallelConfirmationEnabled && totalBytes >= parallelConfirmByteThreshold {
            let planeLayouts = layouts
            let counter = AtomicDifferenceCounter()
            let strips = 4
            DispatchQueue.concurrentPerform(iterations: strips) { strip in
                for layout in planeLayouts {
                    let startY = strip * layout.height / strips
                    let endY = (strip + 1) * layout.height / strips
                    guard endY > startY,
                        let currentBase = UnsafeRawPointer(bitPattern: layout.current),
                        let previousBase = UnsafeRawPointer(bitPattern: layout.previous)
                    else { continue }
                    let ok = scanRows(
                        currentBase: currentBase, previousBase: previousBase,
                        row: layout.row, oldRow: layout.oldRow, width: layout.width,
                        startY: startY, endY: endY, tolerance: tolerance,
                        shouldStop: { counter.count.load(ordering: .relaxed) > limit },
                        recordDifference: { counter.count.add(1, ordering: .relaxed).newValue <= limit })
                    if !ok { return }
                }
            }
            return counter.count.load(ordering: .acquiring) <= limit
        }
        var significant = 0
        for layout in layouts {
            guard let currentBase = UnsafeRawPointer(bitPattern: layout.current),
                let previousBase = UnsafeRawPointer(bitPattern: layout.previous)
            else { return false }
            let ok = scanRows(
                currentBase: currentBase, previousBase: previousBase,
                row: layout.row, oldRow: layout.oldRow, width: layout.width,
                startY: 0, endY: layout.height, tolerance: tolerance,
                shouldStop: { false },
                recordDifference: {
                    significant += 1
                    return significant <= limit
                })
            if !ok { return false }
        }
        return true
    }

    private static func scanRows(
        currentBase: UnsafeRawPointer, previousBase: UnsafeRawPointer,
        row: Int, oldRow: Int, width: Int, startY: Int, endY: Int,
        tolerance: SIMD16<UInt8>, shouldStop: () -> Bool, recordDifference: () -> Bool
    ) -> Bool {
        let vector64End = width - width % 64
        let vector16End = width - width % 16
        for y in startY..<endY {
            if shouldStop() { return false }
            let currentRow = currentBase.advanced(by: y * row)
            let previousRow = previousBase.advanced(by: y * oldRow)
            // Branchless 4x-unrolled SIMD16 max-difference accumulation per row.
            var m0 = SIMD16<UInt8>.zero
            var m1 = SIMD16<UInt8>.zero
            var m2 = SIMD16<UInt8>.zero
            var m3 = SIMD16<UInt8>.zero
            var x = 0
            while x < vector64End {
                let a0 = currentRow.loadUnaligned(fromByteOffset: x, as: SIMD16<UInt8>.self)
                let b0 = previousRow.loadUnaligned(fromByteOffset: x, as: SIMD16<UInt8>.self)
                m0 = pointwiseMax(m0, pointwiseMax(a0, b0) &- pointwiseMin(a0, b0))
                let a1 = currentRow.loadUnaligned(fromByteOffset: x + 16, as: SIMD16<UInt8>.self)
                let b1 = previousRow.loadUnaligned(fromByteOffset: x + 16, as: SIMD16<UInt8>.self)
                m1 = pointwiseMax(m1, pointwiseMax(a1, b1) &- pointwiseMin(a1, b1))
                let a2 = currentRow.loadUnaligned(fromByteOffset: x + 32, as: SIMD16<UInt8>.self)
                let b2 = previousRow.loadUnaligned(fromByteOffset: x + 32, as: SIMD16<UInt8>.self)
                m2 = pointwiseMax(m2, pointwiseMax(a2, b2) &- pointwiseMin(a2, b2))
                let a3 = currentRow.loadUnaligned(fromByteOffset: x + 48, as: SIMD16<UInt8>.self)
                let b3 = previousRow.loadUnaligned(fromByteOffset: x + 48, as: SIMD16<UInt8>.self)
                m3 = pointwiseMax(m3, pointwiseMax(a3, b3) &- pointwiseMin(a3, b3))
                x += 64
            }
            while x < vector16End {
                let a0 = currentRow.loadUnaligned(fromByteOffset: x, as: SIMD16<UInt8>.self)
                let b0 = previousRow.loadUnaligned(fromByteOffset: x, as: SIMD16<UInt8>.self)
                m0 = pointwiseMax(m0, pointwiseMax(a0, b0) &- pointwiseMin(a0, b0))
                x += 16
            }
            let rowMax = pointwiseMax(pointwiseMax(m0, m1), pointwiseMax(m2, m3))
            if any(rowMax .> tolerance) {
                for vx in stride(from: 0, to: vector16End, by: 16) {
                    let a = currentRow.loadUnaligned(fromByteOffset: vx, as: SIMD16<UInt8>.self)
                    let b = previousRow.loadUnaligned(fromByteOffset: vx, as: SIMD16<UInt8>.self)
                    let excessive = (pointwiseMax(a, b) &- pointwiseMin(a, b)) .> tolerance
                    if any(excessive) {
                        for lane in excessive.indices where excessive[lane] {
                            if !recordDifference() { return false }
                        }
                    }
                }
            }
            let a = currentRow.assumingMemoryBound(to: UInt8.self)
            let b = previousRow.assumingMemoryBound(to: UInt8.self)
            for tx in vector16End..<width
            where abs(Int(a[tx]) - Int(b[tx])) > PictureSignature.duplicateByteTolerance {
                // Preserve even small HUD updates; a few isolated capture-noise bytes may differ.
                if !recordDifference() { return false }
            }
        }
        return true
    }

    private func sample(_ buffer: CVReadOnlyPixelBuffer) -> PictureSignature? {
        buffer.withUnsafeBuffer { Self.sampleRaw($0) }
    }

    static func sampleRaw(_ raw: CVPixelBuffer) -> PictureSignature? {
        let format = CVPixelBufferGetPixelFormatType(raw)
        let planar =
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard planar || format == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(raw, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(raw, .readOnly) }
        let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(raw, 0) : CVPixelBufferGetBytesPerRow(raw)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(raw, 0) : CVPixelBufferGetBaseAddress(raw)
        else { return nil }
        let width = CVPixelBufferGetWidth(raw)
        let height = CVPixelBufferGetHeight(raw)
        guard width > 0, height > 0, row >= width * (planar ? 1 : 4) else { return nil }
        let chroma = planar ? CVPixelBufferGetBaseAddressOfPlane(raw, 1) : nil
        let chromaWidth = planar ? CVPixelBufferGetWidthOfPlane(raw, 1) : 0
        let chromaHeight = planar ? CVPixelBufferGetHeightOfPlane(raw, 1) : 0
        let chromaStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(raw, 1) : 0
        return sampleLocked(
            format: format, planar: planar, base: base, rowStride: row, width: width, height: height,
            chroma: chroma, chromaWidth: chromaWidth, chromaHeight: chromaHeight, chromaStride: chromaStride)
    }

    static func sampleLocked(
        format: OSType, planar: Bool, base: UnsafeRawPointer, rowStride: Int, width: Int, height: Int,
        chroma: UnsafeRawPointer?, chromaWidth: Int, chromaHeight: Int, chromaStride: Int
    ) -> PictureSignature? {
        guard width > 0, height > 0, rowStride >= width * (planar ? 1 : 4) else { return nil }
        if planar {
            guard chroma != nil, chromaWidth > 0, chromaHeight > 0, chromaStride >= chromaWidth * 2 else {
                return nil
            }
        }
        var samples: [SIMD3<UInt8>] = []
        samples.reserveCapacity(PictureSignature.rows * PictureSignature.columns)
        for y in 0..<PictureSignature.rows {
            let rowIndex = y * height / PictureSignature.rows
            let line = base.advanced(by: rowIndex * rowStride).assumingMemoryBound(to: UInt8.self)
            let chromaLine = chroma?.advanced(by: min(chromaHeight - 1, rowIndex / 2) * chromaStride)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<PictureSignature.columns {
                let column = x * width / PictureSignature.columns
                if let chromaLine {
                    let offset = min(chromaWidth - 1, column / 2) * 2
                    samples.append(SIMD3(line[column], chromaLine[offset], chromaLine[offset + 1]))
                } else {
                    let offset = column * 4
                    samples.append(SIMD3(line[offset], line[offset + 1], line[offset + 2]))
                }
            }
        }
        return PictureSignature(format: format, samples: samples)
    }
}
