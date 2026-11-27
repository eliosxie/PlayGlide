import CoreMedia
import Dispatch
import Foundation

actor PipelineSession {
    /// Run `PipelineSession` and `FrameProcessor` actors on dedicated `.userInteractive` serial queues
    /// to prevent QoS dips between capture callbacks and presentation (`PLAYGLIDE_PIPELINE_UI_QOS=0` opts out).
    static var userInteractiveQoSEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_PIPELINE_UI_QOS"] != "0"
    }
    /// Reset deduplication and interpolation references whenever input color mode transitions between SDR
    /// and HDR10 PQ (`PLAYGLIDE_COLOR_MODE_RESET=0` restores legacy size/epoch-only input resets for A/B).
    static var colorModeResetEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_COLOR_MODE_RESET"] != "0"
    }

    static func inputResetReason(
        previousSize: VideoSize?, size: VideoSize,
        previousEpoch: UInt64?, epoch: UInt64?,
        previousHDR10: Bool?, isHDR10: Bool,
        resetsOnColorModeChange: Bool = PipelineSession.colorModeResetEnabled
    ) -> HistoryResetReason? {
        if previousSize == nil { return .startup }
        if previousSize != size { return .inputSizeChanged }
        if previousEpoch != epoch { return .windowTimestampEpoch }
        if resetsOnColorModeChange, let previousHDR10, previousHDR10 != isHDR10 {
            return .colorModeChanged
        }
        return nil
    }

    let generation: UUID
    private(set) var settings: SessionDraft
    let mailbox: FrameMailbox
    nonisolated let usesUserInteractiveQueue: Bool
    private let resetsOnColorModeChange: Bool
    private let executorQueue: DispatchSerialQueue
    private let source: any VideoCaptureSource
    private let processor: FrameProcessor
    private let windowSource: WindowCaptureSource?
    private let performanceHoldSettle: Double
    private var pendingSettings: SessionDraft?
    private var stopped = false
    /// Created by `run()` for interpolated sessions and stopped when it returns.
    private(set) var performanceHold: PerformanceHold?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    func activeQoSClass() -> qos_class_t { qos_class_self() }

    private static func usesAdaptiveHarmonicRate(for settings: SessionDraft) -> Bool {
        ContentCadence.dynamicCadenceCapEnabled && settings.source != .window
            && settings.interpolation == .double
            && (settings.contentMode == .automatic || ContentCadence.interactiveSixtyGuardEnabled)
    }

    private static func makeCadence(for settings: SessionDraft, adaptiveHarmonicRate: Bool) -> ContentCadence {
        ContentCadence(
            toleratingWindowJitter: settings.usesStableWindowCadence,
            preservingRepeatedTransport: settings.preservesRepeatedTransportCadence,
            toleratingContentHitches: settings.source != .window
                && (settings.contentMode == .automatic || adaptiveHarmonicRate),
            adaptiveHarmonicRate: adaptiveHarmonicRate)
    }

    init(
        settings: SessionDraft, format: CaptureFormatDescriptor?, generation: UUID, mailbox: FrameMailbox,
        windowSource: WindowCaptureSource? = nil, preferFlowTextureViews: Bool = true,
        performanceHoldSettle: Double = PerformanceHold.settleSeconds,
        useUserInteractiveQueue: Bool = PipelineSession.userInteractiveQoSEnabled,
        resetsOnColorModeChange: Bool = PipelineSession.colorModeResetEnabled,
        customSource: (any VideoCaptureSource)? = nil
    ) throws {
        guard settings.isAvailableInBuild else {
            throw PipelineError(AppText("当前版本不支持所选采集设置。", "The selected capture settings are unavailable."))
        }
        self.settings = settings
        self.performanceHoldSettle = performanceHoldSettle
        self.generation = generation
        self.mailbox = mailbox
        self.usesUserInteractiveQueue = useUserInteractiveQueue
        self.resetsOnColorModeChange = resetsOnColorModeChange
        self.executorQueue = DispatchSerialQueue(
            label: "PlayGlide.pipeline.session",
            qos: useUserInteractiveQueue ? .userInteractive : .unspecified)
        self.windowSource = settings.source == .window ? windowSource : nil
        if let customSource {
            source = customSource
        } else {
            switch settings.source {
            case .testPattern:
                #if PLAYGLIDE_DEVELOPMENT
                    source = SyntheticVideoSource(
                        size: settings.inputPreset.size, signal: settings.testSignal,
                        mailbox: mailbox, generation: generation)
                #else
                    throw PipelineError(AppText("请连接并选择采集卡。", "Connect and select a capture card."))
                #endif
            case .window:
                guard let windowSource, settings.windowSelectionID == windowSource.id else {
                    throw PipelineError(
                        AppText("请先选择播放视频的浏览器窗口", "Choose a window playing video to start capture."))
                }
                source = windowSource
            case .captureCard:
                guard let format, !settings.deviceID.isEmpty else {
                    throw PipelineError(
                        AppText("请选择采集卡及真实输入格式", "Select a capture card and an available input format."))
                }
                source = AVFoundationCaptureSource(
                    deviceID: settings.deviceID, format: format,
                    mailbox: mailbox, generation: generation,
                    audioEnabled: settings.audioEnabled, audioDeviceID: settings.audioDeviceID,
                    colorMode: settings.colorMode)
            }
        }
        processor = FrameProcessor(
            settings: settings, generation: generation, mailbox: mailbox,
            preferFlowTextureViews: preferFlowTextureViews,
            useUserInteractiveQueue: useUserInteractiveQueue
        )
        mailbox.configureAudioSynchronization(
            generation, enabled: settings.source == .captureCard && settings.audioEnabled)
    }

    @discardableResult
    func reconfigure(to next: SessionDraft) -> Bool {
        guard !stopped, next.isAvailableInBuild else { return false }
        let baseline = pendingSettings ?? settings
        guard baseline == next || baseline.canHotReconfigure(to: next) else { return false }
        pendingSettings = next == settings ? nil : next
        return true
    }

    func run() async throws {
        let detector = ContentDetector()
        var activeSettings = settings
        var adaptiveHarmonicRate = Self.usesAdaptiveHarmonicRate(for: activeSettings)
        var cadence = Self.makeCadence(for: activeSettings, adaptiveHarmonicRate: adaptiveHarmonicRate)
        var fastContentRun = 0
        var previousSize: VideoSize?
        var windowEpoch: UInt64?
        var previousHDR10: Bool?
        var duplicateWork = 0.0
        var lastContentArrival: Double?
        var hold = PerformanceHold.applies(to: activeSettings) ? PerformanceHold() : nil
        performanceHold = hold
        defer { performanceHold?.stop() }
        do {
            try await windowSource?.configure(
                size: activeSettings.windowPreset.size, sampling: activeSettings.windowSampling, mailbox: mailbox,
                generation: generation, resolution: activeSettings.windowResolution)
            let frames = try await source.start()
            try Task.checkCancellation()
            for try await frame in frames {
                try Task.checkCancellation()
                if stopped { break }
                var reconfigured = false
                if let next = pendingSettings {
                    pendingSettings = nil
                    if activeSettings.canHotReconfigure(to: next) {
                        let previousSettings = activeSettings
                        activeSettings = next
                        settings = next
                        adaptiveHarmonicRate = Self.usesAdaptiveHarmonicRate(for: next)
                        let processingChanged =
                            previousSettings.contentMode != next.contentMode
                            || previousSettings.interpolation != next.interpolation
                            || previousSettings.backend != next.backend
                            || previousSettings.hybridQuality != next.hybridQuality
                            || previousSettings.upscaling != next.upscaling
                            || previousSettings.outputPreset != next.outputPreset
                            || previousSettings.presentationMode != next.presentationMode
                        if processingChanged {
                            detector.reset()
                            cadence = Self.makeCadence(for: next, adaptiveHarmonicRate: adaptiveHarmonicRate)
                            fastContentRun = 0
                            duplicateWork = 0
                            mailbox.flush(
                                generation, fromSequence: frame.sequence,
                                preserveAudioAnchor: CaptureAudioMonitor.smoothSyncEnabled)
                        }
                        let wantsHold = PerformanceHold.applies(to: next)
                        if wantsHold && hold == nil {
                            hold = PerformanceHold()
                            performanceHold = hold
                        } else if !wantsHold, let existingHold = hold {
                            existingHold.stop()
                            hold = nil
                            performanceHold = nil
                        }
                        hold?.release()
                        await processor.reconfigure(to: next)
                        reconfigured = processingChanged
                    }
                }
                let size = frame.size
                let isHDR10 = frame.pixelBuffer.withUnsafeBuffer { PixelConverter.isHDR10PQ($0) }
                let inputResetReason = Self.inputResetReason(
                    previousSize: previousSize, size: size,
                    previousEpoch: windowEpoch, epoch: frame.windowStamp?.epoch,
                    previousHDR10: previousHDR10, isHDR10: isHDR10,
                    resetsOnColorModeChange: resetsOnColorModeChange)
                if inputResetReason != nil {
                    detector.reset()
                    cadence.reset()
                    duplicateWork = 0
                }
                previousSize = size
                windowEpoch = frame.windowStamp?.epoch
                previousHDR10 = isHDR10
                let start = mediaHostTime()
                let duplicate = detector.isDuplicate(frame, confirmDuplicate: activeSettings.contentMode == .automatic)
                let sceneCut = detector.sceneCut
                let detection = mediaHostTime() - start
                let decision = cadence.accept(
                    time: frame.presentationTime, duration: frame.duration,
                    sequence: frame.sequence, duplicate: duplicate, sceneCut: sceneCut,
                    arrival: frame.arrivalTime)
                mailbox.recordDetection(
                    frame, generation: generation, duration: detection, confirmation: detector.confirmationSeconds,
                    duplicate: decision == .duplicate)
                switch decision {
                case .invalid:
                    throw PipelineError(
                        AppText("输入没有有效的递增视频时间戳", "Input video timestamps are missing or out of order."))
                case .duplicate:
                    mailbox.mutate(generation) { $0.duplicates += 1 }
                    mailbox.noteContent(frame, duplicate: true, generation: generation)
                    duplicateWork += detection
                    continue
                case .keep(let reset, let interval):
                    // A transport discontinuity can retain a picture that matched the old reference.
                    if duplicate { detector.rebase(to: frame) }
                    if reset || lastContentArrival.map({ frame.arrivalTime - $0 > 0.25 }) == true {
                        duplicateWork = 0
                    }
                    lastContentArrival = frame.arrivalTime
                    // A warmup/mailbox skip can land on the second copy of a 30/60 pair.
                    // Its first new-content gap is half an interval: require sustained evidence.
                    fastContentRun = !reset && interval.seconds < 1.0 / 31.0 ? fastContentRun + 1 : 0
                    if activeSettings.interpolation == .quadruple && fastContentRun >= 8 {
                        throw PipelineError(
                            AppText(
                                "4×模式用于约30 fps内容；持续高于约30 fps的内容请选2×，第一版目标最高120 fps",
                                "Use 4× for content around 30 fps. Choose 2× for higher source frame rates. The output target is up to 120 fps."
                            ))
                    }
                    mailbox.mutate(generation) {
                        $0.content += 1
                        $0.contentInterval = interval.seconds
                        if cadence.ingressAffectedCadence { $0.ingressCadenceDisruptions += 1 }
                        if cadence.contentHitch { $0.contentHitches += 1 }
                    }
                    let resetHistory: InterpolationReset
                    if reconfigured || (reset && !cadence.retainsReadinessOnReset) {
                        resetHistory = .timing
                    } else if reset || sceneCut {
                        resetHistory = .reference
                    } else {
                        resetHistory = .none
                    }
                    if let reason = inputResetReason ?? cadence.resetReason ?? (sceneCut ? .sceneCut : nil) {
                        mailbox.recordHistoryReset(frame, reason: reason, generation: generation)
                        // A scene/cadence reset invalidates interpolation references, not already-ready earlier images.
                        if cadence.timelineDiscontinuity { mailbox.flush(generation, fromSequence: frame.sequence) }
                    }
                    mailbox.noteContent(frame, duplicate: false, generation: generation)
                    hold?.release()
                    try await processor.process(
                        frame, resetHistory: resetHistory, contentDuration: interval,
                        schedulingInterval: cadence.schedulingInterval,
                        contentWork: duplicateWork + detection, contentHitch: cadence.contentHitch,
                        phaseSlipOffset: cadence.phaseSlipOffset
                    ) {
                        [mailbox, generation] output in
                        mailbox.mutate(generation) { if output.generated { $0.generated += 1 } }
                        mailbox.enqueue(output)
                    }
                    let holdInterval = (cadence.schedulingInterval ?? interval).seconds
                    let passthroughSixty =
                        adaptiveHarmonicRate && ContentCadence.isSixtyHzTransport(frame.duration.seconds)
                        && (holdInterval < frame.duration.seconds * 1.45
                            || interval.seconds < frame.duration.seconds * 1.45)
                    if let hold, !passthroughSixty || cadence.prewarmingReturnToThirty,
                        mailbox.presentationSurfaceIsStable(
                            generation, for: performanceHoldSettle, now: mediaHostTime())
                    {
                        let targetInterval = cadence.prewarmingReturnToThirty ? interval.seconds : holdInterval
                        hold.hold(for: PerformanceHold.limit(contentInterval: targetInterval))
                    }
                }
                let elapsed = mediaHostTime() - start + duplicateWork
                duplicateWork = 0
                mailbox.mutate(generation) { $0.processingLatency.record(seconds: elapsed) }
            }
            await source.stop()
            await processor.reset()
        } catch {
            await source.stop()
            await processor.reset()
            throw error
        }
    }
    func stop() async {
        stopped = true
        await source.stop()
    }
}
