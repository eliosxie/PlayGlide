import CoreMedia
import Dispatch
import Foundation
import Synchronization

struct FrameTraceEvent: Sendable {
    static let csvHeader =
        "event,host,sequence,pts,window_sequence,window_pts,window_epoch,arrival,frame_id,generated,deadline,display_target,scheduler_time,"
        + "flow_conversion_ms,flow_downscale_ms,flow_forward_ms,flow_backward_ms,flow_reconstruction_ms,history_reset_reason,discard_reason,"
        + "hybrid_vt_ready_ms,hybrid_me_backward_ms,hybrid_me_forward_ms,hybrid_me_wait_ms"

    enum Kind: String, Sendable {
        case capture, sample, inputOverwritten, content, duplicate, reset, historyReset, ready, discarded
        case refresh, gpuBusy, selected, submitted, presented, unpresented, redrawRecovered
    }

    let kind: Kind
    let time: Double
    let sequence: Int64?
    let pts: CMTime?
    let windowStamp: WindowFrameStamp?
    let arrival: Double?
    let frameID: UUID?
    let generated: Bool?
    let deadline: Double?
    let target: Double?
    let schedulerTime: Double?
    let opticalFlowTiming: OpticalFlowTiming?
    let historyResetReason: HistoryResetReason?
    let selectionTimedOut: Bool

    init(
        _ kind: Kind, at time: Double, video: VideoFrame? = nil, frame: PresentationFrame? = nil,
        target: Double? = nil, schedulerTime: Double? = nil, historyResetReason: HistoryResetReason? = nil,
        selectionTimedOut: Bool = false
    ) {
        let video = frame?.video ?? video
        self.kind = kind
        self.time = time
        sequence = video?.sequence
        pts = video?.presentationTime
        windowStamp = video?.windowStamp
        arrival = video?.arrivalTime
        frameID = frame?.id
        generated = frame?.generated
        deadline = frame?.timing?.deadline
        self.target = target
        self.schedulerTime = schedulerTime
        opticalFlowTiming = kind == .ready ? frame?.opticalFlowTiming : nil
        self.historyResetReason = historyResetReason
        self.selectionTimedOut = selectionTimedOut
    }

    var csv: String {
        func string<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? "" }
        func milliseconds(_ seconds: Double?) -> String { string(seconds.map { $0 * 1000 }) }
        func rational(_ time: CMTime?) -> String {
            guard let time else { return "" }
            return "\(time.value)/\(time.timescale)"
        }
        return [
            kind.rawValue, String(time), string(sequence), rational(pts), string(windowStamp?.sequence),
            rational(windowStamp?.pts), string(windowStamp?.epoch), string(arrival), string(frameID), string(generated),
            string(deadline), string(target), string(schedulerTime),
            milliseconds(opticalFlowTiming?.conversion), milliseconds(opticalFlowTiming?.downscale),
            milliseconds(opticalFlowTiming?.forward), milliseconds(opticalFlowTiming?.backward),
            milliseconds(opticalFlowTiming?.reconstruction), string(historyResetReason?.rawValue),
            selectionTimedOut ? "selection_timeout" : "",
            milliseconds(opticalFlowTiming?.hybrid?.vtReady),
            milliseconds(opticalFlowTiming?.hybrid?.backwardMotion),
            milliseconds(opticalFlowTiming?.hybrid?.forwardMotion),
            milliseconds(opticalFlowTiming?.hybrid?.motionWait),
        ].joined(separator: ",")
    }
}

struct FrameTraceSnapshot: Sendable {
    let time: Double
    let interval: Double
    let expectedInterval: Double
    var score: Double
    let precedingEvents: Int
    var events: [FrameTraceEvent]

    func log(generation: UUID) -> String {
        let header =
            "PLAYGLIDE_FRAME_TRACE_SNAPSHOT \(generation) host=\(time) interval=\(interval)"
            + " expected=\(expectedInterval) preceding=\(precedingEvents) events=\(events.count)"
        let rows = events.map(\.csv).joined(separator: "\n")
        return [header, FrameTraceEvent.csvHeader, rows, "PLAYGLIDE_FRAME_TRACE_SNAPSHOT_END \(generation)"]
            .joined(separator: "\n")
    }
}

private struct FrameTrace: Sendable {
    private let capacity = 4096
    private let contextEvents = 192
    private let snapshotLimit = 4
    private var events: [FrameTraceEvent] = []
    private var next = 0
    private var abnormalIntervals = 0
    private var expectedInterval: Double?
    private var pending: FrameTraceSnapshot?
    private(set) var snapshots: [FrameTraceSnapshot] = []

    mutating func append(_ event: @autoclosure () -> FrameTraceEvent) {
        let value = event()
        if events.count < capacity {
            events.append(value)
        } else {
            events[next] = value
            next = (next + 1) % capacity
        }
        if let count = pending?.precedingEvents {
            pending?.events.append(value)
            if pending?.events.count == count + contextEvents { finishSnapshot() }
        }
    }

    mutating func observePresentation(at time: Double, interval: Double, expected: Double) {
        guard expected.isFinite, expected > 0 else {
            abnormalIntervals = 0
            expectedInterval = nil
            return
        }
        if let previous = expectedInterval, abs(expected - previous) > previous / 4 { abnormalIntervals = 0 }
        expectedInterval = expected
        let ratio = interval / expected
        guard abs(ratio - 1) > 0.25 else {
            abnormalIntervals = 0
            return
        }
        abnormalIntervals += 1
        let score = max(ratio, Double(abnormalIntervals))
        if let pendingScore = pending?.score {
            pending?.score = max(pendingScore, score)
            return
        }
        guard ratio >= 3 || abnormalIntervals == 4 else { return }
        let count = min(events.count, contextEvents)
        let preceding = (0..<count).map { events[(next + events.count - count + $0) % events.count] }
        pending = FrameTraceSnapshot(
            time: time, interval: interval, expectedInterval: expected, score: score,
            precedingEvents: count, events: preceding)
    }

    mutating func resetPacing() {
        finishSnapshot()
        abnormalIntervals = 0
        expectedInterval = nil
    }

    mutating func finishSnapshot() {
        guard let pending else { return }
        self.pending = nil
        // Rank after collecting the trailing context, so long bursts can outscore early four-interval triggers.
        if snapshots.count == snapshotLimit {
            guard let lowest = snapshots.indices.min(by: { snapshots[$0].score < snapshots[$1].score }),
                pending.score >= snapshots[lowest].score
            else { return }
            snapshots.remove(at: lowest)
        }
        snapshots.append(pending)
    }

    var chronological: [FrameTraceEvent] {
        guard next > 0 else { return events }
        return Array(events[next...] + events[..<next])
    }
}

struct PresentationRun: Sendable {
    struct Sample: Sendable {
        static let csvHeader = "frame_id,presented,pts,arrival,generated,timeline_revision,drawable"

        let id: UUID
        let presented: Double
        let pts: CMTime
        let arrival: Double
        let generated: Bool
        let timelineRevision: UInt64
        let drawable: VideoSize?

        var csv: String {
            let size = drawable.map { "\($0.width)x\($0.height)" } ?? ""
            return [
                id.uuidString, String(presented), "\(pts.value)/\(pts.timescale)", String(arrival),
                String(generated), String(timelineRevision), size,
            ].joined(separator: ",")
        }
    }

    // 120 fps for a 15-second warmup, 600-second run, and a short tail.
    static let capacity = 80_000
    private let limit: Int
    private(set) var samples: [Sample] = []
    private(set) var dropped = 0
    private(set) var finishedAt: Double?

    init(limit: Int) {
        self.limit = limit
        samples.reserveCapacity(limit)
    }

    mutating func append(_ frame: PresentationFrame, at time: Double, drawable: VideoSize?) {
        guard samples.count < limit else {
            dropped += 1
            return
        }
        samples.append(
            Sample(
                id: frame.id, presented: time, pts: frame.video.presentationTime, arrival: frame.video.arrivalTime,
                generated: frame.generated, timelineRevision: frame.timelineRevision, drawable: drawable))
    }

    mutating func finish(at time: Double) {
        if finishedAt == nil { finishedAt = time }
    }

    func log(generation: UUID, settings: SessionDraft?, statistics: PipelineStatistics) -> String? {
        guard let finishedAt else { return nil }
        var metadata = [
            "session": generation.uuidString,
            "finished_at": String(finishedAt),
            "dropped": String(dropped),
            "backend": statistics.backend.chinese, "requested_backend": settings?.backend.rawValue ?? "",
            "input": statistics.inputSize?.description ?? "",
            "output": statistics.outputSize?.description ?? "",
            "presentation_mode": settings?.presentationMode.rawValue ?? "",
        ]
        if let settings, settings.source == .testPattern {
            let signal = settings.testSignal
            let transport = signal.transportDuration
            let repeats = settings.contentMode == .automatic ? signal.repeats : 1
            let ticks = transport.value * repeats
            let scale = Int64(transport.timescale) * Int64(settings.interpolation.rawValue)
            metadata["signal"] = signal.rawValue
            metadata["target_period"] = "\(ticks)/\(scale)"
        }
        if let settings, settings.source == .window {
            metadata["window_sampling"] = settings.windowSampling.rawValue
            metadata["window_cadence"] = settings.usesStableWindowCadence ? "stable" : "strict"
        }
        guard let json = try? JSONEncoder().encode(metadata) else { return nil }
        let header = "PLAYGLIDE_PRESENTATION_RUN \(String(decoding: json, as: UTF8.self))"
        let rows = samples.map(\.csv).joined(separator: "\n")
        let footer = "PLAYGLIDE_PRESENTATION_RUN_END \(generation)"
        return [header, Sample.csvHeader, rows, footer].joined(separator: "\n")
    }
}

struct OpticalFlowLatencies: Sendable {
    var conversion = PresentationLatency()
    var downscale = PresentationLatency()
    var forward = PresentationLatency()
    var backward = PresentationLatency()
    var reconstruction = PresentationLatency()
    var hybridVTReady = PresentationLatency()
    var hybridMotionBackward = PresentationLatency()
    var hybridMotionForward = PresentationLatency()
    var hybridMotionWait = PresentationLatency()

    mutating func record(_ timing: OpticalFlowTiming) {
        if let conversionTime = timing.conversion { conversion.record(seconds: conversionTime) }
        downscale.record(seconds: timing.downscale)
        forward.record(seconds: timing.forward)
        backward.record(seconds: timing.backward)
        reconstruction.record(seconds: timing.reconstruction)
        if let hybrid = timing.hybrid {
            hybridVTReady.record(seconds: hybrid.vtReady)
            if let meBack = hybrid.backwardMotion { hybridMotionBackward.record(seconds: meBack) }
            if let meFwd = hybrid.forwardMotion { hybridMotionForward.record(seconds: meFwd) }
            hybridMotionWait.record(seconds: hybrid.motionWait)
        }
    }
}

struct PipelineStatistics: Sendable {
    var received = 0
    var content = 0
    var duplicates = 0
    var ingressDropped = 0
    var ingressCadenceDisruptions = 0
    var contentHitches = 0
    var generated = 0
    var passthroughFrames = 0
    var submitted = 0
    var presented = 0
    var presentedGenerated = 0
    var presentationDropped = 0
    var queueDepth = 0
    var lastInputTime: Double = 0
    var lastOutputTime: Double = 0
    var inputSize: VideoSize?
    var outputSize: VideoSize?
    var contentInterval: Double = 0
    var processingLatency = PresentationLatency()
    var processingSamples: [Double] { processingLatency.samples }
    var detectionLatency = PresentationLatency()
    var confirmationLatency = PresentationLatency()
    var captureIngestCopies = 0
    var captureIngestConversions = 0
    var captureIngestLatency = PresentationLatency()
    var captureSurface: AppText = "—"
    var opticalFlowLatencies = OpticalFlowLatencies()
    var backend: AppText = "—"
    var renderMilliseconds: Double = 0
    var previewFullRenders = 0
    var previewCacheHits = 0
    var deferredHybridFallbacks = 0
    var deferredHybridFallbackFailures = 0
    var displayInterval: Double = 0
    var displayLead: Double = 0
    var historyResetReasons: [HistoryResetReason: Int] = [:]
    var historyResets: Int { historyResetReasons.values.reduce(0, +) }
    var presentationDelay: Double = 0
    var outputFrameDuration: Double = 0
    var presentationLatency = PresentationLatency()
    var inputReadyLatency = PresentationLatency()
    var queueSubmitLatency = PresentationLatency()
    var submittedPresentationLatency = PresentationLatency()
    var presentedIntervals = PresentationLatency()
    var longestPresentedInterval = 0.0
    var renderEncodingLatency = PresentationLatency()
    var commandCompletionLatency = PresentationLatency()
    var displayUpdates = 0
    var gpuBusyUpdates = 0
    var noDueUpdates = 0
    var unpresented = 0  // First drawable reported no valid presentation time.
    var redrawRecovered = 0
    var targetPairDelayMilliseconds = 0.0
    var requiredPairDelayMilliseconds = 0.0
    var captureJitterMilliseconds = 0.0
    var phaseSamples = 0
    var fgHeld = false
    var fgProbePairs = 0
    var fgBypassedPairs = 0
    var fgHoldTransitions = 0
    var generatedExpired = 0
    var generatedTimedOut = 0
    var generatedPreempted = 0
    var generatedFlushed = 0
    var generatedDiscardTimings: [GeneratedDiscardTiming] = []
    var realSuperseded = 0
    var capacityDropped = 0
    var generatedDeadlineMisses = 0
    var realDeadlineMisses = 0
    var generatedReadyLateness = PresentationLatency()
    var realReadyLateness = PresentationLatency()
    var deadlineSubmitLateness = PresentationLatency()
    var windowGeometry: AppText = "—"
    var nativeWindowSize: VideoSize?
    var requestedWindowSize: VideoSize?
    var windowResolutionUpdates = 0
    var windowResolutionError: AppText?
    var windowPreparationLatency = PresentationLatency()
    var windowSampleLatency = PresentationLatency()
    var windowSampledSurfaces = 0
    var error: AppText?
    var signalWarning: AppText?
    var formatRehandshakes = 0
    var hdrFramesSkipped = 0
    var detectedHDR10 = false
    var captureRecoveries = 0
    var audioStatus = AppText("未启用", "Disabled")
    var audioFormat: AppText = "—"
    var audioReceived = 0
    var audioEnqueued = 0
    var audioDropped = 0
    var audioResyncs = 0
    var audioAlignmentWaitMilliseconds: Double?
    var audioAlignmentFailures = 0
    var audioRate: Float = 0
    var audioSyncErrorMilliseconds: Double?
    var audioMuted = false
    var audioVolume: Float = 1
    var audioOffsetMilliseconds: Double = 0
    var p50: Double { processingLatency.p50 ?? 0 }
    var p95: Double { processingLatency.p95 ?? 0 }
    var p99: Double { processingLatency.p99 ?? 0 }

    mutating func recordGeneratedDiscard(_ frame: PresentationFrame, at time: Double) {
        guard frame.generated, let timing = frame.timing else { return }
        generatedDiscardTimings.append(
            GeneratedDiscardTiming(
                sequence: frame.video.sequence,
                discardedAt: time,
                readyLateMilliseconds: max(0, frame.readyTime - timing.deadline) * 1000,
                queuedMilliseconds: max(0, time - frame.readyTime) * 1000,
                discardLateMilliseconds: max(0, time - timing.deadline) * 1000))
        if generatedDiscardTimings.count > 64 { generatedDiscardTimings.removeFirst() }
    }
}

struct PreviewPollState {
    let starting: Bool
    let active: Bool
    let stopping: Bool
    let waitingForInput: Bool
    let inputSize: VideoSize?
    let outputFrameDuration: Double
    let signalWarning: AppText?
    let detectedHDR10: Bool

    init(
        starting: Bool, active: Bool, stopping: Bool, waitingForInput: Bool,
        inputSize: VideoSize?, outputFrameDuration: Double, signalWarning: AppText? = nil,
        detectedHDR10: Bool = false
    ) {
        self.starting = starting
        self.active = active
        self.stopping = stopping
        self.waitingForInput = waitingForInput
        self.inputSize = inputSize
        self.outputFrameDuration = outputFrameDuration
        self.signalWarning = signalWarning
        self.detectedHDR10 = detectedHDR10
    }

    func isWaiting(lastInputTime: Double, now: Double) -> Bool {
        active && lastInputTime > 0 && now - lastInputTime > 2
    }
}

final class FrameMailbox: Sendable {
    static var fastPathEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_MAILBOX_FAST_PATH"] != "0"
    }
    /// Wake late-selection waits as soon as a half-slot eligible or future-refresh frame arrives
    /// (`PLAYGLIDE_WAKE_HALF_SLOT=1` opts in pending real-capture ABBA validation).
    static var wakeHalfSlotEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_WAKE_HALF_SLOT"] == "1"
    }

    struct PreviewSubmission {
        let attempt: FramePresentationStatus.Attempt?
    }

    private struct PreviewWait: Sendable {
        let time: Double
        let refreshInterval: Double?
        let semaphore = DispatchSemaphore(value: 0)
    }

    private struct State: Sendable {
        var generation = UUID()
        var frames: [UUID: PresentationFrame] = [:]
        var timeline = FrameTimeline()
        var current: PresentationFrame?
        var statistics = PipelineStatistics()
        var original = false
        var accepting = false
        var hasInterpolated = false
        var inFlight = 0
        var gpuBusySince: Double?
        var timelineCapacity = 8
        var timelineRevision: UInt64 = 0
        var audioAnchor: (value: AudioVideoAnchor, sequence: Int64)?
        var previousCapturePTS: CMTime?
        var minimumSourceSequence: Int64 = 0
        var duplicateInputTime: Double = 0
        var latestContentSequence: Int64?
        var lastPresentationTime: Double?
        var needsScanoutDrain = false
        var surface = PresentationSurfaceStability()
        var trace: FrameTrace?
        var presentationRun: PresentationRun?
        var previewWait: PreviewWait?

        mutating func wakePreview() {
            guard let wait = previewWait else { return }
            previewWait = nil
            wait.semaphore.signal()
        }

        mutating func invalidateTimeline(fromSequence: Int64) {
            timelineRevision += 1
            audioAnchor = nil
            minimumSourceSequence = fromSequence
            duplicateInputTime = 0
            latestContentSequence = nil
            lastPresentationTime = nil
            needsScanoutDrain = false
            trace?.resetPacing()
            statistics.presentationDropped += frames.count
            frames.removeAll()
            timeline = FrameTimeline(capacity: timelineCapacity)
            current = nil
            statistics.queueDepth = 0
        }

        func isCurrentPreviewFrame(_ frame: PresentationFrame) -> Bool {
            accepting && generation == frame.generation && current?.id == frame.id
                && timelineRevision == frame.timelineRevision
        }

        mutating func recordSubmission(_ frame: PresentationFrame, at time: Double) -> FramePresentationStatus.Attempt?
        {
            guard let attempt = frame.presentation.submit() else { return nil }
            guard attempt == .first else { return attempt }
            statistics.submitted += 1
            trace?.append(FrameTraceEvent(.submitted, at: time, frame: frame))
            if let timing = frame.timing {
                statistics.deadlineSubmitLateness.record(seconds: max(0, time - timing.deadline))
            }
            return attempt
        }
    }
    private let state = Mutex(State())
    private let previewSize = Mutex<VideoSize?>(nil)
    private let audioControlState = Mutex(AudioPlaybackControls())
    private let traceEnabled: Bool
    private let presentationRunLimit: Int?
    private let wakeHalfSlot: Bool

    init(
        traceEnabled: Bool = BuildFeatures.developmentTools
            && ProcessInfo.processInfo.environment["PLAYGLIDE_FRAME_TRACE"] == "1",
        presentationRunLimit: Int? = BuildFeatures.developmentTools
            && ProcessInfo.processInfo.environment["PLAYGLIDE_PRESENTATION_RUN"] == "1"
            ? PresentationRun.capacity : nil,
        wakeHalfSlot: Bool = FrameMailbox.wakeHalfSlotEnabled
    ) {
        self.traceEnabled = traceEnabled
        self.presentationRunLimit = presentationRunLimit
        self.wakeHalfSlot = wakeHalfSlot
    }

    func frameTrace(_ generation: UUID) -> [FrameTraceEvent] {
        state.withLock { $0.generation == generation ? $0.trace?.chronological ?? [] : [] }
    }

    func frameTraceSnapshots(_ generation: UUID) -> [FrameTraceSnapshot] {
        state.withLock { $0.generation == generation ? $0.trace?.snapshots ?? [] : [] }
    }

    func takeFinishedPresentationRun(_ generation: UUID) -> PresentationRun? {
        state.withLock {
            guard $0.generation == generation, !$0.accepting else { return nil }
            let run = $0.presentationRun
            $0.presentationRun = nil
            return run
        }
    }

    var previewPixelSize: VideoSize? { previewSize.withLock { $0 } }
    func setPreviewPixelSize(_ size: VideoSize) {
        guard size.width > 0, size.height > 0 else { return }
        previewSize.withLock { $0 = size }
    }

    func setAudioControls(_ controls: AudioPlaybackControls) {
        audioControlState.withLock {
            $0 = AudioPlaybackControls(
                volume: controls.clampedVolume,
                muted: controls.muted,
                offsetMilliseconds: controls.clampedOffsetMilliseconds,
                outputDeviceID: controls.normalizedOutputDeviceID)
        }
    }

    func audioControls() -> AudioPlaybackControls {
        audioControlState.withLock { $0 }
    }

    var isActive: Bool { state.withLock { $0.accepting } }

    /// Whether the preview has presented to one drawable size without interruption for `seconds`.
    func presentationSurfaceIsStable(_ generation: UUID, for seconds: Double, now: Double) -> Bool {
        state.withLock { $0.accepting && $0.generation == generation && $0.surface.isStable(for: seconds, now: now) }
    }

    func configureAudioSynchronization(_ generation: UUID, enabled: Bool) {
        state.withLock {
            guard $0.generation == generation, $0.frames.isEmpty else { return }
            // Steady audio playback at the 120 fps ceiling needs more than eight ready images.
            $0.timelineCapacity = enabled ? 16 : 8
            $0.timeline = FrameTimeline(capacity: $0.timelineCapacity)
        }
    }

    func begin(_ generation: UUID) {
        state.withLock {
            $0.wakePreview()
            let inFlight = $0.inFlight
            $0 = State(generation: generation, accepting: true, inFlight: inFlight)
            if traceEnabled { $0.trace = FrameTrace() }
            if let presentationRunLimit { $0.presentationRun = PresentationRun(limit: presentationRunLimit) }
        }
    }
    func finish(_ generation: UUID) {
        state.withLock {
            guard $0.generation == generation else { return }
            $0.accepting = false
            $0.wakePreview()
            $0.trace?.finishSnapshot()
            $0.presentationRun?.finish(at: mediaHostTime())
            $0.frames.removeAll()
            $0.timeline = FrameTimeline(capacity: $0.timelineCapacity)
            $0.current = nil
            $0.statistics.queueDepth = 0
        }
    }
    func capture(_ frame: VideoFrame, generation: UUID, tracksTimeline: Bool = true) {
        state.withLock {
            guard $0.accepting, $0.generation == generation else { return }
            if tracksTimeline, let previous = $0.previousCapturePTS,
                CMTimeCompare(frame.presentationTime, previous) < 0
                    || CMTimeSubtract(frame.presentationTime, previous).seconds > 0.5
            {
                $0.invalidateTimeline(fromSequence: frame.sequence)
            }
            $0.previousCapturePTS = frame.presentationTime
            $0.statistics.received += 1
            $0.statistics.lastInputTime = frame.arrivalTime
            $0.statistics.inputSize = frame.size
            if frame.windowStamp != nil {
                $0.statistics.windowPreparationLatency.record(
                    capturedAt: frame.arrivalTime, presentedAt: mediaHostTime())
            }
            $0.trace?.append(FrameTraceEvent(.capture, at: mediaHostTime(), video: frame))
        }
    }
    /// Callback entry to an owned read-only image, and the borrowed surface's color contract when it changes.
    func recordCaptureIngest(
        copied: Bool, seconds: Double, surface: AppText?, rehandshaked: Bool = false,
        detectedHDR10: Bool = false, generation: UUID
    ) {
        state.withLock {
            guard $0.accepting, $0.generation == generation else { return }
            if copied { $0.statistics.captureIngestCopies += 1 } else { $0.statistics.captureIngestConversions += 1 }
            $0.statistics.captureIngestLatency.record(seconds: seconds)
            if let surface { $0.statistics.captureSurface = surface }
            if rehandshaked { $0.statistics.formatRehandshakes += 1 }
            $0.statistics.detectedHDR10 = detectedHDR10
            if $0.statistics.signalWarning != nil { $0.statistics.signalWarning = nil }
        }
    }
    func recordWindowSample(_ frame: VideoFrame, generation: UUID, newSurface: Bool) {
        state.withLock {
            guard $0.accepting, $0.generation == generation else { return }
            let now = mediaHostTime()
            if newSurface {
                $0.statistics.windowSampledSurfaces += 1
                $0.statistics.windowSampleLatency.record(capturedAt: frame.arrivalTime, presentedAt: now)
            }
            $0.trace?.append(FrameTraceEvent(.sample, at: now, video: frame))
        }
    }
    func recordInputOverwrite(_ frame: VideoFrame, generation: UUID) {
        state.withLock {
            guard $0.accepting, $0.generation == generation else { return }
            $0.statistics.ingressDropped += 1
            $0.trace?.append(FrameTraceEvent(.inputOverwritten, at: mediaHostTime(), video: frame))
        }
    }
    func recordDetection(
        _ frame: VideoFrame, generation: UUID, duration: Double, confirmation: Double?, duplicate: Bool
    ) {
        state.withLock {
            guard $0.accepting, $0.generation == generation else { return }
            $0.statistics.detectionLatency.record(seconds: duration)
            if let confirmation { $0.statistics.confirmationLatency.record(seconds: confirmation) }
            $0.trace?.append(FrameTraceEvent(duplicate ? .duplicate : .content, at: mediaHostTime(), video: frame))
        }
    }
    func recordHistoryReset(_ frame: VideoFrame, reason: HistoryResetReason, generation: UUID) {
        state.withLock {
            guard $0.accepting, $0.generation == generation else { return }
            $0.statistics.historyResetReasons[reason, default: 0] += 1
            $0.trace?.append(
                FrameTraceEvent(.historyReset, at: mediaHostTime(), video: frame, historyResetReason: reason))
        }
    }
    func noteContent(_ frame: VideoFrame, duplicate: Bool, generation: UUID) {
        state.withLock {
            guard $0.accepting, $0.generation == generation, frame.sequence >= $0.minimumSourceSequence else { return }
            $0.duplicateInputTime = duplicate ? frame.arrivalTime : 0
            if !duplicate { $0.latestContentSequence = frame.sequence }
        }
    }
    func audioReference(_ generation: UUID, now: Double) -> AudioVideoAnchor? {
        state.withLock {
            guard $0.accepting, $0.generation == generation, let anchor = $0.audioAnchor,
                now.isFinite, anchor.value.hostTime - now <= AudioSyncController.futureAnchorTolerance,
                now - $0.statistics.lastInputTime <= 0.25,
                now - anchor.value.hostTime <= 0.25
                    || (($0.latestContentSequence ?? anchor.sequence) <= anchor.sequence
                        && $0.duplicateInputTime > 0 && now - $0.duplicateInputTime <= 0.25)
            else { return nil }
            return anchor.value
        }
    }
    func flush(_ generation: UUID, fromSequence: Int64 = 0) {
        state.withLock {
            guard $0.generation == generation else { return }
            $0.invalidateTimeline(fromSequence: max($0.minimumSourceSequence, fromSequence))
            $0.trace?.append(FrameTraceEvent(.reset, at: mediaHostTime()))
        }
    }
    func compareOriginal(_ value: Bool) { state.withLock { $0.original = value } }
    var showsOriginal: Bool { state.withLock { $0.original } }
    func mutate(_ generation: UUID, _ body: (inout PipelineStatistics) -> Void) {
        state.withLock { if $0.generation == generation { body(&$0.statistics) } }
    }
    func snapshot() -> PipelineStatistics { state.withLock { $0.statistics } }
    func previewSnapshot(_ generation: UUID, previous: PreviewPollState, now: Double) -> PipelineStatistics? {
        state.withLock {
            guard $0.generation == generation else { return nil }
            let isWaiting = previous.isWaiting(lastInputTime: $0.statistics.lastInputTime, now: now)
            guard
                (previous.starting && $0.statistics.lastOutputTime > 0)
                    || isWaiting != previous.waitingForInput
                    || $0.statistics.inputSize != previous.inputSize
                    || $0.statistics.outputFrameDuration != previous.outputFrameDuration
                    || $0.statistics.signalWarning != previous.signalWarning
                    || $0.statistics.detectedHDR10 != previous.detectedHDR10
                    || (!previous.stopping && $0.statistics.error != nil)
            else { return nil }
            return $0.statistics
        }
    }
    func ingressDropCount(_ generation: UUID) -> Int {
        state.withLock { $0.generation == generation ? $0.statistics.ingressDropped : 0 }
    }
    func enqueue(_ frame: PresentationFrame) {
        state.withLock {
            guard $0.generation == frame.generation, $0.accepting else { return }
            guard frame.video.sequence >= $0.minimumSourceSequence else { return }
            if frame.generated && !$0.hasInterpolated {
                // Record the first genuine interpolation boundary. Only flush legacy untimed warmup
                // frames; absolute-deadline originals scheduled before this midpoint stay intact.
                $0.hasInterpolated = true
                $0.trace?.append(FrameTraceEvent(.reset, at: mediaHostTime(), frame: frame))
                if !Self.fastPathEnabled || frame.timing == nil {
                    $0.statistics.presentationDropped += $0.frames.count
                    $0.frames.removeAll()
                    $0.timeline = FrameTimeline(capacity: $0.timelineCapacity)
                } else if let timing = frame.timing {
                    // Drop stale warmup originals whose deadline already lapsed before interpolation started,
                    // while preserving fresh timed originals scheduled right ahead of this first midpoint.
                    let stale = $0.timeline.pruneStale(before: frame.readyTime - timing.pair.outputInterval)
                    for id in stale { $0.frames.removeValue(forKey: id) }
                    $0.statistics.presentationDropped += stale.count
                }
            }
            let removed: [UUID]
            var scheduled = frame
            scheduled.timelineRevision = $0.timelineRevision
            if let timing = frame.timing {
                let pair = timing.pair
                guard timing.deadline.isFinite, pair.outputInterval.isFinite, pair.outputInterval > 0 else {
                    $0.statistics.presentationDropped += 1
                    return
                }
                removed = $0.timeline.enqueue(
                    id: frame.id, deadline: timing.deadline, generated: frame.generated,
                    outputInterval: pair.outputInterval, queuePolicy: timing.queuePolicy, ready: frame.readyTime)
                let deadline = $0.timeline.items.last?.time ?? timing.deadline
                scheduled.timing = LiveFrameTiming(
                    pair: pair, deadline: deadline, requiredDelay: timing.requiredDelay, queuePolicy: timing.queuePolicy
                )
                $0.statistics.targetPairDelayMilliseconds = timing.immediate ? 0 : pair.delay * 1000
                $0.statistics.requiredPairDelayMilliseconds = timing.requiredDelay * 1000
                if pair.evaluate && !pair.probe {
                    let late = max(0, frame.readyTime - deadline)
                    if frame.generated {
                        $0.statistics.generatedDeadlineMisses += late > 0 ? 1 : 0
                        $0.statistics.generatedReadyLateness.record(seconds: late)
                    } else {
                        $0.statistics.realDeadlineMisses += late > 0 ? 1 : 0
                        $0.statistics.realReadyLateness.record(seconds: late)
                    }
                }
            } else {
                removed = $0.timeline.enqueue(
                    id: frame.id, pts: frame.video.presentationTime.seconds,
                    now: mediaHostTime(), delay: frame.presentationDelay)
            }
            for id in removed {
                if let removed = $0.frames.removeValue(forKey: id) {
                    $0.statistics.recordGeneratedDiscard(removed, at: mediaHostTime())
                    $0.trace?.append(FrameTraceEvent(.discarded, at: mediaHostTime(), frame: removed))
                }
            }
            $0.statistics.presentationDropped += removed.count
            $0.frames[frame.id] = scheduled
            if let timing = scheduled.opticalFlowTiming { $0.statistics.opticalFlowLatencies.record(timing) }
            $0.trace?.append(FrameTraceEvent(.ready, at: frame.readyTime, frame: scheduled))
            $0.statistics.queueDepth = $0.frames.count
            $0.statistics.lastOutputTime = mediaHostTime()
            $0.statistics.outputSize = frame.outputSize
            $0.statistics.presentationDelay = frame.presentationDelay
            $0.statistics.outputFrameDuration = frame.displayIntervalHint ?? frame.video.duration.seconds
            $0.statistics.capacityDropped += $0.timeline.capacityDropped
            $0.statistics.generatedExpired += $0.timeline.expiredGenerated
            $0.statistics.generatedTimedOut += $0.timeline.generatedTimedOut
            $0.statistics.generatedPreempted += $0.timeline.generatedPreempted
            $0.statistics.generatedFlushed += $0.timeline.generatedFlushed
            $0.statistics.realSuperseded += $0.timeline.supersededReal
            $0.timeline.clearDropCounters()
            if let previewWait = $0.previewWait {
                let shouldWake =
                    wakeHalfSlot
                    ? !$0.timeline.shouldWaitForReadyFrame(
                        at: previewWait.time, refreshInterval: previewWait.refreshInterval, wakeHalfSlot: true)
                    : $0.timeline.hasStableDueFrame(at: previewWait.time)
                if shouldWake {
                    $0.wakePreview()
                }
            }
        }
    }

    /// Both checking the queue and registering the wait use the enqueue lock, so readiness cannot be missed.
    func waitForReadyPreviewFrame(
        at time: Double, refreshInterval: Double? = nil, until deadline: DispatchTime
    ) -> UUID? {
        let (generation, wait) = state.withLock { (state) -> (UUID?, PreviewWait?) in
            guard state.accepting else { return (nil, nil) }
            if !state.timeline.shouldWaitForReadyFrame(
                at: time, refreshInterval: refreshInterval, wakeHalfSlot: wakeHalfSlot)
                || state.previewWait != nil || DispatchTime.now() >= deadline
            {
                return (state.generation, nil)
            }
            let wait = PreviewWait(time: time, refreshInterval: refreshInterval)
            state.previewWait = wait
            return (state.generation, wait)
        }
        if let wait, wait.semaphore.wait(timeout: deadline) == .timedOut {
            state.withLock {
                if $0.previewWait?.semaphore === wait.semaphore { $0.previewWait = nil }
            }
        }
        return generation
    }

    func next(
        now: Double, refreshInterval: Double? = nil, observedAt: Double? = nil, target: Double? = nil,
        holdingCurrent: Bool = false, allowRedundantRedraw: Bool = true, generation: UUID? = nil
    ) -> PresentationFrame? {
        state.withLock {
            guard $0.accepting, generation == nil || $0.generation == generation else { return nil }
            let observed = observedAt ?? now
            if let target {
                $0.trace?.append(FrameTraceEvent(.refresh, at: observed, target: target, schedulerTime: now))
            }
            let current = holdingCurrent ? $0.current : nil
            let traceTimeouts = $0.trace != nil
            let result = $0.timeline.take(now: now, refreshInterval: refreshInterval, traceTimeouts: traceTimeouts) {
                guard let current, let timing = current.timing, let refreshInterval,
                    now - timing.deadline <= timing.pair.outputInterval + refreshInterval
                else { return false }
                return current.presentation.canPrioritizeRedraw
            }
            $0.statistics.generatedExpired += $0.timeline.expiredGenerated
            $0.statistics.generatedTimedOut += $0.timeline.generatedTimedOut
            $0.statistics.generatedPreempted += $0.timeline.generatedPreempted
            $0.statistics.generatedFlushed += $0.timeline.generatedFlushed
            $0.statistics.realSuperseded += $0.timeline.supersededReal
            $0.timeline.clearDropCounters()
            for id in result.skipped {
                if let removed = $0.frames.removeValue(forKey: id) {
                    $0.statistics.recordGeneratedDiscard(removed, at: observed)
                    $0.trace?.append(
                        FrameTraceEvent(
                            .discarded, at: observed, frame: removed, target: target, schedulerTime: now,
                            selectionTimedOut: result.timedOut.contains(id)))
                }
            }
            $0.statistics.presentationDropped += result.skipped.count
            $0.statistics.queueDepth = $0.frames.count
            if let id = result.selected, let frame = $0.frames.removeValue(forKey: id) {
                $0.trace?.append(
                    FrameTraceEvent(.selected, at: observed, frame: frame, target: target, schedulerTime: now))
                $0.current = frame
                $0.statistics.queueDepth = $0.frames.count
                return frame
            }
            $0.statistics.noDueUpdates += 1
            if holdingCurrent, let current = $0.current {
                if !allowRedundantRedraw && !current.presentation.canPrioritizeRedraw {
                    return nil
                }
                if $0.needsScanoutDrain && !current.presentation.canPrioritizeRedraw {
                    // Drain a 1-refresh scanout FIFO backlog (+8.33 ms R9 offset) by skipping one redundant redraw.
                    $0.needsScanoutDrain = false
                    return nil
                }
                return current
            }
            return nil
        }
    }
    func isCurrentPreviewFrame(_ frame: PresentationFrame) -> Bool {
        state.withLock { $0.isCurrentPreviewFrame(frame) }
    }
    @discardableResult
    func recordSubmission(_ frame: PresentationFrame, at time: Double) -> FramePresentationStatus.Attempt? {
        state.withLock {
            guard $0.accepting, $0.generation == frame.generation else { return nil }
            return $0.recordSubmission(frame, at: time)
        }
    }
    func preparePreviewSubmission(
        _ frame: PresentationFrame, at time: Double, encodingStarted: Double, reused: Bool
    ) -> PreviewSubmission? {
        state.withLock {
            // A reset may invalidate the image while the renderer encodes its commands.
            guard $0.isCurrentPreviewFrame(frame) else { return nil }
            $0.statistics.renderEncodingLatency.record(capturedAt: encodingStarted, presentedAt: time)
            if reused { $0.statistics.previewCacheHits += 1 } else { $0.statistics.previewFullRenders += 1 }
            return PreviewSubmission(attempt: $0.recordSubmission(frame, at: time))
        }
    }
    func acquireGPU(at time: Double, target: Double, generation: UUID? = nil) -> Bool {
        state.withLock {
            guard $0.accepting, generation == nil || $0.generation == generation else { return false }
            $0.statistics.displayUpdates += 1
            guard $0.inFlight < 2 else {
                $0.statistics.gpuBusyUpdates += 1
                $0.trace?.append(FrameTraceEvent(.gpuBusy, at: time, target: target))
                if let since = $0.gpuBusySince {
                    if time - since >= 1, $0.statistics.error == nil {
                        $0.statistics.error = AppText("GPU 预览命令长时间未完成", "The GPU preview command has stalled.")
                    }
                } else {
                    $0.gpuBusySince = time
                }
                return false
            }
            $0.inFlight += 1
            return true
        }
    }
    func recordPresentation(
        _ frame: PresentationFrame, at time: Double, submittedAt: Double? = nil,
        attempt: FramePresentationStatus.Attempt = .first, drawable: VideoSize? = nil,
        target: Double? = nil
    ) {
        state.withLock {
            guard $0.accepting, $0.generation == frame.generation else { return }
            let observation = frame.presentation.observe(at: time, attempt: attempt)
            if observation.firstFailed {
                $0.statistics.unpresented += 1
                $0.trace?.append(FrameTraceEvent(.unpresented, at: mediaHostTime(), frame: frame))
            }
            if let recoveredAt = observation.recoveredAt {
                $0.statistics.redrawRecovered += 1
                $0.trace?.append(FrameTraceEvent(.redrawRecovered, at: recoveredAt, frame: frame))
            }
            guard observation.firstValid else { return }
            if let target, target.isFinite, target > 0 {
                let offset = time - target
                let refresh = $0.statistics.displayInterval > 0 ? $0.statistics.displayInterval : (1.0 / 120)
                if offset >= refresh * 0.72 && offset <= max(0.025, refresh * 3) {
                    $0.needsScanoutDrain = true
                } else if abs(offset) < refresh * 0.36 {
                    $0.needsScanoutDrain = false
                }
            }
            $0.surface.observe(at: time, drawable: drawable)
            $0.trace?.append(FrameTraceEvent(.presented, at: time, frame: frame))
            $0.presentationRun?.append(frame, at: time, drawable: drawable)
            $0.statistics.presented += 1
            if frame.timelineRevision == $0.timelineRevision {
                if let previous = $0.lastPresentationTime, time > previous {
                    let interval = time - previous
                    $0.statistics.presentedIntervals.record(seconds: interval)
                    $0.statistics.longestPresentedInterval = max($0.statistics.longestPresentedInterval, interval)
                    $0.trace?.observePresentation(
                        at: time, interval: interval,
                        expected: frame.displayIntervalHint ?? frame.video.duration.seconds)
                }
                $0.lastPresentationTime = max(time, $0.lastPresentationTime ?? time)
            }
            if frame.generated {
                $0.statistics.presentedGenerated += 1
            } else {
                if frame.timelineRevision == $0.timelineRevision,
                    frame.video.sequence >= $0.minimumSourceSequence, frame.video.presentationTime.isNumeric,
                    $0.audioAnchor.map({
                        time > $0.value.hostTime && CMTimeCompare(frame.video.presentationTime, $0.value.time) > 0
                    }) ?? true
                {
                    $0.audioAnchor = (
                        AudioVideoAnchor(
                            time: frame.video.presentationTime, hostTime: time, revision: $0.timelineRevision),
                        frame.video.sequence
                    )
                }
                // Original content frames have an unambiguous callback entry time.
                // A generated midpoint depends on two inputs and is deliberately excluded.
                $0.statistics.presentationLatency.record(capturedAt: frame.video.arrivalTime, presentedAt: time)
                if let submittedAt, frame.readyTime >= frame.video.arrivalTime,
                    submittedAt >= frame.readyTime, time >= submittedAt
                {
                    $0.statistics.inputReadyLatency.record(
                        capturedAt: frame.video.arrivalTime, presentedAt: frame.readyTime)
                    $0.statistics.queueSubmitLatency.record(capturedAt: frame.readyTime, presentedAt: submittedAt)
                    $0.statistics.submittedPresentationLatency.record(capturedAt: submittedAt, presentedAt: time)
                }
            }
        }
    }
    func releaseGPU() {
        state.withLock {
            $0.inFlight = max(0, $0.inFlight - 1)
            $0.gpuBusySince = nil
        }
    }
}
