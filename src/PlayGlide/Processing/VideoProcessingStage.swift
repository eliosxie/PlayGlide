import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalFX
import VideoToolbox

enum InterpolationReset: Sendable {
    case none, reference, timing
}

protocol VideoProcessingStage: Actor {
    func process(
        _ frame: VideoFrame, resetHistory: InterpolationReset, contentDuration: CMTime?, schedulingInterval: CMTime?,
        contentWork: Double, contentHitch: Bool, phaseSlipOffset: CMTime,
        emit: @escaping @Sendable (PresentationFrame) -> Void) async throws
    func reconfigure(to settings: SessionDraft) async
    func reset() async
}

struct ProcessingPlan: Sendable, Equatable {
    let input: VideoSize
    let output: VideoSize
    let backend: ProcessingBackend
    let multiplier: Int
    let spatial: Bool

    static func make(size: VideoSize, settings: SessionDraft) throws -> ProcessingPlan {
        let adaptiveWindow = settings.source == .window && settings.windowResolution == .adaptive
        let nativeWindow = settings.source == .window && settings.windowResolution == .nativePixels
        let fits =
            size.width <= 3840 && size.height <= 2160
            || adaptiveWindow && size.width <= 2160 && size.height <= 3840
            || nativeWindow && size.width > 0 && size.height > 0 && max(size.width, size.height) <= 3840
                && size.pixels <= InputPreset.uhd4K.size.pixels
        guard size.width > 0, size.height > 0, fits else {
            throw PipelineError(
                AppText("输入分辨率无效或超出 4K 上限。", "The input resolution is invalid or exceeds the 4K limit."))
        }
        let output = settings.upscaling == .off ? size : settings.outputPreset.size(for: size)
        if settings.upscaling != .off {
            guard settings.outputPreset.canUpscale(from: size) else {
                throw PipelineError(
                    AppText(
                        "放大目标需大于输入且不超过 4K；原尺寸补帧请关闭超分",
                        "Choose an upscaling target larger than the input and no higher than 4K. Turn off upscaling to keep the source resolution."
                    ))
            }
            guard let device = MTLCreateSystemDefaultDevice(), MTLFXSpatialScalerDescriptor.supportsDevice(device)
            else {
                throw PipelineError(AppText("当前进程无法使用 MetalFX Spatial", "MetalFX Spatial is unavailable for this app."))
            }
        }
        let multiplier = settings.interpolation.rawValue
        if settings.backend == .opticalFlow && multiplier > 2 {
            throw PipelineError(
                AppText("光流原尺寸重建当前只验证2×，请选择30→60", "Native optical flow supports 2×. Select the 30 → 60 option."))
        }
        var backend = settings.backend
        if multiplier > 1 {
            let maximum = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1) ?? 0
            let pixels = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1) ?? 0
            let lowLatencyFits =
                VTLowLatencyFrameInterpolationConfiguration.isSupported
                && max(size.width, size.height) <= maximum && size.pixels <= pixels
            if backend == .automatic {
                let fourK = size == InputPreset.uhd4K.size
                let fourKWindow = settings.source == .window && fourK
                if (adaptiveWindow || nativeWindow || fourKWindow) && multiplier == 2 {
                    backend = .opticalFlow
                } else if lowLatencyFits {
                    backend = .lowLatency
                } else if multiplier == 2 && (size == InputPreset.qhd1440.size || fourK) {
                    backend = .opticalFlow
                } else {
                    backend = .frameRateConversion
                }
            }
            if backend == .lowLatency && !lowLatencyFits {
                throw PipelineError(
                    AppText(
                        "\(size) 超出本机 VT 低延迟输入范围；请选择自动或原尺寸 FRC",
                        "\(size) exceeds the input limit for VideoToolbox Low Latency on this Mac. Choose Automatic or Native FRC."
                    ))
            }
            if backend == .frameRateConversion && !VTFrameRateConversionConfiguration.isSupported {
                throw PipelineError(
                    AppText("本机不支持普通 VT 帧率转换", "This Mac does not support VideoToolbox frame rate conversion."))
            }
        }
        return ProcessingPlan(
            input: size, output: output, backend: backend,
            multiplier: multiplier, spatial: settings.upscaling == .metalFXSpatial)
    }
    var title: AppText {
        let effect: AppText
        if multiplier == 1 {
            effect = AppText("直通", "Passthrough")
        } else if backend == .opticalFlow {
            effect = AppText("原尺寸光流补帧 2×", "Native Optical Flow 2×")
        } else if backend == .lowLatency {
            effect = AppText("VT 低延迟 \(multiplier)×", "VideoToolbox Low Latency \(multiplier)×")
        } else {
            effect = AppText("VideoToolbox 原尺寸补帧 \(multiplier)×", "VideoToolbox Native Interpolation \(multiplier)×")
        }
        return spatial ? AppText("\(effect.chinese) → MetalFX Spatial", "\(effect.english) → MetalFX Spatial") : effect
    }
}

actor FrameProcessor: VideoProcessingStage {
    private var settings: SessionDraft
    private let generation: UUID
    private let mailbox: FrameMailbox
    private let preferFlowTextureViews: Bool
    private var usesStableWindowCadence: Bool
    private var plan: ProcessingPlan?
    private var processor: VTFrameProcessor?
    private var flowInterpolator: FlowInterpolator?
    /// Automatic 1440p/4K 2×: native originals with VT midpoints from downscaled copies. Chosen over
    /// Vision flow on 2026-11-21 for straighter edges, no ghosting and steadier readiness; an explicit
    /// optical-flow backend or `PLAYGLIDE_HYBRID_VT=0` keeps the flow path.
    private var hybrid: HybridInterpolator?
    private let hybridAllowed = ProcessInfo.processInfo.environment["PLAYGLIDE_HYBRID_VT"] != "0"
    private let dynamicCadenceCapEnabled = ContentCadence.dynamicCadenceCapEnabled
    private let interactiveSixtyGuardEnabled = ContentCadence.interactiveSixtyGuardEnabled
    private var sourcePool: PixelBufferPool?
    private var destinationPool: PixelBufferPool?
    private var readOnlyOutputPool: PixelBufferPool?
    private let converter = PixelConverter()
    private var previous: (converted: VideoFrame?, original: VideoFrame)?
    private var submittedPair = false
    private var inFlight: Task<Void, Error>?
    private var resetting = false
    private var presentation = LivePresentationController()
    private var activePair: LivePairTiming?

    init(settings: SessionDraft, generation: UUID, mailbox: FrameMailbox, preferFlowTextureViews: Bool = true) {
        self.settings = settings
        self.generation = generation
        self.mailbox = mailbox
        self.preferFlowTextureViews = preferFlowTextureViews
        usesStableWindowCadence = settings.usesStableWindowCadence
    }

    private func configure(size: VideoSize) throws {
        presentation = LivePresentationController()
        processor?.endSession()
        processor = nil
        previous = nil
        submittedPair = false
        let plan = try ProcessingPlan.make(size: size, settings: settings)
        self.plan = plan
        mailbox.mutate(generation) {
            $0.backend = AppText("准备：\(plan.title.chinese)", "Preparing: \(plan.title.english)")
            $0.opticalFlowLatencies = OpticalFlowLatencies()
        }
        flowInterpolator = nil
        hybrid = nil
        sourcePool = nil
        let hybrid2x =
            plan.backend == .opticalFlow && plan.multiplier == 2 && hybridAllowed && settings.backend == .automatic
            && settings.source != .window
        let hybrid4x =
            plan.backend == .frameRateConversion && plan.multiplier == 4 && hybridAllowed
            && settings.backend == .automatic && settings.source != .window
            && (size == InputPreset.uhd4K.size || size == InputPreset.qhd1440.size)
        if hybrid2x || hybrid4x,
            let low = HybridInterpolator.lowSize(
                for: size, maxHeight: plan.multiplier == 4 ? 720 : settings.hybridQuality.maxLowHeight)
        {
            let hybrid = try HybridInterpolator(size: size, low: low, multiplier: plan.multiplier)
            self.hybrid = hybrid
            mailbox.mutate(generation) {
                $0.backend = AppText(
                    "原尺寸原帧 + VT \(hybrid.low) 中间帧 \(plan.multiplier)×",
                    "Native originals + VT \(hybrid.low) interpolated frames \(plan.multiplier)×")
            }
            return
        }
        if plan.backend == .opticalFlow && plan.multiplier == 2 {
            let flow = try FlowInterpolator(size: size, preferFlowTextureViews: preferFlowTextureViews)
            flowInterpolator = flow
            mailbox.mutate(generation) {
                $0.backend = AppText(
                    "原尺寸光流补帧 2×（运动估计 \(flow.work)）",
                    "Native Optical Flow 2× (motion estimation \(flow.work))")
            }
            return
        }
        guard plan.multiplier > 1 else {
            mailbox.mutate(generation) { $0.backend = plan.title }
            return
        }
        let configuration: any VTFrameProcessorConfiguration
        let sourceAttributes: [String: any Sendable]
        let destinationAttributes: [String: any Sendable]
        let format: OSType
        if plan.backend == .lowLatency {
            // 2 selects the three available quarter phases; it does not mean 2x output.
            guard
                let config = VTLowLatencyFrameInterpolationConfiguration(
                    frameWidth: size.width, frameHeight: size.height,
                    numberOfInterpolatedFrames: plan.multiplier == 4 ? 2 : 1)
            else {
                throw PipelineError(
                    AppText(
                        "低延迟补帧配置创建失败：\(size)，\(plan.multiplier)×",
                        "Could not configure low-latency interpolation: \(size), \(plan.multiplier)×."))
            }
            guard let pixelFormat = config.supportedPixelFormats.first else {
                throw PipelineError(AppText("处理器没有可用像素格式", "The frame processor has no available pixel formats."))
            }
            configuration = config
            sourceAttributes = config.sourcePixelBufferAttributes
            destinationAttributes = config.destinationPixelBufferAttributes
            format = pixelFormat
        } else {
            guard
                let config = VTFrameRateConversionConfiguration(
                    frameWidth: size.width, frameHeight: size.height, usePrecomputedFlow: false,
                    qualityPrioritization: .normal, revision: VTFrameRateConversionConfiguration.defaultRevision),
                let pixelFormat = config.supportedPixelFormats.first
            else {
                throw PipelineError(
                    AppText("原尺寸帧率转换配置创建失败：\(size)", "Could not configure native frame rate conversion: \(size)."))
            }
            configuration = config
            sourceAttributes = config.sourcePixelBufferAttributes
            destinationAttributes = config.destinationPixelBufferAttributes
            format = pixelFormat
        }
        sourcePool = try PixelBufferPool(size: size, format: format, requirements: sourceAttributes)
        destinationPool = try PixelBufferPool(size: size, format: format, requirements: destinationAttributes)
        readOnlyOutputPool =
            plan.backend == .frameRateConversion
            ? try PixelBufferPool(size: size, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) : nil
        let session = VTFrameProcessor()
        try session.startSession(configuration: configuration)
        processor = session
        mailbox.mutate(generation) { $0.backend = plan.title }
    }

    func process(
        _ frame: VideoFrame, resetHistory: InterpolationReset, contentDuration: CMTime? = nil,
        schedulingInterval: CMTime? = nil, contentWork: Double = 0, contentHitch: Bool = false,
        phaseSlipOffset: CMTime = .zero,
        emit: @escaping @Sendable (PresentationFrame) -> Void
    ) async throws {
        guard inFlight == nil, !resetting else {
            throw PipelineError(AppText("处理器正在排空在途任务", "The frame processor is draining pending work."))
        }
        // VT's sequence cancellation can finish before its native callback has retired.
        // An unstructured task does not inherit the caller's cancellation: retain/drain
        // the complete SDK operation before endSession or releasing its buffers.
        let request = Task {
            try await self.processFrame(
                frame, resetHistory: resetHistory, contentDuration: contentDuration,
                schedulingInterval: schedulingInterval, contentWork: contentWork, contentHitch: contentHitch,
                phaseSlipOffset: phaseSlipOffset, emit: emit)
        }
        inFlight = request
        do {
            try await request.value
            inFlight = nil
            try Task.checkCancellation()
        } catch {
            inFlight = nil
            throw error
        }
    }

    private func processFrame(
        _ frame: VideoFrame, resetHistory: InterpolationReset, contentDuration: CMTime?, schedulingInterval: CMTime?,
        contentWork: Double, contentHitch: Bool, phaseSlipOffset: CMTime,
        emit downstream: @escaping @Sendable (PresentationFrame) -> Void
    ) async throws {
        let started = mediaHostTime()
        let pacedTime =
            phaseSlipOffset.isNumeric && CMTimeCompare(phaseSlipOffset, .zero) != 0
            ? CMTimeSubtract(frame.presentationTime, phaseSlipOffset) : frame.presentationTime
        let frame =
            CMTimeCompare(pacedTime, frame.presentationTime) == 0
            ? frame : frame.timed(at: pacedTime, duration: frame.duration)
        let ingressDropsAtStart = settings.interpolation == .off ? 0 : mailbox.ingressDropCount(generation)
        // Recovery probes exercise real native processing but publish only their current endpoint.
        let emit: @Sendable (PresentationFrame) -> Void = { output in
            if !output.generated || output.timing?.pair.probe != true { downstream(output) }
        }
        activePair = nil
        var completed = false
        defer {
            if completed, let pair = activePair {
                let now = mediaHostTime()
                let execution = now - started + contentWork
                let inputDropped =
                    pair.evaluate && !pair.probe && execution >= LivePresentationController.minimumSevereExecution
                    && mailbox.ingressDropCount(generation) > ingressDropsAtStart
                presentation.complete(
                    pair, requiredDelay: pair.requiredDelay, execution: execution, now: now,
                    transportIntervalWhenDropping: inputDropped ? frame.duration.seconds : nil,
                    inputArrival: settings.presentationMode == .responsive ? frame.arrivalTime : nil,
                    contentHitch: contentHitch)
                mailbox.mutate(generation) {
                    $0.fgHeld = presentation.held
                    $0.fgProbePairs = presentation.probes
                    $0.fgBypassedPairs = presentation.bypassedPairs
                    $0.fgHoldTransitions = presentation.transitions
                    $0.phaseSamples = presentation.sampleCount
                }
            }
            activePair = nil
        }
        if plan?.input != frame.size { try configure(size: frame.size) }
        guard let plan else { throw PipelineError(AppText("处理计划未建立", "The processing plan has not been set.")) }
        let geometryChanged = previous.map { $0.original.contentRect != frame.contentRect } ?? false
        let didReset = resetHistory != .none || geometryChanged
        if didReset {
            if resetHistory == .none {
                mailbox.recordHistoryReset(frame, reason: .contentRectChanged, generation: generation)
            }
            presentation.resetTiming(
                retainingReadinessAt: resetHistory == .reference && !geometryChanged ? started : nil)
            mailbox.mutate(generation) { $0.phaseSamples = presentation.sampleCount }
            previous = nil
            submittedPair = false
            flowInterpolator?.reset()
            hybrid?.reset()
        }
        let period = schedulingInterval?.seconds
        let anchor = presentation.anchor(
            pts: frame.presentationTime.seconds, arrival: frame.arrivalTime,
            interval: period ?? contentDuration?.seconds ?? frame.duration.seconds)
        mailbox.mutate(generation) { $0.captureJitterMilliseconds = presentation.clock.jitter * 1000 }
        if didReset, plan.multiplier > 1, let contentDuration, contentDuration.isNumeric, contentDuration.seconds > 0 {
            if interactiveSixtyGuardEnabled, dynamicCadenceCapEnabled, plan.multiplier == 2,
                settings.source != .window, ContentCadence.isSixtyHzTransport(frame.duration.seconds)
            {
                emitPassthrough(
                    frame, duration: frame.duration, anchor: anchor, plan: plan,
                    countAsPassthrough: false, activatePassthrough: false, emit: emit)
            } else {
                let duration = CMTimeMultiplyByRatio(contentDuration, multiplier: 1, divisor: Int32(plan.multiplier))
                // Show the cut/pause endpoint immediately, without interpolating across the discontinuity.
                emit(
                    packet(
                        frame.timed(at: frame.presentationTime, duration: duration), original: frame, generated: false,
                        plan: plan))
            }
        }
        if flowInterpolator != nil || hybrid != nil {
            defer { previous = (frame, frame) }
            guard let previous else {
                // Warm the first downscaled reference during the gap before frame B arrives.
                if let hybrid { _ = try? hybrid.lowFrame(frame) }
                return
            }
            let delta = CMTimeSubtract(frame.presentationTime, previous.original.presentationTime)
            guard delta.isNumeric, delta.seconds > 0, delta.seconds <= ContentCadence.maximumInterpolationGap else {
                return
            }
            if shouldPassthroughHarmonicSixty(
                delta: delta, schedulingInterval: schedulingInterval, transportDuration: frame.duration, plan: plan)
            {
                let passthroughDuration =
                    delta.seconds < frame.duration.seconds * 1.45 ? delta : (schedulingInterval ?? frame.duration)
                emitPassthrough(frame, duration: passthroughDuration, anchor: anchor, plan: plan, emit: emit)
                return
            }
            let hitchPeriod = contentHitch ? schedulingInterval : nil
            if plan.multiplier == 4 && delta.seconds < 1.0 / 31.0 && hitchPeriod == nil { return }
            let duration = CMTimeMultiplyByRatio(hitchPeriod ?? delta, multiplier: 1, divisor: Int32(plan.multiplier))
            let placements = ContentCadence.interpolationPlacements(
                previous: previous.original.presentationTime, current: frame.presentationTime,
                multiplier: plan.multiplier, hitchPeriod: hitchPeriod)
            beginPair(frame, anchor: anchor, interval: period ?? delta.seconds, plan: plan)
            let endpoint = frame.timed(at: frame.presentationTime, duration: duration)
            let probe = activePair?.probe == true
            let bypass = activePair?.evaluate == false
            if probe || bypass { emit(packet(endpoint, original: frame, generated: false, plan: plan)) }
            if bypass {
                completed = true
                return
            }
            guard !placements.isEmpty else {
                // A make-up pair shorter than one output interval has no room for a generated image.
                if !probe { emit(packet(endpoint, original: frame, generated: false, plan: plan)) }
                return
            }
            if let hybrid {
                try await hybridInterpolate(
                    hybrid, previous: previous.original, current: frame, placements: placements,
                    outputDuration: duration, multiplier: plan.multiplier, plan: plan, emit: emit)
                if !probe { emit(packet(endpoint, original: frame, generated: false, plan: plan)) }
                completed = true
                return
            }
            if let flowInterpolator, let placement = placements.first {
                let pixel = try flowInterpolator.interpolate(
                    previous: previous.original, current: frame, phase: placement.phase)
                let generated = VideoFrame(
                    pixelBuffer: pixel,
                    presentationTime: placement.time,
                    duration: duration, sequence: frame.sequence, arrivalTime: frame.arrivalTime,
                    windowStamp: frame.windowStamp)
                var midpoint = packet(generated, original: previous.original, generated: true, plan: plan)
                midpoint.opticalFlowTiming = flowInterpolator.timing
                emit(midpoint)
                if !probe { emit(packet(endpoint, original: frame, generated: false, plan: plan)) }
                completed = true
            }
            return
        }
        if plan.multiplier == 1 {
            emit(packet(frame, original: frame, generated: false, plan: plan))
            return
        }
        guard let sourcePool, let destinationPool, let processor else {
            throw PipelineError(AppText("处理器未初始化", "The frame processor has not been initialized."))
        }
        if let existing = previous {
            let delta = CMTimeSubtract(frame.presentationTime, existing.original.presentationTime)
            if delta.isNumeric, delta.seconds > 0, delta.seconds <= ContentCadence.maximumInterpolationGap,
                shouldPassthroughHarmonicSixty(
                    delta: delta, schedulingInterval: schedulingInterval, transportDuration: frame.duration, plan: plan)
            {
                let passthroughDuration =
                    delta.seconds < frame.duration.seconds * 1.45 ? delta : (schedulingInterval ?? frame.duration)
                previous = (nil, frame)
                submittedPair = false
                emitPassthrough(frame, duration: passthroughDuration, anchor: anchor, plan: plan, emit: emit)
                return
            }
        }
        let converted = try converter.convert(frame, pool: sourcePool)
        defer { previous = (converted, frame) }
        guard let previous else { return }  // Warm up: start pacing with the first genuine generated frame.
        let previousConverted = try previous.converted ?? converter.convert(previous.original, pool: sourcePool)
        let delta = CMTimeSubtract(frame.presentationTime, previousConverted.presentationTime)
        guard delta.isNumeric, delta.seconds > 0, delta.seconds <= ContentCadence.maximumInterpolationGap else {
            return
        }
        // Do not generate above 120 fps while content cadence is being established.
        // A 30/60 stream may start on its second copy; retain the next true endpoint.
        let hitchPeriod = contentHitch ? schedulingInterval : nil
        if plan.multiplier == 4 && delta.seconds < 1.0 / 31.0 && hitchPeriod == nil { return }
        let outputDuration = CMTimeMultiplyByRatio(hitchPeriod ?? delta, multiplier: 1, divisor: Int32(plan.multiplier))
        beginPair(frame, anchor: anchor, interval: period ?? delta.seconds, plan: plan)
        let endpoint = frame.timed(at: frame.presentationTime, duration: outputDuration)
        let probe = activePair?.probe == true
        let bypass = activePair?.evaluate == false
        if probe || bypass { emit(packet(endpoint, original: frame, generated: false, plan: plan)) }
        if bypass {
            // FRC's internal sequential references no longer match after a bypass.
            submittedPair = false
            completed = true
            return
        }
        let placements = ContentCadence.interpolationPlacements(
            previous: previousConverted.presentationTime, current: frame.presentationTime,
            multiplier: plan.multiplier, hitchPeriod: hitchPeriod)
        guard !placements.isEmpty else {
            // FRC's sequential references no longer match after a pair without generated images.
            submittedPair = false
            if !probe { emit(packet(endpoint, original: frame, generated: false, plan: plan)) }
            return
        }
        // FRC accepts any phase. VT low latency stays on its native phases; see `lowLatencyPhases`.
        let phases =
            plan.backend == .lowLatency
            ? ContentCadence.lowLatencyPhases(count: placements.count, multiplier: plan.multiplier)
            : placements.map(\.phase)
        let destinations = try placements.map { try destinationPool.makeVTFrame(at: $0.time) }
        let currentVT = try vtFrame(converted)
        let previousVT = try vtFrame(previousConverted)
        if plan.backend == .frameRateConversion {
            guard let readOnlyOutputPool else {
                throw PipelineError(AppText("FRC 只读输出池未建立", "The FRC read-only output pool has not been created."))
            }
            // The frame-output overload rejects ordinary FRC on this SDK (-19740).
            // Use the documented completion API per phase, retaining its reference cache.
            for (index, destination) in destinations.enumerated() {
                let mode: VTFrameRateConversionParameters.SubmissionMode =
                    index == 0
                    ? (submittedPair ? .sequential : .random) : .sequentialReferencesUnchanged
                guard
                    let parameters = VTFrameRateConversionParameters(
                        sourceFrame: previousVT, nextFrame: currentVT, opticalFlow: nil,
                        interpolationPhase: [phases[index]], submissionMode: mode, destinationFrames: [destination])
                else {
                    throw PipelineError(AppText("FRC 逐帧参数创建失败", "Could not create FRC frame parameters."))
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    processor.process(
                        parameters: parameters,
                        completionHandler: { _, error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        })
                }
                // Consume into a separately owned read-only buffer after native completion;
                // caller-owned FRC destination buffers must never be published while writable.
                let pixel = try converter.render(CIImage(cvPixelBuffer: destination.buffer), pool: readOnlyOutputPool)
                let video = VideoFrame(
                    pixelBuffer: pixel, presentationTime: destination.presentationTimeStamp,
                    duration: outputDuration, sequence: frame.sequence, arrivalTime: frame.arrivalTime,
                    windowStamp: frame.windowStamp)
                emit(packet(video, original: previous.original, generated: true, plan: plan))
            }
        } else {
            guard
                let parameters = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: currentVT, previousFrame: previousVT, interpolationPhase: phases,
                    destinationFrames: destinations)
            else {
                throw PipelineError(
                    AppText("低延迟逐帧参数创建失败", "Could not create low-latency interpolation frame parameters."))
            }
            var ready: [Int: VTFrameProcessorFrame.ReadOnlyFrame] = [:]
            var nextIndex = 0
            for try await output in processor.process(parameters: parameters) {
                guard
                    let index = destinations.firstIndex(where: {
                        CMTimeCompare($0.presentationTimeStamp, output.timeStamp) == 0
                    }),
                    ready[index] == nil, index >= nextIndex
                else {
                    throw PipelineError(
                        AppText("处理器返回重复或未知的输出时间戳", "The processor returned a duplicate or unknown output timestamp."))
                }
                ready[index] = output
                while let next = ready.removeValue(forKey: nextIndex) {
                    let video = VideoFrame(
                        pixelBuffer: next.frame, presentationTime: next.timeStamp,
                        duration: outputDuration, sequence: frame.sequence, arrivalTime: frame.arrivalTime,
                        windowStamp: frame.windowStamp)
                    emit(packet(video, original: previous.original, generated: true, plan: plan))
                    nextIndex += 1
                }
            }
            guard nextIndex == destinations.count else {
                throw PipelineError(
                    AppText("处理器未返回预期数量的生成帧", "The processor returned an unexpected number of interpolated frames."))
            }
        }
        submittedPair = true
        if !probe { emit(packet(endpoint, original: frame, generated: false, plan: plan)) }
        completed = true
    }

    private static func streamVTOutputs(
        _ session: VTFrameProcessor, parameters: VTLowLatencyFrameInterpolationParameters
    ) -> some AsyncSequence<VTFrameProcessorFrame.ReadOnlyFrame, any Error> {
        session.process(parameters: parameters)
    }

    /// Streams native low-latency VT phases (0.5 for 2×; 0.25/0.5/0.75 for 4×), sharing one media-engine
    /// motion-estimation pass across all generated phases of the pair and emitting each phase as soon as ready.
    private func hybridInterpolate(
        _ hybrid: HybridInterpolator, previous: VideoFrame, current: VideoFrame,
        placements: [(phase: Float, time: CMTime)], outputDuration: CMTime, multiplier: Int,
        plan: ProcessingPlan, emit: @escaping @Sendable (PresentationFrame) -> Void
    ) async throws {
        let started = mediaHostTime()
        let previousLow = try hybrid.lowFrame(previous)
        let currentLow = try hybrid.lowFrame(current)
        let phases = ContentCadence.lowLatencyPhases(count: placements.count, multiplier: multiplier)
        let destinations = try placements.map { try hybrid.destination(at: $0.time) }
        var previousVT: VTFrameProcessorFrame?
        var currentVT: VTFrameProcessorFrame?
        previousLow.withUnsafeBuffer {
            previousVT = VTFrameProcessorFrame(buffer: $0, presentationTimeStamp: previous.presentationTime)
        }
        currentLow.withUnsafeBuffer {
            currentVT = VTFrameProcessorFrame(buffer: $0, presentationTimeStamp: current.presentationTime)
        }
        guard let previousVT, let currentVT,
            let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: currentVT, previousFrame: previousVT, interpolationPhase: phases,
                destinationFrames: destinations)
        else { throw PipelineError(AppText("混合插帧参数创建失败", "Could not create hybrid interpolation frame parameters.")) }
        let downscaled = mediaHostTime()
        // Submit ANE VT before kicking off auxiliary 540p downscale + media-engine motion estimation.
        let vtOutputs = Self.streamVTOutputs(hybrid.session, parameters: parameters)
        let motionTask = hybrid.startMotionEstimation(previous: previous, current: current)
        var ready: [Int: (frame: VTFrameProcessorFrame.ReadOnlyFrame, vtReadyAt: Double)] = [:]
        var nextIndex = 0
        var resolvedMotion: HybridInterpolator.MotionFields?
        var awaitedMotion = false
        do {
            for try await output in vtOutputs {
                let vtReadyAt = mediaHostTime()
                guard
                    let index = destinations.firstIndex(where: {
                        CMTimeCompare($0.presentationTimeStamp, output.timeStamp) == 0
                    }),
                    ready[index] == nil, index >= nextIndex
                else {
                    throw PipelineError(
                        AppText(
                            "混合插帧返回重复或未知的输出时间戳",
                            "Hybrid interpolation returned a duplicate or unknown output timestamp."))
                }
                ready[index] = (output, vtReadyAt)
                while let entry = ready.removeValue(forKey: nextIndex) {
                    let next = entry.frame
                    if !awaitedMotion {
                        resolvedMotion = await motionTask?.value
                        awaitedMotion = true
                    }
                    let interpolated = mediaHostTime()
                    let hybridTiming = HybridReadinessTiming.compute(
                        submittedAt: downscaled,
                        vtReadyAt: entry.vtReadyAt,
                        motionStartedAt: resolvedMotion?.timing?.startedAt,
                        backwardFinishedAt: resolvedMotion?.timing?.backwardFinishedAt,
                        forwardFinishedAt: resolvedMotion?.timing?.forwardFinishedAt,
                        afterMotionWaitAt: interpolated)
                    let deferredRecipe: HybridPreviewRecipe?
                    if HybridInterpolator.deferredComposeEnabled,
                        !plan.spatial || HybridInterpolator.spatialDeferredComposeEnabled
                    {
                        deferredRecipe = hybrid.makePreviewRecipe(
                            previous: previous, current: current, previousLow: previousLow, currentLow: currentLow,
                            midpoint: next.frame, phase: phases[nextIndex], motionField: resolvedMotion)
                    } else {
                        deferredRecipe = nil
                    }
                    let pixel: CVReadOnlyPixelBuffer
                    if deferredRecipe != nil {
                        pixel =
                            HybridInterpolator.deferredFallbackMidpointEnabled
                            ? next.frame : previous.pixelBuffer
                    } else {
                        pixel = try hybrid.compose(
                            previous: previous, current: current, previousLow: previousLow, currentLow: currentLow,
                            midpoint: next.frame, phase: phases[nextIndex], motionField: resolvedMotion,
                            stabilizesSpatialDetail: HybridInterpolator.spatialMovingDetailEnabled
                                && plan.spatial && multiplier == 2 && plan.input == InputPreset.qhd1440.size)
                    }
                    let composed = mediaHostTime()
                    let generated = VideoFrame(
                        pixelBuffer: pixel, presentationTime: next.timeStamp,
                        duration: outputDuration, sequence: current.sequence, arrivalTime: current.arrivalTime,
                        windowStamp: current.windowStamp)
                    var packetFrame = packet(generated, original: previous, generated: true, plan: plan)
                    packetFrame.hybridRecipe = deferredRecipe
                    packetFrame.opticalFlowTiming = OpticalFlowTiming(
                        conversion: nil, downscale: nextIndex == 0 ? downscaled - started : 0,
                        forward: hybridTiming.vtReady, backward: hybridTiming.motionWait,
                        reconstruction: composed - interpolated, hybrid: hybridTiming)
                    emit(packetFrame)
                    nextIndex += 1
                }
            }
        } catch {
            if !awaitedMotion { _ = await motionTask?.value }
            throw error
        }
        if !awaitedMotion { _ = await motionTask?.value }
        guard nextIndex == destinations.count else {
            throw PipelineError(
                AppText("混合插帧未返回预期数量的生成帧", "Hybrid interpolation returned an unexpected number of frames."))
        }
    }

    private func shouldPassthroughHarmonicSixty(
        delta: CMTime, schedulingInterval: CMTime?, transportDuration: CMTime, plan: ProcessingPlan
    ) -> Bool {
        guard dynamicCadenceCapEnabled, plan.multiplier == 2,
            settings.source != .window,
            settings.contentMode == .automatic || interactiveSixtyGuardEnabled
        else { return false }
        let tick = transportDuration.seconds
        guard ContentCadence.isSixtyHzTransport(tick) else { return false }
        return delta.seconds < tick * 1.45 || (schedulingInterval.map { $0.seconds < tick * 1.45 } ?? false)
    }

    private func emitPassthrough(
        _ frame: VideoFrame, duration: CMTime, anchor: Double, plan: ProcessingPlan,
        countAsPassthrough: Bool = true, activatePassthrough: Bool = true,
        emit: @escaping @Sendable (PresentationFrame) -> Void
    ) {
        var video = frame.timed(at: frame.presentationTime, duration: duration)
        video.contentRect = frame.contentRect
        let ready = mediaHostTime()
        var timing = presentation.passthroughFrame(
            sequence: frame.sequence, pts: video.presentationTime.seconds, anchor: anchor,
            outputInterval: duration.seconds, bufferedFrames: settings.presentationMode.bufferedFrames,
            now: ready, activatePassthrough: activatePassthrough, compactColdDelay: interactiveSixtyGuardEnabled)
        if settings.source == .captureCard, settings.audioEnabled {
            timing = timing.allowingAudioPlayback(pts: video.presentationTime.seconds, mode: settings.presentationMode)
        }
        if countAsPassthrough { mailbox.mutate(generation) { $0.passthroughFrames += 1 } }
        emit(
            PresentationFrame(
                generation: generation, video: video, original: frame, generated: false,
                outputSize: plan.output, spatial: plan.spatial, presentationDelay: timing.pair.delay,
                displayIntervalHint: nil, readyTime: ready, timing: timing))
    }

    private func beginPair(_ frame: VideoFrame, anchor: Double, interval: Double, plan: ProcessingPlan) {
        activePair = presentation.beginPair(
            sequence: frame.sequence, pts: frame.presentationTime.seconds, anchor: anchor,
            interval: interval, multiplier: plan.multiplier,
            bufferedFrames: settings.presentationMode.bufferedFrames, now: mediaHostTime())
    }

    private func packet(_ video: VideoFrame, original: VideoFrame, generated: Bool, plan: ProcessingPlan)
        -> PresentationFrame
    {
        var video = video
        video.contentRect = original.contentRect
        let displayInterval: Double?
        if settings.source == .window {
            let fixedInterval = settings.windowSampling.duration.map { $0.seconds / Double(plan.multiplier) }
            displayInterval = fixedInterval ?? (usesStableWindowCadence ? activePair?.outputInterval : nil)
        } else {
            displayInterval = nil
        }
        let ready = mediaHostTime()
        var timing: LiveFrameTiming?
        if var pair = activePair {
            timing = pair.frame(
                pts: video.presentationTime.seconds, ready: ready,
                bufferedFrames: settings.presentationMode.bufferedFrames)
            activePair = pair
        } else {
            let interval = max(0.001, video.duration.seconds * Double(plan.multiplier))
            let pair = LivePairTiming(
                sequence: video.sequence, sourcePTS: video.presentationTime.seconds, anchor: video.arrivalTime,
                interval: interval, multiplier: plan.multiplier, probe: false, evaluate: false,
                bootstrap: false, delay: 0)
            timing = LiveFrameTiming(
                pair: pair, deadline: ready, requiredDelay: ready - video.arrivalTime,
                queuePolicy: plan.multiplier == 1 ? .latest : .ordered)
        }
        if settings.source == .captureCard, settings.audioEnabled {
            timing = timing?.allowingAudioPlayback(pts: video.presentationTime.seconds, mode: settings.presentationMode)
        }
        return PresentationFrame(
            generation: generation, video: video, original: original,
            generated: generated, outputSize: plan.output, spatial: plan.spatial,
            presentationDelay: timing.map { $0.immediate ? 0 : $0.pair.delay } ?? 0,
            displayIntervalHint: displayInterval, readyTime: ready, timing: timing)
    }
    private func vtFrame(_ frame: VideoFrame) throws -> VTFrameProcessorFrame {
        var output: VTFrameProcessorFrame?
        frame.pixelBuffer.withUnsafeBuffer {
            output = VTFrameProcessorFrame(buffer: $0, presentationTimeStamp: frame.presentationTime)
        }
        guard let output else {
            throw PipelineError(AppText("处理器无法包装输入缓冲", "The frame processor could not wrap the input buffer."))
        }
        return output
    }

    func reconfigure(to next: SessionDraft) async {
        guard next != settings else { return }
        resetting = true
        if let inFlight { _ = try? await inFlight.value }
        inFlight = nil
        let onlyPresentationOrDisplayPolicy =
            settings.contentMode == next.contentMode && settings.interpolation == next.interpolation
            && settings.backend == next.backend && settings.hybridQuality == next.hybridQuality
            && settings.upscaling == next.upscaling && settings.outputPreset == next.outputPreset
        let presentationModeChanged = settings.presentationMode != next.presentationMode
        settings = next
        usesStableWindowCadence = next.usesStableWindowCadence
        if onlyPresentationOrDisplayPolicy {
            if presentationModeChanged {
                presentation.resetTiming(retainingReadinessAt: nil)
                mailbox.mutate(generation) { $0.phaseSamples = presentation.sampleCount }
            }
            resetting = false
            return
        }
        processor?.endSession()
        processor = nil
        flowInterpolator = nil
        hybrid = nil
        previous = nil
        plan = nil
        submittedPair = false
        presentation = LivePresentationController()
        activePair = nil
        sourcePool = nil
        destinationPool = nil
        readOnlyOutputPool = nil
        resetting = false
    }

    func reset() async {
        resetting = true
        if let inFlight { _ = try? await inFlight.value }
        inFlight = nil
        processor?.endSession()
        processor = nil
        flowInterpolator = nil
        hybrid = nil
        previous = nil
        plan = nil
        presentation = LivePresentationController()
        activePair = nil
        sourcePool = nil
        destinationPool = nil
        readOnlyOutputPool = nil
        resetting = false
    }
}
