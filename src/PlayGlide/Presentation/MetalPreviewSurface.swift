import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Dispatch
import Metal
import MetalFX
import QuartzCore
import SwiftUI
import Synchronization

struct DeferredHybridUnavailableError: Error {}

/// Fit the complete window content to the actual drawable, removing only padding
/// added by the capture canvas. Browser controls and source-owned black bars remain content.
func fittedPreviewImage(_ image: CIImage, inputSize: VideoSize, contentRect: CGRect?, bounds: CGRect) -> CIImage {
    var content = image
    if let contentRect {
        let scale = CGAffineTransform(
            scaleX: image.extent.width / CGFloat(inputSize.width),
            y: image.extent.height / CGFloat(inputSize.height))
        let rect = contentRect.applying(scale)
            .offsetBy(dx: image.extent.minX, dy: image.extent.minY).intersection(image.extent)
        if !rect.isNull, !rect.isEmpty { content = image.cropped(to: rect) }
    }
    let source = content.extent
    let factor = min(bounds.width / source.width, bounds.height / source.height)
    let normalized = content.transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
    let scaled: CIImage
    if factor < 0.9999 {
        scaled = normalized.applyingFilter(
            "CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
    } else {
        scaled = normalized.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    }
    let target = CGRect(
        x: bounds.midX - source.width * factor / 2, y: bounds.midY - source.height * factor / 2,
        width: source.width * factor, height: source.height * factor)
    return scaled.transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY)).cropped(to: target)
        .composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
}

/// Owned by one executor and Metal queue. Native 1:1/upscaled frames render directly to
/// framebufferOnly drawables via Metal without Core Image or intermediate 4K copies; downsampled
/// or non-standard color inputs use bounded private Core Image caches presented via a RenderPass.
final class PreviewImageRenderer {
    private struct Key: Equatable {
        let frame: UUID
        let generation: UUID
        let compare: Bool
        let size: VideoSize
        let format: UInt
    }
    private struct OriginalKey: Equatable {
        let generation: UUID
        let sequence: Int64
        let buffer: ObjectIdentifier
        let content: CGRect?
        let canvas: VideoSize
        let format: UInt
    }
    private struct SourceUniforms {
        var fitRect: SIMD4<Float>
        var fitMax: SIMD4<Float>
        var uvRect: SIMD4<Float>
        var clampRect: SIMD4<Float>
        var flags: SIMD4<Float>
    }
    private struct PreviewUniforms {
        var primary: SourceUniforms
        var original: SourceUniforms
        var split: SIMD4<Float>
        var post: SIMD4<Float>
    }
    private struct HybridPreviewUniforms {
        var primary: SourceUniforms
        var split: SIMD4<Float>
        var offsets: SIMD4<Float>
        var weights: SIMD4<Float>
        var post: SIMD4<Float>
    }
    private struct HybridPipelineKey: Hashable {
        let format: UInt
        let hasMotion: Bool
    }
    private struct SelectMotionKey: Hashable {
        let hasForwardMotion: Bool
        let sampleMid: Bool
    }
    private struct MetalSource {
        let primary: any MTLTexture
        let chroma: (any MTLTexture)?
        let views: [CVMetalTexture]
        let size: VideoSize
        let contentRect: CGRect?
        let isNV12: Bool
        let needsRec709ToSRGB: Bool
        var isHDR10PQ = false
        /// Normalized offset from chroma texel centers to the sample positions of the surface's 4:2:0 siting.
        var chromaOffset = SIMD2<Float>(0, 0)
    }

    static var hybridEdgeRefineEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_EDGE_REFINE"] != "0"
    }
    static var hybridWindowAAEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_WINDOW_AA"] != "0"
    }
    static var hdr10SoftBlackToeEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HDR10_SOFT_TOE"] != "0"
    }
    /// Strict ITU-R BT.2100 reference PQ decode without shadow gamma crush or chroma boost
    /// (`PLAYGLIDE_HDR10_REFERENCE_PQ=1`).
    static var hdr10ReferencePQEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HDR10_REFERENCE_PQ"] == "1"
    }
    static func hdr10ShaderModeBits(referencePQ: Bool) -> Int {
        if referencePQ { return 3 }
        return hdr10SoftBlackToeEnabled ? 2 : 1
    }
    /// Prewarm preview render and motion-selection Metal pipeline states off the display link callback
    /// (`PLAYGLIDE_PREWARM_PIPELINES=0` opts out for cold-start A/B comparison).
    static var prewarmPipelinesEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_PREWARM_PIPELINES"] != "0"
    }
    /// Optional 5-tap overshoot-clamped RCAS applied symmetrically to original and midpoint frames
    /// (`PLAYGLIDE_GLOBAL_RCAS=0.0..1.0`; unset or `0` disables).
    static var globalRCASStrength: Float {
        guard
            let raw = ProcessInfo.processInfo.environment["PLAYGLIDE_GLOBAL_RCAS"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let value = Float(raw), value.isFinite, value > 0
        else { return 0 }
        return min(1, value)
    }
    /// Luma-guided 2×2 joint-bilateral 4:2:0 → 4:4:4 chroma upsampling to suppress color bleeding on
    /// saturated UI/text edges (`PLAYGLIDE_BILATERAL_CHROMA=1`).
    static var bilateralChromaEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_BILATERAL_CHROMA"] == "1"
    }
    /// Gradient-preserving 4-tap debanding for 8-bit UVC HDR10 PQ inputs before YCbCr→RGB decode
    /// (`PLAYGLIDE_HDR10_DEBAND=1`). Strictly bypasses high-contrast text and micro-texture edges.
    static var hdr10DebandEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HDR10_DEBAND"] == "1"
    }

    private let device: any MTLDevice
    private let context: CIContext
    private let caching: Bool
    private let prefersDirectDownsampling: Bool
    private let spatialPrecision: SpatialUpscaler.Precision
    private let renderLibrary: (any MTLLibrary)?
    private(set) var loadedFromPrecompiledMetallib = false
    private let textureCache: CVMetalTextureCache?
    private var renderPipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
    private var hybridRenderPipelines: [HybridPipelineKey: any MTLRenderPipelineState] = [:]
    private var selectMotionPipelines: [SelectMotionKey: any MTLComputePipelineState] = [:]
    private var hybridMotionDetailTexture: (any MTLTexture)?
    private var hybridMotionDetailFrameID: UUID?
    private var hybridMotionDetailHasForward = false
    private(set) var selectMotionDispatches = 0
    private(set) var precomputedMotionUses = 0
    private(set) var pipelineCreations = 0
    private var spatial: SpatialUpscaler?
    var activeSpatialPixelFormat: MTLPixelFormat? { spatial?.activePixelFormat }
    private var texture: (any MTLTexture)?
    private var key: Key?
    private var writer: (any MTLCommandBuffer)?
    private var originalTexture: (any MTLTexture)?
    private var originalKey: OriginalKey?
    private var originalWriter: (any MTLCommandBuffer)?
    private(set) var directRenders = 0
    private(set) var fullRenders = 0
    private(set) var cacheHits = 0
    private(set) var originalRenders = 0
    private(set) var originalCacheHits = 0
    private(set) var spatialUpscales = 0
    private(set) var deferredHybridFallbacks = 0
    private(set) var deferredHybridFallbackFailures = 0
    /// Test hook to inject CVMetalTexture mapping failures without altering production behavior.
    var failTextureMapping: ((CVPixelBuffer, Int) -> Bool)?
    /// Optional overrides for deterministic GPU tests without mutating process environment variables.
    var spatialDeferredComposeOverride: Bool?
    var spatialMovingDetailOverride: Bool?
    var iconEnvelopeOverride: Bool?
    var hudDehaloOverride: Bool?
    var adaptiveCASOverride: Bool?
    var globalRCASOverride: Float?
    var bilateralChromaOverride: Bool?
    var hdr10ReferencePQOverride: Bool?
    var hdr10DebandOverride: Bool?
    private var resolvedReferencePQ: Bool { hdr10ReferencePQOverride ?? Self.hdr10ReferencePQEnabled }
    /// The frame whose MetalFX output is still in the upscaler's output texture.
    private var spatialKey: Key?
    private var reusedSpatialOutput = false

    init(
        device: any MTLDevice, context: CIContext, caching: Bool = true, prefersDirectDownsampling: Bool = true,
        spatialPrecision: SpatialUpscaler.Precision = SpatialUpscaler.configuredPrecision
    ) {
        self.device = device
        self.context = context
        self.caching = caching
        self.prefersDirectDownsampling = prefersDirectDownsampling
        self.spatialPrecision = spatialPrecision
        if let loaded = try? MetalLibraryLoader.loadLibrary(
            device: device,
            requiredFunctions: [
                "previewVertex", "previewFragment", "previewSelectMotion", "previewHybridFragment",
            ],
            fallbackSource: Self.previewShader)
        {
            renderLibrary = loaded.library
            loadedFromPrecompiledMetallib = loaded.precompiled
        } else {
            renderLibrary = nil
            loadedFromPrecompiledMetallib = false
        }
        var cache: CVMetalTextureCache?
        let attributes = [kCVMetalTextureCacheMaximumTextureAgeKey as String: 1.0] as CFDictionary
        if CVMetalTextureCacheCreate(nil, attributes, device, nil, &cache) == kCVReturnSuccess {
            textureCache = cache
        } else {
            textureCache = nil
        }
    }

    func reset() {
        texture = nil
        key = nil
        writer = nil
        originalTexture = nil
        originalKey = nil
        originalWriter = nil
        spatial = nil
        spatialKey = nil
        hybridMotionDetailTexture = nil
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    @discardableResult
    func encode(
        _ frame: PresentationFrame, compare: Bool, pqOutput: Bool = false, to destination: any MTLTexture,
        command: any MTLCommandBuffer
    ) throws -> Bool {
        let size = VideoSize(width: destination.width, height: destination.height)
        let next = Key(
            frame: frame.id, generation: frame.generation, compare: compare, size: size,
            format: destination.pixelFormat.rawValue)
        if let recipe = frame.hybridRecipe {
            if !frame.spatial,
                try encodeDeferredHybrid(
                    frame, recipe: recipe, compare: compare, pqOutput: pqOutput, to: destination, size: size,
                    command: command)
            {
                key = nil
                writer = nil
                directRenders += 1
                fullRenders += 1
                return false
            }
            if frame.spatial, spatialDeferredComposeOverride ?? HybridInterpolator.spatialDeferredComposeEnabled,
                try encodeDeferredHybridSpatial(
                    frame, recipe: recipe, compare: compare, pqOutput: pqOutput, to: destination, command: command)
            {
                key = nil
                writer = nil
                directRenders += 1
                if reusedSpatialOutput { cacheHits += 1 } else { fullRenders += 1 }
                return reusedSpatialOutput
            }
            if HybridInterpolator.deferredFallbackMidpointEnabled {
                if try encodeDeferredHybridFallback(
                    frame, recipe: recipe, compare: compare, pqOutput: pqOutput, to: destination, size: size,
                    command: command)
                {
                    key = nil
                    writer = nil
                    deferredHybridFallbacks += 1
                    directRenders += 1
                    if reusedSpatialOutput { cacheHits += 1 } else { fullRenders += 1 }
                    return reusedSpatialOutput
                }
                deferredHybridFallbackFailures += 1
                throw DeferredHybridUnavailableError()
            }
        }
        let downsampling = requiresCoreImageDownsampling(frame, compare: compare, output: size)
        if !downsampling,
            try encodeDirectMetal(
                frame, compare: compare, pqOutput: pqOutput, to: destination, size: size, command: command)
        {
            key = nil
            writer = nil
            directRenders += 1
            // A redraw of the same frame reads the previous MetalFX output instead of upscaling again.
            if reusedSpatialOutput { cacheHits += 1 } else { fullRenders += 1 }
            return reusedSpatialOutput
        }
        let reusable =
            writer.map { $0.status == .committed || $0.status == .scheduled || $0.status == .completed } ?? false
        if caching, key == next, reusable, let texture {
            try presentCachedTexture(texture, pqOutput: pqOutput, to: destination, command: command)
            cacheHits += 1
            return true
        }
        key = nil
        writer = nil
        var completed = false
        defer {
            if !completed {
                key = nil
                writer = nil
                originalKey = nil
                originalWriter = nil
            }
        }
        let ciFormat: MTLPixelFormat = destination.pixelFormat == .bgr10a2Unorm ? .rgba16Float : destination.pixelFormat
        let intermediate: (any MTLTexture)?
        if caching, size.pixels <= InputPreset.uhd4K.size.pixels {
            if texture?.width != size.width || texture?.height != size.height
                || texture?.pixelFormat != ciFormat
            {
                texture = makeIntermediateTexture(size: size, format: ciFormat)
            }
            intermediate = texture
        } else {
            texture = nil
            intermediate =
                !pqOutput && destination.usage.contains(.shaderWrite) && destination.pixelFormat == ciFormat
                ? nil : makeIntermediateTexture(size: size, format: ciFormat)
        }
        let target = intermediate ?? destination
        let video = frame.video
        var image = video.pixelBuffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
        if frame.spatial {
            if spatial == nil { spatial = SpatialUpscaler(device: device, precision: spatialPrecision) }
            guard let spatial else {
                throw PipelineError(AppText("Spatial 资源不可用", "MetalFX Spatial resources are unavailable."))
            }
            // The Core Image path overwrites the shared MetalFX output.
            spatialKey = nil
            image = try spatial.encode(
                image, input: video.size, output: frame.outputSize, context: context, command: command)
        }
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let fitted = fittedPreviewImage(image, inputSize: video.size, contentRect: video.contentRect, bounds: bounds)
        if compare {
            let left = CGRect(x: bounds.minX, y: bounds.minY, width: floor(bounds.width / 2), height: bounds.height)
            let right = CGRect(x: left.maxX, y: bounds.minY, width: bounds.maxX - left.maxX, height: bounds.height)
            let content = video.contentRect?.size ?? CGSize(width: video.size.width, height: video.size.height)
            let splitDownsampling =
                content.width * image.extent.width / CGFloat(video.size.width) > bounds.width + 0.01
                || content.height * image.extent.height / CGFloat(video.size.height) > bounds.height + 0.01
            if splitDownsampling {
                try encodeOriginal(frame, bounds: bounds, left: left, to: target, command: command)
                // Restrict the destination before Core Image plans expensive Lanczos intermediates.
                // Both halves retain full-canvas coordinates; the scene is never squeezed or duplicated.
                try render(fitted, region: right, to: target, at: right.origin, command: command)
            } else {
                // At native size there are no downsampling intermediates to save. A fused
                // composite is cheaper than two render tasks and an extra cached-half copy.
                let original = frame.original
                let originalImage = original.pixelBuffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
                let fittedOriginal = fittedPreviewImage(
                    originalImage, inputSize: original.size, contentRect: original.contentRect, bounds: bounds)
                let combined = fittedOriginal.cropped(to: left).composited(over: fitted).cropped(to: bounds)
                try render(combined, region: bounds, to: target, at: .zero, command: command)
            }
        } else {
            try render(fitted, region: bounds, to: target, at: .zero, command: command)
        }
        if let intermediate {
            try presentCachedTexture(intermediate, pqOutput: pqOutput, to: destination, command: command)
            if texture != nil {
                key = next
                writer = command
            }
        }
        completed = true
        fullRenders += 1
        return false
    }

    private func requiresCoreImageDownsampling(_ frame: PresentationFrame, compare: Bool, output: VideoSize) -> Bool {
        // Direct Metal uses a 4-tap bilinear supersample (4×4 texel footprint) down to 0.35×, avoiding
        // 60 fps Core Image Lanczos GPU/CPU overhead in windowed 4K playback; smaller thumbnails keep Lanczos.
        let threshold: CGFloat = prefersDirectDownsampling ? 0.35 : 0.9999
        let videoContent =
            frame.video.contentRect?.size ?? CGSize(width: frame.video.size.width, height: frame.video.size.height)
        let effectiveWidth =
            frame.spatial
            ? videoContent.width * CGFloat(frame.outputSize.width) / CGFloat(frame.video.size.width)
            : videoContent.width
        let effectiveHeight =
            frame.spatial
            ? videoContent.height * CGFloat(frame.outputSize.height) / CGFloat(frame.video.size.height)
            : videoContent.height
        let videoFactor = min(CGFloat(output.width) / effectiveWidth, CGFloat(output.height) / effectiveHeight)
        if videoFactor < threshold { return true }
        if compare {
            let originalContent =
                frame.original.contentRect?.size
                ?? CGSize(width: frame.original.size.width, height: frame.original.size.height)
            let originalFactor = min(
                CGFloat(output.width) / originalContent.width, CGFloat(output.height) / originalContent.height)
            if originalFactor < threshold { return true }
        }
        return false
    }

    private func encodeDeferredHybridFallback(
        _ frame: PresentationFrame, recipe: HybridPreviewRecipe, compare: Bool, pqOutput: Bool,
        to destination: any MTLTexture, size: VideoSize, command: any MTLCommandBuffer
    ) throws -> Bool {
        let scaledRect: CGRect?
        if let rect = frame.video.contentRect, recipe.inputSize.width > 0, recipe.inputSize.height > 0 {
            let scaleX = CGFloat(recipe.lowSize.width) / CGFloat(recipe.inputSize.width)
            let scaleY = CGFloat(recipe.lowSize.height) / CGFloat(recipe.inputSize.height)
            scaledRect = CGRect(
                x: rect.minX * scaleX, y: rect.minY * scaleY,
                width: rect.width * scaleX, height: rect.height * scaleY)
        } else {
            scaledRect = nil
        }
        let midpointVideo = VideoFrame(
            pixelBuffer: recipe.midpoint, presentationTime: frame.video.presentationTime,
            duration: frame.video.duration, sequence: frame.video.sequence, arrivalTime: frame.video.arrivalTime,
            contentRect: scaledRect, windowStamp: frame.video.windowStamp)
        let fallbackFrame = PresentationFrame(
            generation: frame.generation, video: midpointVideo, original: frame.original, generated: frame.generated,
            outputSize: frame.outputSize, spatial: frame.spatial, presentationDelay: frame.presentationDelay,
            displayIntervalHint: frame.displayIntervalHint, readyTime: frame.readyTime, timing: frame.timing,
            timelineRevision: frame.timelineRevision)
        return try encodeDirectMetal(
            fallbackFrame, compare: compare, pqOutput: pqOutput, hdr10Override: recipe.isHDR10PQ,
            to: destination, size: size, command: command)
    }

    private func encodeDirectMetal(
        _ frame: PresentationFrame, compare: Bool, pqOutput: Bool, hdr10Override: Bool? = nil,
        to destination: any MTLTexture, size: VideoSize, command: any MTLCommandBuffer
    ) throws -> Bool {
        reusedSpatialOutput = false
        guard let pipeline = try renderPipeline(for: destination.pixelFormat) else { return false }
        guard let rawVideo = metalSource(for: frame.video, hdr10Override: hdr10Override) else { return false }
        let originalSource: MetalSource?
        if compare {
            guard let mappedOriginal = metalSource(for: frame.original) else { return false }
            originalSource = mappedOriginal
        } else {
            originalSource = nil
        }

        let primarySource: MetalSource
        if frame.spatial {
            if spatial == nil { spatial = SpatialUpscaler(device: device, precision: spatialPrecision) }
            guard let spatial else {
                throw PipelineError(AppText("Spatial 资源不可用", "MetalFX Spatial resources are unavailable."))
            }
            let resources = try spatial.prepare(input: frame.video.size, output: frame.outputSize)
            // Earlier command buffers on this serial queue wrote the output; Metal orders the read after them.
            let spatialNext = Key(
                frame: frame.id, generation: frame.generation, compare: false, size: frame.outputSize,
                format: resources.output.pixelFormat.rawValue)
            reusedSpatialOutput = spatialKey == spatialNext
            if !reusedSpatialOutput {
                spatialKey = nil
                guard let inputPipeline = try renderPipeline(for: resources.input.pixelFormat) else { return false }
                // Convert source pixels into perceptual sRGB for MetalFX without invoking Core Image.
                let fullSource = MetalSource(
                    primary: rawVideo.primary, chroma: rawVideo.chroma, views: rawVideo.views,
                    size: rawVideo.size, contentRect: nil, isNV12: rawVideo.isNV12,
                    needsRec709ToSRGB: rawVideo.needsRec709ToSRGB, isHDR10PQ: rawVideo.isHDR10PQ,
                    chromaOffset: rawVideo.chromaOffset)
                try drawPass(
                    pipeline: inputPipeline, primary: fullSource, original: nil, compare: false, pqOutput: false,
                    suppressDither: spatialPrecision != .unorm8, suppressPostProcess: true,
                    to: resources.input, command: command)
                resources.scaler.encode(commandBuffer: command)
                spatialKey = spatialNext
                spatialUpscales += 1
            }
            let scaledContent: CGRect?
            if let rect = frame.video.contentRect {
                let scaleX = CGFloat(frame.outputSize.width) / CGFloat(frame.video.size.width)
                let scaleY = CGFloat(frame.outputSize.height) / CGFloat(frame.video.size.height)
                scaledContent = CGRect(
                    x: rect.minX * scaleX, y: rect.minY * scaleY,
                    width: rect.width * scaleX, height: rect.height * scaleY)
            } else {
                scaledContent = nil
            }
            primarySource = MetalSource(
                primary: resources.output, chroma: nil, views: [],
                size: frame.outputSize, contentRect: scaledContent, isNV12: false, needsRec709ToSRGB: false,
                isHDR10PQ: rawVideo.isHDR10PQ)
        } else {
            primarySource = rawVideo
        }

        try drawPass(
            pipeline: pipeline, primary: primarySource, original: originalSource, compare: compare, pqOutput: pqOutput,
            to: destination, command: command)
        return true
    }

    private func metalSource(for frame: VideoFrame, hdr10Override: Bool? = nil) -> MetalSource? {
        guard let textureCache else { return nil }
        var result: MetalSource?
        frame.pixelBuffer.withUnsafeBuffer { pixel in
            guard CVPixelBufferGetIOSurface(pixel) != nil else { return }
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixel)
            if pixelFormat == kCVPixelFormatType_32BGRA {
                let needsRec709: Bool
                let isHDR10 = hdr10Override ?? PixelConverter.isHDR10PQ(pixel)
                if isHDR10 {
                    needsRec709 = false
                } else if let colorSpace = CVBufferCopyAttachment(pixel, kCVImageBufferCGColorSpaceKey, nil) {
                    if CFEqual(colorSpace, PixelConverter.rec709) {
                        needsRec709 = true
                    } else if CFEqual(colorSpace, PixelConverter.sRGB) {
                        needsRec709 = false
                    } else {
                        return
                    }
                } else if let transfer = CVBufferCopyAttachment(pixel, kCVImageBufferTransferFunctionKey, nil)
                    as? String
                {
                    if transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String {
                        needsRec709 = true
                    } else if transfer == kCVImageBufferTransferFunction_sRGB as String {
                        needsRec709 = false
                    } else {
                        return
                    }
                } else {
                    needsRec709 = false
                }
                guard
                    let view = mapTexture(
                        pixel, cache: textureCache, format: .bgra8Unorm, width: frame.size.width,
                        height: frame.size.height, plane: 0),
                    let tex = CVMetalTextureGetTexture(view)
                else { return }
                result = MetalSource(
                    primary: tex, chroma: nil, views: [view], size: frame.size, contentRect: frame.contentRect,
                    isNV12: false, needsRec709ToSRGB: needsRec709, isHDR10PQ: isHDR10)
            } else if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                let isHDR10 = hdr10Override ?? PixelConverter.isHDR10PQ(pixel)
                let matrix = CVBufferCopyAttachment(pixel, kCVImageBufferYCbCrMatrixKey, nil) as? String
                let validColor: Bool
                if isHDR10 {
                    validColor =
                        matrix == nil
                        || matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
                        || matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
                } else if let colorSpace = CVBufferCopyAttachment(pixel, kCVImageBufferCGColorSpaceKey, nil),
                    CFEqual(colorSpace, PixelConverter.rec709),
                    matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
                {
                    validColor = true
                } else {
                    validColor = false
                }
                guard CVPixelBufferGetPlaneCount(pixel) == 2,
                    validColor,
                    ((CVBufferCopyAttachment(pixel, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue ?? 1)
                        == 1,
                    let siting = PixelConverter.chromaSitingOffset(of: pixel)
                else { return }
                let chromaWidth = frame.size.width / 2
                let chromaHeight = frame.size.height / 2
                guard frame.size.width.isMultiple(of: 2), frame.size.height.isMultiple(of: 2),
                    CVPixelBufferGetWidthOfPlane(pixel, 0) == frame.size.width,
                    CVPixelBufferGetHeightOfPlane(pixel, 0) == frame.size.height,
                    CVPixelBufferGetWidthOfPlane(pixel, 1) == chromaWidth,
                    CVPixelBufferGetHeightOfPlane(pixel, 1) == chromaHeight,
                    let lumaView = mapTexture(
                        pixel, cache: textureCache, format: .r8Unorm, width: frame.size.width,
                        height: frame.size.height, plane: 0),
                    let chromaView = mapTexture(
                        pixel, cache: textureCache, format: .rg8Unorm, width: chromaWidth, height: chromaHeight,
                        plane: 1),
                    let luma = CVMetalTextureGetTexture(lumaView),
                    let chroma = CVMetalTextureGetTexture(chromaView)
                else { return }
                result = MetalSource(
                    primary: luma, chroma: chroma, views: [lumaView, chromaView], size: frame.size,
                    contentRect: frame.contentRect, isNV12: true, needsRec709ToSRGB: !isHDR10,
                    isHDR10PQ: isHDR10,
                    chromaOffset: siting / SIMD2(Float(frame.size.width), Float(frame.size.height)))
            }
        }
        return result
    }

    private func mapTexture(
        _ pixel: CVPixelBuffer, cache: CVMetalTextureCache, format: MTLPixelFormat, width: Int, height: Int, plane: Int
    ) -> CVMetalTexture? {
        if failTextureMapping?(pixel, plane) == true { return nil }
        var view: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.rawValue] as CFDictionary
        guard
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixel, attributes, format, width, height, plane, &view) == kCVReturnSuccess
        else { return nil }
        return view
    }

    private func sourceUniforms(
        for source: MetalSource, outputSize: VideoSize, pqOutput: Bool = false
    ) -> SourceUniforms {
        let full = CGRect(x: 0, y: 0, width: source.size.width, height: source.size.height)
        let crop: CGRect
        if let rect = source.contentRect?.intersection(full), !rect.isNull, !rect.isEmpty {
            crop = rect
        } else {
            crop = full
        }
        let outW = Double(outputSize.width)
        let outH = Double(outputSize.height)
        let factor = min(outW / crop.width, outH / crop.height)
        let fitW = crop.width * factor
        let fitH = crop.height * factor
        let fitX = (outW - fitW) * 0.5
        let fitY = (outH - fitH) * 0.5

        // Convert Core Image bottom-left contentRect to Metal top-left normalized UV coordinates.
        let srcW = Double(source.size.width)
        let srcH = Double(source.size.height)
        let uMin = crop.minX / srcW
        let uSpan = crop.width / srcW
        let vMin = (srcH - crop.maxY) / srcH
        let vSpan = crop.height / srcH
        let insetU = min(0.5 / Double(source.primary.width), uSpan * 0.5)
        let insetV = min(0.5 / Double(source.primary.height), vSpan * 0.5)
        let downscaling = factor < 0.9999
        let sampleOffsetU = downscaling ? Float(0.25 * uSpan / fitW) : 0
        let sampleOffsetV = downscaling ? Float(0.25 * vSpan / fitH) : 0
        let colorMode: Float
        if source.isHDR10PQ {
            colorMode = 0
        } else if pqOutput {
            colorMode = source.needsRec709ToSRGB ? 3 : 2
        } else {
            colorMode = source.needsRec709ToSRGB ? 1 : 0
        }
        return SourceUniforms(
            fitRect: SIMD4<Float>(Float(fitX), Float(fitY), Float(1.0 / fitW), Float(1.0 / fitH)),
            fitMax: SIMD4<Float>(Float(fitX + fitW), Float(fitY + fitH), sampleOffsetU, sampleOffsetV),
            uvRect: SIMD4<Float>(Float(uMin), Float(vMin), Float(uSpan), Float(vSpan)),
            clampRect: SIMD4<Float>(
                Float(uMin + insetU), Float(vMin + insetV), Float(uMin + uSpan - insetU), Float(vMin + vSpan - insetV)),
            flags: SIMD4<Float>(
                source.isNV12
                    ? (source.isHDR10PQ ? Float(Self.hdr10ShaderModeBits(referencePQ: resolvedReferencePQ) + 1) : 1)
                    : 0,
                colorMode,
                source.chromaOffset.x, source.chromaOffset.y))
    }

    private func drawPass(
        pipeline: any MTLRenderPipelineState, primary: MetalSource, original: MetalSource?, compare: Bool,
        pqOutput: Bool, suppressDither: Bool = false, suppressPostProcess: Bool = false,
        to destination: any MTLTexture, command: any MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw PipelineError(AppText("无法编码 Metal 预览渲染", "Could not encode Metal preview rendering."))
        }
        let outputSize = VideoSize(width: destination.width, height: destination.height)
        let primaryUniforms = sourceUniforms(for: primary, outputSize: outputSize, pqOutput: pqOutput)
        let originalUniforms =
            original.map { sourceUniforms(for: $0, outputSize: outputSize, pqOutput: pqOutput) } ?? primaryUniforms
        let ditherScale: Float
        let usesDither =
            !suppressDither
            && (pqOutput || primary.needsRec709ToSRGB || primary.isHDR10PQ
                || (compare && ((original?.needsRec709ToSRGB ?? false) || (original?.isHDR10PQ ?? false))))
        if usesDither {
            if destination.pixelFormat == .bgra8Unorm {
                ditherScale = Float(1.0 / 255.0)
            } else if destination.pixelFormat == .bgr10a2Unorm || destination.pixelFormat == .rgb10a2Unorm {
                ditherScale = Float(1.0 / 1023.0)
            } else {
                ditherScale = 0
            }
        } else {
            ditherScale = 0
        }
        let rcasStrength = suppressPostProcess ? 0 : min(1, max(0, globalRCASOverride ?? Self.globalRCASStrength))
        let bilateralChroma = bilateralChromaOverride ?? Self.bilateralChromaEnabled
        let hdr10Deband = !suppressPostProcess && (hdr10DebandOverride ?? Self.hdr10DebandEnabled)
        let postFlags: Float = Float((bilateralChroma ? 1 : 0) | (hdr10Deband ? 2 : 0))
        var uniforms = PreviewUniforms(
            primary: primaryUniforms, original: originalUniforms,
            split: SIMD4<Float>(compare ? 1 : 0, floor(Float(destination.width) * 0.5), ditherScale, 0),
            post: SIMD4<Float>(rcasStrength, postFlags, 0, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(primary.primary, index: 0)
        encoder.setFragmentTexture(primary.chroma ?? primary.primary, index: 1)
        encoder.setFragmentTexture(original?.primary ?? primary.primary, index: 2)
        encoder.setFragmentTexture(original?.chroma ?? original?.primary ?? primary.primary, index: 3)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func presentCachedTexture(
        _ source: any MTLTexture, pqOutput: Bool, to destination: any MTLTexture, command: any MTLCommandBuffer
    ) throws {
        if let pipeline = try renderPipeline(for: destination.pixelFormat) {
            let cached = MetalSource(
                primary: source, chroma: nil, views: [],
                size: VideoSize(width: source.width, height: source.height), contentRect: nil,
                isNV12: false, needsRec709ToSRGB: false)
            try drawPass(
                pipeline: pipeline, primary: cached, original: nil, compare: false, pqOutput: pqOutput,
                to: destination, command: command)
            return
        }
        try copy(source, to: destination, command: command)
    }

    private func encodeDeferredHybridSpatial(
        _ frame: PresentationFrame, recipe: HybridPreviewRecipe, compare: Bool, pqOutput: Bool,
        to destination: any MTLTexture, command: any MTLCommandBuffer
    ) throws -> Bool {
        reusedSpatialOutput = false
        guard let pipeline = try renderPipeline(for: destination.pixelFormat) else { return false }
        let originalSource: MetalSource?
        if compare {
            guard let mappedOriginal = metalSource(for: frame.original) else { return false }
            originalSource = mappedOriginal
        } else {
            originalSource = nil
        }
        if spatial == nil { spatial = SpatialUpscaler(device: device, precision: spatialPrecision) }
        guard let spatial else {
            throw PipelineError(AppText("Spatial 资源不可用", "MetalFX Spatial resources are unavailable."))
        }
        let resources = try spatial.prepare(input: recipe.inputSize, output: frame.outputSize)
        let spatialNext = Key(
            frame: frame.id, generation: frame.generation, compare: false, size: frame.outputSize,
            format: resources.output.pixelFormat.rawValue)
        reusedSpatialOutput = spatialKey == spatialNext
        if !reusedSpatialOutput {
            spatialKey = nil
            guard
                try encodeDeferredHybrid(
                    frame, recipe: recipe, compare: false, pqOutput: false, to: resources.input,
                    size: recipe.inputSize, ignoreContentRect: true, suppressDither: spatialPrecision != .unorm8,
                    suppressPostProcess: true, command: command)
            else { return false }
            resources.scaler.encode(commandBuffer: command)
            spatialKey = spatialNext
            spatialUpscales += 1
        }
        let scaledContent: CGRect?
        if let rect = frame.video.contentRect {
            let scaleX = CGFloat(frame.outputSize.width) / CGFloat(recipe.inputSize.width)
            let scaleY = CGFloat(frame.outputSize.height) / CGFloat(recipe.inputSize.height)
            scaledContent = CGRect(
                x: rect.minX * scaleX, y: rect.minY * scaleY,
                width: rect.width * scaleX, height: rect.height * scaleY)
        } else {
            scaledContent = nil
        }
        let primarySource = MetalSource(
            primary: resources.output, chroma: nil, views: [],
            size: frame.outputSize, contentRect: scaledContent, isNV12: false, needsRec709ToSRGB: false,
            isHDR10PQ: recipe.isHDR10PQ)
        try drawPass(
            pipeline: pipeline, primary: primarySource, original: originalSource, compare: compare, pqOutput: pqOutput,
            to: destination, command: command)
        return true
    }

    private func encodeDeferredHybrid(
        _ frame: PresentationFrame, recipe: HybridPreviewRecipe, compare: Bool, pqOutput: Bool,
        to destination: any MTLTexture, size: VideoSize, ignoreContentRect: Bool = false,
        suppressDither: Bool = false, suppressPostProcess: Bool = false, command: any MTLCommandBuffer
    ) throws -> Bool {
        guard let textureCache else { return false }
        let contentRect = ignoreContentRect ? nil : frame.video.contentRect
        let prevVideo = VideoFrame(
            pixelBuffer: recipe.previous, presentationTime: frame.video.presentationTime,
            duration: frame.video.duration, sequence: frame.video.sequence, arrivalTime: frame.video.arrivalTime,
            contentRect: contentRect)
        let currVideo = VideoFrame(
            pixelBuffer: recipe.current, presentationTime: frame.video.presentationTime,
            duration: frame.video.duration, sequence: frame.video.sequence, arrivalTime: frame.video.arrivalTime,
            contentRect: contentRect)
        guard let srcA = metalSource(for: prevVideo), let srcB = metalSource(for: currVideo),
            let aChroma = srcA.chroma, let bChroma = srcB.chroma
        else { return false }
        func mapNV12Planes(_ buffer: CVReadOnlyPixelBuffer, size: VideoSize) -> (
            luma: any MTLTexture, chroma: any MTLTexture, views: [CVMetalTexture]
        )? {
            var mapped: (any MTLTexture, any MTLTexture, [CVMetalTexture])?
            buffer.withUnsafeBuffer { pixel in
                let half = VideoSize(width: size.width / 2, height: size.height / 2)
                guard
                    let yView = mapTexture(
                        pixel, cache: textureCache, format: .r8Unorm, width: size.width, height: size.height, plane: 0),
                    let uvView = mapTexture(
                        pixel, cache: textureCache, format: .rg8Unorm, width: half.width, height: half.height, plane: 1),
                    let yTex = CVMetalTextureGetTexture(yView),
                    let uvTex = CVMetalTextureGetTexture(uvView)
                else { return }
                mapped = (yTex, uvTex, [yView, uvView])
            }
            return mapped
        }
        guard let lowA = mapNV12Planes(recipe.previousLow, size: recipe.lowSize),
            let lowB = mapNV12Planes(recipe.currentLow, size: recipe.lowSize),
            let lowMid = mapNV12Planes(recipe.midpoint, size: recipe.lowSize)
        else { return false }
        var motionView: CVMetalTexture?
        var forwardMotionView: CVMetalTexture?
        var activeMotionDetailTexture: (any MTLTexture)?
        var useMotion = false
        if let precomputed = recipe.precomputedMotionDetail,
            precomputed.isValid(forDevice: device.registryID)
        {
            command.encodeWaitForEvent(precomputed.event, value: precomputed.signalValue)
            command.addCompletedHandler { _ in withExtendedLifetime(precomputed) {} }
            activeMotionDetailTexture = precomputed.texture
            precomputedMotionUses += 1
            useMotion = true
        } else {
            if let backward = recipe.motionBackward {
                backward.withUnsafeBuffer { pixel in
                    guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_TwoComponent16Half else {
                        return
                    }
                    let w = CVPixelBufferGetWidth(pixel)
                    let h = CVPixelBufferGetHeight(pixel)
                    motionView = mapTexture(
                        pixel, cache: textureCache, format: .rg16Float, width: w, height: h, plane: 0)
                }
            }
            if let forward = recipe.motionForward {
                forward.withUnsafeBuffer { pixel in
                    guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_TwoComponent16Half else {
                        return
                    }
                    let w = CVPixelBufferGetWidth(pixel)
                    let h = CVPixelBufferGetHeight(pixel)
                    forwardMotionView = mapTexture(
                        pixel, cache: textureCache, format: .rg16Float, width: w, height: h, plane: 0)
                }
            }
            let motionTexture = motionView.flatMap { CVMetalTextureGetTexture($0) }
            let forwardMotionTexture = forwardMotionView.flatMap { CVMetalTextureGetTexture($0) }
            if let motionTexture {
                if hybridMotionDetailTexture?.width != recipe.selectSize.width
                    || hybridMotionDetailTexture?.height != recipe.selectSize.height
                {
                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .rgba16Float, width: recipe.selectSize.width, height: recipe.selectSize.height,
                        mipmapped: false)
                    desc.storageMode = .private
                    desc.usage = [.shaderRead, .shaderWrite]
                    hybridMotionDetailTexture = device.makeTexture(descriptor: desc)
                    hybridMotionDetailFrameID = nil
                }
                let hasForward = forwardMotionTexture != nil
                if FrameMailbox.fastPathEnabled, hybridMotionDetailTexture != nil,
                    hybridMotionDetailFrameID == frame.id, hybridMotionDetailHasForward == hasForward
                {
                    activeMotionDetailTexture = hybridMotionDetailTexture
                    useMotion = true
                } else if let detailTex = hybridMotionDetailTexture,
                    let selectPipeline = try selectMotionPipeline(
                        hasForwardMotion: hasForward, sampleMid: recipe.selectSize != recipe.lowSize),
                    let select = command.makeComputeCommandEncoder()
                {
                    let hdrBits = recipe.isHDR10PQ ? Self.hdr10ShaderModeBits(referencePQ: resolvedReferencePQ) : 0
                    let hudDehalo = hudDehaloOverride ?? HybridInterpolator.hudDehaloEnabled
                    let motionFlags =
                        hdrBits | (hudDehalo ? 8 : 0)
                        | (HybridInterpolator.shaderSafeFiniteEnabled ? 16 : 0)
                    var weights = SIMD4<Float>(
                        recipe.phase, recipe.restoresStaticPixels ? 1 : 0, recipe.sharpenStrength,
                        Float(recipe.motionSize.width))
                    var motionParams = SIMD4<Float>(
                        1 / Float(recipe.motionSize.width), 1 / Float(recipe.motionSize.height),
                        Float(recipe.motionSize.width) / Float(recipe.forwardMotionSize.width),
                        Float(motionFlags))
                    select.setComputePipelineState(selectPipeline)
                    select.setTexture(lowA.luma, index: 0)
                    select.setTexture(lowA.chroma, index: 1)
                    select.setTexture(lowB.luma, index: 2)
                    select.setTexture(lowB.chroma, index: 3)
                    select.setTexture(lowMid.luma, index: 4)
                    select.setTexture(motionTexture, index: 5)
                    select.setTexture(detailTex, index: 6)
                    if let forwardMotionTexture { select.setTexture(forwardMotionTexture, index: 7) }
                    select.setBytes(&weights, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    select.setBytes(&motionParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                    select.dispatchThreads(
                        MTLSize(width: recipe.selectSize.width, height: recipe.selectSize.height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                    select.endEncoding()
                    hybridMotionDetailFrameID = frame.id
                    hybridMotionDetailHasForward = hasForward
                    selectMotionDispatches += 1
                    activeMotionDetailTexture = detailTex
                    useMotion = true
                }
            }
        }
        guard let pipeline = try hybridRenderPipeline(for: destination.pixelFormat, hasMotion: useMotion) else {
            return false
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw PipelineError(AppText("无法编码融合混合预览渲染", "Could not encode fused hybrid preview rendering."))
        }
        let primaryUniforms = sourceUniforms(for: srcA, outputSize: size, pqOutput: pqOutput)
        let ditherScale: Float
        if !suppressDither && (pqOutput || srcA.needsRec709ToSRGB || srcA.isHDR10PQ) {
            if destination.pixelFormat == .bgra8Unorm {
                ditherScale = Float(1.0 / 255.0)
            } else if destination.pixelFormat == .bgr10a2Unorm || destination.pixelFormat == .rgb10a2Unorm {
                ditherScale = Float(1.0 / 1023.0)
            } else {
                ditherScale = 0
            }
        } else {
            ditherScale = 0
        }
        let stabilizesSpatialDetail =
            (spatialMovingDetailOverride ?? HybridInterpolator.spatialMovingDetailEnabled) && frame.spatial
        let iconEnvelope = iconEnvelopeOverride ?? HybridInterpolator.iconEnvelopeEnabled
        let hudDehalo = hudDehaloOverride ?? HybridInterpolator.hudDehaloEnabled
        let adaptiveCAS = adaptiveCASOverride ?? HybridInterpolator.adaptiveCASEnabled
        let rcasStrength = suppressPostProcess ? 0 : min(1, max(0, globalRCASOverride ?? Self.globalRCASStrength))
        let bilateralChroma = bilateralChromaOverride ?? Self.bilateralChromaEnabled
        let hdr10Deband = !suppressPostProcess && (hdr10DebandOverride ?? Self.hdr10DebandEnabled)
        let postFlags: Float = Float((bilateralChroma ? 1 : 0) | (hdr10Deband ? 2 : 0))
        let qualityFlags =
            (Self.hybridEdgeRefineEnabled ? 1 : 0) | (hudDehalo ? 4 : 0)
            | (stabilizesSpatialDetail ? 8 : 0) | (iconEnvelope ? 16 : 0) | (adaptiveCAS ? 32 : 0)
        var uniforms = HybridPreviewUniforms(
            primary: primaryUniforms,
            split: SIMD4<Float>(
                compare ? 1 : 0, floor(Float(destination.width) * 0.5), ditherScale,
                Self.hybridWindowAAEnabled ? 1 : 0),
            offsets: SIMD4<Float>(srcA.chromaOffset.x, srcA.chromaOffset.y, srcB.chromaOffset.x, srcB.chromaOffset.y),
            weights: SIMD4<Float>(
                recipe.phase, recipe.restoresStaticPixels ? 1 : 0, recipe.sharpenStrength,
                Float(qualityFlags)),
            post: SIMD4<Float>(rcasStrength, postFlags, 0, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(srcA.primary, index: 0)
        encoder.setFragmentTexture(aChroma, index: 1)
        encoder.setFragmentTexture(srcB.primary, index: 2)
        encoder.setFragmentTexture(bChroma, index: 3)
        encoder.setFragmentTexture(lowA.luma, index: 4)
        encoder.setFragmentTexture(lowA.chroma, index: 5)
        encoder.setFragmentTexture(lowB.luma, index: 6)
        encoder.setFragmentTexture(lowB.chroma, index: 7)
        encoder.setFragmentTexture(lowMid.luma, index: 8)
        encoder.setFragmentTexture(lowMid.chroma, index: 9)
        if useMotion, let detailTex = activeMotionDetailTexture {
            encoder.setFragmentTexture(detailTex, index: 10)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HybridPreviewUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        _ = (srcA.views, srcB.views, lowA.views, lowB.views, lowMid.views, motionView, forwardMotionView)
        return true
    }

    /// Pre-creates preview render and deferred-hybrid compute pipeline states off the display callback,
    /// populating the existing caches so the first presented frame avoids synchronous pipeline compilation.
    func prewarmPipelines(pixelFormats: [MTLPixelFormat] = [.bgr10a2Unorm, .bgra8Unorm]) {
        var seen: Set<UInt> = []
        for format in pixelFormats where seen.insert(format.rawValue).inserted {
            _ = try? renderPipeline(for: format)
            _ = try? hybridRenderPipeline(for: format, hasMotion: false)
            _ = try? hybridRenderPipeline(for: format, hasMotion: true)
        }
        for hasForward in [false, true] {
            for sampleMid in [false, true] {
                _ = try? selectMotionPipeline(hasForwardMotion: hasForward, sampleMid: sampleMid)
            }
        }
    }

    private func selectMotionPipeline(hasForwardMotion: Bool, sampleMid: Bool) throws -> (any MTLComputePipelineState)?
    {
        let key = SelectMotionKey(hasForwardMotion: hasForwardMotion, sampleMid: sampleMid)
        if let existing = selectMotionPipelines[key] { return existing }
        guard let renderLibrary else { return nil }
        let constants = MTLFunctionConstantValues()
        var hasMotion = true
        var hasFwd = hasForwardMotion
        var sampleMidFlag = sampleMid
        constants.setConstantValue(&hasMotion, type: .bool, index: 0)
        constants.setConstantValue(&hasFwd, type: .bool, index: 1)
        constants.setConstantValue(&sampleMidFlag, type: .bool, index: 2)
        let function = try renderLibrary.makeFunction(name: "previewSelectMotion", constantValues: constants)
        let pipeline = try device.makeComputePipelineState(function: function)
        selectMotionPipelines[key] = pipeline
        pipelineCreations += 1
        return pipeline
    }

    private func hybridRenderPipeline(for pixelFormat: MTLPixelFormat, hasMotion: Bool) throws -> (
        any MTLRenderPipelineState
    )? {
        let key = HybridPipelineKey(format: pixelFormat.rawValue, hasMotion: hasMotion)
        if let existing = hybridRenderPipelines[key] { return existing }
        guard let renderLibrary,
            let vertex = renderLibrary.makeFunction(name: "previewVertex")
        else { return nil }
        let constants = MTLFunctionConstantValues()
        var motion = hasMotion
        var fwd = false
        var sampleMid = false
        constants.setConstantValue(&motion, type: .bool, index: 0)
        constants.setConstantValue(&fwd, type: .bool, index: 1)
        constants.setConstantValue(&sampleMid, type: .bool, index: 2)
        let fragment = try renderLibrary.makeFunction(name: "previewHybridFragment", constantValues: constants)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        hybridRenderPipelines[key] = pipeline
        pipelineCreations += 1
        return pipeline
    }

    private func renderPipeline(for pixelFormat: MTLPixelFormat) throws -> (any MTLRenderPipelineState)? {
        if let existing = renderPipelines[pixelFormat] { return existing }
        guard let renderLibrary,
            let vertex = renderLibrary.makeFunction(name: "previewVertex"),
            let fragment = renderLibrary.makeFunction(name: "previewFragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        renderPipelines[pixelFormat] = pipeline
        pipelineCreations += 1
        return pipeline
    }

    private func makeIntermediateTexture(size: VideoSize, format: MTLPixelFormat) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size.width, height: size.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private func encodeOriginal(
        _ frame: PresentationFrame, bounds: CGRect, left: CGRect, to target: any MTLTexture,
        command: any MTLCommandBuffer
    ) throws {
        guard left.width > 0 else { return }
        let original = frame.original
        let size = VideoSize(width: target.width, height: target.height)
        let next = OriginalKey(
            generation: frame.generation, sequence: original.sequence,
            buffer: original.pixelBuffer.withUnsafeBuffer { ObjectIdentifier($0) }, content: original.contentRect,
            canvas: size, format: target.pixelFormat.rawValue)
        let reusable =
            originalWriter.map {
                $0.status == .committed || $0.status == .scheduled || $0.status == .completed
            } ?? false
        if caching, originalKey == next, reusable, let originalTexture {
            try copy(originalTexture, to: target, command: command)
            originalCacheHits += 1
            return
        }
        originalKey = nil
        originalWriter = nil
        if caching, size.pixels <= InputPreset.uhd4K.size.pixels {
            if originalTexture?.width != Int(left.width) || originalTexture?.height != size.height
                || originalTexture?.pixelFormat != target.pixelFormat
            {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: target.pixelFormat, width: Int(left.width), height: size.height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
                originalTexture = device.makeTexture(descriptor: descriptor)
            }
        } else {
            originalTexture = nil
        }
        let image = original.pixelBuffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
        let fitted = fittedPreviewImage(
            image, inputSize: original.size, contentRect: original.contentRect, bounds: bounds)
        try render(fitted, region: left, to: originalTexture ?? target, at: .zero, command: command)
        if let originalTexture {
            try copy(originalTexture, to: target, command: command)
            originalKey = next
            originalWriter = command
        }
        originalRenders += 1
    }

    private func render(
        _ image: CIImage, region: CGRect, to target: any MTLTexture, at point: CGPoint,
        command: any MTLCommandBuffer
    ) throws {
        guard !region.isEmpty else { return }
        let destination = CIRenderDestination(mtlTexture: target, commandBuffer: command)
        destination.colorSpace = PixelConverter.sRGB
        // Store the image's upper row at Metal row zero, for private and drawable textures alike.
        destination.isFlipped = true
        _ = try context.startTask(toRender: image, from: region, to: destination, at: point)
    }

    private func copy(_ source: any MTLTexture, to destination: any MTLTexture, command: any MTLCommandBuffer) throws {
        guard let blit = command.makeBlitCommandEncoder() else {
            throw PipelineError(AppText("无法提交预览缓存", "Could not submit the preview cache."))
        }
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    static let previewShader = """
        #include <metal_stdlib>
        using namespace metal;
        struct SourceUniforms {
            float4 fitRect;
            float4 fitMax;
            float4 uvRect;
            float4 clampRect;
            float4 flags;
        };
        struct PreviewUniforms {
            SourceUniforms primary;
            SourceUniforms original;
            float4 split;
            float4 post;
        };
        struct HybridPreviewUniforms {
            SourceUniforms primary;
            float4 split;
            float4 offsets;
            float4 weights;
            float4 post;
        };
        constant bool previewHasMotion [[function_constant(0)]];
        constant bool previewHasForwardMotion [[function_constant(1)]];
        constant bool previewSampleMid [[function_constant(2)]];
        struct PreviewVertex {
            float4 position [[position]];
        };
        constexpr sampler previewSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler previewNearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
        vertex PreviewVertex previewVertex(uint vid [[vertex_id]]) {
            constexpr float2 positions[3] = {
                float2(-1.0f, -1.0f),
                float2(3.0f, -1.0f),
                float2(-1.0f, 3.0f)
            };
            PreviewVertex out;
            out.position = float4(positions[vid], 0.0f, 1.0f);
            return out;
        }
        inline half3 rec709ToSRGB(half3 value) {
            float3 v = clamp(float3(value), 0.0f, 1.0f);
            // Match macOS CGColorSpace.itur_709 (BT.1886 gamma 2.4) -> sRGB to <= 1/255 across 0..255.
            float3 low = 12.92f * pow(v, 2.4f);
            float3 high = fma(1.055f, v, -0.055f);
            return half3(saturate(select(high, low, v <= 0.0906066f)));
        }
        inline half3 encodeSDRToBT2020PQ(half3 rgb, bool fromRec709) {
            float3 v = clamp(float3(rgb), 0.0f, 1.0f);
            float3 lin709;
            if (fromRec709) {
                lin709 = pow(v, float3(2.4f));
            } else {
                float3 low = v * (1.0f / 12.92f);
                float3 high = pow((v + 0.055f) * (1.0f / 1.055f), float3(2.4f));
                lin709 = select(high, low, v <= 0.04045f);
            }
            // ITU-R BT.2087 Rec.709 -> BT.2020 linear primaries scaled to 100-nit reference white / 10000 nits.
            float3 lin2020 = float3(
                dot(lin709, float3(0.6274039f, 0.3292830f, 0.0433131f)),
                dot(lin709, float3(0.0690973f, 0.9195404f, 0.0113623f)),
                dot(lin709, float3(0.0163914f, 0.0880133f, 0.8955953f)));
            float3 y = max(lin2020, 0.0f) * 0.01f;
            constexpr float m1 = 0.1593017578125f;
            constexpr float m2 = 78.84375f;
            constexpr float c1 = 0.8359375f;
            constexpr float c2 = 18.8515625f;
            constexpr float c3 = 18.6875f;
            float3 ym1 = pow(y, float3(m1));
            float3 pq = pow((c1 + c2 * ym1) / (1.0f + c3 * ym1), float3(m2));
            return half3(saturate(select(pq, float3(0.0f), y <= 0.0f)));
        }
        inline half3 finalizePreviewColor(half3 rgb, float colorMode) {
            if (colorMode > 2.5f) {
                return encodeSDRToBT2020PQ(rgb, true);
            }
            if (colorMode > 1.5f) {
                return encodeSDRToBT2020PQ(rgb, false);
            }
            if (colorMode > 0.5f) {
                return rec709ToSRGB(rgb);
            }
            return rgb;
        }
        inline half3 decodeYCbCr(half y, half2 cbcr, uint hdrMode) {
            if (hdrMode == 3u) {
                // ITU-R BT.2100 / BT.2020 reference PQ decode: exact non-constant-luminance matrix,
                // no chroma boost, and no shadow gamma crush (PLAYGLIDE_HDR10_REFERENCE_PQ=1 / Reference style).
                half yClamped = saturate(y);
                return saturate(half3(
                    fma(half(1.4746), cbcr.y, yClamped),
                    fma(half(-0.5713531), cbcr.y, fma(half(-0.1645531), cbcr.x, yClamped)),
                    fma(half(1.8814), cbcr.x, yClamped)));
            }
            if (hdrMode >= 1u) {
                half yPos = max(half(0.0), y);
                half yAnchored;
                half2 cBoost;
                if (hdrMode == 2u) {
                    // C1-smooth near-black toe: Y=16 maps to strict 0.0 OLED black while keeping Y=17..33 shadow steps.
                    half t = saturate(yPos * half(1.0 / 0.08));
                    yAnchored = yPos * mix(half(0.25), half(1.0), t);
                    cBoost = cbcr * mix(half(0.75), half(1.12), t);
                } else {
                    // Legacy hard black-floor clamp (PLAYGLIDE_HDR10_SOFT_TOE=0).
                    yAnchored = max(half(0.0), (yPos - half(0.042)) * half(1.0 / 0.958));
                    cBoost = cbcr * half(1.12);
                }
                half3 rgb = saturate(half3(
                    fma(half(1.4746), cBoost.y, yAnchored),
                    fma(half(-0.57135), cBoost.y, fma(half(-0.16455), cBoost.x, yAnchored)),
                    fma(half(1.8814), cBoost.x, yAnchored)));
                // Subtle S-curve in PQ domain deepens shadow contrast while preserving 100..1000 nit highlights.
                return saturate(pow(rgb, half3(1.10)));
            }
            return saturate(half3(
                fma(half(1.5748), cbcr.y, y),
                fma(half(-0.468124), cbcr.y, fma(half(-0.187324), cbcr.x, y)),
                fma(half(1.8556), cbcr.x, y)));
        }
        inline half2 sampleBilateralChroma(
            texture2d<half, access::sample> lumaTex,
            texture2d<half, access::sample> chromaTex,
            float2 uv, float2 chromaOffset, half centerRawY
        ) {
            float2 cSize = float2(chromaTex.get_width(), chromaTex.get_height());
            float2 invCSize = 1.0f / cSize;
            float2 cPos = (uv + chromaOffset) * cSize - 0.5f;
            float2 cBase = floor(cPos);
            float2 f = saturate(cPos - cBase);
            float2 c00 = (cBase + 0.5f) * invCSize;
            float2 c10 = c00 + float2(invCSize.x, 0.0f);
            float2 c01 = c00 + float2(0.0f, invCSize.y);
            float2 c11 = c00 + invCSize;

            half sw00 = half((1.0f - f.x) * (1.0f - f.y));
            half sw10 = half(f.x * (1.0f - f.y));
            half sw01 = half((1.0f - f.x) * f.y);
            half sw11 = half(f.x * f.y);

            half y00 = lumaTex.sample(previewSampler, c00 - chromaOffset).r;
            half y10 = lumaTex.sample(previewSampler, c10 - chromaOffset).r;
            half y01 = lumaTex.sample(previewSampler, c01 - chromaOffset).r;
            half y11 = lumaTex.sample(previewSampler, c11 - chromaOffset).r;

            half d00 = centerRawY - y00;
            half d10 = centerRawY - y10;
            half d01 = centerRawY - y01;
            half d11 = centerRawY - y11;
            half w00 = sw00 / fma(d00 * d00, half(1200.0), half(1.0));
            half w10 = sw10 / fma(d10 * d10, half(1200.0), half(1.0));
            half w01 = sw01 / fma(d01 * d01, half(1200.0), half(1.0));
            half w11 = sw11 / fma(d11 * d11, half(1200.0), half(1.0));
            half wSum = w00 + w10 + w01 + w11;

            half2 uv00 = chromaTex.sample(previewNearestSampler, c00).rg;
            half2 uv10 = chromaTex.sample(previewNearestSampler, c10).rg;
            half2 uv01 = chromaTex.sample(previewNearestSampler, c01).rg;
            half2 uv11 = chromaTex.sample(previewNearestSampler, c11).rg;
            return (uv00 * w00 + uv10 * w10 + uv01 * w01 + uv11 * w11) / max(wSum, half(1e-4));
        }
        // Gradient-preserving 2-tap symmetric integer-offset luma debanding for 8-bit UVC HDR10 PQ inputs.
        // Uses two L1-coherent nearest texel taps (zero bilinear edge bleed, zero trig, branchless ALU) so
        // 1..2 LSB PQ quantization bands blend continuously into 10-bit output while fine text/edges (>3 LSB)
        // strictly bypass.
        inline half debandHDR10Luma(
            texture2d<half, access::sample> lumaTex,
            float2 uv, float2 px, float4 clampRect, half rawY
        ) {
            float h0 = fract(52.9829189f * fract(dot(px, float2(0.06711056f, 0.00583715f))));
            float h1 = fract(h0 * 1.6180339f + 0.37f);
            float2 texStep = 1.0f / float2(lumaTex.get_width(), lumaTex.get_height());
            float dx = floor(1.0f + 9.0f * h0);
            float sy = fract(h1 * 2.0f);
            float dy = floor(1.0f + 9.0f * sy) * ((h1 >= 0.5f) ? 1.0f : -1.0f);
            float2 dir = float2(dx, dy) * texStep;

            half y0 = lumaTex.sample(previewNearestSampler, clamp(uv + dir, clampRect.xy, clampRect.zw)).r;
            half y1 = lumaTex.sample(previewNearestSampler, clamp(uv - dir, clampRect.xy, clampRect.zw)).r;
            half maxDiffY = max(abs(y0 - rawY), abs(y1 - rawY));
            half wY = half(1.0) - smoothstep(half(1.8 / 255.0), half(3.2 / 255.0), maxDiffY);
            return mix(rawY, (y0 + y1) * half(0.5), wY);
        }
        inline half3 sampleSource(
            texture2d<half, access::sample> primaryTex,
            texture2d<half, access::sample> chromaTex,
            SourceUniforms src,
            float2 px,
            bool bilateralChroma = false,
            bool hdr10Deband = false
        ) {
            if (px.x < src.fitRect.x || px.x >= src.fitMax.x || px.y < src.fitRect.y || px.y >= src.fitMax.y) {
                return half3(0.0h);
            }
            float2 normalized = (px - src.fitRect.xy) * src.fitRect.zw;
            float2 uv = clamp(fma(normalized, src.uvRect.zw, src.uvRect.xy), src.clampRect.xy, src.clampRect.zw);
            half3 rgb;
            uint hdrMode = src.flags.x > 1.5f ? uint(src.flags.x - 0.5f) : 0u;
            if (src.fitMax.z > 0.0f) {
                float2 d = src.fitMax.zw;
                float2 uv0 = clamp(uv + float2(-d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
                float2 uv1 = clamp(uv + float2( d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
                float2 uv2 = clamp(uv + float2(-d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
                float2 uv3 = clamp(uv + float2( d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
                if (src.flags.x > 0.5f) {
                    half luma = (primaryTex.sample(previewSampler, uv0).r
                               + primaryTex.sample(previewSampler, uv1).r
                               + primaryTex.sample(previewSampler, uv2).r
                               + primaryTex.sample(previewSampler, uv3).r) * half(0.25);
                    half2 chroma = (chromaTex.sample(previewSampler, uv0 + src.flags.zw).rg
                                  + chromaTex.sample(previewSampler, uv1 + src.flags.zw).rg
                                  + chromaTex.sample(previewSampler, uv2 + src.flags.zw).rg
                                  + chromaTex.sample(previewSampler, uv3 + src.flags.zw).rg) * half(0.25);
                    half y = fma(luma, half(255.0 / 219.0), half(-16.0 / 219.0));
                    half2 cbcr = fma(chroma, half(255.0 / 224.0), half(-128.0 / 224.0));
                    rgb = decodeYCbCr(y, cbcr, hdrMode);
                } else {
                    rgb = (primaryTex.sample(previewSampler, uv0).rgb
                         + primaryTex.sample(previewSampler, uv1).rgb
                         + primaryTex.sample(previewSampler, uv2).rgb
                         + primaryTex.sample(previewSampler, uv3).rgb) * half(0.25);
                }
            } else if (src.flags.x > 0.5f) {
                half rawY = primaryTex.sample(previewSampler, uv).r;
                // flags.zw moves from chroma texel centers to the surface's 4:2:0 sample positions.
                half2 chroma = bilateralChroma
                    ? sampleBilateralChroma(primaryTex, chromaTex, uv, src.flags.zw, rawY)
                    : chromaTex.sample(previewSampler, uv + src.flags.zw).rg;
                if (hdr10Deband && hdrMode >= 1u) {
                    rawY = debandHDR10Luma(primaryTex, uv, px, src.clampRect, rawY);
                }
                half y = fma(rawY, half(255.0 / 219.0), half(-16.0 / 219.0));
                half2 cbcr = fma(chroma, half(255.0 / 224.0), half(-128.0 / 224.0));
                rgb = decodeYCbCr(y, cbcr, hdrMode);
            } else {
                rgb = primaryTex.sample(previewSampler, uv).rgb;
            }
            return finalizePreviewColor(rgb, src.flags.y);
        }
        inline half triangularDither(float2 px) {
            float n0 = fract(52.9829189f * fract(dot(px, float2(0.06711056f, 0.00583715f))));
            float n1 = fract(52.9829189f * fract(dot(px + float2(17.0f, 31.0f), float2(0.06711056f, 0.00583715f))));
            return half((n0 - n1) * 0.5f);
        }
        // 5-tap overshoot-clamped RCAS with high-contrast static-text guard (zero ringing, zero white halos).
        inline half previewRCASLuma(half3 rgb, bool bt2020) {
            return bt2020 ? dot(rgb, half3(0.2627, 0.6780, 0.0593))
                          : dot(rgb, half3(0.2126, 0.7152, 0.0722));
        }
        inline half3 previewApplyRCAS(half3 c, half3 n, half3 s, half3 e, half3 w, half strength, bool bt2020) {
            half lC = previewRCASLuma(c, bt2020);
            half lN = previewRCASLuma(n, bt2020);
            half lS = previewRCASLuma(s, bt2020);
            half lE = previewRCASLuma(e, bt2020);
            half lW = previewRCASLuma(w, bt2020);
            half lMin = min(lC, min(min(lN, lS), min(lE, lW)));
            half lMax = max(lC, max(max(lN, lS), max(lE, lW)));
            half contrast = lMax - lMin;
            half textGuard = half(1.0) - smoothstep(half(0.55), half(0.75), contrast);
            half amp = clamp(min(lMin, half(1.0) - lMax) / max(lMax, half(1e-4)), half(0.0), half(1.0));
            half lobe = -half(0.1875) * strength * sqrt(amp) * textGuard;
            half3 out = (c + lobe * (n + s + e + w)) / (half(1.0) + half(4.0) * lobe);
            half3 rgbMin = min(c, min(min(n, s), min(e, w)));
            half3 rgbMax = max(c, max(max(n, s), max(e, w)));
            return clamp(out, rgbMin, rgbMax);
        }
        inline half previewApplyLumaRCAS(half c, half n, half s, half e, half w, half strength) {
            half lMin = min(c, min(min(n, s), min(e, w)));
            half lMax = max(c, max(max(n, s), max(e, w)));
            half contrast = lMax - lMin;
            half textGuard = half(1.0) - smoothstep(half(0.55), half(0.75), contrast);
            half amp = clamp(min(lMin, half(1.0) - lMax) / max(lMax, half(1e-4)), half(0.0), half(1.0));
            half lobe = -half(0.1875) * strength * sqrt(amp) * textGuard;
            return clamp((c + lobe * (n + s + e + w)) / (half(1.0) + half(4.0) * lobe), lMin, lMax);
        }
        fragment half4 previewFragment(
            PreviewVertex in [[stage_in]],
            texture2d<half, access::sample> primaryTex [[texture(0)]],
            texture2d<half, access::sample> primaryChroma [[texture(1)]],
            texture2d<half, access::sample> originalTex [[texture(2)]],
            texture2d<half, access::sample> originalChroma [[texture(3)]],
            constant PreviewUniforms &uniforms [[buffer(0)]]
        ) {
            float2 px = in.position.xy;
            uint postFlags = uint(uniforms.post.y + 0.5f);
            bool bilateralChroma = (postFlags & 1u) != 0u;
            bool hdr10Deband = (postFlags & 2u) != 0u;
            bool useOriginal = uniforms.split.x > 0.5f && px.x < uniforms.split.y;
            SourceUniforms activeSrc = useOriginal ? uniforms.original : uniforms.primary;
            half3 rgb = useOriginal
                ? sampleSource(originalTex, originalChroma, activeSrc, px, bilateralChroma, hdr10Deband)
                : sampleSource(primaryTex, primaryChroma, activeSrc, px, bilateralChroma, hdr10Deband);
            if (uniforms.post.x > 0.001f
                && px.x >= activeSrc.fitRect.x && px.x < activeSrc.fitMax.x
                && px.y >= activeSrc.fitRect.y && px.y < activeSrc.fitMax.y) {
                half3 n = useOriginal
                    ? sampleSource(originalTex, originalChroma, activeSrc, px + float2(0.0f, -1.0f), bilateralChroma, hdr10Deband)
                    : sampleSource(primaryTex, primaryChroma, activeSrc, px + float2(0.0f, -1.0f), bilateralChroma, hdr10Deband);
                half3 s = useOriginal
                    ? sampleSource(originalTex, originalChroma, activeSrc, px + float2(0.0f, 1.0f), bilateralChroma, hdr10Deband)
                    : sampleSource(primaryTex, primaryChroma, activeSrc, px + float2(0.0f, 1.0f), bilateralChroma, hdr10Deband);
                half3 e = useOriginal
                    ? sampleSource(originalTex, originalChroma, activeSrc, px + float2(1.0f, 0.0f), bilateralChroma, hdr10Deband)
                    : sampleSource(primaryTex, primaryChroma, activeSrc, px + float2(1.0f, 0.0f), bilateralChroma, hdr10Deband);
                half3 w = useOriginal
                    ? sampleSource(originalTex, originalChroma, activeSrc, px + float2(-1.0f, 0.0f), bilateralChroma, hdr10Deband)
                    : sampleSource(primaryTex, primaryChroma, activeSrc, px + float2(-1.0f, 0.0f), bilateralChroma, hdr10Deband);
                bool bt2020 = activeSrc.flags.x > 1.5f;
                rgb = previewApplyRCAS(rgb, n, s, e, w, half(uniforms.post.x), bt2020);
            }
            if (uniforms.split.z > 0.0f) {
                rgb = saturate(rgb + half3(triangularDither(px) * half(uniforms.split.z)));
            }
            return half4(rgb, half(1.0));
        }
        // Bit-level IEEE 754 exponent checks survive Metal's default fast-math optimization.
        inline bool previewIsFiniteHalf2(half2 value) {
            return (as_type<ushort>(value.x) & 0x7C00u) != 0x7C00u
                && (as_type<ushort>(value.y) & 0x7C00u) != 0x7C00u;
        }
        inline bool previewIsFiniteMotion(half2 raw, float2 value, bool safeFinite) {
            if (safeFinite) return previewIsFiniteHalf2(raw);
            return isfinite(value.x) && isfinite(value.y);
        }
        inline half previewNv12Luma(half luma) {
            return fma(luma, half(255.0 / 219.0), half(-16.0 / 219.0));
        }
        inline void sampleStaticPlane(
            texture2d<half, access::sample> lumaTex,
            texture2d<half, access::sample> chromaTex,
            float2 uv, float2 chromaOffset, SourceUniforms src, bool windowAA, bool bilateralChroma,
            thread half &outY, thread half2 &outUV
        ) {
            if (windowAA) {
                float2 d = src.fitMax.zw;
                float2 uv0 = clamp(uv + float2(-d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
                float2 uv1 = clamp(uv + float2( d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
                float2 uv2 = clamp(uv + float2(-d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
                float2 uv3 = clamp(uv + float2( d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
                outY = (lumaTex.sample(previewSampler, uv0).r
                      + lumaTex.sample(previewSampler, uv1).r
                      + lumaTex.sample(previewSampler, uv2).r
                      + lumaTex.sample(previewSampler, uv3).r) * half(0.25);
                outUV = (chromaTex.sample(previewSampler, uv0 + chromaOffset).rg
                       + chromaTex.sample(previewSampler, uv1 + chromaOffset).rg
                       + chromaTex.sample(previewSampler, uv2 + chromaOffset).rg
                       + chromaTex.sample(previewSampler, uv3 + chromaOffset).rg) * half(0.25);
            } else {
                outY = lumaTex.sample(previewSampler, uv).r;
                outUV = bilateralChroma
                    ? sampleBilateralChroma(lumaTex, chromaTex, uv, chromaOffset, outY)
                    : chromaTex.sample(previewSampler, uv + chromaOffset).rg;
            }
        }
        inline half3 previewLowBlur(
            texture2d<half, access::sample> luma, texture2d<half, access::sample> chroma,
            float2 uv, uint hdrMode
        ) {
            float2 step = 1.0f / float2(luma.get_width(), luma.get_height());
            half y = (luma.sample(previewSampler, uv + float2(-step.x, -step.y)).r
                    + luma.sample(previewSampler, uv + float2(step.x, -step.y)).r
                    + luma.sample(previewSampler, uv + float2(-step.x, step.y)).r
                    + luma.sample(previewSampler, uv + float2(step.x, step.y)).r) * half(0.25);
            half2 cbcr = fma(chroma.sample(previewSampler, uv).rg, half(255.0 / 224.0), half(-128.0 / 224.0));
            return decodeYCbCr(previewNv12Luma(y), cbcr, hdrMode);
        }
        // Local 3x3 envelope breakout with low-contrast background gating: keeps static fine text at staticW == 1.0
        // while preserving fast-moving midpoint icons gliding over smooth static backgrounds.
        inline half previewIconEnvelopeRelease(
            texture2d<half, access::sample> lowA, texture2d<half, access::sample> lowAChroma,
            texture2d<half, access::sample> lowB, texture2d<half, access::sample> lowBChroma,
            texture2d<half, access::sample> lowMid, texture2d<half, access::sample> lowMidChroma,
            float2 uv
        ) {
            float2 lStep = 1.0f / float2(lowA.get_width(), lowA.get_height());
            half minY = half(1.0);
            half maxY = half(0.0);
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    float2 p = uv + float2(float(dx), float(dy)) * lStep;
                    half ya = saturate(previewNv12Luma(lowA.sample(previewSampler, p).r));
                    half yb = saturate(previewNv12Luma(lowB.sample(previewSampler, p).r));
                    minY = min(minY, min(ya, yb));
                    maxY = max(maxY, max(ya, yb));
                }
            }
            // Include +/-2 cardinal neighbors to cover VT's 2-texel blur footprint around static fine text.
            const float2 haloOffsets[4] = {
                float2(-2.0f, 0.0f), float2(2.0f, 0.0f), float2(0.0f, -2.0f), float2(0.0f, 2.0f)
            };
            for (int i = 0; i < 4; ++i) {
                float2 p = uv + haloOffsets[i] * lStep;
                half ya = saturate(previewNv12Luma(lowA.sample(previewSampler, p).r));
                half yb = saturate(previewNv12Luma(lowB.sample(previewSampler, p).r));
                minY = min(minY, min(ya, yb));
                maxY = max(maxY, max(ya, yb));
            }
            half rangeY = maxY - minY;
            if (rangeY >= half(0.08)) return half(0.0);
            float2 cStep = 1.0f / float2(lowAChroma.get_width(), lowAChroma.get_height());
            half2 minC = half2(1.0);
            half2 maxC = half2(0.0);
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    float2 p = uv + float2(float(dx), float(dy)) * cStep;
                    half2 ca = lowAChroma.sample(previewSampler, p).rg;
                    half2 cb = lowBChroma.sample(previewSampler, p).rg;
                    minC = min(minC, min(ca, cb));
                    maxC = max(maxC, max(ca, cb));
                }
            }
            half2 rangeC = (maxC - minC) * half(255.0 / 224.0);
            half maxRangeC = max(rangeC.x, rangeC.y);
            if (maxRangeC >= half(0.07)) return half(0.0);
            half midY = saturate(previewNv12Luma(lowMid.sample(previewSampler, uv).r));
            half2 midC = lowMidChroma.sample(previewSampler, uv).rg;
            half lumaBreak = max(half(0.0), max(minY - midY, midY - maxY));
            half2 chromaOver = max(half2(0.0), max(minC - midC, midC - maxC)) * half(255.0 / 224.0);
            half chromaBreak = length(chromaOver);
            half bgSmooth = (half(1.0) - smoothstep(half(0.03), half(0.08), rangeY))
                * (half(1.0) - smoothstep(half(0.03), half(0.07), maxRangeC));
            half breakout = max(
                smoothstep(half(0.065), half(0.14), lumaBreak),
                smoothstep(half(0.055), half(0.12), chromaBreak));
            return bgSmooth * breakout;
        }
        inline float4 previewCatmullRom(texture2d<half, access::sample> image, float2 uv, bool antiRing) {
            float2 size = float2(image.get_width(), image.get_height());
            float2 position = uv * size;
            float2 center = floor(position - 0.5f) + 0.5f;
            float2 f = position - center;
            float2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
            float2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
            float2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
            float2 w3 = f * f * (-0.5f + 0.5f * f);
            float2 w12 = w1 + w2;
            float2 p0 = (center - 1.0f) / size, p12 = (center + w2 / w12) / size, p3 = (center + 2.0f) / size;
            float4 result = float4(image.sample(previewSampler, float2(p0.x, p0.y))) * w0.x * w0.y;
            result += float4(image.sample(previewSampler, float2(p12.x, p0.y))) * w12.x * w0.y;
            result += float4(image.sample(previewSampler, float2(p3.x, p0.y))) * w3.x * w0.y;
            result += float4(image.sample(previewSampler, float2(p0.x, p12.y))) * w0.x * w12.y;
            result += float4(image.sample(previewSampler, float2(p12.x, p12.y))) * w12.x * w12.y;
            result += float4(image.sample(previewSampler, float2(p3.x, p12.y))) * w3.x * w12.y;
            result += float4(image.sample(previewSampler, float2(p0.x, p3.y))) * w0.x * w3.y;
            result += float4(image.sample(previewSampler, float2(p12.x, p3.y))) * w12.x * w3.y;
            result += float4(image.sample(previewSampler, float2(p3.x, p3.y))) * w3.x * w3.y;
            if (antiRing) {
                float2 c00 = center / size;
                float2 c11 = (center + 1.0f) / size;
                float s00 = float(image.sample(previewNearestSampler, float2(c00.x, c00.y)).r);
                float s10 = float(image.sample(previewNearestSampler, float2(c11.x, c00.y)).r);
                float s01 = float(image.sample(previewNearestSampler, float2(c00.x, c11.y)).r);
                float s11 = float(image.sample(previewNearestSampler, float2(c11.x, c11.y)).r);
                float lo = min(min(s00, s10), min(s01, s11));
                float hi = max(max(s00, s10), max(s01, s11));
                result.r = clamp(result.r, lo, hi);
            }
            return result;
        }
        inline half previewPatchDiff(texture2d<half, access::sample> img, float2 uv, float2 step,
                                     half m0, half m1, half m2, half m3, half m4,
                                     half wg1, half wg2, half wg3, half wg4, half invW) {
            half d = abs(img.sample(previewSampler, uv).r - m0);
            d += wg1 * abs(img.sample(previewSampler, uv + float2(step.x, 0.0f)).r - m1);
            d += wg2 * abs(img.sample(previewSampler, uv - float2(step.x, 0.0f)).r - m2);
            d += wg3 * abs(img.sample(previewSampler, uv + float2(0.0f, step.y)).r - m3);
            d += wg4 * abs(img.sample(previewSampler, uv - float2(0.0f, step.y)).r - m4);
            return d * invW;
        }
        kernel void previewSelectMotion(
            texture2d<half, access::sample> lowA [[texture(0)]],
            texture2d<half, access::sample> lowAChroma [[texture(1)]],
            texture2d<half, access::sample> lowB [[texture(2)]],
            texture2d<half, access::sample> lowBChroma [[texture(3)]],
            texture2d<half, access::sample> lowMid [[texture(4)]],
            texture2d<half, access::sample> motion [[texture(5)]],
            texture2d<half, access::write> detailOut [[texture(6)]],
            texture2d<half, access::sample> forwardMotion [[texture(7), function_constant(previewHasForwardMotion)]],
            constant float4 &weights [[buffer(0)]],
            constant float4 &motionScale [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            uint w = detailOut.get_width(), h = detailOut.get_height();
            if (gid.x >= w || gid.y >= h) return;
            float2 lowSize = float2(lowA.get_width(), lowA.get_height());
            float2 lowStep = 1.0f / lowSize;
            float2 uv = (float2(gid) + 0.5f) / float2(w, h);
            uint motionFlags = uint(motionScale.w + 0.5f);
            uint hdrMode = motionFlags & 3u;
            bool hudDehalo = (motionFlags & 8u) != 0u;
            bool safeFinite = (motionFlags & 16u) != 0u;
            bool lowStatic = false;
            if (weights.y > 0.5f) {
                half3 la = previewLowBlur(lowA, lowAChroma, uv, hdrMode);
                half3 lb = previewLowBlur(lowB, lowBChroma, uv, hdrMode);
                lowStatic = length(la - lb) < half(0.012);
            }
            half2 centerRaw = motion.sample(previewNearestSampler, uv).rg;
            float2 centerV = float2(centerRaw);
            bool centerFinite = previewIsFiniteMotion(centerRaw, centerV, safeFinite);
            bool centerSmall = !centerFinite || (abs(centerV.x) < 0.25f && abs(centerV.y) < 0.25f);
            if (lowStatic && centerSmall) {
                detailOut.write(half4(half(0.0), half(0.0), half(2.0), half(0.0)), gid);
                return;
            }
            float fwdScale = motionScale.z;
            half2 centerFwdRaw = previewHasForwardMotion
                ? forwardMotion.sample(previewNearestSampler, uv).rg : half2(half(0.0));
            float2 centerFwdV = previewHasForwardMotion ? -float2(centerFwdRaw) * fwdScale : float2(0.0f);
            float2 gridSize = float2(motion.get_width(), motion.get_height());
            float2 gridStep = 1.0f / gridSize;
            float2 gridFrac = fract(uv * gridSize);
            float sx = gridFrac.x < 0.5f ? -1.0f : 1.0f;
            float sy = gridFrac.y < 0.5f ? -1.0f : 1.0f;
            float t = weights.x;
            half m0, m1, m2, m3, m4;
            if (previewSampleMid) {
                m0 = lowMid.sample(previewSampler, uv).r;
                m1 = lowMid.sample(previewSampler, uv + float2(lowStep.x, 0.0f)).r;
                m2 = lowMid.sample(previewSampler, uv - float2(lowStep.x, 0.0f)).r;
                m3 = lowMid.sample(previewSampler, uv + float2(0.0f, lowStep.y)).r;
                m4 = lowMid.sample(previewSampler, uv - float2(0.0f, lowStep.y)).r;
            } else {
                uint x0 = gid.x, y0 = gid.y;
                uint xm = x0 > 0 ? x0 - 1 : 0;
                uint xp = x0 + 1 < w ? x0 + 1 : w - 1;
                uint ym = y0 > 0 ? y0 - 1 : 0;
                uint yp = y0 + 1 < h ? y0 + 1 : h - 1;
                m0 = lowMid.read(uint2(x0, y0)).r;
                m1 = lowMid.read(uint2(xp, y0)).r;
                m2 = lowMid.read(uint2(xm, y0)).r;
                m3 = lowMid.read(uint2(x0, yp)).r;
                m4 = lowMid.read(uint2(x0, ym)).r;
            }
            half wg1 = half(1.0) / (half(1.0) + half(16.0) * abs(m1 - m0));
            half wg2 = half(1.0) / (half(1.0) + half(16.0) * abs(m2 - m0));
            half wg3 = half(1.0) / (half(1.0) + half(16.0) * abs(m3 - m0));
            half wg4 = half(1.0) / (half(1.0) + half(16.0) * abs(m4 - m0));
            half invW = half(1.0) / (half(1.0) + wg1 + wg2 + wg3 + wg4);
            const float2 probeOffsets[6] = {
                float2(0.0f, 0.0f), float2(sx, 0.0f), float2(0.0f, sy), float2(sx, sy),
                float2(-sx, 0.0f), float2(0.0f, -sy)
            };
            float2 bestDUV = float2(0.0f);
            float2 bestV = float2(0.0f);
            half bestScore = half(1.0);
            half bestErrA = half(1.0);
            half bestErrB = half(1.0);
            float2 lastV = float2(1e6f);
            int totalCandidates = previewHasForwardMotion ? 7 : 6;
            for (int i = 0; i < totalCandidates; ++i) {
                if (i == 4 && bestScore < half(0.015)) break;
                if (i == 5 && bestScore < half(0.022)) break;
                half2 rawV;
                float2 v;
                if (i == 0) {
                    rawV = centerRaw;
                    v = centerV;
                } else if (i < 4) {
                    rawV = motion.sample(previewNearestSampler, uv + probeOffsets[i] * gridStep).rg;
                    v = float2(rawV);
                } else if (previewHasForwardMotion && i == 4) {
                    rawV = centerFwdRaw;
                    v = centerFwdV;
                } else {
                    int idx = previewHasForwardMotion ? (i - 1) : i;
                    rawV = motion.sample(previewNearestSampler, uv + probeOffsets[idx] * gridStep).rg;
                    v = float2(rawV);
                }
                if (!previewIsFiniteMotion(rawV, v, safeFinite) || (abs(v.x) < 0.25f && abs(v.y) < 0.25f)) continue;
                if (i > 0 && ((centerFinite && abs(v.x - centerV.x) < 0.25f && abs(v.y - centerV.y) < 0.25f)
                           || (abs(v.x - lastV.x) < 0.25f && abs(v.y - lastV.y) < 0.25f)
                           || (abs(v.x - bestV.x) < 0.25f && abs(v.y - bestV.y) < 0.25f))) continue;
                lastV = v;
                float2 dUV = v * motionScale.xy;
                float2 uvA = uv + t * dUV;
                float2 uvB = uv - (1.0f - t) * dUV;
                half eA = previewPatchDiff(lowA, uvA, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
                half eB = previewPatchDiff(lowB, uvB, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
                half score = min(eA, eB) + half(0.5) * max(eA, eB);
                if (score < bestScore) {
                    bestScore = score;
                    bestDUV = dUV;
                    bestV = v;
                    bestErrA = eA;
                    bestErrB = eB;
                    if (score < half(0.010)) break;
                }
            }
            if (hudDehalo && bestScore >= half(0.015) && (abs(bestV.x) >= 0.25f || abs(bestV.y) >= 0.25f)) {
                float2 uvA = uv + t * bestDUV;
                float2 uvB = uv - (1.0f - t) * bestDUV;
                if (bestErrB < half(0.018) && bestErrA > bestErrB + half(0.025)) {
                    half occA = abs(lowA.sample(previewSampler, uvA).r - lowB.sample(previewSampler, uvA).r)
                        * half(255.0 / 219.0);
                    if (occA < half(0.025)) { bestScore = min(bestScore, bestErrB + half(0.006)); }
                } else if (bestErrA < half(0.018) && bestErrB > bestErrA + half(0.025)) {
                    half occB = abs(lowA.sample(previewSampler, uvB).r - lowB.sample(previewSampler, uvB).r)
                        * half(255.0 / 219.0);
                    if (occB < half(0.025)) { bestScore = min(bestScore, bestErrA + half(0.006)); }
                }
            }
            if (hudDehalo && centerSmall && !lowStatic && bestScore >= half(0.015)) {
                // Gate far-distance (+/-2..3 macroblock) background probes on local spatial contrast plus a nearby
                // static stroke anchor so dark or subtly moving MV=0 backgrounds never pay 80 extra texture fetches.
                const float2 gateOffsets[9] = {
                    float2(0.0f, 0.0f),
                    float2(0.25f, 0.0f), float2(-0.25f, 0.0f), float2(0.0f, 0.25f), float2(0.0f, -0.25f),
                    float2(0.50f, 0.0f), float2(-0.50f, 0.0f), float2(0.0f, 0.50f), float2(0.0f, -0.50f)
                };
                half minA = half(1.0), maxA = half(0.0);
                half minB = half(1.0), maxB = half(0.0);
                half minStaticDiff = half(1.0);
                for (int g = 0; g < 9; ++g) {
                    float2 gp = uv + gateOffsets[g] * gridStep;
                    half ga = lowA.sample(previewSampler, gp).r;
                    half gb = lowB.sample(previewSampler, gp).r;
                    minA = min(minA, ga);
                    maxA = max(maxA, ga);
                    minB = min(minB, gb);
                    maxB = max(maxB, gb);
                    minStaticDiff = min(minStaticDiff, abs(ga - gb));
                }
                half spatialContrast = max(maxA - minA, maxB - minB) * half(255.0 / 219.0);
                bool nearHighContrastHUD = spatialContrast >= half(0.18)
                    && (minStaticDiff * half(255.0 / 219.0)) < half(0.045);
                // Static high-contrast HUD text locks its 16x16 macroblock (32x32 at 4K) to MV=0.
                // Step 2-3 macroblocks past text rows to borrow background MV and allow unoccluded
                // single-sided matches when the opposite endpoint lands on static HUD text.
                const float2 hudOffsets[8] = {
                    float2(0.0f, 2.0f), float2(0.0f, -2.0f), float2(0.0f, 3.0f), float2(0.0f, -3.0f),
                    float2(2.0f, 0.0f), float2(-2.0f, 0.0f), float2(3.0f, 0.0f), float2(-3.0f, 0.0f)
                };
                float2 hudLastV = float2(1e6f);
                for (int k = 0; nearHighContrastHUD && k < 8; ++k) {
                    half2 rawV = motion.sample(previewNearestSampler, uv + hudOffsets[k] * gridStep).rg;
                    float2 v = float2(rawV);
                    if (!previewIsFiniteMotion(rawV, v, safeFinite) || (abs(v.x) < 0.25f && abs(v.y) < 0.25f)) continue;
                    if ((abs(v.x - hudLastV.x) < 0.25f && abs(v.y - hudLastV.y) < 0.25f)
                        || (abs(v.x - bestV.x) < 0.25f && abs(v.y - bestV.y) < 0.25f)) continue;
                    hudLastV = v;
                    float2 dUV = v * motionScale.xy;
                    float2 uvA = uv + t * dUV;
                    float2 uvB = uv - (1.0f - t) * dUV;
                    half eA = previewPatchDiff(lowA, uvA, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
                    half eB = previewPatchDiff(lowB, uvB, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
                    half score = min(eA, eB) + half(0.5) * max(eA, eB);
                    if (eB < half(0.018) && eA > eB + half(0.025)) {
                        half occA = abs(lowA.sample(previewSampler, uvA).r - lowB.sample(previewSampler, uvA).r)
                            * half(255.0 / 219.0);
                        if (occA < half(0.025)) { score = min(score, eB + half(0.006)); }
                    } else if (eA < half(0.018) && eB > eA + half(0.025)) {
                        half occB = abs(lowA.sample(previewSampler, uvB).r - lowB.sample(previewSampler, uvB).r)
                            * half(255.0 / 219.0);
                        if (occB < half(0.025)) { score = min(score, eA + half(0.006)); }
                    }
                    if (score < bestScore) {
                        bestScore = score;
                        bestDUV = dUV;
                        bestV = v;
                        bestErrA = eA;
                        bestErrB = eB;
                        if (score < half(0.010)) break;
                    }
                }
            }
            half wA = smoothstep(half(0.045), half(0.010), bestErrA);
            half wB = smoothstep(half(0.045), half(0.010), bestErrB);
            if (previewHasForwardMotion && (wA + wB > half(0.02))) {
                float2 uvA = uv + t * bestDUV;
                float2 uvB = uv - (1.0f - t) * bestDUV;
                half2 rawAB = forwardMotion.sample(previewNearestSampler, uvA).rg;
                half2 rawBA = motion.sample(previewNearestSampler, uvB).rg;
                float2 vABatA = float2(rawAB) * fwdScale;
                float2 vBAatB = float2(rawBA);
                float fbThresh = max(2.5f, 0.25f * length(bestV));
                if (previewIsFiniteMotion(rawAB, vABatA, safeFinite) && bestErrA > bestErrB + half(0.005)) {
                    float fbA = length(vABatA + bestV);
                    if (fbA > fbThresh) {
                        wA *= smoothstep(half(fbThresh * 2.0f), half(fbThresh), half(fbA));
                    }
                }
                if (previewIsFiniteMotion(rawBA, vBAatB, safeFinite) && bestErrB > bestErrA + half(0.005)) {
                    float fbB = length(vBAatB - bestV);
                    if (fbB > fbThresh) {
                        wB *= smoothstep(half(fbThresh * 2.0f), half(fbThresh), half(fbB));
                    }
                }
            }
            detailOut.write(half4(half(bestDUV.x), half(bestDUV.y), lowStatic ? (wA + half(2.0)) : wA, wB), gid);
        }
        // Fused single-pass hybrid midpoint decode directly to 10-bit/8-bit preview drawable,
        // eliminating the 12.4 MB 4K 420v intermediate round-trip and its 8-bit quantization loss.
        fragment half4 previewHybridFragment(
            PreviewVertex in [[stage_in]],
            texture2d<half, access::sample> aTex [[texture(0)]],
            texture2d<half, access::sample> aChroma [[texture(1)]],
            texture2d<half, access::sample> bTex [[texture(2)]],
            texture2d<half, access::sample> bChroma [[texture(3)]],
            texture2d<half, access::sample> lowATex [[texture(4)]],
            texture2d<half, access::sample> lowAChroma [[texture(5)]],
            texture2d<half, access::sample> lowBTex [[texture(6)]],
            texture2d<half, access::sample> lowBChroma [[texture(7)]],
            texture2d<half, access::sample> lowMidTex [[texture(8)]],
            texture2d<half, access::sample> lowMidChroma [[texture(9)]],
            texture2d<half, access::sample> motionDetail [[texture(10), function_constant(previewHasMotion)]],
            constant HybridPreviewUniforms &u [[buffer(0)]]
        ) {
            float2 px = in.position.xy;
            SourceUniforms src = u.primary;
            if (px.x < src.fitRect.x || px.x >= src.fitMax.x || px.y < src.fitRect.y || px.y >= src.fitMax.y) {
                return half4(half3(0.0h), half(1.0));
            }
            uint postFlags = uint(u.post.y + 0.5f);
            bool bilateralChroma = (postFlags & 1u) != 0u;
            bool hdr10Deband = (postFlags & 2u) != 0u;
            if (u.split.x > 0.5f && px.x < u.split.y) {
                half3 orig = sampleSource(aTex, aChroma, src, px, bilateralChroma, hdr10Deband);
                if (u.post.x > 0.001f) {
                    half3 n = sampleSource(aTex, aChroma, src, px + float2(0.0f, -1.0f), bilateralChroma, hdr10Deband);
                    half3 s = sampleSource(aTex, aChroma, src, px + float2(0.0f, 1.0f), bilateralChroma, hdr10Deband);
                    half3 e = sampleSource(aTex, aChroma, src, px + float2(1.0f, 0.0f), bilateralChroma, hdr10Deband);
                    half3 w = sampleSource(aTex, aChroma, src, px + float2(-1.0f, 0.0f), bilateralChroma, hdr10Deband);
                    orig = previewApplyRCAS(orig, n, s, e, w, half(u.post.x), src.flags.x > 1.5f);
                }
                if (u.split.z > 0.0f) {
                    orig = saturate(orig + half3(triangularDither(px) * half(u.split.z)));
                }
                return half4(orig, half(1.0));
            }
            float2 normalized = (px - src.fitRect.xy) * src.fitRect.zw;
            float2 uv = clamp(fma(normalized, src.uvRect.zw, src.uvRect.xy), src.clampRect.xy, src.clampRect.zw);
            uint hdrMode = src.flags.x > 1.5f ? uint(src.flags.x - 0.5f) : 0u;
            float colorMode = src.flags.y;
            half4 md = half4(0.0);
            bool lowStatic = false;
            if (previewHasMotion) {
                md = motionDetail.sample(previewNearestSampler, uv);
                lowStatic = md.z >= half(1.5);
                if (lowStatic) md.z -= half(2.0);
            } else if (u.weights.y > 0.5f) {
                half3 la = previewLowBlur(lowATex, lowAChroma, uv, hdrMode);
                half3 lb = previewLowBlur(lowBTex, lowBChroma, uv, hdrMode);
                lowStatic = length(la - lb) < half(0.012);
            }
            float t = u.weights.x;
            half tHalf = half(t);
            uint qualityFlags = uint(u.weights.w + 0.5f);
            bool edgeRefine = (qualityFlags & 1u) != 0u;
            bool hudDehalo = (qualityFlags & 4u) != 0u;
            bool spatialMovingDetail = (qualityFlags & 8u) != 0u && previewHasMotion;
            bool iconEnvelope = (qualityFlags & 16u) != 0u;
            bool adaptiveCAS = (qualityFlags & 32u) != 0u;
            half rcasStrength = half(u.post.x);
            float2 pxUVStep = src.fitRect.zw * src.uvRect.zw;
            half pairedConfidence = spatialMovingDetail
                ? smoothstep(half(0.05), half(0.45), min(md.z, md.w)) : half(0.0);
            bool windowAA = u.split.w > 0.5f && src.fitMax.z > 0.0f;
            float srcPixelsPerOutPixel = windowAA ? (float(aTex.get_width()) * src.fitMax.z * 4.0f) : 1.0f;
            half detailScale = windowAA ? half(smoothstep(2.0f, 1.0f, srcPixelsPerOutPixel)) : half(1.0);
            half staticW = half(0.0);
            half yA = half(0.0), yB = half(0.0);
            half2 caUV = half2(0.0), cbUV = half2(0.0);
            if (lowStatic) {
                sampleStaticPlane(aTex, aChroma, uv, u.offsets.xy, src, windowAA, bilateralChroma, yA, caUV);
                sampleStaticPlane(bTex, bChroma, uv, u.offsets.zw, src, windowAA, bilateralChroma, yB, cbUV);
                half dY = (yA - yB) * half(255.0 / 219.0);
                half2 dCbCr = (caUV - cbUV) * half(255.0 / 224.0);
                half dR, dG, dB;
                if (hdrMode >= 2u) {
                    dR = dY + half(1.4746) * dCbCr.y;
                    dG = dY + fma(half(-0.57135), dCbCr.y, half(-0.16455) * dCbCr.x);
                    dB = dY + half(1.8814) * dCbCr.x;
                } else {
                    dR = dY + half(1.5748) * dCbCr.y;
                    dG = dY + fma(half(-0.468124), dCbCr.y, half(-0.187324) * dCbCr.x);
                    dB = dY + half(1.8556) * dCbCr.x;
                }
                staticW = smoothstep(half(0.022), half(0.011), sqrt(dR * dR + dG * dG + dB * dB));
                if (iconEnvelope && staticW > half(0.001)) {
                    staticW *= half(1.0) - previewIconEnvelopeRelease(
                        lowATex, lowAChroma, lowBTex, lowBChroma, lowMidTex, lowMidChroma, uv);
                }
                if (staticW >= half(0.999) && pairedConfidence == half(0.0)) {
                    half rawStaticY = mix(yA, yB, tHalf);
                    half2 rawStaticUV = mix(caUV, cbUV, tHalf);
                    if (hdr10Deband && hdrMode >= 1u && !windowAA) {
                        rawStaticY = debandHDR10Luma(aTex, uv, px, src.clampRect, rawStaticY);
                    }
                    half yStatic = saturate(previewNv12Luma(rawStaticY));
                    if (rcasStrength > half(0.001)) {
                        half yN = saturate(previewNv12Luma(mix(
                            aTex.sample(previewSampler, clamp(uv + float2(0.0f, -pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                            bTex.sample(previewSampler, clamp(uv + float2(0.0f, -pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                            tHalf)));
                        half yS = saturate(previewNv12Luma(mix(
                            aTex.sample(previewSampler, clamp(uv + float2(0.0f, pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                            bTex.sample(previewSampler, clamp(uv + float2(0.0f, pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                            tHalf)));
                        half yE = saturate(previewNv12Luma(mix(
                            aTex.sample(previewSampler, clamp(uv + float2(pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                            bTex.sample(previewSampler, clamp(uv + float2(pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                            tHalf)));
                        half yW = saturate(previewNv12Luma(mix(
                            aTex.sample(previewSampler, clamp(uv + float2(-pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                            bTex.sample(previewSampler, clamp(uv + float2(-pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                            tHalf)));
                        yStatic = previewApplyLumaRCAS(yStatic, yN, yS, yE, yW, rcasStrength);
                    }
                    half2 cbcrStatic = fma(rawStaticUV, half(255.0 / 224.0), half(-128.0 / 224.0));
                    half3 rgb = finalizePreviewColor(decodeYCbCr(yStatic, cbcrStatic, hdrMode), colorMode);
                    if (u.split.z > 0.0f) rgb = saturate(rgb + half3(triangularDither(px) * half(u.split.z)));
                    return half4(rgb, half(1.0));
                }
            }
            half midY;
            if (windowAA && srcPixelsPerOutPixel > 2.0f) {
                float2 d = src.fitMax.zw;
                float2 uv0 = clamp(uv + float2(-d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
                float2 uv1 = clamp(uv + float2( d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
                float2 uv2 = clamp(uv + float2(-d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
                float2 uv3 = clamp(uv + float2( d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
                half mLuma = (lowMidTex.sample(previewSampler, uv0).r
                            + lowMidTex.sample(previewSampler, uv1).r
                            + lowMidTex.sample(previewSampler, uv2).r
                            + lowMidTex.sample(previewSampler, uv3).r) * half(0.25);
                midY = saturate(previewNv12Luma(mLuma));
            } else {
                midY = saturate(previewNv12Luma(half(previewCatmullRom(lowMidTex, uv, edgeRefine).r)));
            }
            half midRawY = clamp(fma(midY, half(219.0 / 255.0), half(16.0 / 255.0)), half(16.0 / 255.0), half(235.0 / 255.0));
            half2 midUV = bilateralChroma
                ? sampleBilateralChroma(lowMidTex, lowMidChroma, uv, float2(0.0f), midRawY)
                : lowMidChroma.sample(previewSampler, uv).rg;
            half y = midY;
            half alignedY = midY;
            half alignedWeight = half(0.0);
            half2 outChroma = midUV;
            bool appliedMotion = false;
            half motionConf = half(0.0);
            float2 motionUV = uv;
            bool motionRefIsB = false;
            if (previewHasMotion && detailScale > half(0.01)) {
                if (edgeRefine && (!spatialMovingDetail || pairedConfidence == half(0.0))) {
                    float2 mdSize = float2(motionDetail.get_width(), motionDetail.get_height());
                    float2 mdPos = uv * mdSize;
                    float2 mdCenter = floor(mdPos - 0.5f) + 0.5f;
                    float2 mdFrac = mdPos - mdCenter;
                    float2 p00 = mdCenter / mdSize;
                    float2 p10 = (mdCenter + float2(1.0f, 0.0f)) / mdSize;
                    float2 p01 = (mdCenter + float2(0.0f, 1.0f)) / mdSize;
                    float2 p11 = (mdCenter + float2(1.0f, 1.0f)) / mdSize;
                    half l00 = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, p00).r));
                    half l10 = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, p10).r));
                    half l01 = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, p01).r));
                    half l11 = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, p11).r));
                    half lRange = max(max(l00, l10), max(l01, l11)) - min(min(l00, l10), min(l01, l11));
                    if (lRange > half(0.02)) {
                        float d00 = abs(float(midY - l00)) + 0.015f * length(mdFrac);
                        float d10 = abs(float(midY - l10)) + 0.015f * length(mdFrac - float2(1.0f, 0.0f));
                        float d01 = abs(float(midY - l01)) + 0.015f * length(mdFrac - float2(0.0f, 1.0f));
                        float d11 = abs(float(midY - l11)) + 0.015f * length(mdFrac - float2(1.0f, 1.0f));
                        float2 bestUV = p00;
                        float bestD = d00;
                        if (d10 < bestD) { bestD = d10; bestUV = p10; }
                        if (d01 < bestD) { bestD = d01; bestUV = p01; }
                        if (d11 < bestD) { bestUV = p11; }
                        md = motionDetail.sample(previewNearestSampler, bestUV);
                        if (md.z >= half(1.5)) md.z -= half(2.0);
                    }
                }
                if (spatialMovingDetail) {
                    pairedConfidence = smoothstep(half(0.05), half(0.45), min(md.z, md.w));
                }
                half wA = md.z;
                half wB = md.w;
                if (wA + wB > half(0.02)) {
                    appliedMotion = true;
                    float2 bestDUV = float2(md.xy);
                    float2 uvA = uv + t * bestDUV;
                    float2 uvB = uv - (1.0f - t) * bestDUV;
                    half wa = half(1.0 - t) * wA;
                    half wb = half(t) * wB;
                    half invWAB = half(1.0) / max(wa + wb, half(1e-4));
                    half conf = max(wA, wB) * detailScale;
                    motionConf = conf;
                    motionRefIsB = wb > wa;
                    motionUV = motionRefIsB ? uvB : uvA;
                    half srcAY = midY, srcBY = midY;
                    half baseAY = midY, baseBY = midY;
                    half hiAY = half(0.0), hiBY = half(0.0);
                    half2 srcAUV = midUV, srcBUV = midUV;
                    half2 hiAUV = half2(0.0), hiBUV = half2(0.0);
                    if (wA > half(0.01)) {
                        srcAY = saturate(previewNv12Luma(aTex.sample(previewSampler, uvA).r));
                        baseAY = saturate(previewNv12Luma(lowATex.sample(previewSampler, uvA).r));
                        hiAY = srcAY - baseAY;
                        srcAUV = aChroma.sample(previewSampler, uvA + u.offsets.xy).rg;
                        hiAUV = srcAUV - lowAChroma.sample(previewSampler, uvA).rg;
                    }
                    if (wB > half(0.01)) {
                        srcBY = saturate(previewNv12Luma(bTex.sample(previewSampler, uvB).r));
                        baseBY = saturate(previewNv12Luma(lowBTex.sample(previewSampler, uvB).r));
                        hiBY = srcBY - baseBY;
                        srcBUV = bChroma.sample(previewSampler, uvB + u.offsets.zw).rg;
                        hiBUV = srcBUV - lowBChroma.sample(previewSampler, uvB).rg;
                    }
                    half baseY = midY;
                    if (hudDehalo) {
                        if (wB > half(0.70) && wA < half(0.05)) {
                            half haloGate = half(1.0) - smoothstep(half(0.04), half(0.12), abs(midY - baseBY));
                            baseY = mix(midY, baseBY, wB * haloGate * half(0.45));
                        } else if (wA > half(0.70) && wB < half(0.05)) {
                            half haloGate = half(1.0) - smoothstep(half(0.04), half(0.12), abs(midY - baseAY));
                            baseY = mix(midY, baseAY, wA * haloGate * half(0.45));
                        }
                    }
                    half detailY = (hiAY * wa + hiBY * wb) * invWAB;
                    half envMinY = min(midY, min(wA > half(0.1) ? srcAY : midY, wB > half(0.1) ? srcBY : midY));
                    half envMaxY = max(midY, max(wA > half(0.1) ? srcAY : midY, wB > half(0.1) ? srcBY : midY));
                    y = clamp(baseY + conf * detailY, envMinY, envMaxY);
                    if (pairedConfidence > half(0.0)) {
                        half agrees = half(1.0) - smoothstep(half(0.012), half(0.045), abs(srcAY - srcBY));
                        alignedWeight = pairedConfidence * agrees * detailScale;
                        alignedY = mix(srcAY, srcBY, tHalf);
                        if (staticW > half(0.0)) {
                            half originalY = saturate(previewNv12Luma(mix(yA, yB, tHalf)));
                            half movement = clamp(sign(alignedY - originalY) * (midY - originalY), half(0.0), half(1.0));
                            staticW *= half(1.0) - alignedWeight * smoothstep(half(0.025), half(0.10), movement);
                        }
                    }
                    half2 detailUV = (hiAUV * wa + hiBUV * wb) * invWAB;
                    half2 uvMin = min(midUV, min(wA > half(0.1) ? srcAUV : midUV, wB > half(0.1) ? srcBUV : midUV));
                    half2 uvMax = max(midUV, max(wA > half(0.1) ? srcAUV : midUV, wB > half(0.1) ? srcBUV : midUV));
                    outChroma = clamp(midUV + conf * detailUV, uvMin, uvMax);
                }
            }
            if (hudDehalo && !lowStatic && !appliedMotion && u.weights.y > 0.5f) {
                half syA = aTex.sample(previewSampler, uv).r;
                half syB = bTex.sample(previewSampler, uv).r;
                half dSY = abs(syA - syB) * half(255.0 / 219.0);
                if (dSY < half(0.012)) {
                    half lowAY = saturate(previewNv12Luma(lowATex.sample(previewSampler, uv).r));
                    half lowBY = saturate(previewNv12Luma(lowBTex.sample(previewSampler, uv).r));
                    half midDev = max(half(0.0), max(min(lowAY, lowBY) - midY, midY - max(lowAY, lowBY)));
                    half stYA = half(0.0), stYB = half(0.0);
                    half2 stCA = half2(0.0), stCB = half2(0.0);
                    sampleStaticPlane(aTex, aChroma, uv, u.offsets.xy, src, windowAA, bilateralChroma, stYA, stCA);
                    sampleStaticPlane(bTex, bChroma, uv, u.offsets.zw, src, windowAA, bilateralChroma, stYB, stCB);
                    half dSC = length((stCA - stCB) * half(255.0 / 224.0));
                    half strokeW = (half(1.0) - smoothstep(half(0.005), half(0.012), dSY))
                        * (half(1.0) - smoothstep(half(0.012), half(0.024), dSC))
                        * (half(1.0) - smoothstep(half(0.025), half(0.065), midDev));
                    if (strokeW > half(0.01)) {
                        yA = stYA;
                        yB = stYB;
                        caUV = stCA;
                        cbUV = stCB;
                        staticW = max(staticW, strokeW);
                    }
                }
            }
            half casGain = adaptiveCAS ? half(1.45) * (half(1.0) - half(0.65) * motionConf) : half(1.0);
            half casStrength = half(u.weights.z) * casGain * detailScale;
            if (casStrength > half(0.001)) {
                float2 casStep = 0.75f / float2(lowMidTex.get_width(), lowMidTex.get_height());
                half n = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(0.0f, -casStep.y)).r));
                half so = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(0.0f, casStep.y)).r));
                half e = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(casStep.x, 0.0f)).r));
                half w = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(-casStep.x, 0.0f)).r));
                half mn = min(y, min(min(n, so), min(e, w)));
                half mx = max(y, max(max(n, so), max(e, w)));
                half amp = clamp(min(mn, half(1.0) - mx) / max(mx, half(1e-4)), half(0.0), half(1.0));
                half kCas = -casStrength * sqrt(amp);
                y = clamp((y + kCas * (n + so + e + w)) / (half(1.0) + half(4.0) * kCas), mn, mx);
            }
            if (alignedWeight > half(0.001)) {
                y = mix(y, alignedY, alignedWeight);
            }
            if (staticW > half(0.001)) {
                y = mix(y, saturate(previewNv12Luma(mix(yA, yB, tHalf))), staticW);
                outChroma = mix(outChroma, mix(caUV, cbUV, tHalf), staticW);
            }
            if (rcasStrength > half(0.001)) {
                half rC, rN, rS, rE, rW;
                if (staticW > half(0.5)) {
                    rC = saturate(previewNv12Luma(mix(yA, yB, tHalf)));
                    rN = saturate(previewNv12Luma(mix(
                        aTex.sample(previewSampler, clamp(uv + float2(0.0f, -pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                        bTex.sample(previewSampler, clamp(uv + float2(0.0f, -pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                        tHalf)));
                    rS = saturate(previewNv12Luma(mix(
                        aTex.sample(previewSampler, clamp(uv + float2(0.0f, pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                        bTex.sample(previewSampler, clamp(uv + float2(0.0f, pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                        tHalf)));
                    rE = saturate(previewNv12Luma(mix(
                        aTex.sample(previewSampler, clamp(uv + float2(pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                        bTex.sample(previewSampler, clamp(uv + float2(pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                        tHalf)));
                    rW = saturate(previewNv12Luma(mix(
                        aTex.sample(previewSampler, clamp(uv + float2(-pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                        bTex.sample(previewSampler, clamp(uv + float2(-pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                        tHalf)));
                } else if (appliedMotion && motionConf > half(0.25)) {
                    texture2d<half, access::sample> refTex = motionRefIsB ? bTex : aTex;
                    rC = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV).r));
                    rN = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV + float2(0.0f, -pxUVStep.y)).r));
                    rS = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV + float2(0.0f, pxUVStep.y)).r));
                    rE = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV + float2(pxUVStep.x, 0.0f)).r));
                    rW = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV + float2(-pxUVStep.x, 0.0f)).r));
                } else {
                    rC = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv).r));
                    rN = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(0.0f, -pxUVStep.y)).r));
                    rS = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(0.0f, pxUVStep.y)).r));
                    rE = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(pxUVStep.x, 0.0f)).r));
                    rW = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(-pxUVStep.x, 0.0f)).r));
                }
                y = previewApplyLumaRCAS(
                    y, saturate(y + (rN - rC)), saturate(y + (rS - rC)),
                    saturate(y + (rE - rC)), saturate(y + (rW - rC)), rcasStrength);
            }
            if (hdr10Deband && hdrMode >= 1u && !windowAA) {
                half rawOutY = clamp(fma(y, half(219.0 / 255.0), half(16.0 / 255.0)), half(16.0 / 255.0), half(235.0 / 255.0));
                rawOutY = debandHDR10Luma(lowMidTex, uv, px, src.clampRect, rawOutY);
                y = saturate(previewNv12Luma(rawOutY));
            }
            half2 cbcr = fma(outChroma, half(255.0 / 224.0), half(-128.0 / 224.0));
            half3 rgb = finalizePreviewColor(decodeYCbCr(y, cbcr, hdrMode), colorMode);
            if (u.split.z > 0.0f) rgb = saturate(rgb + half3(triangularDither(px) * half(u.split.z)));
            return half4(rgb, half(1.0));
        }
        """
}

enum PreviewSurfaceSizing {
    /// On a scaled HiDPI monitor (e.g. a 3840×2160 4K OLED set to "Looks like 2560×1440", producing a
    /// 5120×2880 virtual backing), rendering fullscreen video at the oversampled backing forces
    /// `3840 → 5120 → 3840` double resampling and 1.78× drawable fillrate. Cap immersive drawables to
    /// the physical panel resolution when aspects match so 4K frames map 1:1 to physical pixels.
    static let prefersNativeFullscreenDrawable =
        ProcessInfo.processInfo.environment["PLAYGLIDE_NATIVE_FULLSCREEN_DRAWABLE"] != "0"

    static func drawableSize(
        backing: VideoSize, nativePhysical: VideoSize?, immersive: Bool,
        prefersNative: Bool = prefersNativeFullscreenDrawable
    ) -> VideoSize {
        guard prefersNative, immersive, let native = nativePhysical,
            backing.width > 0, backing.height > 0, native.width > 0, native.height > 0
        else { return backing }
        guard backing.width > native.width || backing.height > native.height else { return backing }
        let backingAspect = Double(backing.width) / Double(backing.height)
        let nativeAspect = Double(native.width) / Double(native.height)
        guard abs(backingAspect - nativeAspect) / max(backingAspect, nativeAspect) <= 0.02 else {
            return backing
        }
        return native
    }
}

enum PreviewContainerPolicy {
    /// Keep a unified 10-bit `itur_2100_PQ` EDR container when the display already runs macOS HDR
    /// (`maximumExtendedDynamicRangeColorComponentValue > 1.0`), avoiding DP 1.4 DSC sRGB <-> PQ
    /// mode-switch blackouts (`PLAYGLIDE_UNIFIED_EDR_CONTAINER=0` disables).
    static var unifiedEDRContainerEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_UNIFIED_EDR_CONTAINER"] != "0"
    }

    static func prefersPQContainer(
        hdr10Input: Bool,
        displayEDRHeadroom: CGFloat,
        unifiedEnabled: Bool = unifiedEDRContainerEnabled
    ) -> Bool {
        if hdr10Input { return true }
        guard unifiedEnabled, displayEDRHeadroom.isFinite else { return false }
        return displayEDRHeadroom > 1.001
    }
}

struct MetalPreviewSurface: NSViewRepresentable {
    let mailbox: FrameMailbox
    let active: Bool
    let outputFrameDuration: Double
    let presentationMode: PresentationMode
    let prefersLateSelection: Bool
    var immersive = false
    var roundedCorners = false
    var hdr10Active = false
    var hdrDisplayStyle: HDRDisplayStyle = .defaultStyle
    var onPointerMove: (@MainActor () -> Void)?
    var onDisplayIDChange: (@MainActor (Int?) -> Void)?
    func makeCoordinator() -> PreviewCoordinator { PreviewCoordinator(mailbox: mailbox) }
    func makeNSView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView(frame: .zero)
        view.onDrawableSizeChange = { [mailbox, weak coordinator = context.coordinator] size in
            mailbox.setPreviewPixelSize(size)
            coordinator?.setDrawableSize(size)
        }
        view.onScreenChange = { [weak coordinator = context.coordinator] maximumFPS in
            coordinator?.setMaximumFPS(maximumFPS)
        }
        view.onDisplayEDRChange = { [weak coordinator = context.coordinator] headroom in
            coordinator?.setDisplayEDRHeadroom(headroom)
        }
        view.onDisplayIDChange = onDisplayIDChange
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: MetalPreviewView, context: Context) {
        if !context.coordinator.attached, let layer = view.layer as? CAMetalLayer {
            context.coordinator.attach(layer)
        }
        view.onPointerMove = onPointerMove
        view.onDisplayIDChange = onDisplayIDChange
        view.onDisplayIDChange?(view.displayID)
        view.setRoundedCorners(roundedCorners)
        view.setHDRDisplayStyle(hdrDisplayStyle)
        view.setHDR10Active(hdr10Active)
        view.setImmersive(immersive)
        context.coordinator.update(
            active: active, interval: outputFrameDuration,
            maximumFPS: view.maximumFPS, presentationMode: presentationMode,
            prefersLateSelection: prefersLateSelection, immersive: immersive,
            displayEDRHeadroom: view.displayEDRHeadroom, hdrDisplayStyle: hdrDisplayStyle)
    }
    static func dismantleNSView(_ nsView: MetalPreviewView, coordinator: PreviewCoordinator) {
        nsView.onScreenChange = nil
        nsView.onDisplayEDRChange = nil
        let displayChange = nsView.onDisplayIDChange
        nsView.onDisplayIDChange = nil
        displayChange?(nil)
        nsView.stopObservingWindow()
        coordinator.stop()
    }
}

struct SystemDisplayHDRDescriptor: Equatable, Sendable {
    let displayID: Int
    let hasHDRModes: Bool
    let preferHDRModes: Bool
    let canToggleHDR: Bool
}

@MainActor
final class SystemDisplayHDRController {
    static let shared = SystemDisplayHDRController()

    /// Restrict automatic HDR toggling to the exact display hosting the preview window
    /// (`PLAYGLIDE_STRICT_HDR_DISPLAY=0` restores legacy first-HDR-display fallback for A/B).
    nonisolated static var strictDisplayMatchingEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_STRICT_HDR_DISPLAY"] != "0"
    }

    private(set) var managedDisplayIDs: Set<Int> = []
    private var bundleLoaded = false
    private let strictDisplayMatching: Bool
    private var listDisplays: (@MainActor () -> [SystemDisplayHDRDescriptor])?
    private var setPreferHDRModes: (@MainActor (Int, Bool) -> Void)?
    private var fallbackDisplayID: (@MainActor () -> Int?)?

    private init() {
        self.strictDisplayMatching = Self.strictDisplayMatchingEnabled
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SystemDisplayHDRController.shared.restoreManagedDisplays()
            }
        }
    }

    init(
        strictDisplayMatching: Bool = SystemDisplayHDRController.strictDisplayMatchingEnabled,
        listDisplays: @escaping @MainActor () -> [SystemDisplayHDRDescriptor],
        setPreferHDRModes: @escaping @MainActor (Int, Bool) -> Void,
        fallbackDisplayID: @escaping @MainActor () -> Int? = { nil }
    ) {
        self.strictDisplayMatching = strictDisplayMatching
        self.listDisplays = listDisplays
        self.setPreferHDRModes = setPreferHDRModes
        self.fallbackDisplayID = fallbackDisplayID
    }

    func update(hdrSessionActive: Bool, policy: SystemHDRPolicy, immersive: Bool, displayID: Int? = nil) {
        guard policy != .manual else {
            restoreManagedDisplays()
            return
        }
        let shouldEnable = hdrSessionActive && (policy == .session || (policy == .fullscreen && immersive))
        if shouldEnable {
            enableHDR(on: displayID)
        } else {
            restoreManagedDisplays()
        }
    }

    private func loadMonitorPanel() -> [NSObject] {
        if !bundleLoaded {
            bundleLoaded =
                Bundle(path: "/System/Library/PrivateFrameworks/MonitorPanel.framework")?.load() ?? false
        }
        guard bundleLoaded,
            let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type
        else { return [] }
        let manager = cls.init()
        return (manager.value(forKey: "displays") as? [NSObject]) ?? []
    }

    private func currentDisplays() -> [SystemDisplayHDRDescriptor] {
        if let listDisplays { return listDisplays() }
        let setSelector = NSSelectorFromString("setPreferHDRModes:")
        return loadMonitorPanel().compactMap { display in
            guard let id = display.value(forKey: "displayID") as? Int else { return nil }
            return SystemDisplayHDRDescriptor(
                displayID: id,
                hasHDRModes: (display.value(forKey: "hasHDRModes") as? Bool) == true,
                preferHDRModes: (display.value(forKey: "preferHDRModes") as? Bool) == true,
                canToggleHDR: display.responds(to: setSelector)
            )
        }
    }

    private func applyPreferHDRModes(_ enabled: Bool, to displayID: Int) {
        if let setPreferHDRModes {
            setPreferHDRModes(displayID, enabled)
            return
        }
        let setSelector = NSSelectorFromString("setPreferHDRModes:")
        guard
            let target = loadMonitorPanel().first(where: {
                ($0.value(forKey: "displayID") as? Int) == displayID
                    && ($0.value(forKey: "hasHDRModes") as? Bool) == true
                    && $0.responds(to: setSelector)
            })
        else { return }
        target.setValue(enabled, forKey: "preferHDRModes")
    }

    private func activeScreenDisplayID() -> Int? {
        if let fallbackDisplayID { return fallbackDisplayID() }
        let window =
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        let screen = window?.screen ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }

    private func enableHDR(on previewDisplayID: Int?) {
        let displays = currentDisplays()
        let target: SystemDisplayHDRDescriptor?
        if strictDisplayMatching {
            guard let previewDisplayID else {
                restoreManagedDisplays(excluding: nil, using: displays)
                return
            }
            restoreManagedDisplays(excluding: previewDisplayID, using: displays)
            target = displays.first(where: {
                $0.displayID == previewDisplayID && $0.hasHDRModes && $0.canToggleHDR
            })
        } else {
            let preferredID = previewDisplayID ?? activeScreenDisplayID()
            let candidate =
                displays.first(where: {
                    $0.displayID == preferredID && $0.hasHDRModes && $0.canToggleHDR
                })
                ?? displays.first(where: { $0.hasHDRModes && $0.canToggleHDR })
            restoreManagedDisplays(excluding: candidate?.displayID, using: displays)
            target = candidate
        }
        guard let target else { return }
        if !target.preferHDRModes {
            managedDisplayIDs.insert(target.displayID)
            applyPreferHDRModes(true, to: target.displayID)
        }
    }

    func restoreManagedDisplays() {
        restoreManagedDisplays(excluding: nil, using: nil)
    }

    private func restoreManagedDisplays(excluding keepID: Int?, using cachedDisplays: [SystemDisplayHDRDescriptor]?) {
        guard !managedDisplayIDs.isEmpty else { return }
        let toRestore = keepID.map { managedDisplayIDs.subtracting([$0]) } ?? managedDisplayIDs
        guard !toRestore.isEmpty else { return }
        let displays = cachedDisplays ?? currentDisplays()
        for display in displays where toRestore.contains(display.displayID) {
            if display.hasHDRModes && display.canToggleHDR && display.preferHDRModes {
                applyPreferHDRModes(false, to: display.displayID)
            }
        }
        managedDisplayIDs.subtract(toRestore)
    }
}

@MainActor
final class MetalPreviewView: NSView {
    /// HDR10 mastering peak luminance aligned to display style: 1000-nit SMPTE ST 2086 reference peak
    /// in `.reference` mode and 500-nit enhanced mapping in `.enhanced` mode.
    nonisolated static func hdr10EDRPeakLuminance(referencePQ: Bool) -> Float {
        referencePQ ? 1000.0 : 500.0
    }

    /// HDR10 mastering metadata with 100-nit reference diffuse white.
    /// Required by macOS WindowServer for `itur_2100_PQ` layers so values > 100 nits (PQ > 0.508)
    /// tone-map smoothly into active EDR headroom instead of hard-clipping at 100 nits.
    nonisolated static func makeHDR10EDRMetadata(
        referencePQ: Bool = PreviewImageRenderer.hdr10ReferencePQEnabled
    ) -> CAEDRMetadata {
        CAEDRMetadata.hdr10(
            minLuminance: referencePQ ? 0.0001 : 0.0005,
            maxLuminance: hdr10EDRPeakLuminance(referencePQ: referencePQ),
            opticalOutputScale: 100.0)
    }

    var onDrawableSizeChange: ((VideoSize) -> Void)?
    var onScreenChange: (@MainActor (Float) -> Void)?
    var onDisplayEDRChange: (@MainActor (CGFloat) -> Void)?
    var onDisplayIDChange: (@MainActor (Int?) -> Void)?
    var onPointerMove: (@MainActor () -> Void)?
    var displayID: Int? {
        (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }
    var maximumFPS: Float {
        let rate = window?.screen?.maximumFramesPerSecond ?? 120
        return rate > 0 ? Float(rate) : 60
    }
    var displayEDRHeadroom: CGFloat {
        window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
    }
    private var pointerTrackingArea: NSTrackingArea?
    private var immersive = false
    private var hdr10Active = false
    private var hdrDisplayStyle: HDRDisplayStyle = .defaultStyle
    private var layerPQActive = false
    private var layerReferencePQ = PreviewImageRenderer.hdr10ReferencePQEnabled
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { true }
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat =
            ProcessInfo.processInfo.environment["PLAYGLIDE_PREVIEW_10BIT"] == "0" ? .bgra8Unorm : .bgr10a2Unorm
        // All preview outputs write via MTLRenderCommandEncoder, allowing lossless TBDR
        // framebuffer compression and Apple Silicon fullscreen Direct-to-Display scanout.
        layer.framebufferOnly = true
        layer.colorspace = PixelConverter.sRGB
        layer.displaySyncEnabled = true
        // Windowed macOS can retain a drawable across several display intervals.
        // Keep the native triple-buffer pool; bound app queueing separately.
        layer.maximumDrawableCount = 3
        layer.isOpaque = true
        return layer
    }
    func setRoundedCorners(_ rounded: Bool) {
        guard let layer else { return }
        let radius: CGFloat = rounded ? 14 : 0
        if layer.cornerRadius != radius { layer.cornerRadius = radius }
        if layer.masksToBounds != rounded { layer.masksToBounds = rounded }
    }
    func setImmersive(_ value: Bool) {
        guard immersive != value else { return }
        immersive = value
        resizeSurface()
    }
    func setHDRDisplayStyle(_ style: HDRDisplayStyle) {
        guard hdrDisplayStyle != style else { return }
        hdrDisplayStyle = style
        syncLayerColorContainer()
    }
    func setHDR10Active(_ value: Bool) {
        hdr10Active = value
        syncLayerColorContainer()
    }
    private func syncLayerColorContainer() {
        guard let layer = layer as? CAMetalLayer else { return }
        let headroom = displayEDRHeadroom
        let usesPQ = PreviewContainerPolicy.prefersPQContainer(
            hdr10Input: hdr10Active, displayEDRHeadroom: headroom)
        let refPQ = hdrDisplayStyle == .reference
        if layerPQActive != usesPQ || (usesPQ && layerReferencePQ != refPQ) {
            layerPQActive = usesPQ
            layerReferencePQ = refPQ
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.wantsExtendedDynamicRangeContent = usesPQ
            layer.colorspace = usesPQ ? PixelConverter.itur2100PQ : PixelConverter.sRGB
            layer.edrMetadata = usesPQ ? Self.makeHDR10EDRMetadata(referencePQ: refPQ) : nil
            CATransaction.commit()
        }
        onDisplayEDRChange?(headroom)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMove?()
    }
    override func layout() {
        super.layout()
        resizeSurface()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopObservingWindow()
        if newWindow == nil { onDisplayIDChange?(nil) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            // AppKit's 15-second NSPersistentUIManager state-restoration flush snapshots restorable
            // windows, which forces macOS WindowServer out of fullscreen Direct-to-Display scanout
            // (+1 refresh / +8.33 ms permanent latency on external 120 Hz displays).
            if window.isRestorable { window.isRestorable = false }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidChangeScreen(_:)), name: NSWindow.didChangeScreenNotification,
                object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(screenParametersDidChange(_:)),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        onDisplayIDChange?(displayID)
        onScreenChange?(maximumFPS)
        syncLayerColorContainer()
        resizeSurface()
    }
    fileprivate func stopObservingWindow() {
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: window)
    }
    @objc private func windowDidChangeScreen(_ notification: Notification) {
        onDisplayIDChange?(displayID)
        onScreenChange?(maximumFPS)
        syncLayerColorContainer()
        resizeSurface()
    }
    @objc private func screenParametersDidChange(_ notification: Notification) {
        onDisplayIDChange?(displayID)
        syncLayerColorContainer()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onScreenChange?(maximumFPS)
        syncLayerColorContainer()
        resizeSurface()
    }
    private static func nativePhysicalSize(of screen: NSScreen?) -> VideoSize? {
        guard let screen,
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode], !modes.isEmpty else {
            return nil
        }
        let nativeFlag: UInt32 = 0x0200_0000  // kDisplayModeNativeFlag
        if let native = modes.filter({ ($0.ioFlags & nativeFlag) != 0 })
            .max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }),
            native.pixelWidth > 0, native.pixelHeight > 0
        {
            return VideoSize(width: native.pixelWidth, height: native.pixelHeight)
        }
        if let oneX = modes.filter({ $0.pixelWidth == $0.width && $0.pixelHeight == $0.height })
            .max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }),
            oneX.pixelWidth > 0, oneX.pixelHeight > 0
        {
            return VideoSize(width: oneX.pixelWidth, height: oneX.pixelHeight)
        }
        return nil
    }
    private func resizeSurface() {
        guard let layer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 1
        if layer.contentsScale != scale { layer.contentsScale = scale }
        let backing = convertToBacking(bounds).size
        let backingSize = VideoSize(width: Int(backing.width.rounded()), height: Int(backing.height.rounded()))
        let size = PreviewSurfaceSizing.drawableSize(
            backing: backingSize, nativePhysical: Self.nativePhysicalSize(of: window?.screen), immersive: immersive)
        let targetSize = CGSize(width: size.width, height: size.height)
        if layer.drawableSize != targetSize { layer.drawableSize = targetSize }
        onDrawableSizeChange?(size)
    }
}

@MainActor
final class PreviewCoordinator {
    private let mailbox: FrameMailbox
    private var worker: PreviewWorker?
    var attached: Bool { worker != nil }
    init(mailbox: FrameMailbox) { self.mailbox = mailbox }
    func attach(_ layer: CAMetalLayer) { worker = PreviewWorker(layer: layer, mailbox: mailbox) }
    func setDrawableSize(_ size: VideoSize) { worker?.setDrawableSize(size) }
    func setMaximumFPS(_ rate: Float) { worker?.setMaximumFPS(rate) }
    func setDisplayEDRHeadroom(_ headroom: CGFloat) { worker?.setDisplayEDRHeadroom(headroom) }
    func update(
        active: Bool, interval: Double, maximumFPS: Float, presentationMode: PresentationMode,
        prefersLateSelection: Bool, immersive: Bool = false, displayEDRHeadroom: CGFloat = 1.0,
        hdrDisplayStyle: HDRDisplayStyle = .defaultStyle
    ) {
        worker?.update(
            active: active, interval: interval, maximumFPS: maximumFPS, presentationMode: presentationMode,
            prefersLateSelection: prefersLateSelection, immersive: immersive,
            displayEDRHeadroom: displayEDRHeadroom, hdrDisplayStyle: hdrDisplayStyle)
    }
    func stop() {
        worker?.stop()
        worker = nil
    }
    deinit { worker?.stop() }
}

/// Core Animation's Metal surface is shared with the view for sizing, while drawable
/// acquisition/rendering belongs to one worker run loop. No pixel buffer uses unchecked Sendable.
private final class DisplaySurface: @unchecked Sendable {
    let layer: CAMetalLayer
    let link: CAMetalDisplayLink

    @MainActor init(_ layer: CAMetalLayer) {
        self.layer = layer
        link = CAMetalDisplayLink(metalLayer: layer)
    }
}

private final class PreviewWorker: Sendable {
    private struct Control: Sendable {
        var active = false
        var immersive = false
        var displayEDRHeadroom: CGFloat = 1.0
        var hdrDisplayStyle: HDRDisplayStyle = .defaultStyle
        var timing = PreviewDisplayTiming()
        var drawableSize = VideoSize(width: 0, height: 0)
        var stopped = false
    }
    private final class ControlBox: Sendable {
        let state = Mutex(Control())
    }
    private let control = ControlBox()
    @MainActor init(layer: CAMetalLayer, mailbox: FrameMailbox) {
        let surface = DisplaySurface(layer)
        let control = control
        let size = layer.drawableSize
        let initialPQ = layer.wantsExtendedDynamicRangeContent
        control.state.withLock {
            $0.drawableSize = VideoSize(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        }
        let thread = Thread {
            let renderer = PreviewRenderer(surface: surface, mailbox: mailbox, initialPQActive: initialPQ) {
                control.state.withLock(\.drawableSize)
            }
            // Keep an idle run loop wakeable for start/stop without crossing Cocoa objects.
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in }
            RunLoop.current.add(timer, forMode: .default)
            renderer.install()
            while true {
                let settings = control.state.withLock { $0 }
                if settings.stopped { break }
                renderer.configure(
                    active: settings.active, target: settings.timing.requestedFPS,
                    maximumFPS: settings.timing.maximumFPS, lateSelection: settings.timing.lateSelection,
                    immersive: settings.immersive, displayEDRHeadroom: settings.displayEDRHeadroom,
                    hdrDisplayStyle: settings.hdrDisplayStyle)
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            renderer.shutdown()
            timer.invalidate()
        }
        thread.name = "PlayGlide.video.presentation"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    func update(
        active: Bool, interval: Double, maximumFPS: Float, presentationMode: PresentationMode,
        prefersLateSelection: Bool, immersive: Bool = false, displayEDRHeadroom: CGFloat = 1.0,
        hdrDisplayStyle: HDRDisplayStyle = .defaultStyle
    ) {
        control.state.withLock {
            $0.active = active
            $0.immersive = immersive
            $0.displayEDRHeadroom = displayEDRHeadroom
            $0.hdrDisplayStyle = hdrDisplayStyle
            $0.timing = PreviewDisplayTiming(
                outputInterval: interval, mode: presentationMode, prefersLateSelection: prefersLateSelection,
                maximumFPS: maximumFPS)
        }
    }
    func setMaximumFPS(_ rate: Float) { control.state.withLock { $0.timing.maximumFPS = rate } }
    func setDisplayEDRHeadroom(_ headroom: CGFloat) { control.state.withLock { $0.displayEDRHeadroom = headroom } }
    func setDrawableSize(_ size: VideoSize) { control.state.withLock { $0.drawableSize = size } }
    func stop() { control.state.withLock { $0.stopped = true } }
}

/// Constructed, configured, called and destroyed on the presentation thread's run loop.
private final class PreviewRenderer: NSObject, CAMetalDisplayLinkDelegate {
    private let queue: (any MTLCommandQueue)?
    private let mailbox: FrameMailbox
    private let surface: DisplaySurface
    private let currentDrawableSize: @Sendable () -> VideoSize
    private final class GPUExecutionTracker: Sendable {
        private let peak = Mutex<Double>(0)
        func record(_ seconds: Double) {
            peak.withLock { $0 = max($0, seconds) }
        }
        func drain() -> Double {
            peak.withLock { value in
                let current = value
                value = 0
                return current
            }
        }
    }
    private var displayClock = DisplayClock()
    private var selectionBudget = DrawableSelectionBudget()
    private let latestGPUExecution = GPUExecutionTracker()
    private var scanoutRecovery = ScanoutLatencyRecovery()
    private let wakesOnFrameReadiness = ProcessInfo.processInfo.environment["PLAYGLIDE_PREVIEW_READY_WAKE"] != "0"
    private let advancesLateSelectionHorizon = ProcessInfo.processInfo.environment["PLAYGLIDE_LATE_ADVANCE"] != "0"
    private let usesNominalLateAdvance = ProcessInfo.processInfo.environment["PLAYGLIDE_LATE_ADVANCE_NOMINAL"] != "0"
    private let logsDisplayLeadTransitions = ProcessInfo.processInfo.environment["PLAYGLIDE_DISPLAY_LEAD_LOG"] == "1"
    private let recoversElevatedLead = ProcessInfo.processInfo.environment["PLAYGLIDE_LEAD_RECOVER"] != "0"
    private struct RenderedPresentationState: Equatable {
        let frameID: UUID
        let compare: Bool
        let drawableSize: VideoSize
        let hdr10: Bool
        let pqOutput: Bool
        let referencePQ: Bool
    }
    private let skipsRedundantRedraw = ProcessInfo.processInfo.environment["PLAYGLIDE_SKIP_REDUNDANT_REDRAW"] != "0"
    private var lastRenderedState: RenderedPresentationState?
    private var recentCallbacks: [String] = []
    private var lastLoggedLead: Double?
    private var lateSelection = false
    private var immersive = false
    private var displayEDRHeadroom: CGFloat = 1.0
    private var referencePQ = PreviewImageRenderer.hdr10ReferencePQEnabled
    private var layerPQActive = false
    private var layerReferencePQ = PreviewImageRenderer.hdr10ReferencePQEnabled
    private let imageRenderer: PreviewImageRenderer?
    private var requestedFPS: Float = 0
    private var maximumFPS: Float = 0
    private var active = false

    init(
        surface: DisplaySurface, mailbox: FrameMailbox, initialPQActive: Bool = false,
        currentDrawableSize: @escaping @Sendable () -> VideoSize
    ) {
        self.surface = surface
        self.mailbox = mailbox
        self.layerPQActive = initialPQActive
        self.currentDrawableSize = currentDrawableSize
        let device = surface.layer.device
        let queue = device?.makeCommandQueue()
        self.queue = queue
        // Share the presentation command queue so Core Image and Metal encode on one serial timeline.
        let context = queue.map { CIContext(mtlCommandQueue: $0, options: [.cacheIntermediates: false]) }
        imageRenderer = device.flatMap { device in context.map { PreviewImageRenderer(device: device, context: $0) } }
        super.init()
    }
    func install() {
        if PreviewImageRenderer.prewarmPipelinesEnabled {
            imageRenderer?.prewarmPipelines(pixelFormats: [surface.layer.pixelFormat, .bgra8Unorm])
        }
        let link = surface.link
        link.delegate = self
        link.preferredFrameLatency = 1
        link.isPaused = true
        link.add(to: .current, forMode: .common)
    }
    func configure(
        active: Bool, target: Float, maximumFPS: Float, lateSelection: Bool, immersive: Bool,
        displayEDRHeadroom: CGFloat = 1.0, hdrDisplayStyle: HDRDisplayStyle = .defaultStyle
    ) {
        self.lateSelection = lateSelection
        self.displayEDRHeadroom = displayEDRHeadroom
        let wantsRefPQ = hdrDisplayStyle == .reference
        if self.referencePQ != wantsRefPQ {
            self.referencePQ = wantsRefPQ
            imageRenderer?.hdr10ReferencePQOverride = wantsRefPQ
            lastRenderedState = nil
        }
        if self.immersive != immersive {
            self.immersive = immersive
            scanoutRecovery.reset()
        }
        if self.maximumFPS != maximumFPS {
            displayClock = DisplayClock()
            selectionBudget = DrawableSelectionBudget()
            scanoutRecovery.reset()
        }
        if requestedFPS != target || self.maximumFPS != maximumFPS {
            surface.link.preferredFrameRateRange = CAFrameRateRange(
                minimum: target, maximum: maximumFPS, preferred: target)
            requestedFPS = target
            self.maximumFPS = maximumFPS
        }
        if self.active != active {
            self.active = active
            surface.link.isPaused = !active
            if !active {
                displayClock = DisplayClock()
                selectionBudget = DrawableSelectionBudget()
                scanoutRecovery.reset()
                lastRenderedState = nil
                imageRenderer?.reset()
                let idlePQ = PreviewContainerPolicy.prefersPQContainer(
                    hdr10Input: false, displayEDRHeadroom: displayEDRHeadroom)
                if layerPQActive != idlePQ || (idlePQ && layerReferencePQ != referencePQ) {
                    layerPQActive = idlePQ
                    layerReferencePQ = referencePQ
                    surface.layer.wantsExtendedDynamicRangeContent = idlePQ
                    surface.layer.colorspace = idlePQ ? PixelConverter.itur2100PQ : PixelConverter.sRGB
                    surface.layer.edrMetadata =
                        idlePQ ? MetalPreviewView.makeHDR10EDRMetadata(referencePQ: referencePQ) : nil
                }
            }
        }
    }
    func shutdown() {
        surface.link.invalidate()
        imageRenderer?.reset()
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        autoreleasepool { render(at: update.targetPresentationTimestamp, displayUpdate: update) }
    }

    private func render(at targetTime: Double, displayUpdate: CAMetalDisplayLink.Update) {
        let started = mediaHostTime()
        let rawLead = (targetTime - started) * 1000
        let rawSlack = (displayUpdate.targetTimestamp - started) * 1000
        let scanoutLag = targetTime - displayUpdate.targetTimestamp
        let scanoutLagMs = scanoutLag * 1000
        if logsDisplayLeadTransitions {
            if let prev = lastLoggedLead, abs(rawLead - prev) > 3.5 {
                let history = recentCallbacks.joined(separator: "\n  ")
                print(
                    String(
                        format:
                            "PLAYGLIDE_LEAD_JUMP t=%.4f prevLead=%.2fms newLead=%.2fms slack=%.2fms scanLag=%.2fms\n  %@",
                        started, prev, rawLead, rawSlack, scanoutLagMs, history))
                fflush(stdout)
            }
            lastLoggedLead = rawLead
        }
        func logCB(_ tag: String, extra: String = "") {
            guard logsDisplayLeadTransitions else { return }
            let entry = String(
                format: "t=%.4f lead=%.2f slack=%.2f end-dl=%.2f %@ %@",
                started, rawLead, rawSlack, (mediaHostTime() - displayUpdate.targetTimestamp) * 1000, tag, extra)
            recentCallbacks.append(entry)
            if recentCallbacks.count > 8 { recentCallbacks.removeFirst() }
        }
        guard
            displayClock.isFreshScanoutSlot(
                target: targetTime, now: started, submissionDeadline: displayUpdate.targetTimestamp)
        else {
            logCB("stale")
            return
        }
        // Even a busy renderer received this refresh; its next callback still spans one period.
        let refresh = displayClock.observeRefresh(target: targetTime)
        if recoversElevatedLead,
            scanoutRecovery.observe(
                immersive: immersive, refreshInterval: refresh, scanoutLag: scanoutLag, now: started)
        {
            if logsDisplayLeadTransitions {
                print(String(format: "PLAYGLIDE_LEAD_RECOVER t=%.4f scanLag=%.2fms", started, scanoutLagMs))
                fflush(stdout)
            }
            surface.link.isPaused = true
            surface.link.preferredFrameLatency = 1
            surface.link.isPaused = false
            displayClock = DisplayClock()
            return
        }
        let selection: (sourceTime: Double, generation: UUID?)?
        if lateSelection {
            let gpuDuration = latestGPUExecution.drain()
            if gpuDuration > 0 {
                selectionBudget.recordGPUExecution(seconds: gpuDuration)
            }
            let submissionDeadline = displayUpdate.targetTimestamp
            let delay = selectionBudget.selectionDelay(now: started, deadline: submissionDeadline)
            let advance: Double
            if !advancesLateSelectionHorizon {
                advance = 0
            } else if usesNominalLateAdvance {
                advance = selectionBudget.nominalSelectionAdvance(refreshInterval: refresh, fallbackDelay: delay)
            } else {
                advance = selectionBudget.selectionAdvance(delay: delay, refreshInterval: refresh)
            }
            let sourceTime = displayClock.sourceTime(target: targetTime, now: started) + advance
            let remaining = max(0, started + delay - mediaHostTime())
            if wakesOnFrameReadiness {
                guard
                    let generation = mailbox.waitForReadyPreviewFrame(
                        at: sourceTime, refreshInterval: refresh, until: .now() + remaining)
                else {
                    logCB("inactiveWait")
                    return
                }
                selection = (sourceTime, generation)
            } else {
                guard mailbox.isActive else { return }
                if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
                selection = (sourceTime, nil)
            }
        } else {
            selection = nil
        }
        let callbackTime = selection == nil ? started : mediaHostTime()
        guard mailbox.acquireGPU(at: callbackTime, target: targetTime, generation: selection?.generation) else {
            logCB("gpuBusy")
            return
        }
        guard let queue, let imageRenderer else {
            mailbox.releaseGPU()
            return
        }
        let expectedSize = currentDrawableSize()
        guard expectedSize.width > 0, expectedSize.height > 0 else {
            mailbox.releaseGPU()
            return
        }
        // Live pairs use capture host-time anchors. Account for the system's scanout
        // lead before comparing deadlines, or a future timestamp discards valid frames.
        let now = mediaHostTime()
        let clockSample = selection == nil ? now : started
        let sourceTime = selection?.sourceTime ?? displayClock.sourceTime(target: targetTime, now: clockSample)
        let allowRedundantRedraw = selection == nil || now + 0.0007 < displayUpdate.targetTimestamp
        guard
            let frame = mailbox.next(
                now: sourceTime, refreshInterval: refresh, observedAt: callbackTime, target: targetTime,
                holdingCurrent: true, allowRedundantRedraw: allowRedundantRedraw, generation: selection?.generation)
        else {
            logCB(
                "noFrame",
                extra:
                    "allowRedraw=\(allowRedundantRedraw) waitMs=\(String(format: "%.2f", (callbackTime - started) * 1000))"
            )
            mailbox.releaseGPU()
            return
        }
        mailbox.mutate(frame.generation) {
            if let refresh, refresh > 0 { $0.displayInterval = refresh }
            $0.displayLead = max(0, targetTime - clockSample)
        }
        let compare = mailbox.showsOriginal
        guard mailbox.isCurrentPreviewFrame(frame) else {
            mailbox.releaseGPU()
            return
        }
        let wantsHDR10 =
            frame.hybridRecipe?.isHDR10PQ ?? frame.video.pixelBuffer.withUnsafeBuffer { PixelConverter.isHDR10PQ($0) }
        let wantsPQ = PreviewContainerPolicy.prefersPQContainer(
            hdr10Input: wantsHDR10, displayEDRHeadroom: displayEDRHeadroom)
        let renderState = RenderedPresentationState(
            frameID: frame.id, compare: compare, drawableSize: expectedSize, hdr10: wantsHDR10, pqOutput: wantsPQ,
            referencePQ: referencePQ)
        if skipsRedundantRedraw, !frame.presentation.needsSubmission, lastRenderedState == renderState {
            logCB("skipRedundant")
            mailbox.releaseGPU()
            return
        }
        if wantsPQ != layerPQActive || (wantsPQ && layerReferencePQ != referencePQ) {
            layerPQActive = wantsPQ
            layerReferencePQ = referencePQ
            surface.layer.wantsExtendedDynamicRangeContent = wantsPQ
            surface.layer.colorspace = wantsPQ ? PixelConverter.itur2100PQ : PixelConverter.sRGB
            surface.layer.edrMetadata =
                wantsPQ ? MetalPreviewView.makeHDR10EDRMetadata(referencePQ: referencePQ) : nil
        }
        let drawable = displayUpdate.drawable
        let texture = drawable.texture
        let actualSize = VideoSize(width: texture.width, height: texture.height)
        guard actualSize.width > 0, actualSize.height > 0 else {
            mailbox.releaseGPU()
            return
        }
        let encodingStarted = mediaHostTime()
        guard let command = queue.makeCommandBuffer() else {
            mailbox.releaseGPU()
            return
        }
        do {
            let fallbacksBefore = imageRenderer.deferredHybridFallbacks
            let reused = try imageRenderer.encode(
                frame, compare: compare, pqOutput: wantsPQ, to: texture, command: command)
            let fallbackDelta = imageRenderer.deferredHybridFallbacks - fallbacksBefore
            if fallbackDelta > 0 {
                mailbox.mutate(frame.generation) { $0.deferredHybridFallbacks += fallbackDelta }
            }
            let mailbox = mailbox
            let submittedAt = mediaHostTime()
            guard
                let submission = mailbox.preparePreviewSubmission(
                    frame, at: submittedAt, encodingStarted: encodingStarted, reused: reused)
            else {
                // Core Image attaches completion work to the command buffer; commit without presenting so it drains.
                command.addCompletedHandler { _ in
                    withExtendedLifetime(frame) {}
                    mailbox.releaseGPU()
                }
                command.commit()
                return
            }
            let attempt = submission.attempt
            if let attempt {
                drawable.addPresentedHandler { presented in
                    mailbox.recordPresentation(
                        frame, at: presented.presentedTime, submittedAt: submittedAt, attempt: attempt,
                        drawable: actualSize, target: targetTime)
                }
            }
            let latestGPUExecution = self.latestGPUExecution
            command.addCompletedHandler { completed in
                withExtendedLifetime(frame) {}
                mailbox.releaseGPU()
                let gpuDuration =
                    completed.gpuEndTime > completed.gpuStartTime
                    ? completed.gpuEndTime - completed.gpuStartTime : 0
                if gpuDuration > 0 {
                    latestGPUExecution.record(gpuDuration)
                }
                mailbox.mutate(frame.generation) {
                    $0.commandCompletionLatency.record(capturedAt: submittedAt, presentedAt: mediaHostTime())
                    if let error = completed.error {
                        $0.error = AppText(
                            "GPU 呈现失败：\(error.localizedDescription)",
                            "GPU presentation failed: \(error.localizedDescription)")
                    }
                    if gpuDuration > 0 {
                        $0.renderMilliseconds = gpuDuration * 1000
                    }
                }
            }
            // Schedule presentation through the command buffer so WindowServer never races ahead of GPU scheduling.
            command.present(drawable)
            command.commit()
            lastRenderedState = renderState
            logCB(
                "commit",
                extra: String(
                    format: "wait=%.2f enc=%.2f sz=%dx%d gen=%@",
                    (callbackTime - started) * 1000, (mediaHostTime() - callbackTime) * 1000,
                    actualSize.width, actualSize.height, frame.generated ? "1" : "0"))
            if lateSelection {
                selectionBudget.recordEncoding(seconds: mediaHostTime() - callbackTime)
            }
        } catch is DeferredHybridUnavailableError {
            lastRenderedState = nil
            mailbox.mutate(frame.generation) {
                $0.deferredHybridFallbackFailures += 1
                $0.unpresented += 1
            }
            mailbox.releaseGPU()
        } catch {
            let mailbox = mailbox
            lastRenderedState = nil
            imageRenderer.reset()
            if command.status == .notEnqueued {
                command.addCompletedHandler { _ in
                    withExtendedLifetime(frame) {}
                    mailbox.releaseGPU()
                }
                command.commit()
            } else {
                mailbox.releaseGPU()
            }
            mailbox.mutate(frame.generation) { $0.error = AppText(error: error) }
        }
    }
}
