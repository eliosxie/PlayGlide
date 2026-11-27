import CoreMedia
import CoreVideo
import Foundation
import Metal
import Synchronization
import VideoToolbox

/// Automatic 1440p/4K 2× path (`PLAYGLIDE_HYBRID_VT=0` disables): originals keep their native size; each midpoint comes from VT
/// low-latency interpolation of downscaled copies, upscaled with Catmull-Rom, and pixels that are
/// unchanged between the sources take the source value so static detail stays native and does not flicker.
/// Confined to FrameProcessor's actor; the native VT call is awaited by the actor itself.
final class HybridInterpolator {
    /// Controls moving-region 4K/1440p high-frequency detail recovery and overshoot-clamped CAS sharpening.
    /// Default `.detail` runs 16×16 media-engine motion estimation in parallel with VT 1080p and applies light
    /// CAS (`0.10`) on moving pixels; `PLAYGLIDE_HYBRID_DETAIL=none` disables both for A/B runs.
    enum DetailMode: String, Sendable {
        case none
        case cas
        case detail
        case detailOnly = "detail-only"

        static let configured =
            Self(rawValue: ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_DETAIL"] ?? "") ?? .detail

        var usesMotion: Bool { self == .detail || self == .detailOnly }
        var sharpenStrength: Float {
            switch self {
            case .cas:
                return Float(ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_SHARPEN"] ?? "") ?? 0.14
            case .detail:
                return Float(ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_SHARPEN"] ?? "") ?? 0.10
            case .none, .detailOnly:
                return 0
            }
        }
    }

    /// Media-engine motion estimation timestamps for separating overlapping ME work from VT wait time.
    struct MotionTiming: Sendable, Equatable {
        let startedAt: Double
        let backwardFinishedAt: Double
        let forwardFinishedAt: Double?
    }

    /// Hardware motion vectors estimated concurrently with VT on the media engine.
    /// `backward` maps `B → A` (always computed in detail mode); `forward` maps `A → B` when bidirectional
    /// occlusion estimation is enabled (`PLAYGLIDE_HYBRID_BIDIR != "0"`).
    struct MotionFields: Sendable {
        let backward: CVReadOnlyPixelBuffer
        let forward: CVReadOnlyPixelBuffer?
        let timing: MotionTiming?

        init(
            backward: CVReadOnlyPixelBuffer,
            forward: CVReadOnlyPixelBuffer?,
            timing: MotionTiming? = nil
        ) {
            self.backward = backward
            self.forward = forward
            self.timing = timing
        }
    }

    private struct HybridPipelines: Sendable {
        let loadedFromPrecompiledMetallib: Bool
        let shrinkLuma: any MTLComputePipelineState
        let shrinkChroma: any MTLComputePipelineState
        let selectMotion: any MTLComputePipelineState
        let selectMotionBidir: any MTLComputePipelineState
        let selectMotionSampleMid: any MTLComputePipelineState
        let selectMotionBidirSampleMid: any MTLComputePipelineState
        let mergeNV12: any MTLComputePipelineState
        let mergeBGRA: any MTLComputePipelineState
        let mergeDetailNV12: any MTLComputePipelineState
        let mergeDetailBGRA: any MTLComputePipelineState
        let mergeNV12Out: any MTLComputePipelineState
        let mergeDetailNV12Out: any MTLComputePipelineState
        let mergeNV12Out2x: any MTLComputePipelineState
        let mergeDetailNV12Out2x: any MTLComputePipelineState
    }

    private static let pipelineCache = Mutex<[UInt64: HybridPipelines]>([:])

    static var lazyResourcesEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_LAZY_RESOURCES"] != "0"
    }
    /// Contrast-gated background motion borrowing around static high-contrast HUD text
    /// (`PLAYGLIDE_HYBRID_HUD_DEHALO=0` opts out for A/B rollback).
    static var hudDehaloEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_HUD_DEHALO"] != "0"
    }
    static var spatialDeferredComposeEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_SPATIAL_DEFERRED_COMPOSE"] == "1"
    }
    /// Fallback to the ready VT midpoint instead of holding the previous original frame if deferred hybrid
    /// texture mapping fails (`PLAYGLIDE_DEFERRED_FALLBACK_MIDPOINT=0` restores previous-frame placeholder).
    static var deferredFallbackMidpointEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_DEFERRED_FALLBACK_MIDPOINT"] != "0"
    }
    /// Use IEEE-754 exponent bit-mask checks for motion vectors so Metal's default fast-math mode cannot
    /// optimize `isfinite()` away (`PLAYGLIDE_SHADER_SAFE_FINITE=0` restores legacy `isfinite` for A/B).
    static var shaderSafeFiniteEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_SHADER_SAFE_FINITE"] != "0"
    }
    /// Precompute hybrid `selectMotion` asynchronously into a bounded 3-slot Metal texture pool synced via
    /// `MTLSharedEvent` so the display link callback skips compute work (`PLAYGLIDE_PRECOMPUTE_MOTION_DETAIL=0`
    /// opts out for A/B rollback).
    static var precomputeMotionDetailEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_PRECOMPUTE_MOTION_DETAIL"] != "0"
    }
    /// Fuse CPU 2:1 NV12 luma and chroma downscale into a single parallel barrier and move 540p forward
    /// downscaling into the concurrent motion-estimation task (`PLAYGLIDE_FUSED_CPU_SHRINK=1`).
    static var fusedCPUShrinkEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_FUSED_CPU_SHRINK"] == "1"
    }
    /// Preserve paired moving-detail sharpness on MetalFX Spatial 4K paths without disturbing static HUD
    /// (`PLAYGLIDE_SPATIAL_MOVING_DETAIL=0` opts out for A/B rollback).
    static var spatialMovingDetailEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_SPATIAL_MOVING_DETAIL"] != "0"
    }
    /// Protect fast-moving small icons crossing smooth static backgrounds via local 3×3 envelope
    /// breakout gating without degrading high-contrast static text (`PLAYGLIDE_HYBRID_ICON_ENVELOPE=0` opts out).
    static var iconEnvelopeEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_ICON_ENVELOPE"] != "0"
    }
    /// Modulate midpoint CAS inversely with motion-detail confidence `(1 - 0.65 * conf)` so occlusion fallback
    /// regions match native 4K sharpness without over-sharpening recovered moving detail (`PLAYGLIDE_ADAPTIVE_CAS=0`
    /// opts out for A/B rollback).
    static var adaptiveCASEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_ADAPTIVE_CAS"] != "0"
    }

    let input: VideoSize
    let low: VideoSize
    let multiplier: Int
    let detailMode: DetailMode
    let reusedCompiledPipelines: Bool
    var loadedFromPrecompiledMetallib: Bool { pipelines.loadedFromPrecompiledMetallib }
    let session = VTFrameProcessor()
    private let motionSession: VTMotionEstimationSession?
    private let forwardMotionSession: VTMotionEstimationSession?
    private let motionSize: VideoSize
    private let forwardMotionSize: VideoSize
    private let selectSize: VideoSize
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipelines: HybridPipelines
    private var shrinkLuma: any MTLComputePipelineState { pipelines.shrinkLuma }
    private var shrinkChroma: any MTLComputePipelineState { pipelines.shrinkChroma }
    private var selectMotion: any MTLComputePipelineState { pipelines.selectMotion }
    private var selectMotionBidir: any MTLComputePipelineState { pipelines.selectMotionBidir }
    private var selectMotionSampleMid: any MTLComputePipelineState { pipelines.selectMotionSampleMid }
    private var selectMotionBidirSampleMid: any MTLComputePipelineState { pipelines.selectMotionBidirSampleMid }
    private var mergeNV12: any MTLComputePipelineState { pipelines.mergeNV12 }
    private var mergeBGRA: any MTLComputePipelineState { pipelines.mergeBGRA }
    private var mergeDetailNV12: any MTLComputePipelineState { pipelines.mergeDetailNV12 }
    private var mergeDetailBGRA: any MTLComputePipelineState { pipelines.mergeDetailBGRA }
    private var mergeNV12Out: any MTLComputePipelineState { pipelines.mergeNV12Out }
    private var mergeDetailNV12Out: any MTLComputePipelineState { pipelines.mergeDetailNV12Out }
    private var mergeNV12Out2x: any MTLComputePipelineState { pipelines.mergeNV12Out2x }
    private var mergeDetailNV12Out2x: any MTLComputePipelineState { pipelines.mergeDetailNV12Out2x }
    private var motionDetailTexture: (any MTLTexture)?
    private var motionDetailPool: MotionDetailSlotPool?
    var precomputedMotionPoolExhaustions: Int { motionDetailPool?.exhaustionFallbacks ?? 0 }
    var precomputedMotionInUseCount: Int { motionDetailPool?.inUseCount ?? 0 }
    private let cache: CVMetalTextureCache
    private let transfer: VTPixelTransferSession
    private let sourcePool: PixelBufferPool
    private let motionSourcePool: PixelBufferPool?
    private let forwardSourcePool: PixelBufferPool?
    private let destinationPool: PixelBufferPool
    private var outputPool: PixelBufferPool?
    private var outputNV12Pool: PixelBufferPool?
    var hasAllocatedOutputPools: Bool { outputPool != nil || outputNV12Pool != nil }
    private let outputsNV12 = ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_NV12_OUT"] != "0"
    private final class ForwardLowCache: Sendable {
        private let entries = Mutex<[(source: CVReadOnlyPixelBuffer, low: CVReadOnlyPixelBuffer)]>([])
        func lookup(_ key: CVReadOnlyPixelBuffer) -> CVReadOnlyPixelBuffer? {
            entries.withLock { $0.first(where: { $0.source === key })?.low }
        }
        func insert(key: CVReadOnlyPixelBuffer, value: CVReadOnlyPixelBuffer) {
            entries.withLock { list in
                list = Array((list + [(key, value)]).suffix(2))
            }
        }
        func removeAll() { entries.withLock { $0.removeAll() } }
    }

    private var cachedLow: [(source: CVReadOnlyPixelBuffer, low: CVReadOnlyPixelBuffer)] = []
    private var cachedMotionLow: [(source: CVReadOnlyPixelBuffer, low: CVReadOnlyPixelBuffer)] = []
    private let cachedForwardLow = ForwardLowCache()
    /// Fuses hybrid midpoint composition directly into the Metal preview render pass, removing the 12.4 MB
    /// 4K 420v intermediate write and CPU waitUntilCompleted() from the critical path. `PLAYGLIDE_DEFERRED_COMPOSE=0`
    /// restores eager 420v composition for A/B runs.
    static let deferredComposeEnabled = ProcessInfo.processInfo.environment["PLAYGLIDE_DEFERRED_COMPOSE"] != "0"

    /// Tests turn this off to measure the upscaled VT midpoint alone.
    var restoresStaticPixels = true
    /// Exact 2:1 NV12 inputs (4K -> 1080p) shrink on the CPU with SIMD halving adds instead of waking
    /// the GPU for a separate Metal pass. `PLAYGLIDE_HYBRID_CPU_SHRINK=0` keeps Metal for A/B runs.
    var usesCPUDownscale = ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_CPU_SHRINK"] != "0"
    /// Single-barrier fused luma+chroma CPU shrink and async 540p forward downscale (`PLAYGLIDE_FUSED_CPU_SHRINK=1`).
    var usesFusedCPUShrink = HybridInterpolator.fusedCPUShrinkEnabled
    /// Optional overrides for deterministic GPU tests without mutating process environment variables.
    var iconEnvelopeOverride: Bool?
    var hudDehaloOverride: Bool?
    var adaptiveCASOverride: Bool?

    /// The largest even size within VT low-latency's limits that keeps the input aspect ratio.
    /// Passing `maxHeight: 720` (or `PLAYGLIDE_HYBRID_LOW=720`) stays inside Apple Neural Engine
    /// on-chip SRAM without spatial tiling (`SpatialSplitGenericDAG`), cutting VT time from ~12 ms to ~3.5 ms.
    static func lowSize(for input: VideoSize, maxHeight: Int? = nil) -> VideoSize? {
        let maximum = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1) ?? 0
        let pixels = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1) ?? 0
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported, maximum > 0, pixels > 0,
            input.width > 0, input.height > 0
        else { return nil }
        var scale = min(1, Double(maximum) / Double(max(input.width, input.height)))
        scale = min(scale, (Double(pixels) / Double(input.pixels)).squareRoot())
        let envCap = ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_LOW"].flatMap(Int.init)
        if let heightCap = envCap ?? maxHeight, heightCap >= 360, heightCap < input.height {
            scale = min(scale, Double(heightCap) / Double(input.height))
        }
        let size = VideoSize(
            width: Int((Double(input.width) * scale / 2).rounded()) * 2,
            height: Int((Double(input.height) * scale / 2).rounded()) * 2)
        return size.width < input.width && size.height < input.height ? size : nil
    }

    init(
        size: VideoSize, low requested: VideoSize? = nil, multiplier: Int = 2, detailMode: DetailMode = .configured,
        bidirectionalMotion: Bool = ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_BIDIR"] != "0"
    ) throws {
        let clampedMultiplier = multiplier == 4 ? 4 : 2
        guard let low = requested ?? Self.lowSize(for: size),
            let configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: low.width, frameHeight: low.height,
                numberOfInterpolatedFrames: clampedMultiplier == 4 ? 2 : 1),
            let format = configuration.supportedPixelFormats.first,
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            throw PipelineError(
                AppText(
                    "混合插帧需要 VT 低延迟 420v 输入：\(size)",
                    "Hybrid interpolation requires 420v input for VideoToolbox Low Latency: \(size)"))
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PipelineError(AppText("混合插帧需要可用的Metal设备", "Hybrid interpolation requires a Metal device."))
        }
        input = size
        self.low = low
        self.multiplier = clampedMultiplier
        self.detailMode = detailMode
        let usesFullResolutionMotion =
            ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_ME_SCALE"] == "full"
        let upgradedLowMotion =
            !usesFullResolutionMotion
            && ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_L2_ME"] != "0"
            && low.height < 1080 && size.width == 3840 && size.height == 2160
        let motionSize =
            usesFullResolutionMotion
            ? size
            : (upgradedLowMotion ? VideoSize(width: size.width / 2, height: size.height / 2) : low)
        let selectSize = upgradedLowMotion ? motionSize : low
        let usesFullForward = ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_BIDIR"] == "full"
        let halfForward =
            !usesFullForward && motionSize.width >= 1280 && motionSize.height >= 720
            && motionSize.width.isMultiple(of: 32) && motionSize.height.isMultiple(of: 4)
        let forwardMotionSize =
            halfForward ? VideoSize(width: motionSize.width / 2, height: motionSize.height / 2) : motionSize
        self.motionSize = motionSize
        self.forwardMotionSize = forwardMotionSize
        self.selectSize = selectSize
        let lazyResources = Self.lazyResourcesEnabled
        if detailMode.usesMotion {
            motionSession = try? VTMotionEstimationSession(
                width: UInt32(motionSize.width), height: UInt32(motionSize.height),
                motionVectorSize: .blockSize16x16, useMultiPassSearch: true)
            forwardMotionSession =
                bidirectionalMotion
                ? (try? VTMotionEstimationSession(
                    width: UInt32(forwardMotionSize.width), height: UInt32(forwardMotionSize.height),
                    motionVectorSize: .blockSize16x16, useMultiPassSearch: true))
                : nil
            if lazyResources {
                motionDetailTexture = nil
            } else {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba16Float, width: selectSize.width, height: selectSize.height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite]
                motionDetailTexture = device.makeTexture(descriptor: descriptor)
            }
        } else {
            motionSession = nil
            forwardMotionSession = nil
            motionDetailTexture = nil
        }
        self.device = device
        self.queue = queue
        let resolvedPipelines = try Self.resolvePipelines(device: device, useCache: lazyResources)
        pipelines = resolvedPipelines.pipelines
        reusedCompiledPipelines = resolvedPipelines.reused
        var cache: CVMetalTextureCache?
        let attributes = [kCVMetalTextureCacheMaximumTextureAgeKey as String: 1.0] as CFDictionary
        guard CVMetalTextureCacheCreate(nil, attributes, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw PipelineError(AppText("无法创建混合插帧纹理缓存", "Could not create the hybrid interpolation texture cache."))
        }
        self.cache = cache
        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr, let transfer
        else { throw PipelineError(AppText("无法创建缩图会话", "Could not create the downscaling session.")) }
        self.transfer = transfer
        sourcePool = try PixelBufferPool(
            size: low, format: format, requirements: configuration.sourcePixelBufferAttributes)
        motionSourcePool =
            upgradedLowMotion && detailMode.usesMotion
            ? try PixelBufferPool(size: motionSize, format: format) : nil
        forwardSourcePool =
            forwardMotionSession != nil && forwardMotionSize != motionSize
            ? try PixelBufferPool(size: forwardMotionSize, format: format) : nil
        destinationPool = try PixelBufferPool(
            size: low, format: format, requirements: configuration.destinationPixelBufferAttributes)
        if lazyResources {
            outputPool = nil
            outputNV12Pool = nil
        } else {
            outputPool = try PixelBufferPool(size: size, format: kCVPixelFormatType_32BGRA)
            outputNV12Pool = try PixelBufferPool(size: size, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
        try session.startSession(configuration: configuration)
    }

    private static func resolvePipelines(device: any MTLDevice, useCache: Bool) throws -> (
        pipelines: HybridPipelines, reused: Bool
    ) {
        if useCache, let cached = pipelineCache.withLock({ $0[device.registryID] }) {
            return (cached, true)
        }
        let compiled = try makePipelines(device: device)
        if useCache {
            pipelineCache.withLock { $0[device.registryID] = compiled }
        }
        return (compiled, false)
    }

    private static func makePipelines(device: any MTLDevice) throws -> HybridPipelines {
        let loaded = try MetalLibraryLoader.loadLibrary(
            device: device,
            requiredFunctions: ["shrinkLuma", "shrinkChroma", "selectMotion", "merge", "mergeNV12Out"],
            fallbackSource: Self.shader)
        let library = loaded.library
        func pipeline(
            _ name: String, nv12: Bool, hasMotion: Bool = false, hasForwardMotion: Bool = false,
            exactTwoX: Bool = false, sampleMid: Bool = false
        ) throws -> any MTLComputePipelineState {
            let constants = MTLFunctionConstantValues()
            var nv12 = nv12
            var hasMotion = hasMotion
            var hasForwardMotion = hasForwardMotion
            var exactTwoX = exactTwoX
            var sampleMid = sampleMid
            constants.setConstantValue(&nv12, type: .bool, index: 0)
            constants.setConstantValue(&hasMotion, type: .bool, index: 1)
            constants.setConstantValue(&hasForwardMotion, type: .bool, index: 2)
            constants.setConstantValue(&exactTwoX, type: .bool, index: 3)
            constants.setConstantValue(&sampleMid, type: .bool, index: 4)
            return try device.makeComputePipelineState(
                function: try library.makeFunction(name: name, constantValues: constants))
        }
        return HybridPipelines(
            loadedFromPrecompiledMetallib: loaded.precompiled,
            shrinkLuma: try pipeline("shrinkLuma", nv12: true),
            shrinkChroma: try pipeline("shrinkChroma", nv12: true),
            selectMotion: try pipeline("selectMotion", nv12: true, hasMotion: true, hasForwardMotion: false),
            selectMotionBidir: try pipeline("selectMotion", nv12: true, hasMotion: true, hasForwardMotion: true),
            selectMotionSampleMid: try pipeline(
                "selectMotion", nv12: true, hasMotion: true, hasForwardMotion: false, sampleMid: true),
            selectMotionBidirSampleMid: try pipeline(
                "selectMotion", nv12: true, hasMotion: true, hasForwardMotion: true, sampleMid: true),
            mergeNV12: try pipeline("merge", nv12: true, hasMotion: false),
            mergeBGRA: try pipeline("merge", nv12: false, hasMotion: false),
            mergeDetailNV12: try pipeline("merge", nv12: true, hasMotion: true),
            mergeDetailBGRA: try pipeline("merge", nv12: false, hasMotion: true),
            mergeNV12Out: try pipeline("mergeNV12Out", nv12: true, hasMotion: false, exactTwoX: false),
            mergeDetailNV12Out: try pipeline("mergeNV12Out", nv12: true, hasMotion: true, exactTwoX: false),
            mergeNV12Out2x: try pipeline("mergeNV12Out", nv12: true, hasMotion: false, exactTwoX: true),
            mergeDetailNV12Out2x: try pipeline("mergeNV12Out", nv12: true, hasMotion: true, exactTwoX: true))
    }

    private func resolveOutputPool(nv12: Bool) throws -> PixelBufferPool {
        if nv12 {
            if let existing = outputNV12Pool { return existing }
            let pool = try PixelBufferPool(size: input, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            outputNV12Pool = pool
            return pool
        }
        if let existing = outputPool { return existing }
        let pool = try PixelBufferPool(size: input, format: kCVPixelFormatType_32BGRA)
        outputPool = pool
        return pool
    }

    private func resolveMotionDetailTexture() -> (any MTLTexture)? {
        guard detailMode.usesMotion else { return nil }
        if let existing = motionDetailTexture { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: selectSize.width, height: selectSize.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        let created = device.makeTexture(descriptor: descriptor)
        motionDetailTexture = created
        return created
    }

    deinit { session.endSession() }

    func reset() {
        cachedLow.removeAll()
        cachedMotionLow.removeAll()
        cachedForwardLow.removeAll()
        motionDetailPool?.invalidateAll()
        CVMetalTextureCacheFlush(cache, 0)
    }

    /// Downscales 4K NV12 to 1080p on CPU SIMD for L2 (720p ANE VT + 1080p media-engine motion).
    private func motionLowFrame(_ frame: VideoFrame) throws -> CVReadOnlyPixelBuffer? {
        guard let motionSourcePool else { return nil }
        if let hit = cachedMotionLow.first(where: { $0.source === frame.pixelBuffer }) { return hit.low }
        let output = try motionSourcePool.makeMutable()
        guard
            Self.shrinkNV12HalfOnCPU(
                from: frame.pixelBuffer, sourceSize: input, to: output, targetSize: motionSize,
                fused: usesFusedCPUShrink)
        else {
            return nil
        }
        let low = CVReadOnlyPixelBuffer(output)
        cachedMotionLow = Array((cachedMotionLow + [(frame.pixelBuffer, low)]).suffix(2))
        return low
    }

    /// Downscales the 1080p/720p motion reference 2:1 on CPU SIMD (~0.06 ms) for lightweight asymmetric
    /// forward occlusion estimation (~0.89 ms on the media engine at 960×540).
    private func forwardLowFrame(from motionRef: CVReadOnlyPixelBuffer, key: CVReadOnlyPixelBuffer) throws
        -> CVReadOnlyPixelBuffer?
    {
        guard let forwardSourcePool else { return motionRef }
        if let hit = cachedForwardLow.lookup(key) { return hit }
        let output = try forwardSourcePool.makeMutable()
        guard
            Self.shrinkNV12HalfOnCPU(
                from: motionRef, sourceSize: motionSize, to: output, targetSize: forwardMotionSize,
                fused: usesFusedCPUShrink)
        else { return nil }
        let low = CVReadOnlyPixelBuffer(output)
        cachedForwardLow.insert(key: key, value: low)
        return low
    }

    /// The downscaled copy handed to VT, reused for the next pair. Exact 2:1 NV12 inputs shrink on the
    /// CPU in one pass; other NV12 sizes use Metal, and non-NV12 formats use VideoToolbox.
    func lowFrame(_ frame: VideoFrame) throws -> CVReadOnlyPixelBuffer {
        if let hit = cachedLow.first(where: { $0.source === frame.pixelBuffer }) { return hit.low }
        let output = try sourcePool.makeMutable()
        if usesCPUDownscale && input.width == low.width * 2 && input.height == low.height * 2,
            Self.shrinkNV12HalfOnCPU(
                from: frame.pixelBuffer, sourceSize: input, to: output, targetSize: low,
                fused: usesFusedCPUShrink)
        {
            let low = CVReadOnlyPixelBuffer(output)
            cachedLow = Array((cachedLow + [(frame.pixelBuffer, low)]).suffix(2))
            return low
        }
        // In L2 mode (720p VT + 1080p ME on 4K), shrink from the CPU-cached 1080p surface (3.1 MB)
        // instead of reading the full 4K frame (12.4 MB) again on GPU.
        if let motionLow = try? motionLowFrame(frame), let motionPlanes = try? planes(motionLow, size: motionSize) {
            try output.withUnsafeBuffer { destination in
                PixelConverter.attach709(to: destination)
                let luma = try texture(destination, format: .r8Unorm, size: low, usage: .shaderWrite)
                let half = VideoSize(width: low.width / 2, height: low.height / 2)
                let lowChroma = try texture(destination, format: .rg8Unorm, size: half, plane: 1, usage: .shaderWrite)
                guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder(),
                    let lumaTexture = CVMetalTextureGetTexture(luma),
                    let chromaTexture = CVMetalTextureGetTexture(lowChroma)
                else {
                    throw PipelineError(AppText("无法编码混合插帧缩图", "Could not encode hybrid interpolation downscaling."))
                }
                encoder.setComputePipelineState(shrinkLuma)
                encoder.setTexture(motionPlanes.luma, index: 0)
                encoder.setTexture(lumaTexture, index: 1)
                encoder.dispatchThreads(
                    MTLSize(width: low.width, height: low.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.setComputePipelineState(shrinkChroma)
                encoder.setTexture(motionPlanes.chroma, index: 0)
                encoder.setTexture(chromaTexture, index: 1)
                var offset = SIMD2<Float>.zero
                encoder.setBytes(&offset, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                encoder.dispatchThreads(
                    MTLSize(width: half.width, height: half.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.endEncoding()
                withExtendedLifetime((motionPlanes, luma, lowChroma)) {
                    command.commit()
                    command.waitUntilCompleted()
                }
                if let error = command.error { throw error }
                guard command.status == .completed else {
                    throw PipelineError(AppText("混合插帧缩图没有完成", "Hybrid interpolation downscaling did not complete."))
                }
            }
            let low = CVReadOnlyPixelBuffer(output)
            cachedLow = Array((cachedLow + [(frame.pixelBuffer, low)]).suffix(2))
            return low
        }
        if let source = try reference(frame), let chroma = source.chroma {
            try output.withUnsafeBuffer { destination in
                PixelConverter.attach709(to: destination)
                let luma = try texture(destination, format: .r8Unorm, size: low, usage: .shaderWrite)
                let half = VideoSize(width: low.width / 2, height: low.height / 2)
                let lowChroma = try texture(destination, format: .rg8Unorm, size: half, plane: 1, usage: .shaderWrite)
                guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder(),
                    let lumaTexture = CVMetalTextureGetTexture(luma),
                    let chromaTexture = CVMetalTextureGetTexture(lowChroma)
                else {
                    throw PipelineError(AppText("无法编码混合插帧缩图", "Could not encode hybrid interpolation downscaling."))
                }
                encoder.setComputePipelineState(shrinkLuma)
                encoder.setTexture(source.image, index: 0)
                encoder.setTexture(lumaTexture, index: 1)
                encoder.dispatchThreads(
                    MTLSize(width: low.width, height: low.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.setComputePipelineState(shrinkChroma)
                encoder.setTexture(chroma, index: 0)
                encoder.setTexture(chromaTexture, index: 1)
                var offset = source.offset
                encoder.setBytes(&offset, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                encoder.dispatchThreads(
                    MTLSize(width: half.width, height: half.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.endEncoding()
                withExtendedLifetime((source, luma, lowChroma)) {
                    command.commit()
                    command.waitUntilCompleted()
                }
                if let error = command.error { throw error }
                guard command.status == .completed else {
                    throw PipelineError(AppText("混合插帧缩图没有完成", "Hybrid interpolation downscaling did not complete."))
                }
            }
        } else {
            var status = noErr
            frame.pixelBuffer.withUnsafeBuffer { source in
                output.withUnsafeBuffer { destination in
                    PixelConverter.attach709(to: destination)
                    status = VTPixelTransferSessionTransferImage(transfer, from: source, to: destination)
                }
            }
            guard status == noErr else {
                throw PipelineError(AppText("混合插帧缩图失败：\(status)", "Hybrid interpolation downscaling failed: \(status)"))
            }
        }
        let low = CVReadOnlyPixelBuffer(output)
        cachedLow = Array((cachedLow + [(frame.pixelBuffer, low)]).suffix(2))
        return low
    }

    func destination(at time: CMTime) throws -> VTFrameProcessorFrame {
        try destinationPool.makeVTFrame(at: time)
    }

    private final class ExclusiveMutableBuffer: @unchecked Sendable {
        var buffer: CVMutablePixelBuffer?
        init(_ buffer: consuming CVMutablePixelBuffer) { self.buffer = consume buffer }
        func take() -> CVMutablePixelBuffer? { buffer.take() }
    }

    /// Starts hardware motion estimation on the media engine so it can run concurrently with VT.
    /// Computes `B → A` (and `A → B` when bidirectional occlusion estimation is enabled; ~4.6 ms total at 1080p,
    /// fully hidden inside the ~12 ms VT pass). Skips non-420v inputs gracefully.
    func startMotionEstimation(previous: VideoFrame, current: VideoFrame) -> Task<MotionFields?, Never>? {
        guard let motionSession else { return nil }
        func isNative420v(_ buffer: CVReadOnlyPixelBuffer) -> Bool {
            buffer.withUnsafeBuffer { pixel in
                CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    && CVPixelBufferGetWidth(pixel) == input.width
                    && CVPixelBufferGetHeight(pixel) == input.height
            }
        }
        guard isNative420v(previous.pixelBuffer), isNative420v(current.pixelBuffer) else { return nil }
        let refA: CVReadOnlyPixelBuffer
        let refB: CVReadOnlyPixelBuffer
        if motionSize == low {
            guard
                let lowA = cachedLow.first(where: { $0.source === previous.pixelBuffer })?.low
                    ?? (try? lowFrame(previous)),
                let lowB = cachedLow.first(where: { $0.source === current.pixelBuffer })?.low
                    ?? (try? lowFrame(current))
            else { return nil }
            refA = lowA
            refB = lowB
        } else if motionSourcePool != nil {
            guard
                let lowA = cachedMotionLow.first(where: { $0.source === previous.pixelBuffer })?.low
                    ?? (try? motionLowFrame(previous)),
                let lowB = cachedMotionLow.first(where: { $0.source === current.pixelBuffer })?.low
                    ?? (try? motionLowFrame(current))
            else { return nil }
            refA = lowA
            refB = lowB
        } else {
            refA = previous.pixelBuffer
            refB = current.pixelBuffer
        }
        let forwardSession = forwardMotionSession
        let asyncForwardShrink = usesFusedCPUShrink && forwardSession != nil && forwardSourcePool != nil
        var fwdRefA: CVReadOnlyPixelBuffer?
        var fwdRefB: CVReadOnlyPixelBuffer?
        var pendingOutA: ExclusiveMutableBuffer?
        var pendingOutB: ExclusiveMutableBuffer?
        if asyncForwardShrink, let forwardSourcePool {
            fwdRefA = cachedForwardLow.lookup(previous.pixelBuffer)
            fwdRefB = cachedForwardLow.lookup(current.pixelBuffer)
            if fwdRefA == nil, let mutable = try? forwardSourcePool.makeMutable() {
                pendingOutA = ExclusiveMutableBuffer(mutable)
            }
            if fwdRefB == nil, let mutable = try? forwardSourcePool.makeMutable() {
                pendingOutB = ExclusiveMutableBuffer(mutable)
            }
        } else if forwardSession != nil {
            fwdRefA = try? forwardLowFrame(from: refA, key: previous.pixelBuffer)
            fwdRefB = try? forwardLowFrame(from: refB, key: current.pixelBuffer)
        }
        let capturedMotionSize = motionSize
        let capturedForwardSize = forwardMotionSize
        let capturedPrevKey = previous.pixelBuffer
        let capturedCurrKey = current.pixelBuffer
        let capturedFused = usesFusedCPUShrink
        let capturedForwardCache = cachedForwardLow
        let initialFwdA = fwdRefA
        let initialFwdB = fwdRefB
        let outA = pendingOutA
        let outB = pendingOutB
        return Task {
            let startedAt = mediaHostTime()
            guard
                let backward = try? await motionSession.motion(
                    of: refB, comparedTo: refA, flags: .currentBufferWillBeNextReferenceBuffer
                ).motionVector
            else { return nil }
            let backwardFinishedAt = mediaHostTime()
            let forward: CVReadOnlyPixelBuffer?
            let forwardFinishedAt: Double?
            if let forwardSession {
                var resolvedA = initialFwdA
                var resolvedB = initialFwdB
                if resolvedA == nil, let mutable = outA?.take(),
                    Self.shrinkNV12HalfOnCPU(
                        from: refA, sourceSize: capturedMotionSize, to: mutable, targetSize: capturedForwardSize,
                        fused: capturedFused)
                {
                    let ready = CVReadOnlyPixelBuffer(mutable)
                    resolvedA = ready
                    capturedForwardCache.insert(key: capturedPrevKey, value: ready)
                }
                if resolvedB == nil, let mutable = outB?.take(),
                    Self.shrinkNV12HalfOnCPU(
                        from: refB, sourceSize: capturedMotionSize, to: mutable, targetSize: capturedForwardSize,
                        fused: capturedFused)
                {
                    let ready = CVReadOnlyPixelBuffer(mutable)
                    resolvedB = ready
                    capturedForwardCache.insert(key: capturedCurrKey, value: ready)
                }
                if let resolvedA, let resolvedB {
                    forward = try? await forwardSession.motion(of: resolvedA, comparedTo: resolvedB, flags: [])
                        .motionVector
                    forwardFinishedAt = forward != nil ? mediaHostTime() : nil
                } else {
                    forward = nil
                    forwardFinishedAt = nil
                }
            } else {
                forward = nil
                forwardFinishedAt = nil
            }
            return MotionFields(
                backward: backward,
                forward: forward,
                timing: MotionTiming(
                    startedAt: startedAt, backwardFinishedAt: backwardFinishedAt,
                    forwardFinishedAt: forwardFinishedAt))
        }
    }

    private final class RetainedMotionInputs: @unchecked Sendable {
        let items: [Any]
        init(_ items: [Any]) { self.items = items }
    }

    /// Asynchronously encodes `selectMotion` into a bounded 3-slot private texture pool synced via `MTLSharedEvent`
    /// without blocking the caller or passing `CVMetalTexture` across threads. Returns `nil` if the pool is full
    /// or mapping fails so the preview pass falls back transparently to inline `previewSelectMotion`.
    func precomputeMotionDetail(
        previousLow: CVReadOnlyPixelBuffer, currentLow: CVReadOnlyPixelBuffer,
        midpoint: CVReadOnlyPixelBuffer, phase: Float, motionField: MotionFields,
        isHDR10PQ: Bool, sharpenStrength: Float? = nil
    ) -> PrecomputedMotionDetail? {
        guard detailMode.usesMotion else { return nil }
        if motionDetailPool == nil {
            motionDetailPool = MotionDetailSlotPool(device: device, selectSize: selectSize)
        }
        guard let pool = motionDetailPool else { return nil }
        guard let lowA = try? planes(previousLow, size: low),
            let lowB = try? planes(currentLow, size: low),
            let lowMid = try? planes(midpoint, size: low)
        else { return nil }
        var motionView: CVMetalTexture?
        var forwardMotionView: CVMetalTexture?
        motionField.backward.withUnsafeBuffer { pixel in
            guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_TwoComponent16Half else { return }
            let size = VideoSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
            motionView = try? texture(pixel, format: .rg16Float, size: size)
        }
        if let forward = motionField.forward {
            forward.withUnsafeBuffer { pixel in
                guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_TwoComponent16Half else { return }
                let size = VideoSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
                forwardMotionView = try? texture(pixel, format: .rg16Float, size: size)
            }
        }
        guard let motionTexture = motionView.flatMap({ CVMetalTextureGetTexture($0) }) else { return nil }
        let forwardMotionTexture = forwardMotionView.flatMap { CVMetalTextureGetTexture($0) }
        guard let token = pool.acquire(hasForward: forwardMotionTexture != nil) else { return nil }
        guard let command = queue.makeCommandBuffer(), let select = command.makeComputeCommandEncoder() else {
            return nil
        }
        let sampledMid = selectSize != low
        if sampledMid {
            select.setComputePipelineState(
                forwardMotionTexture != nil ? selectMotionBidirSampleMid : selectMotionSampleMid)
        } else {
            select.setComputePipelineState(forwardMotionTexture != nil ? selectMotionBidir : selectMotion)
        }
        let hdrBits =
            isHDR10PQ
            ? PreviewImageRenderer.hdr10ShaderModeBits(referencePQ: PreviewImageRenderer.hdr10ReferencePQEnabled) : 0
        let hudDehalo = hudDehaloOverride ?? Self.hudDehaloEnabled
        let motionFlags =
            hdrBits | (hudDehalo ? 8 : 0) | (Self.shaderSafeFiniteEnabled ? 16 : 0)
        var weights = SIMD4<Float>(
            phase, restoresStaticPixels ? 1 : 0, sharpenStrength ?? detailMode.sharpenStrength,
            Float(motionSize.width))
        var motionParams = SIMD4<Float>(
            1 / Float(motionSize.width), 1 / Float(motionSize.height),
            Float(motionSize.width) / Float(forwardMotionSize.width),
            Float(motionFlags))
        select.setTexture(lowA.luma, index: 0)
        select.setTexture(lowA.chroma, index: 1)
        select.setTexture(lowB.luma, index: 2)
        select.setTexture(lowB.chroma, index: 3)
        select.setTexture(lowMid.luma, index: 4)
        select.setTexture(motionTexture, index: 5)
        select.setTexture(token.texture, index: 6)
        if let forwardMotionTexture { select.setTexture(forwardMotionTexture, index: 7) }
        select.setBytes(&weights, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        select.setBytes(&motionParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        select.dispatchThreads(
            MTLSize(width: selectSize.width, height: selectSize.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        select.endEncoding()
        command.encodeSignalEvent(token.event, value: token.signalValue)
        var retainedList: [Any] = [
            token, previousLow, currentLow, midpoint, motionField.backward, lowA, lowB, lowMid,
        ]
        if let motionView { retainedList.append(motionView) }
        if let forwardMotionView { retainedList.append(forwardMotionView) }
        if let forward = motionField.forward { retainedList.append(forward) }
        let retained = RetainedMotionInputs(retainedList)
        command.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
        command.commit()
        return token
    }

    /// Builds a read-only recipe so `PreviewImageRenderer` can execute `selectMotion` and midpoint merge
    /// directly into the 10-bit preview drawable without an intermediate 4K 420v pass or CPU wait.
    func makePreviewRecipe(
        previous: VideoFrame, current: VideoFrame, previousLow: CVReadOnlyPixelBuffer,
        currentLow: CVReadOnlyPixelBuffer, midpoint: CVReadOnlyPixelBuffer, phase: Float,
        motionField: MotionFields? = nil, sharpenStrength: Float? = nil,
        precomputeMotionDetail: Bool = HybridInterpolator.precomputeMotionDetailEnabled
    ) -> HybridPreviewRecipe? {
        func isDirectNV12(_ buffer: CVReadOnlyPixelBuffer) -> (valid: Bool, hdr10: Bool) {
            buffer.withUnsafeBuffer { pixel in
                guard CVPixelBufferGetIOSurface(pixel) != nil,
                    CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    CVPixelBufferGetPlaneCount(pixel) == 2,
                    CVPixelBufferGetWidthOfPlane(pixel, 0) == input.width,
                    CVPixelBufferGetHeightOfPlane(pixel, 0) == input.height,
                    input.width.isMultiple(of: 2), input.height.isMultiple(of: 2),
                    CVPixelBufferGetWidthOfPlane(pixel, 1) == input.width / 2,
                    CVPixelBufferGetHeightOfPlane(pixel, 1) == input.height / 2,
                    ((CVBufferCopyAttachment(pixel, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue ?? 1)
                        == 1,
                    PixelConverter.chromaSitingOffset(of: pixel) != nil
                else { return (false, false) }
                let hdr10 = PixelConverter.isHDR10PQ(pixel)
                let matrix = CVBufferCopyAttachment(pixel, kCVImageBufferYCbCrMatrixKey, nil) as? String
                if hdr10 {
                    let ok =
                        matrix == nil
                        || matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
                        || matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
                    return (ok, true)
                }
                guard let colorSpace = CVBufferCopyAttachment(pixel, kCVImageBufferCGColorSpaceKey, nil),
                    CFEqual(colorSpace, PixelConverter.rec709),
                    matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
                else { return (false, false) }
                return (true, false)
            }
        }
        let prevCheck = isDirectNV12(previous.pixelBuffer)
        let currCheck = isDirectNV12(current.pixelBuffer)
        guard prevCheck.valid, currCheck.valid, prevCheck.hdr10 == currCheck.hdr10 else { return nil }
        let precomputed: PrecomputedMotionDetail?
        if precomputeMotionDetail, let motionField {
            precomputed = self.precomputeMotionDetail(
                previousLow: previousLow, currentLow: currentLow, midpoint: midpoint,
                phase: phase, motionField: motionField, isHDR10PQ: prevCheck.hdr10,
                sharpenStrength: sharpenStrength)
        } else {
            precomputed = nil
        }
        return HybridPreviewRecipe(
            previous: previous.pixelBuffer, current: current.pixelBuffer,
            previousLow: previousLow, currentLow: currentLow, midpoint: midpoint,
            motionBackward: motionField?.backward, motionForward: motionField?.forward,
            phase: phase, sharpenStrength: sharpenStrength ?? detailMode.sharpenStrength,
            restoresStaticPixels: restoresStaticPixels,
            inputSize: input, lowSize: low, motionSize: motionSize, forwardMotionSize: forwardMotionSize,
            selectSize: selectSize, isHDR10PQ: prevCheck.hdr10,
            precomputedMotionDetail: precomputed)
    }

    /// Upscales VT's midpoint, restores unchanged source pixels, and optionally transfers native high-frequency
    /// detail or applies overshoot-clamped adaptive sharpening.
    func compose(
        previous: VideoFrame, current: VideoFrame, previousLow: CVReadOnlyPixelBuffer,
        currentLow: CVReadOnlyPixelBuffer, midpoint: CVReadOnlyPixelBuffer, phase: Float,
        motionField: MotionFields? = nil, sharpenStrength: Float? = nil, stabilizesSpatialDetail: Bool = false
    ) throws -> CVReadOnlyPixelBuffer {
        try autoreleasepool {
            guard let first = try reference(previous), let second = try reference(current) else {
                throw PipelineError(AppText("混合插帧不支持此源格式", "Hybrid interpolation does not support this source format."))
            }
            let lowA = try planes(previousLow, size: low)
            let lowB = try planes(currentLow, size: low)
            let lowMid = try planes(midpoint, size: low)
            var motionView: CVMetalTexture?
            var forwardMotionView: CVMetalTexture?
            if let motionField {
                try motionField.backward.withUnsafeBuffer { pixel in
                    guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_TwoComponent16Half else {
                        return
                    }
                    let size = VideoSize(
                        width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
                    motionView = try texture(pixel, format: .rg16Float, size: size)
                }
                if let forward = motionField.forward {
                    try forward.withUnsafeBuffer { pixel in
                        guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_TwoComponent16Half else {
                            return
                        }
                        let size = VideoSize(
                            width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
                        forwardMotionView = try texture(pixel, format: .rg16Float, size: size)
                    }
                }
            }
            let motionTexture = motionView.flatMap { CVMetalTextureGetTexture($0) }
            let forwardMotionTexture = forwardMotionView.flatMap { CVMetalTextureGetTexture($0) }
            let emitNV12 =
                outputsNV12 && first.chroma != nil && second.chroma != nil
                && input.width.isMultiple(of: 2) && input.height.isMultiple(of: 2)
            let isHDR10 = previous.pixelBuffer.withUnsafeBuffer { PixelConverter.isHDR10PQ($0) }
            let output = try resolveOutputPool(nv12: emitNV12).makeMutable()
            let motionDetail = motionTexture != nil ? resolveMotionDetailTexture() : nil
            try output.withUnsafeBuffer { raw in
                if isHDR10 {
                    PixelConverter.attachHDR10PQ(to: raw)
                } else {
                    PixelConverter.attach709(to: raw)
                }
                guard let command = queue.makeCommandBuffer() else {
                    throw PipelineError(AppText("无法编码混合插帧", "Could not encode hybrid interpolation."))
                }
                let hudDehalo = hudDehaloOverride ?? Self.hudDehaloEnabled
                let iconEnvelope = iconEnvelopeOverride ?? Self.iconEnvelopeEnabled
                let adaptiveCAS = adaptiveCASOverride ?? Self.adaptiveCASEnabled
                let hdrBits =
                    isHDR10
                    ? PreviewImageRenderer.hdr10ShaderModeBits(
                        referencePQ: PreviewImageRenderer.hdr10ReferencePQEnabled) : 0
                let motionFlags = hdrBits | (hudDehalo ? 8 : 0) | (Self.shaderSafeFiniteEnabled ? 16 : 0)
                var weights = SIMD4<Float>(
                    phase, restoresStaticPixels ? 1 : 0,
                    sharpenStrength ?? detailMode.sharpenStrength,
                    Float(
                        hdrBits | (hudDehalo ? 4 : 0) | (stabilizesSpatialDetail ? 8 : 0)
                            | (iconEnvelope ? 16 : 0) | (adaptiveCAS ? 32 : 0)))
                var motionParams = SIMD4<Float>(
                    1 / Float(motionSize.width), 1 / Float(motionSize.height),
                    Float(motionSize.width) / Float(forwardMotionSize.width),
                    Float(motionFlags))
                let useMotion = motionTexture != nil && motionDetail != nil
                if useMotion, let motionTexture, let motionDetail {
                    guard let select = command.makeComputeCommandEncoder() else {
                        throw PipelineError(AppText("无法编码运动筛选", "Could not encode motion selection."))
                    }
                    let sampledMid = selectSize != low
                    if sampledMid {
                        select.setComputePipelineState(
                            forwardMotionTexture != nil ? selectMotionBidirSampleMid : selectMotionSampleMid)
                    } else {
                        select.setComputePipelineState(forwardMotionTexture != nil ? selectMotionBidir : selectMotion)
                    }
                    select.setTexture(lowA.luma, index: 0)
                    select.setTexture(lowA.chroma, index: 1)
                    select.setTexture(lowB.luma, index: 2)
                    select.setTexture(lowB.chroma, index: 3)
                    select.setTexture(lowMid.luma, index: 4)
                    select.setTexture(motionTexture, index: 5)
                    select.setTexture(motionDetail, index: 6)
                    if let forwardMotionTexture { select.setTexture(forwardMotionTexture, index: 7) }
                    select.setBytes(&weights, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    select.setBytes(&motionParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                    select.dispatchThreads(
                        MTLSize(width: selectSize.width, height: selectSize.height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                    select.endEncoding()
                }
                guard let merge = command.makeComputeCommandEncoder() else {
                    throw PipelineError(AppText("无法编码混合合成", "Could not encode hybrid composition."))
                }
                var retainedViews: [CVMetalTexture] = []
                if emitNV12, let aChroma = first.chroma, let bChroma = second.chroma {
                    let half = VideoSize(width: input.width / 2, height: input.height / 2)
                    let outYView = try texture(raw, format: .r8Unorm, size: input, plane: 0, usage: .shaderWrite)
                    let outUVView = try texture(raw, format: .rg8Unorm, size: half, plane: 1, usage: .shaderWrite)
                    guard let outY = CVMetalTextureGetTexture(outYView),
                        let outUV = CVMetalTextureGetTexture(outUVView)
                    else { throw PipelineError(AppText("无法映射混合插帧 NV12 输出", "Could not map the hybrid NV12 output.")) }
                    retainedViews = [outYView, outUVView]
                    if input.width == low.width * 2 && input.height == low.height * 2 {
                        merge.setComputePipelineState(useMotion ? mergeDetailNV12Out2x : mergeNV12Out2x)
                    } else {
                        merge.setComputePipelineState(useMotion ? mergeDetailNV12Out : mergeNV12Out)
                    }
                    merge.setTexture(first.image, index: 0)
                    merge.setTexture(second.image, index: 1)
                    merge.setTexture(aChroma, index: 2)
                    merge.setTexture(bChroma, index: 3)
                    merge.setTexture(lowA.luma, index: 4)
                    merge.setTexture(lowA.chroma, index: 5)
                    merge.setTexture(lowB.luma, index: 6)
                    merge.setTexture(lowB.chroma, index: 7)
                    merge.setTexture(lowMid.luma, index: 8)
                    merge.setTexture(lowMid.chroma, index: 9)
                    merge.setTexture(outY, index: 10)
                    merge.setTexture(outUV, index: 11)
                    if useMotion, let motionDetail { merge.setTexture(motionDetail, index: 12) }
                    var offsets = SIMD4<Float>(first.offset.x, first.offset.y, second.offset.x, second.offset.y)
                    merge.setBytes(&offsets, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    merge.setBytes(&weights, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                    merge.dispatchThreads(
                        MTLSize(width: half.width, height: half.height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                } else {
                    let resultView = try texture(raw, format: .bgra8Unorm, size: input, usage: .shaderWrite)
                    guard let result = CVMetalTextureGetTexture(resultView) else {
                        throw PipelineError(AppText("无法编码混合插帧", "Could not encode hybrid interpolation."))
                    }
                    retainedViews = [resultView]
                    if first.chroma == nil {
                        merge.setComputePipelineState(useMotion ? mergeDetailBGRA : mergeBGRA)
                    } else {
                        merge.setComputePipelineState(useMotion ? mergeDetailNV12 : mergeNV12)
                    }
                    merge.setTexture(first.image, index: 0)
                    merge.setTexture(second.image, index: 1)
                    if let a = first.chroma, let b = second.chroma {
                        merge.setTexture(a, index: 2)
                        merge.setTexture(b, index: 3)
                    }
                    merge.setTexture(lowA.luma, index: 4)
                    merge.setTexture(lowA.chroma, index: 5)
                    merge.setTexture(lowB.luma, index: 6)
                    merge.setTexture(lowB.chroma, index: 7)
                    merge.setTexture(lowMid.luma, index: 8)
                    merge.setTexture(lowMid.chroma, index: 9)
                    merge.setTexture(result, index: 10)
                    if useMotion, let motionDetail { merge.setTexture(motionDetail, index: 11) }
                    var offsets = SIMD4<Float>(first.offset.x, first.offset.y, second.offset.x, second.offset.y)
                    merge.setBytes(&offsets, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    merge.setBytes(&weights, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                    merge.dispatchThreads(
                        MTLSize(width: input.width, height: input.height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                }
                merge.endEncoding()
                withExtendedLifetime(
                    (first, second, lowA, lowB, lowMid, motionView, forwardMotionView, retainedViews)
                ) {
                    command.commit()
                    command.waitUntilCompleted()
                }
                if let error = command.error { throw error }
                guard command.status == .completed else {
                    throw PipelineError(AppText("混合插帧GPU没有完成", "GPU hybrid interpolation did not complete."))
                }
            }
            return CVReadOnlyPixelBuffer(output)
        }
    }

    private struct Source {
        let image: any MTLTexture
        let chroma: (any MTLTexture)?
        let offset: SIMD2<Float>
        let views: [CVMetalTexture]
    }

    private struct Planes {
        let luma: any MTLTexture
        let chroma: any MTLTexture
        let views: [CVMetalTexture]
    }

    private func reference(_ frame: VideoFrame) throws -> Source? {
        var source: Source?
        try frame.pixelBuffer.withUnsafeBuffer { pixel in
            let format = CVPixelBufferGetPixelFormatType(pixel)
            if format == kCVPixelFormatType_32BGRA {
                let view = try texture(pixel, format: .bgra8Unorm, size: input)
                guard let image = CVMetalTextureGetTexture(view) else { return }
                source = Source(image: image, chroma: nil, offset: .zero, views: [view])
                return
            }
            guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, CVPixelBufferGetPlaneCount(pixel) == 2,
                CVPixelBufferGetWidthOfPlane(pixel, 0) == input.width,
                CVPixelBufferGetHeightOfPlane(pixel, 0) == input.height
            else { return }
            let siting = PixelConverter.chromaSitingOffset(of: pixel) ?? .zero
            let luma = try texture(pixel, format: .r8Unorm, size: input)
            let chroma = try texture(
                pixel, format: .rg8Unorm, size: VideoSize(width: input.width / 2, height: input.height / 2), plane: 1)
            guard let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma)
            else { return }
            source = Source(
                image: lumaTexture, chroma: chromaTexture,
                offset: siting / SIMD2(Float(input.width), Float(input.height)), views: [luma, chroma])
        }
        return source
    }

    private func planes(_ buffer: CVReadOnlyPixelBuffer, size: VideoSize) throws -> Planes {
        var result: Planes?
        try buffer.withUnsafeBuffer { pixel in
            let luma = try texture(pixel, format: .r8Unorm, size: size)
            let chroma = try texture(
                pixel, format: .rg8Unorm, size: VideoSize(width: size.width / 2, height: size.height / 2), plane: 1)
            guard let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma)
            else { return }
            result = Planes(luma: lumaTexture, chroma: chromaTexture, views: [luma, chroma])
        }
        guard let result else {
            throw PipelineError(AppText("无法映射混合插帧的 420v 平面", "Could not map the hybrid 420v planes."))
        }
        return result
    }

    private func texture(
        _ pixel: CVPixelBuffer, format: MTLPixelFormat, size: VideoSize, plane: Int = 0,
        usage: MTLTextureUsage = .shaderRead
    ) throws -> CVMetalTexture {
        var result: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary
        guard
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixel, attributes, format, size.width, size.height, plane, &result) == kCVReturnSuccess,
            let result, CVMetalTextureGetTexture(result) != nil
        else { throw PipelineError(AppText("无法映射混合插帧纹理", "Could not map the hybrid interpolation textures.")) }
        return result
    }

    /// Halves a 420v Rec.709 surface on the CPU using SIMD halving adds (ARM64 urhadd/uhadd), matching
    /// `shrinkLuma`/`shrinkChroma` across all six supported chroma sitings without a GPU round trip.
    /// When `fused` is true, large 4K -> 1080p surfaces execute luma and chroma inside one 4-strip parallel barrier.
    static func shrinkNV12HalfOnCPU(
        from source: CVReadOnlyPixelBuffer, sourceSize: VideoSize,
        to destination: borrowing CVMutablePixelBuffer, targetSize: VideoSize,
        fused: Bool = HybridInterpolator.fusedCPUShrinkEnabled
    ) -> Bool {
        source.withUnsafeBuffer { src in
            guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                CVPixelBufferGetPlaneCount(src) == 2,
                CVPixelBufferGetWidthOfPlane(src, 0) == sourceSize.width,
                CVPixelBufferGetHeightOfPlane(src, 0) == sourceSize.height,
                sourceSize.width == targetSize.width * 2, sourceSize.height == targetSize.height * 2,
                targetSize.width % 16 == 0, targetSize.width > 0, targetSize.height > 0,
                (targetSize.width / 2) * 2 % 16 == 0, targetSize.height % 2 == 0,
                let siting = PixelConverter.chromaSitingOffset(of: src),
                siting.x == 0 || siting.x == 0.5,
                siting.y == 0 || siting.y == 0.5 || siting.y == -0.5
            else { return false }
            return destination.withUnsafeBuffer { dst in
                guard CVPixelBufferLockBaseAddress(src, .readOnly) == kCVReturnSuccess else { return false }
                defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
                guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else { return false }
                defer { CVPixelBufferUnlockBaseAddress(dst, []) }
                guard let srcY = CVPixelBufferGetBaseAddressOfPlane(src, 0),
                    let dstY = CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                    let srcUV = CVPixelBufferGetBaseAddressOfPlane(src, 1),
                    let dstUV = CVPixelBufferGetBaseAddressOfPlane(dst, 1)
                else { return false }
                let srcYRow = CVPixelBufferGetBytesPerRowOfPlane(src, 0)
                let dstYRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 0)
                let srcUVRow = CVPixelBufferGetBytesPerRowOfPlane(src, 1)
                let dstUVRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
                let lowChromaBytes = targetSize.width
                let lowChromaHeight = targetSize.height / 2
                let srcChromaHeight = sourceSize.height / 2
                guard srcYRow >= sourceSize.width, dstYRow >= targetSize.width,
                    srcUVRow >= sourceSize.width, dstUVRow >= lowChromaBytes
                else { return false }

                if fused && targetSize.width * targetSize.height >= 1_000_000 {
                    let srcYAddr = Int(bitPattern: srcY)
                    let dstYAddr = Int(bitPattern: dstY)
                    let srcUVAddr = Int(bitPattern: srcUV)
                    let dstUVAddr = Int(bitPattern: dstUV)
                    let strips = 4
                    DispatchQueue.concurrentPerform(iterations: strips) { strip in
                        let startY = strip * targetSize.height / strips
                        let endY = (strip + 1) * targetSize.height / strips
                        if endY > startY,
                            let ySrc = UnsafeRawPointer(bitPattern: srcYAddr),
                            let yDst = UnsafeMutableRawPointer(bitPattern: dstYAddr)
                        {
                            Self.shrinkLumaRows(
                                from: ySrc, sourceRow: srcYRow, to: yDst, destinationRow: dstYRow,
                                width: targetSize.width, startY: startY, endY: endY)
                        }
                        let startUV = strip * lowChromaHeight / strips
                        let endUV = (strip + 1) * lowChromaHeight / strips
                        if endUV > startUV,
                            let uvSrc = UnsafeRawPointer(bitPattern: srcUVAddr),
                            let uvDst = UnsafeMutableRawPointer(bitPattern: dstUVAddr)
                        {
                            Self.shrinkChromaRows(
                                from: uvSrc, sourceRow: srcUVRow, sourceHeight: srcChromaHeight,
                                to: uvDst, destinationRow: dstUVRow, rowBytes: lowChromaBytes,
                                startY: startUV, endY: endUV, siting: siting)
                        }
                    }
                } else {
                    Self.shrinkLumaHalf(
                        from: srcY, sourceRow: srcYRow, to: dstY, destinationRow: dstYRow,
                        width: targetSize.width, height: targetSize.height)
                    Self.shrinkChromaHalf(
                        from: srcUV, sourceRow: srcUVRow, sourceHeight: srcChromaHeight,
                        to: dstUV, destinationRow: dstUVRow,
                        rowBytes: lowChromaBytes, height: lowChromaHeight, siting: siting)
                }
                CVPixelBufferFillExtendedPixels(dst)
                PixelConverter.attach709(to: dst)
                return true
            }
        }
    }

    @inline(__always)
    private static func urhadd(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>) -> SIMD16<UInt8> {
        (a | b) &- ((a ^ b) &>> 1)
    }

    @inline(__always)
    private static func uhadd(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>) -> SIMD16<UInt8> {
        (a & b) &+ ((a ^ b) &>> 1)
    }

    /// (3*a + 4*b + c) / 8 without widening, matching the +0.25 texel shift of left/top siting.
    @inline(__always)
    private static func weighted341(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>, _ c: SIMD16<UInt8>) -> SIMD16<UInt8> {
        uhadd(b, urhadd(a, urhadd(a, c)))
    }

    private static func shrinkLumaRows(
        from srcBase: UnsafeRawPointer, sourceRow: Int, to dstBase: UnsafeMutableRawPointer, destinationRow: Int,
        width: Int, startY: Int, endY: Int
    ) {
        for y in startY..<endY {
            let r0 = srcBase.advanced(by: (y * 2) * sourceRow)
            let r1 = srcBase.advanced(by: (y * 2 + 1) * sourceRow)
            let out = dstBase.advanced(by: y * destinationRow)
            var x = 0
            while x < width {
                let sx = x * 2
                let v0 = urhadd(
                    r0.loadUnaligned(fromByteOffset: sx, as: SIMD16<UInt8>.self),
                    r1.loadUnaligned(fromByteOffset: sx, as: SIMD16<UInt8>.self))
                let v1 = urhadd(
                    r0.loadUnaligned(fromByteOffset: sx + 16, as: SIMD16<UInt8>.self),
                    r1.loadUnaligned(fromByteOffset: sx + 16, as: SIMD16<UInt8>.self))
                let even = SIMD16<UInt8>(lowHalf: v0.evenHalf, highHalf: v1.evenHalf)
                let odd = SIMD16<UInt8>(lowHalf: v0.oddHalf, highHalf: v1.oddHalf)
                out.storeBytes(of: uhadd(even, odd), toByteOffset: x, as: SIMD16<UInt8>.self)
                x += 16
            }
        }
    }

    private static func shrinkLumaHalf(
        from src: UnsafeRawPointer, sourceRow: Int, to dst: UnsafeMutableRawPointer, destinationRow: Int,
        width: Int, height: Int
    ) {
        let srcAddr = Int(bitPattern: src)
        let dstAddr = Int(bitPattern: dst)
        let strips = width * height >= 1_000_000 ? 4 : 1
        let work: @Sendable (Int) -> Void = { strip in
            let startY = strip * height / strips
            let endY = (strip + 1) * height / strips
            guard endY > startY,
                let srcBase = UnsafeRawPointer(bitPattern: srcAddr),
                let dstBase = UnsafeMutableRawPointer(bitPattern: dstAddr)
            else { return }
            Self.shrinkLumaRows(
                from: srcBase, sourceRow: sourceRow, to: dstBase, destinationRow: destinationRow,
                width: width, startY: startY, endY: endY)
        }
        if strips > 1 {
            DispatchQueue.concurrentPerform(iterations: strips, execute: work)
        } else {
            work(0)
        }
    }

    private static func shrinkChromaRows(
        from srcBase: UnsafeRawPointer, sourceRow: Int, sourceHeight: Int,
        to dstBase: UnsafeMutableRawPointer, destinationRow: Int,
        rowBytes: Int, startY: Int, endY: Int, siting: SIMD2<Float>
    ) {
        let shiftRight = siting.x > 0
        let shiftDown = siting.y > 0
        let shiftUp = siting.y < 0
        for y in startY..<endY {
            let y0 = y * 2
            let y1 = y0 + 1
            let r0 = srcBase.advanced(by: y0 * sourceRow)
            let r1 = srcBase.advanced(by: y1 * sourceRow)
            let rExtra: UnsafeRawPointer?
            if shiftDown {
                rExtra = srcBase.advanced(by: min(y0 + 2, sourceHeight - 1) * sourceRow)
            } else if shiftUp {
                rExtra = srcBase.advanced(by: max(y0 - 1, 0) * sourceRow)
            } else {
                rExtra = nil
            }
            let out = dstBase.advanced(by: y * destinationRow)
            @inline(__always)
            func vertical(_ byteOffset: Int) -> SIMD16<UInt8> {
                let a = r0.loadUnaligned(fromByteOffset: byteOffset, as: SIMD16<UInt8>.self)
                let b = r1.loadUnaligned(fromByteOffset: byteOffset, as: SIMD16<UInt8>.self)
                guard let rExtra else { return urhadd(a, b) }
                let extra = rExtra.loadUnaligned(fromByteOffset: byteOffset, as: SIMD16<UInt8>.self)
                return shiftDown ? weighted341(a, b, extra) : weighted341(b, a, extra)
            }
            @inline(__always)
            func verticalPair(_ byteOffset: Int) -> UInt16 {
                let a = r0.loadUnaligned(fromByteOffset: byteOffset, as: SIMD2<UInt8>.self)
                let b = r1.loadUnaligned(fromByteOffset: byteOffset, as: SIMD2<UInt8>.self)
                let result: SIMD2<UInt8>
                if let rExtra {
                    let extra = rExtra.loadUnaligned(fromByteOffset: byteOffset, as: SIMD2<UInt8>.self)
                    let p0 = shiftDown ? a : b
                    let p1 = shiftDown ? b : a
                    let avg02 = (p0 | extra) &- ((p0 ^ extra) &>> 1)
                    let avg0 = (p0 | avg02) &- ((p0 ^ avg02) &>> 1)
                    result = (p1 & avg0) &+ ((p1 ^ avg0) &>> 1)
                } else {
                    result = (a | b) &- ((a ^ b) &>> 1)
                }
                return unsafeBitCast(result, to: UInt16.self)
            }
            var x = 0
            while x < rowBytes {
                let sx = x * 2
                let u0 = unsafeBitCast(vertical(sx), to: SIMD8<UInt16>.self)
                let u1 = unsafeBitCast(vertical(sx + 16), to: SIMD8<UInt16>.self)
                let p0Pairs = SIMD8<UInt16>(lowHalf: u0.evenHalf, highHalf: u1.evenHalf)
                let p1Pairs = SIMD8<UInt16>(lowHalf: u0.oddHalf, highHalf: u1.oddHalf)
                let p0 = unsafeBitCast(p0Pairs, to: SIMD16<UInt8>.self)
                let p1 = unsafeBitCast(p1Pairs, to: SIMD16<UInt8>.self)
                if !shiftRight {
                    out.storeBytes(of: uhadd(p0, p1), toByteOffset: x, as: SIMD16<UInt8>.self)
                } else {
                    let nextPair = x + 16 < rowBytes ? verticalPair(sx + 32) : p1Pairs[7]
                    let p2Pairs = SIMD8<UInt16>(
                        p0Pairs[1], p0Pairs[2], p0Pairs[3], p0Pairs[4],
                        p0Pairs[5], p0Pairs[6], p0Pairs[7], nextPair)
                    let p2 = unsafeBitCast(p2Pairs, to: SIMD16<UInt8>.self)
                    out.storeBytes(of: weighted341(p0, p1, p2), toByteOffset: x, as: SIMD16<UInt8>.self)
                }
                x += 16
            }
        }
    }

    private static func shrinkChromaHalf(
        from src: UnsafeRawPointer, sourceRow: Int, sourceHeight: Int,
        to dst: UnsafeMutableRawPointer, destinationRow: Int,
        rowBytes: Int, height: Int, siting: SIMD2<Float>
    ) {
        let srcAddr = Int(bitPattern: src)
        let dstAddr = Int(bitPattern: dst)
        let strips = rowBytes * height >= 500_000 ? 4 : 1
        let work: @Sendable (Int) -> Void = { strip in
            let startY = strip * height / strips
            let endY = (strip + 1) * height / strips
            guard endY > startY,
                let srcBase = UnsafeRawPointer(bitPattern: srcAddr),
                let dstBase = UnsafeMutableRawPointer(bitPattern: dstAddr)
            else { return }
            Self.shrinkChromaRows(
                from: srcBase, sourceRow: sourceRow, sourceHeight: sourceHeight,
                to: dstBase, destinationRow: destinationRow,
                rowBytes: rowBytes, startY: startY, endY: endY, siting: siting)
        }
        if strips > 1 {
            DispatchQueue.concurrentPerform(iterations: strips, execute: work)
        } else {
            work(0)
        }
    }

    static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        constant bool nv12 [[function_constant(0)]];
        constant bool hasMotion [[function_constant(1)]];
        constant bool hasForwardMotion [[function_constant(2)]];
        constant bool exactTwoX [[function_constant(3)]];
        constant bool sampleMid [[function_constant(4)]];
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
        inline half nv12Luma(half luma) {
            return fma(luma, half(255.0 / 219.0), half(-16.0 / 219.0));
        }
        inline half3 nv12FromY(half y, half2 chroma) {
            half2 cbcr = fma(chroma, half(255.0 / 224.0), half(-128.0 / 224.0));
            return saturate(half3(
                fma(half(1.5748), cbcr.y, y),
                fma(half(-0.468124), cbcr.y, fma(half(-0.187324), cbcr.x, y)),
                fma(half(1.8556), cbcr.x, y)));
        }
        inline half3 nv12Color(half luma, half2 chroma) {
            return nv12FromY(nv12Luma(luma), chroma);
        }
        inline half3 sourceColor(texture2d<half, access::sample> image, texture2d<half, access::sample> chroma,
                                 float2 uv, float2 offset) {
            half3 value = image.sample(linearSampler, uv).rgb;
            if (!nv12) return value;
            return nv12Color(value.r, chroma.sample(linearSampler, uv + offset).rg);
        }
        inline half3 decodeLowYCbCr(half y, half2 cbcr, uint hdrMode) {
            if (hdrMode == 3u) {
                // Strict ITU-R BT.2100 / BT.2020 non-constant-luminance PQ decode without chroma boost or gamma crush.
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
        // Low-frequency color over about three downscaled pixels; ignores moire that VT adds to fine detail.
        inline half3 lowBlur(texture2d<half, access::sample> luma, texture2d<half, access::sample> chroma,
                             float2 uv, uint hdrMode = 0u) {
            float2 step = 1.0f / float2(luma.get_width(), luma.get_height());
            half y = (luma.sample(linearSampler, uv + float2(-step.x, -step.y)).r
                    + luma.sample(linearSampler, uv + float2(step.x, -step.y)).r
                    + luma.sample(linearSampler, uv + float2(-step.x, step.y)).r
                    + luma.sample(linearSampler, uv + float2(step.x, step.y)).r) * half(0.25);
            if (hdrMode == 0u) return nv12Color(y, chroma.sample(linearSampler, uv).rg);
            half2 cbcr = fma(chroma.sample(linearSampler, uv).rg, half(255.0 / 224.0), half(-128.0 / 224.0));
            return decodeLowYCbCr(nv12Luma(y), cbcr, hdrMode);
        }
        // Local 3x3 envelope breakout with low-contrast background gating: VT blur on static fine text stays
        // inside or adjacent to high-contrast 3x3 extrema (rangeY/rangeC large -> 0 release), while a fast-moving
        // icon gliding across a smooth static background breaks out of the local [min3x3, max3x3] envelope.
        inline half iconEnvelopeRelease(
            texture2d<half, access::sample> lowA, texture2d<half, access::sample> lowAChroma,
            texture2d<half, access::sample> lowB, texture2d<half, access::sample> lowBChroma,
            texture2d<half, access::sample> lowMid, texture2d<half, access::sample> lowMidChroma,
            float2 uv
        ) {
            // Exact center early-out: neighbor extrema can only widen [min, max], so if the center
            // midpoint sample already lies within the breakout thresholds of lowA/lowB at uv, the full
            // 3x3 + +/-2 envelope is mathematically guaranteed to return 0.0.
            half midY = saturate(nv12Luma(lowMid.sample(linearSampler, uv).r));
            half a0 = saturate(nv12Luma(lowA.sample(linearSampler, uv).r));
            half b0 = saturate(nv12Luma(lowB.sample(linearSampler, uv).r));
            half minY = min(a0, b0);
            half maxY = max(a0, b0);
            half2 midC = lowMidChroma.sample(linearSampler, uv).rg;
            half2 ca0 = lowAChroma.sample(linearSampler, uv).rg;
            half2 cb0 = lowBChroma.sample(linearSampler, uv).rg;
            half2 minC = min(ca0, cb0);
            half2 maxC = max(ca0, cb0);
            half centerLumaBreak = max(half(0.0), max(minY - midY, midY - maxY));
            half2 centerChromaOver = max(half2(0.0), max(minC - midC, midC - maxC)) * half(255.0 / 224.0);
            if (centerLumaBreak <= half(0.065) && length(centerChromaOver) <= half(0.055)) {
                return half(0.0);
            }
            float2 lStep = 1.0f / float2(lowA.get_width(), lowA.get_height());
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    if (dx == 0 && dy == 0) continue;
                    float2 p = uv + float2(float(dx), float(dy)) * lStep;
                    half ya = saturate(nv12Luma(lowA.sample(linearSampler, p).r));
                    half yb = saturate(nv12Luma(lowB.sample(linearSampler, p).r));
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
                half ya = saturate(nv12Luma(lowA.sample(linearSampler, p).r));
                half yb = saturate(nv12Luma(lowB.sample(linearSampler, p).r));
                minY = min(minY, min(ya, yb));
                maxY = max(maxY, max(ya, yb));
            }
            half rangeY = maxY - minY;
            if (rangeY >= half(0.08)) return half(0.0);
            float2 cStep = 1.0f / float2(lowAChroma.get_width(), lowAChroma.get_height());
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    if (dx == 0 && dy == 0) continue;
                    float2 p = uv + float2(float(dx), float(dy)) * cStep;
                    half2 ca = lowAChroma.sample(linearSampler, p).rg;
                    half2 cb = lowBChroma.sample(linearSampler, p).rg;
                    minC = min(minC, min(ca, cb));
                    maxC = max(maxC, max(ca, cb));
                }
            }
            half2 rangeC = (maxC - minC) * half(255.0 / 224.0);
            half maxRangeC = max(rangeC.x, rangeC.y);
            if (maxRangeC >= half(0.07)) return half(0.0);
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
        // Four bilinear taps per output texel; covers both the 0.5 (4K) and 0.75 (1440p) scales.
        kernel void shrinkLuma(texture2d<half, access::sample> source [[texture(0)]],
                               texture2d<half, access::write> output [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float2 size = float2(output.get_width(), output.get_height());
            float2 uv = (float2(gid) + 0.5f) / size;
            float2 o = 0.25f / size;
            half value = (source.sample(linearSampler, uv + float2(-o.x, -o.y)).r
                        + source.sample(linearSampler, uv + float2(o.x, -o.y)).r
                        + source.sample(linearSampler, uv + float2(-o.x, o.y)).r
                        + source.sample(linearSampler, uv + float2(o.x, o.y)).r) * half(0.25);
            output.write(half4(value), gid);
        }
        kernel void shrinkChroma(texture2d<half, access::sample> source [[texture(0)]],
                                 texture2d<half, access::write> output [[texture(1)]],
                                 constant float2 &offset [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float2 size = float2(output.get_width(), output.get_height());
            float2 uv = (float2(gid) + 0.5f) / size + offset;
            float2 o = 0.25f / size;
            half2 value = (source.sample(linearSampler, uv + float2(-o.x, -o.y)).rg
                         + source.sample(linearSampler, uv + float2(o.x, -o.y)).rg
                         + source.sample(linearSampler, uv + float2(-o.x, o.y)).rg
                         + source.sample(linearSampler, uv + float2(o.x, o.y)).rg) * half(0.5) * half(0.5);
            output.write(half4(value, half(0.0), half(0.0)), gid);
        }
        // Catmull-Rom from nine bilinear taps.
        inline float4 catmullRom(texture2d<half, access::sample> image, float2 uv) {
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
            float4 result = float4(image.sample(linearSampler, float2(p0.x, p0.y))) * w0.x * w0.y;
            result += float4(image.sample(linearSampler, float2(p12.x, p0.y))) * w12.x * w0.y;
            result += float4(image.sample(linearSampler, float2(p3.x, p0.y))) * w3.x * w0.y;
            result += float4(image.sample(linearSampler, float2(p0.x, p12.y))) * w0.x * w12.y;
            result += float4(image.sample(linearSampler, float2(p12.x, p12.y))) * w12.x * w12.y;
            result += float4(image.sample(linearSampler, float2(p3.x, p12.y))) * w3.x * w12.y;
            result += float4(image.sample(linearSampler, float2(p0.x, p3.y))) * w0.x * w3.y;
            result += float4(image.sample(linearSampler, float2(p12.x, p3.y))) * w12.x * w3.y;
            result += float4(image.sample(linearSampler, float2(p3.x, p3.y))) * w3.x * w3.y;
            return result;
        }
        // Edge-aware weighted 5-tap patch mismatch so cross taps across a sharp object silhouette
        // do not corrupt motion-vector selection at the 1-pixel boundary.
        inline half patchDiff(texture2d<half, access::sample> img, float2 uv, float2 step,
                              half m0, half m1, half m2, half m3, half m4,
                              half wg1, half wg2, half wg3, half wg4, half invW) {
            half d = abs(img.sample(linearSampler, uv).r - m0);
            d += wg1 * abs(img.sample(linearSampler, uv + float2(step.x, 0.0f)).r - m1);
            d += wg2 * abs(img.sample(linearSampler, uv - float2(step.x, 0.0f)).r - m2);
            d += wg3 * abs(img.sample(linearSampler, uv + float2(0.0f, step.y)).r - m3);
            d += wg4 * abs(img.sample(linearSampler, uv - float2(0.0f, step.y)).r - m4);
            return d * invW;
        }
        // Bit-level IEEE 754 exponent checks survive Metal's default fast-math optimization.
        inline bool isFiniteHalf2(half2 value) {
            return (as_type<ushort>(value.x) & 0x7C00u) != 0x7C00u
                && (as_type<ushort>(value.y) & 0x7C00u) != 0x7C00u;
        }
        inline bool isFiniteMotion(half2 raw, float2 value, bool safeFinite) {
            if (safeFinite) return isFiniteHalf2(raw);
            return isfinite(value.x) && isfinite(value.y);
        }
        // Evaluates bidirectional motion-vector candidates, edge-aware patch mismatch, forward-backward
        // occlusion consistency, and low-frequency static candidacy once per downscaled pixel (1/4 the
        // threads of 4K), packing (bestDUV.x, bestDUV.y, lowStatic ? wA + 2 : wA, wB) for full-res merge.
        kernel void selectMotion(texture2d<half, access::sample> lowA [[texture(0)]],
                                 texture2d<half, access::sample> lowAChroma [[texture(1)]],
                                 texture2d<half, access::sample> lowB [[texture(2)]],
                                 texture2d<half, access::sample> lowBChroma [[texture(3)]],
                                 texture2d<half, access::sample> lowMid [[texture(4)]],
                                 texture2d<half, access::sample> motion [[texture(5)]],
                                 texture2d<half, access::write> detailOut [[texture(6)]],
                                 texture2d<half, access::sample> forwardMotion [[texture(7), function_constant(hasForwardMotion)]],
                                 constant float4 &weights [[buffer(0)]],
                                 constant float4 &motionScale [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
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
                half3 la = lowBlur(lowA, lowAChroma, uv, hdrMode);
                half3 lb = lowBlur(lowB, lowBChroma, uv, hdrMode);
                lowStatic = length(la - lb) < half(0.012);
            }
            half2 centerRaw = motion.sample(nearestSampler, uv).rg;
            float2 centerV = float2(centerRaw);
            bool centerFinite = isFiniteMotion(centerRaw, centerV, safeFinite);
            bool centerSmall = !centerFinite || (abs(centerV.x) < 0.25f && abs(centerV.y) < 0.25f);
            if (lowStatic && centerSmall) {
                detailOut.write(half4(half(0.0), half(0.0), half(2.0), half(0.0)), gid);
                return;
            }
            float fwdScale = motionScale.z;
            half2 centerFwdRaw = hasForwardMotion
                ? forwardMotion.sample(nearestSampler, uv).rg : half2(half(0.0));
            float2 centerFwdV = hasForwardMotion ? -float2(centerFwdRaw) * fwdScale : float2(0.0f);
            float2 gridSize = float2(motion.get_width(), motion.get_height());
            float2 gridStep = 1.0f / gridSize;
            float2 gridFrac = fract(uv * gridSize);
            float sx = gridFrac.x < 0.5f ? -1.0f : 1.0f;
            float sy = gridFrac.y < 0.5f ? -1.0f : 1.0f;
            float t = weights.x;
            half m0, m1, m2, m3, m4;
            if (sampleMid) {
                m0 = lowMid.sample(linearSampler, uv).r;
                m1 = lowMid.sample(linearSampler, uv + float2(lowStep.x, 0.0f)).r;
                m2 = lowMid.sample(linearSampler, uv - float2(lowStep.x, 0.0f)).r;
                m3 = lowMid.sample(linearSampler, uv + float2(0.0f, lowStep.y)).r;
                m4 = lowMid.sample(linearSampler, uv - float2(0.0f, lowStep.y)).r;
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
            // Quadrant-nearest 2x2 macroblocks cover horizontal, vertical and diagonal object silhouettes
            // in 4 probes; only residual thin-object edges fall through to forward and opposite cardinals.
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
            int totalCandidates = hasForwardMotion ? 7 : 6;
            for (int i = 0; i < totalCandidates; ++i) {
                if (i == 4 && bestScore < half(0.015)) break;
                if (i == 5 && bestScore < half(0.022)) break;
                half2 rawV;
                float2 v;
                if (i == 0) {
                    rawV = centerRaw;
                    v = centerV;
                } else if (i < 4) {
                    rawV = motion.sample(nearestSampler, uv + probeOffsets[i] * gridStep).rg;
                    v = float2(rawV);
                } else if (hasForwardMotion && i == 4) {
                    rawV = centerFwdRaw;
                    v = centerFwdV;
                } else {
                    int idx = hasForwardMotion ? (i - 1) : i;
                    rawV = motion.sample(nearestSampler, uv + probeOffsets[idx] * gridStep).rg;
                    v = float2(rawV);
                }
                if (!isFiniteMotion(rawV, v, safeFinite) || (abs(v.x) < 0.25f && abs(v.y) < 0.25f)) continue;
                if (i > 0 && ((centerFinite && abs(v.x - centerV.x) < 0.25f && abs(v.y - centerV.y) < 0.25f)
                           || (abs(v.x - lastV.x) < 0.25f && abs(v.y - lastV.y) < 0.25f)
                           || (abs(v.x - bestV.x) < 0.25f && abs(v.y - bestV.y) < 0.25f))) continue;
                lastV = v;
                float2 dUV = v * motionScale.xy;
                float2 uvA = uv + t * dUV;
                float2 uvB = uv - (1.0f - t) * dUV;
                half eA = patchDiff(lowA, uvA, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
                half eB = patchDiff(lowB, uvB, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
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
                    half occA = abs(lowA.sample(linearSampler, uvA).r - lowB.sample(linearSampler, uvA).r)
                        * half(255.0 / 219.0);
                    if (occA < half(0.025)) { bestScore = min(bestScore, bestErrB + half(0.006)); }
                } else if (bestErrA < half(0.018) && bestErrB > bestErrA + half(0.025)) {
                    half occB = abs(lowA.sample(linearSampler, uvB).r - lowB.sample(linearSampler, uvB).r)
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
                    half ga = lowA.sample(linearSampler, gp).r;
                    half gb = lowB.sample(linearSampler, gp).r;
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
                    half2 rawV = motion.sample(nearestSampler, uv + hudOffsets[k] * gridStep).rg;
                    float2 v = float2(rawV);
                    if (!isFiniteMotion(rawV, v, safeFinite) || (abs(v.x) < 0.25f && abs(v.y) < 0.25f)) continue;
                    if ((abs(v.x - hudLastV.x) < 0.25f && abs(v.y - hudLastV.y) < 0.25f)
                        || (abs(v.x - bestV.x) < 0.25f && abs(v.y - bestV.y) < 0.25f)) continue;
                    hudLastV = v;
                    float2 dUV = v * motionScale.xy;
                    float2 uvA = uv + t * dUV;
                    float2 uvB = uv - (1.0f - t) * dUV;
                    half eA = patchDiff(lowA, uvA, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
                    half eB = patchDiff(lowB, uvB, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
                    half score = min(eA, eB) + half(0.5) * max(eA, eB);
                    if (eB < half(0.018) && eA > eB + half(0.025)) {
                        half occA = abs(lowA.sample(linearSampler, uvA).r - lowB.sample(linearSampler, uvA).r)
                            * half(255.0 / 219.0);
                        if (occA < half(0.025)) { score = min(score, eB + half(0.006)); }
                    } else if (eA < half(0.018) && eB > eA + half(0.025)) {
                        half occB = abs(lowA.sample(linearSampler, uvB).r - lowB.sample(linearSampler, uvB).r)
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
            if (hasForwardMotion && (wA + wB > half(0.02))) {
                float2 uvA = uv + t * bestDUV;
                float2 uvB = uv - (1.0f - t) * bestDUV;
                half2 rawAB = forwardMotion.sample(nearestSampler, uvA).rg;
                half2 rawBA = motion.sample(nearestSampler, uvB).rg;
                float2 vABatA = float2(rawAB) * fwdScale;
                float2 vBAatB = float2(rawBA);
                float fbThresh = max(2.5f, 0.25f * length(bestV));
                if (isFiniteMotion(rawAB, vABatA, safeFinite) && bestErrA > bestErrB + half(0.005)) {
                    float fbA = length(vABatA + bestV);
                    if (fbA > fbThresh) {
                        wA *= smoothstep(half(fbThresh * 2.0f), half(fbThresh), half(fbA));
                    }
                }
                if (isFiniteMotion(rawBA, vBAatB, safeFinite) && bestErrB > bestErrA + half(0.005)) {
                    float fbB = length(vBAatB - bestV);
                    if (fbB > fbThresh) {
                        wB *= smoothstep(half(fbThresh * 2.0f), half(fbThresh), half(fbB));
                    }
                }
            }
            detailOut.write(half4(half(bestDUV.x), half(bestDUV.y), lowStatic ? (wA + half(2.0)) : wA, wB), gid);
        }
        // A pixel that is unchanged in both native sources and in their blurred downscaled copies keeps the
        // native value; elsewhere VT's midpoint is upscaled with Catmull-Rom, with optional motion-guided
        // native high-frequency detail transfer and overshoot-clamped adaptive sharpening.
        kernel void merge(texture2d<half, access::sample> a [[texture(0)]],
                          texture2d<half, access::sample> b [[texture(1)]],
                          texture2d<half, access::sample> aChroma [[texture(2), function_constant(nv12)]],
                          texture2d<half, access::sample> bChroma [[texture(3), function_constant(nv12)]],
                          texture2d<half, access::sample> lowA [[texture(4)]],
                          texture2d<half, access::sample> lowAChroma [[texture(5)]],
                          texture2d<half, access::sample> lowB [[texture(6)]],
                          texture2d<half, access::sample> lowBChroma [[texture(7)]],
                          texture2d<half, access::sample> lowMid [[texture(8)]],
                          texture2d<half, access::sample> lowMidChroma [[texture(9)]],
                          texture2d<half, access::write> output [[texture(10)]],
                          texture2d<half, access::sample> motionDetail [[texture(11), function_constant(hasMotion)]],
                          constant float4 &offsets [[buffer(0)]],
                          constant float4 &weights [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float2 uv = (float2(gid) + 0.5f) / float2(output.get_width(), output.get_height());
            uint qualityFlags = uint(weights.w + 0.5f);
            uint hdrMode = qualityFlags & 3u;
            bool iconEnvelope = (qualityFlags & 16u) != 0u;
            bool adaptiveCAS = (qualityFlags & 32u) != 0u;
            half4 md = half4(0.0);
            bool lowStatic = false;
            if (hasMotion) {
                md = motionDetail.sample(nearestSampler, uv);
                lowStatic = md.z >= half(1.5);
                if (lowStatic) md.z -= half(2.0);
            } else if (weights.y > 0.5f) {
                half3 la = lowBlur(lowA, lowAChroma, uv, hdrMode), lb = lowBlur(lowB, lowBChroma, uv, hdrMode);
                lowStatic = length(la - lb) < half(0.012);
            }
            half staticW = half(0.0);
            half3 staticColor = half3(0.0);
            if (lowStatic) {
                half3 ca = sourceColor(a, aChroma, uv, offsets.xy), cb = sourceColor(b, bChroma, uv, offsets.zw);
                if (length(ca - cb) < half(0.014)) {
                    half release = iconEnvelope
                        ? iconEnvelopeRelease(lowA, lowAChroma, lowB, lowBChroma, lowMid, lowMidChroma, uv)
                        : half(0.0);
                    staticW = half(1.0) - release;
                    staticColor = mix(ca, cb, half(weights.x));
                    if (staticW >= half(0.999)) {
                        output.write(half4(staticColor, half(1.0)), gid);
                        return;
                    }
                }
            }
            half midRawY = half(catmullRom(lowMid, uv).r);
            half2 midUV = lowMidChroma.sample(linearSampler, uv).rg;
            half3 midpoint = nv12Color(midRawY, midUV);
            half3 color = midpoint;
            half motionConf = half(0.0);
            if (hasMotion) {
                half wA = md.z;
                half wB = md.w;
                if (wA + wB > half(0.02)) {
                    float t = weights.x;
                    float2 bestDUV = float2(md.xy);
                    float2 uvA = uv + t * bestDUV;
                    float2 uvB = uv - (1.0f - t) * bestDUV;
                    half3 srcA = midpoint, srcB = midpoint;
                    half3 hiA = half3(0.0), hiB = half3(0.0);
                    if (wA > half(0.01)) {
                        srcA = sourceColor(a, aChroma, uvA, offsets.xy);
                        half3 baseA = nv12Color(
                            lowA.sample(linearSampler, uvA).r, lowAChroma.sample(linearSampler, uvA).rg);
                        hiA = srcA - baseA;
                    }
                    if (wB > half(0.01)) {
                        srcB = sourceColor(b, bChroma, uvB, offsets.zw);
                        half3 baseB = nv12Color(
                            lowB.sample(linearSampler, uvB).r, lowBChroma.sample(linearSampler, uvB).rg);
                        hiB = srcB - baseB;
                    }
                    half wa = half(1.0 - t) * wA;
                    half wb = half(t) * wB;
                    half3 detail = (hiA * wa + hiB * wb) / max(wa + wb, half(1e-4));
                    half conf = max(wA, wB);
                    motionConf = conf;
                    half3 envMin = min(midpoint, min(wA > half(0.1) ? srcA : midpoint, wB > half(0.1) ? srcB : midpoint));
                    half3 envMax = max(midpoint, max(wA > half(0.1) ? srcA : midpoint, wB > half(0.1) ? srcB : midpoint));
                    color = clamp(midpoint + conf * detail, envMin, envMax);
                }
            }
            if (weights.z > 0.001f) {
                float2 s = 0.75f / float2(lowMid.get_width(), lowMid.get_height());
                half y = dot(color, half3(0.2126, 0.7152, 0.0722));
                half n = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(0.0f, -s.y)).r));
                half so = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(0.0f, s.y)).r));
                half e = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(s.x, 0.0f)).r));
                half w = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(-s.x, 0.0f)).r));
                half mn = min(y, min(min(n, so), min(e, w)));
                half mx = max(y, max(max(n, so), max(e, w)));
                half amp = clamp(min(mn, half(1.0) - mx) / max(mx, half(1e-4)), half(0.0), half(1.0));
                half casGain = adaptiveCAS ? half(1.45) * (half(1.0) - half(0.65) * motionConf) : half(1.0);
                half k = -half(weights.z) * casGain * sqrt(amp);
                half sharpY = clamp((y + k * (n + so + e + w)) / (half(1.0) + half(4.0) * k), mn, mx);
                color = saturate(color + half3(sharpY - y));
            }
            if (staticW > half(0.001)) {
                color = mix(color, staticColor, staticW);
            }
            output.write(half4(color, half(1.0)), gid);
        }
        inline half lumaToNV12Y(half y) {
            return clamp(fma(y, half(219.0 / 255.0), half(16.0 / 255.0)), half(16.0 / 255.0), half(235.0 / 255.0));
        }
        // Emits native Rec.709 420v (12.4 MB vs 33.2 MB BGRA at 4K), running 1 thread per 2x2 luma block.
        // At exact 2:1 (4K from 1080p), a 20x20 threadgroup tile computes exact separable Catmull-Rom and
        // 4-tap CAS directly from SRAM (replacing 80 lowMid texture fetches/block), while operating purely
        // in YCbCr with smooth static/dynamic feathering to eliminate RGB round-trips and HUD edge shimmer.
        kernel void mergeNV12Out(texture2d<half, access::sample> a [[texture(0)]],
                                 texture2d<half, access::sample> b [[texture(1)]],
                                 texture2d<half, access::sample> aChroma [[texture(2)]],
                                 texture2d<half, access::sample> bChroma [[texture(3)]],
                                 texture2d<half, access::sample> lowA [[texture(4)]],
                                 texture2d<half, access::sample> lowAChroma [[texture(5)]],
                                 texture2d<half, access::sample> lowB [[texture(6)]],
                                 texture2d<half, access::sample> lowBChroma [[texture(7)]],
                                 texture2d<half, access::sample> lowMid [[texture(8)]],
                                 texture2d<half, access::sample> lowMidChroma [[texture(9)]],
                                 texture2d<half, access::write> outY [[texture(10)]],
                                 texture2d<half, access::write> outUV [[texture(11)]],
                                 texture2d<half, access::sample> motionDetail [[texture(12), function_constant(hasMotion)]],
                                 constant float4 &offsets [[buffer(0)]],
                                 constant float4 &weights [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]],
                                 uint2 tid [[thread_position_in_threadgroup]],
                                 uint2 tgSize [[threads_per_threadgroup]]) {
            threadgroup half midTile[20][20];
            if (exactTwoX) {
                int2 groupBase = int2(gid) - int2(tid);
                int lowW = int(lowMid.get_width());
                int lowH = int(lowMid.get_height());
                uint tgCount = tgSize.x * tgSize.y;
                uint linearTid = tid.y * tgSize.x + tid.x;
                for (uint idx = linearTid; idx < 400; idx += tgCount) {
                    uint ty = idx / 20;
                    uint tx = idx - ty * 20;
                    int sx = clamp(groupBase.x + int(tx) - 2, 0, lowW - 1);
                    int sy = clamp(groupBase.y + int(ty) - 2, 0, lowH - 1);
                    midTile[ty][tx] = nv12Luma(lowMid.read(uint2(sx, sy)).r);
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }
            uint halfW = outUV.get_width(), halfH = outUV.get_height();
            if (gid.x >= halfW || gid.y >= halfH) return;
            uint2 base = gid * 2;
            float2 invFull = 1.0f / float2(outY.get_width(), outY.get_height());
            float2 uvCenter = (float2(base) + 1.0f) * invFull;
            uint qualityFlags = uint(weights.w + 0.5f);
            uint hdrMode = qualityFlags & 3u;
            bool bt2020 = hdrMode >= 1u;
            half4 md = half4(0.0);
            bool lowStatic = false;
            if (hasMotion) {
                md = motionDetail.sample(nearestSampler, uvCenter);
                lowStatic = md.z >= half(1.5);
                if (lowStatic) md.z -= half(2.0);
            } else if (weights.y > 0.5f) {
                half3 la = lowBlur(lowA, lowAChroma, uvCenter, hdrMode);
                half3 lb = lowBlur(lowB, lowBChroma, uvCenter, hdrMode);
                lowStatic = length(la - lb) < half(0.012);
            }
            half tHalf = half(weights.x);
            bool hudDehalo = (qualityFlags & 4u) != 0u;
            bool iconEnvelope = (qualityFlags & 16u) != 0u;
            bool adaptiveCAS = (qualityFlags & 32u) != 0u;
            half iconRelease = (iconEnvelope && lowStatic)
                ? iconEnvelopeRelease(lowA, lowAChroma, lowB, lowBChroma, lowMid, lowMidChroma, uvCenter)
                : half(0.0);
            half pairedConfidence = (qualityFlags & 8u) != 0u && hasMotion
                ? smoothstep(half(0.25), half(0.80), min(md.z, md.w)) : half(0.0);
            half2 caUV = half2(0.0), cbUV = half2(0.0);
            half yA[4] = { half(0.0), half(0.0), half(0.0), half(0.0) };
            half yB[4] = { half(0.0), half(0.0), half(0.0), half(0.0) };
            half diff2[4] = { half(1.0), half(1.0), half(1.0), half(1.0) };
            if (lowStatic) {
                caUV = aChroma.sample(linearSampler, uvCenter + offsets.xy).rg;
                cbUV = bChroma.sample(linearSampler, uvCenter + offsets.zw).rg;
                yA[0] = a.sample(nearestSampler, (float2(base) + float2(0.5f, 0.5f)) * invFull).r;
                yB[0] = b.sample(nearestSampler, (float2(base) + float2(0.5f, 0.5f)) * invFull).r;
                yA[1] = a.sample(nearestSampler, (float2(base) + float2(1.5f, 0.5f)) * invFull).r;
                yB[1] = b.sample(nearestSampler, (float2(base) + float2(1.5f, 0.5f)) * invFull).r;
                yA[2] = a.sample(nearestSampler, (float2(base) + float2(0.5f, 1.5f)) * invFull).r;
                yB[2] = b.sample(nearestSampler, (float2(base) + float2(0.5f, 1.5f)) * invFull).r;
                yA[3] = a.sample(nearestSampler, (float2(base) + float2(1.5f, 1.5f)) * invFull).r;
                yB[3] = b.sample(nearestSampler, (float2(base) + float2(1.5f, 1.5f)) * invFull).r;
                half2 dCbCr = (caUV - cbUV) * half(255.0 / 224.0);
                half dR = bt2020 ? (half(1.4746) * dCbCr.y) : (half(1.5748) * dCbCr.y);
                half dG = bt2020
                    ? fma(half(-0.57135), dCbCr.y, half(-0.16455) * dCbCr.x)
                    : fma(half(-0.468124), dCbCr.y, half(-0.187324) * dCbCr.x);
                half dB = bt2020 ? (half(1.8814) * dCbCr.x) : (half(1.8556) * dCbCr.x);
                for (uint k = 0; k < 4; ++k) {
                    half dY = (yA[k] - yB[k]) * half(255.0 / 219.0);
                    half r = dY + dR;
                    half g = dY + dG;
                    half bl = dY + dB;
                    diff2[k] = r * r + g * g + bl * bl;
                }
                if (pairedConfidence == half(0.0) && iconRelease < half(0.001)
                    && max(max(diff2[0], diff2[1]), max(diff2[2], diff2[3])) < half(0.014 * 0.014)) {
                    outY.write(half4(mix(yA[0], yB[0], tHalf)), base);
                    outY.write(half4(mix(yA[1], yB[1], tHalf)), base + uint2(1, 0));
                    outY.write(half4(mix(yA[2], yB[2], tHalf)), base + uint2(0, 1));
                    outY.write(half4(mix(yA[3], yB[3], tHalf)), base + uint2(1, 1));
                    outUV.write(half4(mix(caUV, cbUV, tHalf), half(0.0), half(0.0)), gid);
                    return;
                }
            }
            half2 midUV = lowMidChroma.sample(linearSampler, uvCenter).rg;
            float t = weights.x;
            float2 bestDUV = float2(md.xy);
            half wA = md.z;
            half wB = md.w;
            bool applyMotion = hasMotion && (wA + wB > half(0.02));
            half wa = half(1.0 - t) * wA;
            half wb = half(t) * wB;
            half invWAB = half(1.0) / max(wa + wb, half(1e-4));
            half conf = max(wA, wB);
            half2 outChroma = midUV;
            if (applyMotion) {
                float2 uvAC = uvCenter + t * bestDUV;
                float2 uvBC = uvCenter - (1.0f - t) * bestDUV;
                half2 srcAUV = midUV, srcBUV = midUV;
                half2 hiAUV = half2(0.0), hiBUV = half2(0.0);
                if (wA > half(0.01)) {
                    srcAUV = aChroma.sample(linearSampler, uvAC + offsets.xy).rg;
                    hiAUV = srcAUV - lowAChroma.sample(linearSampler, uvAC).rg;
                }
                if (wB > half(0.01)) {
                    srcBUV = bChroma.sample(linearSampler, uvBC + offsets.zw).rg;
                    hiBUV = srcBUV - lowBChroma.sample(linearSampler, uvBC).rg;
                }
                half2 detailUV = (hiAUV * wa + hiBUV * wb) * invWAB;
                half2 uvMin = min(midUV, min(wA > half(0.1) ? srcAUV : midUV, wB > half(0.1) ? srcBUV : midUV));
                half2 uvMax = max(midUV, max(wA > half(0.1) ? srcAUV : midUV, wB > half(0.1) ? srcBUV : midUV));
                outChroma = clamp(midUV + conf * detailUV, uvMin, uvMax);
            }
            half catY[4];
            half t00 = half(0.0), t01 = half(0.0), t02 = half(0.0);
            half t10 = half(0.0), t11 = half(0.0), t12 = half(0.0);
            half t20 = half(0.0), t21 = half(0.0), t22 = half(0.0);
            if (exactTwoX) {
                uint lx = tid.x + 2;
                uint ly = tid.y + 2;
                const half c0 = half(-3.0 / 128.0);
                const half c1 = half(29.0 / 128.0);
                const half c2 = half(111.0 / 128.0);
                const half c3 = half(-9.0 / 128.0);
                half rowL[5];
                half rowR[5];
                for (uint r = 0; r < 5; ++r) {
                    uint ry = ly - 2 + r;
                    half s0 = midTile[ry][lx - 2];
                    half s1 = midTile[ry][lx - 1];
                    half s2 = midTile[ry][lx];
                    half s3 = midTile[ry][lx + 1];
                    half s4 = midTile[ry][lx + 2];
                    rowL[r] = fma(c0, s0, fma(c1, s1, fma(c2, s2, c3 * s3)));
                    rowR[r] = fma(c3, s1, fma(c2, s2, fma(c1, s3, c0 * s4)));
                }
                catY[0] = saturate(fma(c0, rowL[0], fma(c1, rowL[1], fma(c2, rowL[2], c3 * rowL[3]))));
                catY[1] = saturate(fma(c0, rowR[0], fma(c1, rowR[1], fma(c2, rowR[2], c3 * rowR[3]))));
                catY[2] = saturate(fma(c3, rowL[1], fma(c2, rowL[2], fma(c1, rowL[3], c0 * rowL[4]))));
                catY[3] = saturate(fma(c3, rowR[1], fma(c2, rowR[2], fma(c1, rowR[3], c0 * rowR[4]))));
                if (weights.z > 0.001f) {
                    t00 = saturate(midTile[ly - 1][lx - 1]);
                    t01 = saturate(midTile[ly - 1][lx]);
                    t02 = saturate(midTile[ly - 1][lx + 1]);
                    t10 = saturate(midTile[ly][lx - 1]);
                    t11 = saturate(midTile[ly][lx]);
                    t12 = saturate(midTile[ly][lx + 1]);
                    t20 = saturate(midTile[ly + 1][lx - 1]);
                    t21 = saturate(midTile[ly + 1][lx]);
                    t22 = saturate(midTile[ly + 1][lx + 1]);
                }
            }
            float2 casStep = 0.75f / float2(lowMid.get_width(), lowMid.get_height());
            half staticWeightSum = half(0.0);
            for (uint dy = 0; dy < 2; ++dy) {
                for (uint dx = 0; dx < 2; ++dx) {
                    uint k = dy * 2 + dx;
                    uint2 px = base + uint2(dx, dy);
                    half staticW = lowStatic
                        ? smoothstep(half(0.022), half(0.011), sqrt(diff2[k])) * (half(1.0) - iconRelease)
                        : half(0.0);
                    if (staticW >= half(0.999) && pairedConfidence == half(0.0)) {
                        staticWeightSum += staticW;
                        outY.write(half4(mix(yA[k], yB[k], tHalf)), px);
                        continue;
                    }
                    float2 uv = (float2(px) + 0.5f) * invFull;
                    half midY = exactTwoX ? catY[k] : saturate(nv12Luma(half(catmullRom(lowMid, uv).r)));
                    half y = midY;
                    half alignedY = midY;
                    half alignedWeight = half(0.0);
                    if (applyMotion) {
                        float2 uvA = uv + t * bestDUV;
                        float2 uvB = uv - (1.0f - t) * bestDUV;
                        half srcAY = midY, srcBY = midY;
                        half baseAY = midY, baseBY = midY;
                        half hiAY = half(0.0), hiBY = half(0.0);
                        if (wA > half(0.01)) {
                            srcAY = saturate(nv12Luma(a.sample(linearSampler, uvA).r));
                            baseAY = saturate(nv12Luma(lowA.sample(linearSampler, uvA).r));
                            hiAY = srcAY - baseAY;
                        }
                        if (wB > half(0.01)) {
                            srcBY = saturate(nv12Luma(b.sample(linearSampler, uvB).r));
                            baseBY = saturate(nv12Luma(lowB.sample(linearSampler, uvB).r));
                            hiBY = srcBY - baseBY;
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
                            half agrees = half(1.0) - smoothstep(half(0.012), half(0.04), abs(srcAY - srcBY));
                            alignedWeight = pairedConfidence * agrees;
                            alignedY = mix(srcAY, srcBY, tHalf);
                            if (staticW > half(0.0)) {
                                // A thin moving stroke can lie between its two original positions.
                                // Require its direction of contrast change to agree with the VT midpoint.
                                half originalY = nv12Luma(mix(yA[k], yB[k], tHalf));
                                half movement = clamp(sign(alignedY - originalY) * (midY - originalY),
                                                      half(0.0), half(1.0));
                                staticW *= half(1.0)
                                    - alignedWeight * smoothstep(half(0.025), half(0.10), movement);
                            }
                        }
                    } else if (hudDehalo && !lowStatic && weights.y > 0.5f) {
                        half syA = a.sample(nearestSampler, uv).r;
                        half syB = b.sample(nearestSampler, uv).r;
                        half dSY = abs(syA - syB) * half(255.0 / 219.0);
                        if (dSY < half(0.012)) {
                            half lowAY = saturate(nv12Luma(lowA.sample(linearSampler, uv).r));
                            half lowBY = saturate(nv12Luma(lowB.sample(linearSampler, uv).r));
                            half midDev = max(half(0.0), max(min(lowAY, lowBY) - midY, midY - max(lowAY, lowBY)));
                            half2 scA = aChroma.sample(linearSampler, uvCenter + offsets.xy).rg;
                            half2 scB = bChroma.sample(linearSampler, uvCenter + offsets.zw).rg;
                            half dSC = length((scA - scB) * half(255.0 / 224.0));
                            half strokeW = (half(1.0) - smoothstep(half(0.005), half(0.012), dSY))
                                * (half(1.0) - smoothstep(half(0.012), half(0.024), dSC))
                                * (half(1.0) - smoothstep(half(0.025), half(0.065), midDev));
                            if (strokeW > half(0.01)) {
                                yA[k] = syA;
                                yB[k] = syB;
                                caUV = scA;
                                cbUV = scB;
                                staticW = max(staticW, strokeW);
                            }
                        }
                    }
                    if (weights.z > 0.001f) {
                        half n, so, e, w;
                        if (exactTwoX) {
                            if (dx == 0) {
                                half xm0 = fma(half(0.25), t00, half(0.75) * t01);
                                half xm1 = fma(half(0.25), t10, half(0.75) * t11);
                                half xm2 = fma(half(0.25), t20, half(0.75) * t21);
                                if (dy == 0) {
                                    n = xm0;
                                    so = (xm1 + xm2) * half(0.5);
                                    w = fma(half(0.25), t00, half(0.75) * t10);
                                    e = fma(half(0.125), t01 + t02, half(0.375) * (t11 + t12));
                                } else {
                                    n = (xm0 + xm1) * half(0.5);
                                    so = xm2;
                                    w = fma(half(0.75), t10, half(0.25) * t20);
                                    e = fma(half(0.375), t11 + t12, half(0.125) * (t21 + t22));
                                }
                            } else {
                                half xp0 = fma(half(0.75), t01, half(0.25) * t02);
                                half xp1 = fma(half(0.75), t11, half(0.25) * t12);
                                half xp2 = fma(half(0.75), t21, half(0.25) * t22);
                                if (dy == 0) {
                                    n = xp0;
                                    so = (xp1 + xp2) * half(0.5);
                                    w = fma(half(0.125), t00 + t01, half(0.375) * (t10 + t11));
                                    e = fma(half(0.25), t02, half(0.75) * t12);
                                } else {
                                    n = (xp0 + xp1) * half(0.5);
                                    so = xp2;
                                    w = fma(half(0.375), t10 + t11, half(0.125) * (t20 + t21));
                                    e = fma(half(0.75), t12, half(0.25) * t22);
                                }
                            }
                        } else {
                            n = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(0.0f, -casStep.y)).r));
                            so = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(0.0f, casStep.y)).r));
                            e = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(casStep.x, 0.0f)).r));
                            w = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(-casStep.x, 0.0f)).r));
                        }
                        half mn = min(y, min(min(n, so), min(e, w)));
                        half mx = max(y, max(max(n, so), max(e, w)));
                        half amp = clamp(min(mn, half(1.0) - mx) / max(mx, half(1e-4)), half(0.0), half(1.0));
                        half motionConf = applyMotion ? conf : half(0.0);
                        half casGain = adaptiveCAS ? half(1.45) * (half(1.0) - half(0.65) * motionConf) : half(1.0);
                        half kCas = -half(weights.z) * casGain * sqrt(amp);
                        y = clamp((y + kCas * (n + so + e + w)) / (half(1.0) + half(4.0) * kCas), mn, mx);
                    }
                    half yRaw = lumaToNV12Y(mix(y, alignedY, alignedWeight));
                    staticWeightSum += staticW;
                    if (staticW > half(0.001)) {
                        yRaw = mix(yRaw, mix(yA[k], yB[k], tHalf), staticW);
                    }
                    outY.write(half4(yRaw), px);
                }
            }
            if (staticWeightSum > half(0.001)) {
                outChroma = mix(outChroma, mix(caUV, cbUV, tHalf), min(half(1.0), staticWeightSum * half(0.25)));
            }
            outUV.write(half4(outChroma, half(0.0), half(0.0)), gid);
        }
        """
}
