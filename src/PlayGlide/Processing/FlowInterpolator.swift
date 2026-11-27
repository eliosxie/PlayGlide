import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision

struct HybridReadinessTiming: Sendable, Equatable {
    /// Time from VT submission to VT midpoint availability.
    let vtReady: Double
    /// Backward media-engine motion estimation duration (B -> A), overlapping with VT.
    let backwardMotion: Double?
    /// Forward media-engine motion estimation duration (A -> B), following backward ME.
    let forwardMotion: Double?
    /// Extra wall-clock wait strictly after VT midpoint was ready while waiting for ME completion.
    let motionWait: Double
    /// Non-overlapping critical-path time from VT submission to midpoint+motion availability.
    let criticalPath: Double

    static func compute(
        submittedAt: Double,
        vtReadyAt: Double,
        motionStartedAt: Double?,
        backwardFinishedAt: Double?,
        forwardFinishedAt: Double?,
        afterMotionWaitAt: Double
    ) -> HybridReadinessTiming {
        let vtReady = max(0, vtReadyAt - submittedAt)
        let backward: Double? =
            if let motionStartedAt, let backwardFinishedAt {
                max(0, backwardFinishedAt - motionStartedAt)
            } else {
                nil
            }
        let forward: Double? =
            if let backwardFinishedAt, let forwardFinishedAt {
                max(0, forwardFinishedAt - backwardFinishedAt)
            } else {
                nil
            }
        let motionFinished = forwardFinishedAt ?? backwardFinishedAt
        let motionWait: Double
        if let motionFinished {
            motionWait = max(0, motionFinished - vtReadyAt)
        } else {
            motionWait = max(0, afterMotionWaitAt - vtReadyAt)
        }
        let readyAt = max(vtReadyAt, motionFinished ?? afterMotionWaitAt)
        let criticalPath = max(0, readyAt - submittedAt)
        return HybridReadinessTiming(
            vtReady: vtReady,
            backwardMotion: backward,
            forwardMotion: forward,
            motionWait: motionWait,
            criticalPath: criticalPath)
    }
}

struct OpticalFlowTiming: Sendable {
    let conversion: Double?
    let downscale: Double
    let forward: Double
    let backward: Double
    let reconstruction: Double
    let hybrid: HybridReadinessTiming?

    init(
        conversion: Double?,
        downscale: Double,
        forward: Double,
        backward: Double,
        reconstruction: Double,
        hybrid: HybridReadinessTiming? = nil
    ) {
        self.conversion = conversion
        self.downscale = downscale
        self.forward = forward
        self.backward = backward
        self.reconstruction = reconstruction
        self.hybrid = hybrid
    }
}

/// Confined to FrameProcessor's actor. Native Vision buffers never leave this executor.
final class FlowInterpolator {
    let input: VideoSize
    let work: VideoSize
    let loadedFromPrecompiledMetallib: Bool
    private(set) var timing: OpticalFlowTiming?
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let nv12Pipeline: (any MTLComputePipelineState)?
    private let downscalePipeline: any MTLComputePipelineState
    private let downscaleNV12Pipeline: (any MTLComputePipelineState)?
    /// Summed forward and backward motion, in motion-image pixels, below which a pixel that is identical in
    /// both sources keeps its source value instead of a resampled one, so static fine detail does not
    /// alternate between sharp sources and softer midpoints. A higher limit can erase thin moving details.
    static let defaultStaticFlowLimit: Float = 4
    /// Preserve HDR10 PQ pixel encoding and BT.2020/ST.2084 attachments across explicit optical-flow and
    /// VideoToolbox FRC backends so generated frames match original frame luminance and color
    /// (`PLAYGLIDE_FLOW_HDR_PASSTHROUGH=1`).
    static var hdrPassthroughEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_FLOW_HDR_PASSTHROUGH"] == "1"
    }
    private let staticFlowLimit: Float
    private let preservesHDR10: Bool
    var hdr10ReferencePQOverride: Bool?
    private let cache: CVMetalTextureCache
    private let forwardTexture: any MTLTexture
    private let backwardTexture: any MTLTexture
    private let lowPool: PixelBufferPool
    private let outputPool: PixelBufferPool
    private let converter = PixelConverter()
    private var conversionPool: PixelBufferPool?
    private let preferFlowTextureViews: Bool
    private(set) var flowTextureViewHits = 0
    private(set) var flowTextureUploadFallbacks = 0
    private var cachedLow: (source: CVReadOnlyPixelBuffer, pixel: CVReadOnlyPixelBuffer)?
    private var cachedConversion: (source: CVReadOnlyPixelBuffer, frame: VideoFrame)?

    private struct Reference {
        let frame: VideoFrame
        let image: CVMetalTexture
        let chroma: CVMetalTexture?
        /// Normalized offset from chroma texel centers to the sample positions of this surface's siting.
        var chromaOffset = SIMD2<Float>(0, 0)
        var isHDR10PQ = false
    }

    private struct FlowField {
        let texture: any MTLTexture
        let view: CVMetalTexture?
        let pixel: CVPixelBuffer?
    }

    init(
        size: VideoSize, preferFlowTextureViews: Bool = true, preferNV12: Bool = true,
        prefersOcclusionSelection: Bool = ProcessInfo.processInfo.environment["PLAYGLIDE_FLOW_OCCLUSION_SELECT"] == "1",
        staticFlowLimit: Float = Float(ProcessInfo.processInfo.environment["PLAYGLIDE_FLOW_STATIC_LIMIT"] ?? "")
            ?? FlowInterpolator.defaultStaticFlowLimit,
        preservesHDR10: Bool = FlowInterpolator.hdrPassthroughEnabled
    ) throws {
        input = size
        self.preferFlowTextureViews = preferFlowTextureViews
        self.staticFlowLimit = max(0, staticFlowLimit)
        self.preservesHDR10 = preservesHDR10
        let scale = min(1, 480.0 / Double(max(size.width, size.height)))
        let work = VideoSize(
            width: max(32, Int((Double(size.width) * scale / 2).rounded()) * 2),
            height: max(32, Int((Double(size.height) * scale / 2).rounded()) * 2))
        self.work = work
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PipelineError(AppText("光流重建需要可用的Metal设备", "Optical flow reconstruction requires a Metal device."))
        }
        self.device = device
        self.queue = queue
        let loaded = try MetalLibraryLoader.loadLibrary(
            device: device,
            requiredFunctions: ["downscale", "interpolate"],
            fallbackSource: Self.shader)
        let library = loaded.library
        loadedFromPrecompiledMetallib = loaded.precompiled
        func makePipeline(name: String, nv12: Bool) throws -> any MTLComputePipelineState {
            let constants = MTLFunctionConstantValues()
            var nv12 = nv12
            constants.setConstantValue(&nv12, type: .bool, index: 0)
            if name == "interpolate" {
                var selectsOcclusion = prefersOcclusionSelection
                constants.setConstantValue(&selectsOcclusion, type: .bool, index: 1)
            }
            let function = try library.makeFunction(name: name, constantValues: constants)
            return try device.makeComputePipelineState(function: function)
        }
        pipeline = try makePipeline(name: "interpolate", nv12: false)
        nv12Pipeline = preferNV12 ? try makePipeline(name: "interpolate", nv12: true) : nil
        downscalePipeline = try makePipeline(name: "downscale", nv12: false)
        downscaleNV12Pipeline = preferNV12 ? try makePipeline(name: "downscale", nv12: true) : nil
        var cache: CVMetalTextureCache?
        let cacheAttributes = [kCVMetalTextureCacheMaximumTextureAgeKey as String: 1.0] as CFDictionary
        guard CVMetalTextureCacheCreate(nil, cacheAttributes, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw PipelineError(AppText("无法创建光流纹理缓存", "Could not create the optical flow texture cache."))
        }
        self.cache = cache
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float, width: work.width,
            height: work.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let forward = device.makeTexture(descriptor: descriptor),
            let backward = device.makeTexture(descriptor: descriptor)
        else {
            throw PipelineError(AppText("无法分配双向光流纹理", "Could not allocate bidirectional optical flow textures."))
        }
        forwardTexture = forward
        backwardTexture = backward
        lowPool = try PixelBufferPool(
            size: work, format: kCVPixelFormatType_32BGRA, allocationThreshold: 8, minimumBufferCount: 3)
        outputPool = try PixelBufferPool(size: size, format: kCVPixelFormatType_32BGRA)
    }

    func reset() {
        cachedLow = nil
        cachedConversion = nil
        timing = nil
        CVMetalTextureCacheFlush(cache, 0)
    }

    func interpolate(previous: VideoFrame, current: VideoFrame, phase: Float = 0.5) throws -> CVReadOnlyPixelBuffer {
        try autoreleasepool { try interpolateFrame(previous: previous, current: current, phase: phase) }
    }

    private func interpolateFrame(previous: VideoFrame, current: VideoFrame, phase: Float) throws
        -> CVReadOnlyPixelBuffer
    {
        guard previous.size == input, current.size == input, phase > 0, phase < 1 else {
            throw PipelineError(AppText("光流参考尺寸或相位无效", "Invalid optical flow reference size or phase."))
        }
        let first: Reference
        let second: Reference
        let reconstructionPipeline: any MTLComputePipelineState
        var conversion: Double?
        if let nv12Pipeline, let a = nv12Reference(previous), let b = nv12Reference(current) {
            first = a
            second = b
            reconstructionPipeline = nv12Pipeline
            cachedConversion = nil
        } else {
            let a = try bgraFrame(previous, conversion: &conversion)
            let b = try bgraFrame(current, conversion: &conversion)
            cachedConversion = b.pixelBuffer === current.pixelBuffer ? nil : (current.pixelBuffer, b)
            first = try bgraReference(a)
            second = try bgraReference(b)
            reconstructionPipeline = pipeline
        }
        let started = mediaHostTime()
        let lowA: CVReadOnlyPixelBuffer
        let lowB: CVReadOnlyPixelBuffer
        if let cachedLow, cachedLow.source === first.frame.pixelBuffer {
            lowA = cachedLow.pixel
            lowB = try reduced(second)
        } else {
            (lowA, lowB) = try reducedPair(first, second)
        }
        cachedLow = (second.frame.pixelBuffer, lowB)
        // Release each request after perform; keep its returned field alive through synthesis.
        let downscaled = mediaHostTime()
        let forward = try flowField(estimate(from: lowA, to: lowB), fallback: forwardTexture)
        let forwardEstimated = mediaHostTime()
        let backward = try flowField(estimate(from: lowB, to: lowA), fallback: backwardTexture)
        let forwardSeconds = forwardEstimated - downscaled
        let backwardSeconds = mediaHostTime() - forwardEstimated
        let estimated = mediaHostTime()
        let isHDR10Output = preservesHDR10 && first.isHDR10PQ && second.isHDR10PQ
        var hdrMode: UInt32 =
            isHDR10Output
            ? UInt32(
                PreviewImageRenderer.hdr10ShaderModeBits(
                    referencePQ: hdr10ReferencePQOverride ?? PreviewImageRenderer.hdr10ReferencePQEnabled))
            : 0
        let output = try outputPool.makeMutable()
        try output.withUnsafeBuffer { outputRaw in
            if isHDR10Output {
                PixelConverter.attachHDR10PQ(to: outputRaw)
            } else {
                PixelConverter.attach709(to: outputRaw)
            }
            let resultTexture = try texture(outputRaw, format: .bgra8Unorm, size: input, usage: .shaderWrite)
            guard let a = CVMetalTextureGetTexture(first.image),
                let b = CVMetalTextureGetTexture(second.image),
                let result = CVMetalTextureGetTexture(resultTexture),
                let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
            else {
                throw PipelineError(
                    AppText("无法编码原尺寸光流重建", "Could not encode native-resolution optical flow reconstruction."))
            }
            encoder.setComputePipelineState(reconstructionPipeline)
            encoder.setTexture(a, index: 0)
            encoder.setTexture(b, index: 1)
            encoder.setTexture(forward.texture, index: 2)
            encoder.setTexture(backward.texture, index: 3)
            encoder.setTexture(result, index: 4)
            if let aChroma = first.chroma, let bChroma = second.chroma {
                encoder.setTexture(CVMetalTextureGetTexture(aChroma), index: 5)
                encoder.setTexture(CVMetalTextureGetTexture(bChroma), index: 6)
            }
            var parameters = SIMD4<Float>(phase, Float(work.width), Float(work.height), staticFlowLimit)
            encoder.setBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            var chromaOffsets = SIMD4<Float>(
                first.chromaOffset.x, first.chromaOffset.y, second.chromaOffset.x, second.chromaOffset.y)
            encoder.setBytes(&chromaOffsets, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setBytes(&hdrMode, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: input.width, height: input.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            // Keep the source buffers and texture views alive through GPU completion.
            withExtendedLifetime((first, second, resultTexture, forward, backward)) {
                command.commit()
                command.waitUntilCompleted()
            }
            if let error = command.error { throw error }
            guard command.status == .completed else {
                throw PipelineError(AppText("光流GPU重建没有完成", "GPU optical flow reconstruction did not complete."))
            }
        }
        let pixel = CVReadOnlyPixelBuffer(output)
        timing = OpticalFlowTiming(
            conversion: conversion, downscale: downscaled - started, forward: forwardSeconds,
            backward: backwardSeconds, reconstruction: mediaHostTime() - estimated)
        return pixel
    }

    private func flowField(_ pixel: CVPixelBuffer, fallback: any MTLTexture) throws -> FlowField {
        guard CVPixelBufferGetWidth(pixel) == work.width, CVPixelBufferGetHeight(pixel) == work.height,
            CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_TwoComponent16Half
        else { throw PipelineError(AppText("光流像素格式或尺寸不一致", "Optical flow pixel formats or dimensions do not match.")) }
        if preferFlowTextureViews, CVPixelBufferGetIOSurface(pixel) != nil {
            var view: CVMetalTexture?
            let attributes = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.rawValue] as CFDictionary
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixel, attributes, .rg16Float, work.width, work.height, 0, &view)
            if status == kCVReturnSuccess, let view, let texture = CVMetalTextureGetTexture(view) {
                flowTextureViewHits += 1
                // Vision results and their views remain actor-owned until synthesis completes.
                return FlowField(texture: texture, view: view, pixel: pixel)
            }
        }
        try upload(pixel, to: fallback)
        flowTextureUploadFallbacks += 1
        return FlowField(texture: fallback, view: nil, pixel: nil)
    }

    private func reduced(_ reference: Reference) throws -> CVReadOnlyPixelBuffer {
        guard let command = queue.makeCommandBuffer() else {
            throw PipelineError(AppText("无法编码光流缩图", "Could not encode optical flow downscaling."))
        }
        let output = try lowPool.makeMutable()
        try output.withUnsafeBuffer { raw in
            let destinationView = try encodeDownscale(reference, into: raw, command: command)
            withExtendedLifetime((reference, destinationView)) {
                command.commit()
                command.waitUntilCompleted()
            }
        }
        if let error = command.error { throw error }
        guard command.status == .completed else {
            throw PipelineError(AppText("光流缩图没有完成", "Optical flow downscaling did not complete."))
        }
        return CVReadOnlyPixelBuffer(output)
    }

    private func reducedPair(_ first: Reference, _ second: Reference) throws -> (
        CVReadOnlyPixelBuffer, CVReadOnlyPixelBuffer
    ) {
        guard let command = queue.makeCommandBuffer() else {
            throw PipelineError(AppText("无法编码光流缩图", "Could not encode optical flow downscaling."))
        }
        let firstOutput = try lowPool.makeMutable()
        let secondOutput = try lowPool.makeMutable()
        try firstOutput.withUnsafeBuffer { firstRaw in
            try secondOutput.withUnsafeBuffer { secondRaw in
                let firstView = try encodeDownscale(first, into: firstRaw, command: command)
                let secondView = try encodeDownscale(second, into: secondRaw, command: command)
                withExtendedLifetime((first, second, firstView, secondView)) {
                    command.commit()
                    command.waitUntilCompleted()
                }
            }
        }
        if let error = command.error { throw error }
        guard command.status == .completed else {
            throw PipelineError(AppText("光流缩图没有完成", "Optical flow downscaling did not complete."))
        }
        return (CVReadOnlyPixelBuffer(firstOutput), CVReadOnlyPixelBuffer(secondOutput))
    }

    private func encodeDownscale(
        _ reference: Reference, into raw: CVPixelBuffer, command: any MTLCommandBuffer
    ) throws -> CVMetalTexture {
        PixelConverter.attach709(to: raw)
        let destinationView = try texture(raw, format: .bgra8Unorm, size: work, usage: .shaderWrite)
        guard let source = CVMetalTextureGetTexture(reference.image),
            let destination = CVMetalTextureGetTexture(destinationView),
            let encoder = command.makeComputeCommandEncoder()
        else { throw PipelineError(AppText("无法编码光流缩图", "Could not encode optical flow downscaling.")) }
        if let chroma = reference.chroma, let downscaleNV12Pipeline {
            encoder.setComputePipelineState(downscaleNV12Pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.setTexture(CVMetalTextureGetTexture(chroma), index: 2)
        } else {
            encoder.setComputePipelineState(downscalePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
        }
        var chromaOffset = reference.chromaOffset
        encoder.setBytes(&chromaOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        var hdrMode: UInt32 =
            preservesHDR10 && reference.isHDR10PQ
            ? UInt32(
                PreviewImageRenderer.hdr10ShaderModeBits(
                    referencePQ: hdr10ReferencePQOverride ?? PreviewImageRenderer.hdr10ReferencePQEnabled))
            : 0
        encoder.setBytes(&hdrMode, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: work.width, height: work.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        return destinationView
    }
    private func estimate(from: CVReadOnlyPixelBuffer, to: CVReadOnlyPixelBuffer) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        try autoreleasepool {
            try from.withUnsafeBuffer { source in
                try to.withUnsafeBuffer { target in
                    let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: target, options: [:])
                    request.revision = VNGenerateOpticalFlowRequestRevision1
                    request.computationAccuracy = .medium
                    request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
                    try VNImageRequestHandler(cvPixelBuffer: source, options: [:]).perform([request])
                    result = request.results?.first?.pixelBuffer
                }
            }
        }
        guard let result else {
            throw PipelineError(AppText("光流估计没有返回位移场", "Optical flow estimation returned no displacement field."))
        }
        return result
    }
    private func upload(_ pixel: CVPixelBuffer, to texture: any MTLTexture) throws {
        guard CVPixelBufferGetWidth(pixel) == work.width, CVPixelBufferGetHeight(pixel) == work.height,
            CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_TwoComponent16Half,
            CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess
        else {
            throw PipelineError(AppText("光流像素格式或尺寸不一致", "Optical flow pixel formats or dimensions do not match."))
        }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else {
            throw PipelineError(AppText("光流数据不可读", "Optical flow data is unreadable."))
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, work.width, work.height), mipmapLevel: 0, withBytes: base,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixel))
    }
    private func bgraFrame(_ frame: VideoFrame, conversion: inout Double?) throws -> VideoFrame {
        if frame.pixelBuffer.withUnsafeBuffer({ CVPixelBufferGetPixelFormatType($0) }) == kCVPixelFormatType_32BGRA {
            return frame
        }
        if let cachedConversion, cachedConversion.source === frame.pixelBuffer { return cachedConversion.frame }
        let started = mediaHostTime()
        let pool = try conversionPool ?? PixelBufferPool(size: input, format: kCVPixelFormatType_32BGRA)
        conversionPool = pool
        let converted = try converter.convert(frame, pool: pool, preserveHDR10: preservesHDR10)
        conversion = (conversion ?? 0) + (mediaHostTime() - started)
        return converted
    }

    private func bgraReference(_ frame: VideoFrame) throws -> Reference {
        var view: CVMetalTexture?
        var isHDR10 = false
        try frame.pixelBuffer.withUnsafeBuffer { pixel in
            isHDR10 = preservesHDR10 && PixelConverter.isHDR10PQ(pixel)
            view = try texture(pixel, format: .bgra8Unorm, size: input)
        }
        guard let view else {
            throw PipelineError(AppText("无法映射 BGRA 参考图像", "Could not map the BGRA reference image."))
        }
        return Reference(frame: frame, image: view, chroma: nil, isHDR10PQ: isHDR10)
    }

    private func nv12Reference(_ frame: VideoFrame) -> Reference? {
        var reference: Reference?
        frame.pixelBuffer.withUnsafeBuffer { pixel in
            // The shader decodes progressive video-range Rec.709 (or HDR10 PQ BT.2020 when preservesHDR10 is enabled)
            // at center, left, top or bottom 4:2:0 siting. Delegate any other color profile or plane layout to Core Image.
            guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                CVPixelBufferGetPlaneCount(pixel) == 2, CVPixelBufferGetIOSurface(pixel) != nil
            else { return }
            let isHDR10 = preservesHDR10 && PixelConverter.isHDR10PQ(pixel)
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
            guard validColor,
                ((CVBufferCopyAttachment(pixel, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue ?? 1) == 1,
                let siting = PixelConverter.chromaSitingOffset(of: pixel)
            else { return }
            let chroma = VideoSize(width: input.width / 2, height: input.height / 2)
            guard CVPixelBufferGetWidthOfPlane(pixel, 0) == input.width,
                CVPixelBufferGetHeightOfPlane(pixel, 0) == input.height,
                input.width.isMultiple(of: 2), input.height.isMultiple(of: 2),
                CVPixelBufferGetWidthOfPlane(pixel, 1) == chroma.width,
                CVPixelBufferGetHeightOfPlane(pixel, 1) == chroma.height,
                let lumaView = try? texture(pixel, format: .r8Unorm, size: input),
                let chromaView = try? texture(pixel, format: .rg8Unorm, size: chroma, plane: 1)
            else { return }
            reference = Reference(
                frame: frame, image: lumaView, chroma: chromaView,
                chromaOffset: siting / SIMD2(Float(input.width), Float(input.height)), isHDR10PQ: isHDR10)
        }
        return reference
    }

    private func texture(
        _ pixel: CVPixelBuffer, format: MTLPixelFormat, size: VideoSize, plane: Int = 0,
        usage: MTLTextureUsage = .shaderRead
    ) throws -> CVMetalTexture {
        var result: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary
        guard
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixel, attributes, format,
                size.width, size.height, plane, &result) == kCVReturnSuccess,
            let result, CVMetalTextureGetTexture(result) != nil
        else { throw PipelineError(AppText("无法映射原尺寸图像纹理", "Could not map the native-resolution image texture.")) }
        return result
    }

    static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        constant bool nv12 [[function_constant(0)]];
        constant bool selectOcclusion [[function_constant(1)]];
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        // Bit-level IEEE 754 exponent checks survive Metal's default fast-math optimization.
        inline bool isFiniteHalf(half value) {
            return (as_type<ushort>(value) & 0x7C00u) != 0x7C00u;
        }
        inline half3 nv12Color(half luma, half2 chroma, uint hdrMode) {
            half y = fma(luma, half(255.0 / 219.0), half(-16.0 / 219.0));
            half2 cbcr = fma(chroma, half(255.0 / 224.0), half(-128.0 / 224.0));
            if (hdrMode == 3u) {
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
                    half t = saturate(yPos * half(1.0 / 0.08));
                    yAnchored = yPos * mix(half(0.25), half(1.0), t);
                    cBoost = cbcr * mix(half(0.75), half(1.12), t);
                } else {
                    yAnchored = max(half(0.0), (yPos - half(0.042)) * half(1.0 / 0.958));
                    cBoost = cbcr * half(1.12);
                }
                half3 rgb = saturate(half3(
                    fma(half(1.4746), cBoost.y, yAnchored),
                    fma(half(-0.57135), cBoost.y, fma(half(-0.16455), cBoost.x, yAnchored)),
                    fma(half(1.8814), cBoost.x, yAnchored)));
                return saturate(pow(rgb, half3(1.10)));
            }
            return saturate(half3(
                fma(half(1.5748), cbcr.y, y),
                fma(half(-0.468124), cbcr.y, fma(half(-0.187324), cbcr.x, y)),
                fma(half(1.8556), cbcr.x, y)));
        }
        // chromaOffset moves from chroma texel centers to the sample positions of the surface's 4:2:0 siting.
        inline half3 colorAt(texture2d<half, access::sample> image, texture2d<half, access::sample> chroma, float2 uv,
                             float2 chromaOffset, uint hdrMode) {
            half3 value = image.sample(linearSampler, uv).rgb;
            if (!nv12) return value;
            return nv12Color(value.r, chroma.sample(linearSampler, uv + chromaOffset).rg, hdrMode);
        }
        inline half valid(float2 p) { return all(p >= 0.0f) && all(p <= 1.0f) ? half(1.0) : half(0.0); }
        inline float2 flowAt(texture2d<half, access::sample> field, float2 uv) {
            half2 value = field.sample(linearSampler, uv).xy;
            return (isFiniteHalf(value.x) && isFiniteHalf(value.y)) ? float2(value) : float2(0.0f);
        }
        kernel void downscale(texture2d<half, access::sample> image [[texture(0)]],
                              texture2d<half, access::write> output [[texture(1)]],
                              texture2d<half, access::sample> chroma [[texture(2), function_constant(nv12)]],
                              constant float2 &chromaOffset [[buffer(0)]],
                              constant uint &hdrMode [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float2 outSize = float2(output.get_width(), output.get_height());
            float2 base = (float2(gid) + 0.5f) / outSize;
            half3 color;
            if (image.get_width() == output.get_width() && image.get_height() == output.get_height()) {
                color = colorAt(image, chroma, base, chromaOffset, hdrMode);
            } else {
                float2 offset = 0.25f / outSize;
                color = (colorAt(image, chroma, base + float2(-offset.x, -offset.y), chromaOffset, hdrMode)
                       + colorAt(image, chroma, base + float2( offset.x, -offset.y), chromaOffset, hdrMode)
                       + colorAt(image, chroma, base + float2(-offset.x,  offset.y), chromaOffset, hdrMode)
                       + colorAt(image, chroma, base + float2( offset.x,  offset.y), chromaOffset, hdrMode)) * half(0.25);
            }
            output.write(half4(saturate(color), half(1.0)), gid);
        }
        kernel void interpolate(texture2d<half, access::sample> a [[texture(0)]],
                                texture2d<half, access::sample> b [[texture(1)]],
                                texture2d<half, access::sample> forward [[texture(2)]],
                                texture2d<half, access::sample> backward [[texture(3)]],
                                texture2d<half, access::write> output [[texture(4)]],
                                texture2d<half, access::sample> aChroma [[texture(5), function_constant(nv12)]],
                                texture2d<half, access::sample> bChroma [[texture(6), function_constant(nv12)]],
                                constant float4 &parameters [[buffer(0)]],
                                constant float4 &chromaOffsets [[buffer(1)]],
                                constant uint &hdrMode [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float2 uv = (float2(gid) + 0.5f) / float2(output.get_width(), output.get_height());
            float2 invFlowSize = 1.0f / parameters.yz;
            float phase = parameters.x;
            float2 aOffset = chromaOffsets.xy, bOffset = chromaOffsets.zw;
            float2 originalForward = flowAt(forward, uv), originalBackward = flowAt(backward, uv);
            float motionSum = length(originalForward) + length(originalBackward);
            bool lowMotion = motionSum < 0.1f;
            if (!lowMotion && motionSum < parameters.w) {
                // An unchanged pixel under small estimated motion keeps its exact source value, so static
                // fine detail does not alternate between source and resampled images.
                half3 originalA = colorAt(a, aChroma, uv, aOffset, hdrMode);
                half3 originalB = colorAt(b, bChroma, uv, bOffset, hdrMode);
                if (length(originalA - originalB) < half(0.006)) {
                    output.write(half4(originalA, half(1.0)), gid);
                    return;
                }
            }
            half3 fallbackColor = half3(0.0);
            if (lowMotion) {
                half3 originalA = colorAt(a, aChroma, uv, aOffset, hdrMode);
                half3 originalB = colorAt(b, bChroma, uv, bOffset, hdrMode);
                if (length(originalA - originalB) < half(0.006)) {
                    output.write(half4(originalA, half(1.0)), gid);
                    return;
                }
                fallbackColor = phase < 0.5f ? originalA : originalB;
            }
            float2 p = mix(uv, uv - phase * originalForward * invFlowSize, 0.8f);
            float2 q = mix(uv, uv - (1.0f - phase) * originalBackward * invFlowSize, 0.8f);
            for (int i = 1; i < 4; ++i) {
                p = mix(p, uv - phase * flowAt(forward, p) * invFlowSize, 0.8f);
                q = mix(q, uv - (1.0f - phase) * flowAt(backward, q) * invFlowSize, 0.8f);
            }
            float2 f = flowAt(forward, p);
            float2 r = flowAt(backward, q);
            float2 nextP = p + f * invFlowSize, previousQ = q + r * invFlowSize;
            half3 ca = colorAt(a, aChroma, p, aOffset, hdrMode), cb = colorAt(b, bChroma, q, bOffset, hdrMode);
            half errorA = half(min(length(f + flowAt(backward, nextP)), 100.0f));
            half errorB = half(min(length(r + flowAt(forward, previousQ)), 100.0f));
            half photoA = length(ca - colorAt(b, bChroma, nextP, bOffset, hdrMode));
            half photoB = length(cb - colorAt(a, aChroma, previousQ, aOffset, hdrMode));
            half hPhase = half(phase);
            half wa = valid(p) * valid(nextP) * exp(fma(half(-8.0), photoA, half(-0.7) * errorA)) * (half(1.0) - hPhase);
            half wb = valid(q) * valid(previousQ) * exp(fma(half(-8.0), photoB, half(-0.7) * errorB)) * hPhase;
            if (!isFiniteHalf(wa)) wa = half(0.0);
            if (!isFiniteHalf(wb)) wb = half(0.0);
            half weightSum = wa + wb;
            half3 color;
            if (weightSum < half(0.05)) {
                if (lowMotion) color = fallbackColor;
                else color = phase < 0.5f ? colorAt(a, aChroma, uv, aOffset, hdrMode) : colorAt(b, bChroma, uv, bOffset, hdrMode);
            } else {
                color = (wa * ca + wb * cb) / weightSum;
                if (selectOcclusion && !lowMotion && length(ca - cb) > half(0.08)) {
                    // Cancel the blend's phase bias before comparing the two directions.
                    half confidenceA = wa * hPhase;
                    half confidenceB = wb * (half(1.0) - hPhase);
                    if (confidenceA > half(4.0) * confidenceB) color = ca;
                    else if (confidenceB > half(4.0) * confidenceA) color = cb;
                }
            }
            output.write(half4(saturate(color), half(1.0)), gid);
        }
        """
}
