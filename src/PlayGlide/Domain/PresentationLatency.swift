import CoreMedia
import Foundation

/// An original video's source PTS paired with its actual display time, never its processing deadline.
struct AudioVideoAnchor: Sendable {
    let time: CMTime
    let hostTime: Double
    let revision: UInt64

    func mediaTime(at host: Double) -> CMTime {
        CMTimeAdd(time, CMTime(seconds: host - hostTime, preferredTimescale: 1_000_000_000))
    }
}

/// Capture timestamps remain rational. Payloads are owned by the caller's actor/lock.
struct AudioBufferQueue<Payload> {
    struct Entry {
        let sequence: Int64
        let time: CMTime
        let end: CMTime
        let payload: Payload
    }
    private(set) var entries: [Entry] = []
    private var sequence: Int64 = 0
    private var previousEnd: CMTime?
    let capacity: Int
    let maximumDuration: Double

    init(capacity: Int = 64, maximumDuration: Double = 0.35) {
        self.capacity = max(1, capacity)
        self.maximumDuration = maximumDuration
    }

    /// A discontinuity invalidates already-scheduled audio as well as the local queue.
    mutating func append(time: CMTime, duration: CMTime, payload: Payload)
        -> (accepted: Bool, reset: Bool, dropped: Int)
    {
        guard time.isNumeric, duration.isNumeric, time.seconds >= 0,
            duration.seconds > 0, duration.seconds <= 0.1
        else { return (false, false, 1) }
        let end = CMTimeAdd(time, duration)
        let gap = previousEnd.map { CMTimeSubtract(time, $0).seconds } ?? 0
        let reset = gap < -0.000_001 || gap > 0.25
        var dropped = 0
        if reset {
            dropped = entries.count
            entries.removeAll(keepingCapacity: true)
        }
        entries.append(Entry(sequence: sequence, time: time, end: end, payload: payload))
        sequence += 1
        previousEnd = end
        while entries.count > capacity
            || (entries.count > 1 && CMTimeSubtract(end, entries[0].time).seconds > maximumDuration)
        {
            entries.removeFirst()
            dropped += 1
        }
        return (true, reset, dropped)
    }

    func contains(_ time: CMTime) -> Bool {
        entries.contains { CMTimeCompare($0.time, time) <= 0 && CMTimeCompare(time, $0.end) < 0 }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        previousEnd = nil
    }
}

/// Small errors slew the audio clock; discontinuities seek and discard pending renderer audio.
/// The caller supplies the renderer time, so this policy is testable without audio hardware.
struct AudioSyncController: Sendable {
    enum Action: Equatable {
        case none, pause
        case align(time: CMTime, hostTime: Double)
        case rate(Float)
    }
    private(set) var revision: UInt64?
    private(set) var errorSeconds: Double?
    private(set) var filteredErrorSeconds: Double?
    private(set) var rate: Float = 0
    private var lastAdjustment = -Double.infinity
    private var lastSampleHost = -Double.infinity
    private var appliedOffsetSeconds = 0.0
    static let startLead = 0.02
    /// `MTLDrawable.presentedTime` can report the imminent display scanout slightly ahead of `now`.
    static let futureAnchorTolerance = 0.05
    /// Low-pass time constant suppressing scanout quantization (±8.33 ms) and transient video reset dips.
    static let errorSmoothingSeconds = 1.5
    static let minManualOffsetSeconds = -0.1
    static let maxManualOffsetSeconds = 0.2

    mutating func update(
        anchor: AudioVideoAnchor?, playbackTime: CMTime, now: Double, offsetSeconds: Double = 0,
        canAlign: @autoclosure () -> Bool = true
    ) -> Action {
        guard let anchor, now.isFinite, anchor.time.isNumeric, anchor.hostTime.isFinite,
            anchor.hostTime - now <= Self.futureAnchorTolerance, anchor.time.seconds >= 0
        else {
            let wasRunning = revision != nil
            self = AudioSyncController()
            return wasRunning ? .pause : .none
        }
        let clampedOffset =
            offsetSeconds.isFinite
            ? min(Self.maxManualOffsetSeconds, max(Self.minManualOffsetSeconds, offsetSeconds)) : 0
        let offsetTime = CMTime(seconds: clampedOffset, preferredTimescale: 1_000_000_000)
        let target = CMTimeSubtract(anchor.mediaTime(at: now), offsetTime)
        guard target.isNumeric, target.seconds >= 0 else { return .none }
        let error = playbackTime.isNumeric ? CMTimeSubtract(playbackTime, target).seconds : Double.infinity
        errorSeconds = error.isFinite ? error : nil
        let needsInitialAlign = revision != anchor.revision || !error.isFinite
        let offsetChanged = !needsInitialAlign && abs(clampedOffset - appliedOffsetSeconds) >= 0.005
        if !needsInitialAlign {
            if now > lastSampleHost {
                let dt = now - lastSampleHost
                lastSampleHost = now
                let previous = filteredErrorSeconds ?? 0
                let alpha = 1 - exp(-dt / Self.errorSmoothingSeconds)
                filteredErrorSeconds = previous + alpha * (error - previous)
            } else if filteredErrorSeconds == nil {
                filteredErrorSeconds = error
            }
        }
        let smoothed = filteredErrorSeconds ?? error
        // Flush and realign on timeline discontinuities, user sync offset shifts, catastrophic jumps (> 250 ms),
        // or sustained drift (> 150 ms) — never on transient video reset latency dips (30–80 ms) on a shared clock.
        if needsInitialAlign || offsetChanged || abs(error) > 0.25 || abs(smoothed) > 0.15 {
            guard canAlign() else {
                // Keep steady playback alive if a manual offset push temporarily exceeds buffered audio headroom.
                if offsetChanged && abs(error) <= 0.25 && abs(smoothed) <= 0.15 { return .none }
                let wasRunning = revision != nil
                self = AudioSyncController()
                return wasRunning ? .pause : .none
            }
            errorSeconds = nil
            filteredErrorSeconds = 0
            revision = anchor.revision
            appliedOffsetSeconds = clampedOffset
            rate = 1
            let startHost = now + Self.startLead
            lastAdjustment = startHost
            lastSampleHost = startHost
            return .align(time: CMTimeSubtract(anchor.mediaTime(at: startHost), offsetTime), hostTime: startHost)
        }
        guard now - lastAdjustment >= 1.5 else { return .none }
        let corrected: Float
        if abs(smoothed) <= 0.004 || (rate == 1 && abs(smoothed) <= 0.015) {
            corrected = 1
        } else {
            corrected = Float(1 - min(0.005, max(-0.005, smoothed / 2)))
        }
        guard corrected == 1 ? rate != 1 : abs(corrected - rate) >= 0.001 else { return .none }
        rate = corrected
        lastAdjustment = now
        return .rate(corrected)
    }
}

struct GeneratedDiscardTiming: Sendable {
    let sequence: Int64
    let discardedAt: Double
    let readyLateMilliseconds: Double
    let queuedMilliseconds: Double
    let discardLateMilliseconds: Double
}

enum PipelinePressure: Sendable, Equatable {
    case warmingUp, normal, processing, inputCadence, presentation

    var isWarning: Bool { self == .processing || self == .inputCadence || self == .presentation }
    var message: AppText {
        switch self {
        case .warmingUp: AppText("正在预热并建立内容节奏，请稍候观察。", "The pipeline is warming up and detecting the source cadence.")
        case .normal:
            AppText(
                "速率为最近5秒均值；处理耗时不是端到端延迟。",
                "Frame rates are averages over the last five seconds. Processing time covers detection and interpolation."
            )
        case .processing:
            AppText("处理速度跟不上输入，请尝试降低采集分辨率。", "Processing is falling behind. Try a lower capture resolution.")
        case .inputCadence:
            AppText("输入帧率不稳定，请检查信号源的输出设置。", "The input frame rate is unstable. Check the source's output settings.")
        case .presentation:
            AppText(
                "画面呈现不稳定，可尝试切换补帧档位或降低采集分辨率。",
                "Presentation is uneven. Try a different interpolation quality or a lower capture resolution.")
        }
    }
}

struct PipelinePressureMonitor: Sendable {
    private struct Sample: Sendable {
        let time: Double
        let ingress: Int
        let cadence: Int
        let expired: Int
    }
    private var samples: [Sample] = []
    private var startedAt: Double?
    private var pressureSince: Double?
    private var calmSince: Double?
    private var lastProcessed: Int?
    private var lastProgressAt = 0.0
    private(set) var state = PipelinePressure.warmingUp
    private(set) var recentReplacements = 0

    mutating func update(
        now: Double, interval: Double, processing: [Double], processed: Int, ingress: Int,
        cadence: Int, expired: Int, held: Bool
    ) -> PipelinePressure {
        if startedAt == nil { startedAt = now }
        if lastProcessed != processed {
            lastProcessed = processed
            lastProgressAt = now
        }
        samples.append(Sample(time: now, ingress: ingress, cadence: cadence, expired: expired))
        while samples.count > 1 && samples[1].time <= now - 2 { samples.removeFirst() }
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
        let before = samples[0]
        recentReplacements = max(0, ingress - before.ingress)
        if held {
            state = .processing
            pressureSince = now
            calmSince = nil
            return state
        }
        guard now - (startedAt ?? now) >= 3, interval.isFinite, interval > 0, processing.count >= 16 else {
            state = .warmingUp
            return state
        }
        let costs = processing.suffix(max(8, min(120, Int(2 / interval))))
        let mean = costs.reduce(0, +) / Double(costs.count)
        let candidate: PipelinePressure
        if now - lastProgressAt <= 2 && mean > interval * 1000 * 1.05 {
            candidate = .processing
        } else if cadence - before.cadence >= 2 {
            candidate = .inputCadence
        } else if expired - before.expired >= 2 {
            candidate = .presentation
        } else {
            candidate = .normal
        }
        if candidate.isWarning {
            calmSince = nil
            if pressureSince == nil { pressureSince = now }
            if now - (pressureSince ?? now) >= 1 { state = candidate }
        } else {
            pressureSince = nil
            if !state.isWarning { state = .normal }
            if calmSince == nil { calmSince = now }
            if now - (calmSince ?? now) >= 2 { state = .normal }
        }
        return state
    }
}

/// A bounded window of elapsed times in milliseconds.
struct PresentationLatency: Sendable {
    private var storage: [Double] = []
    private var next = 0
    let capacity: Int
    init(capacity: Int = 600) { self.capacity = max(1, capacity) }
    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var samples: [Double] {
        guard next > 0 else { return storage }
        return Array(storage[next...] + storage[..<next])
    }
    mutating func record(capturedAt: Double, presentedAt: Double) {
        guard capturedAt.isFinite, presentedAt.isFinite, capturedAt > 0, presentedAt >= capturedAt else { return }
        record(seconds: presentedAt - capturedAt)
    }
    mutating func record(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let milliseconds = seconds * 1000
        if storage.count < capacity {
            storage.append(milliseconds)
        } else {
            storage[next] = milliseconds
            next += 1
            if next == capacity { next = 0 }
        }
    }
    var p50: Double? { percentile(0.5) }
    var p95: Double? { percentile(0.95) }
    var p99: Double? { percentile(0.99) }
    private func percentile(_ fraction: Double) -> Double? {
        guard !isEmpty else { return nil }
        let sorted = storage.sorted()
        return sorted[Int(Double(sorted.count - 1) * fraction)]
    }
}

/// Maps source PTS onto the callback clock without changing either endpoint's media timestamp.
/// A single late callback does not move the presentation phase; two agree on a clock jump.
struct CaptureClock: Sendable {
    static var decoupleTransportFloor: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_CLOCK_TRANSPORT_FLOOR"] != "0"
    }
    private static let lockWarmupSamples = 60
    private static let transportJitterFloor = 0.011
    private var offset: Double?
    private var drift = 0.0
    private var outside = 0.0
    private var previousPTS: Double?
    private var lockedSamples = 0
    private(set) var jitter = 0.0

    mutating func anchor(pts: Double, arrival: Double, interval: Double) -> Double {
        guard pts.isFinite, arrival.isFinite, interval.isFinite, interval > 0 else { return arrival }
        let measured = arrival - pts
        let discontinuity = previousPTS.map { pts <= $0 || pts - $0 > 0.25 } ?? true
        previousPTS = pts
        guard let offset, !discontinuity else {
            self.offset = measured
            drift = 0
            outside = 0
            lockedSamples = 0
            jitter = 0
            return arrival
        }
        let error = measured - offset
        jitter += 0.05 * (abs(error) - jitter)
        let outlierThreshold =
            Self.decoupleTransportFloor ? Self.transportJitterFloor : min(Self.transportJitterFloor, interval / 3)
        if abs(error) > outlierThreshold {
            let consistent = error * outside > 0 && abs(error - outside) <= max(0.002, interval / 10)
            if consistent || abs(error) > 0.25 {
                self.offset = measured
                drift = 0
                outside = 0
                lockedSamples = 0
                return arrival
            }
            outside = error
        } else {
            outside = 0
            // Converge quickly on startup/reset, then tighten loop bandwidth so periodic capture-card
            // USB delivery sawtooth (~±7.5 ms every ~233 ms) does not wobble deadlines across refresh slots.
            let locked = lockedSamples >= Self.lockWarmupSamples
            let offsetGain = locked ? 0.025 : 0.1
            let driftGain = locked ? 0.0003 : 0.0025
            self.offset = offset + offsetGain * error + drift
            drift = min(interval * 0.002, max(-interval * 0.002, drift + driftGain * error))
            if !locked { lockedSamples += 1 }
        }
        return pts + (self.offset ?? measured)
    }
}

struct DrawableSelectionBudget {
    /// Keep 1.8 ms minimum margin before `targetTimestamp` (Direct Metal encode+render takes ~0.3 ms;
    /// `recordEncoding` dynamically widens the margin for slower paths) while allowing up to 6.0 ms
    /// late-selection wait on 120 Hz Direct-to-Display scanout.
    private static let minimumBudget = 0.0018
    private static let maximumDelay = 0.006
    private var encodingBudget = minimumBudget

    func selectionDelay(now: Double, deadline: Double) -> Double {
        guard deadline.isFinite, now.isFinite else { return 0 }
        return max(0, min(Self.maximumDelay, deadline - now - encodingBudget))
    }

    /// Forward horizon applied to `DisplayClock.sourceTime` during late selection so frames ready within
    /// the callback's wait window hit the current scanout slot without overlapping sawtooth peak arrivals.
    func selectionAdvance(delay: Double, refreshInterval: Double?) -> Double {
        guard delay.isFinite, delay > 0 else { return 0 }
        let cap = refreshInterval.map { min(0.0028, $0 * 0.34) } ?? 0.0028
        return min(cap, delay * 0.48)
    }

    /// Wakeup-jitter-free forward horizon computed from stable `refreshInterval` and `encodingBudget`
    /// rather than instantaneous `deadline - started`, preventing late callback wakeups from pulling
    /// `DisplayClock.sourceTime` backward and inducing spurious short intervals on 59.94@120Hz.
    func nominalSelectionAdvance(refreshInterval: Double?, fallbackDelay: Double) -> Double {
        let nominalDelay: Double
        if let refreshInterval, refreshInterval.isFinite, refreshInterval > 0 {
            nominalDelay = max(0, min(Self.maximumDelay, refreshInterval - encodingBudget))
        } else {
            nominalDelay = fallbackDelay
        }
        return selectionAdvance(delay: nominalDelay, refreshInterval: refreshInterval)
    }

    mutating func recordEncoding(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        encodingBudget = max(Self.minimumBudget, encodingBudget * 0.95, seconds + 0.0005)
    }
}

struct LivePairTiming: Sendable {
    static var exactBootstrapEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_BOOTSTRAP_EXACT"] != "0"
    }

    let sequence: Int64
    let sourcePTS: Double
    let anchor: Double
    let interval: Double
    let multiplier: Int
    let probe: Bool
    let evaluate: Bool
    let bootstrap: Bool
    var delay: Double
    var resumesAfterHold = false
    private(set) var requiredDelay = 0.0
    private(set) var outputs = 0

    var outputInterval: Double { interval / Double(multiplier) }

    mutating func frame(pts: Double, ready: Double, bufferedFrames: Double) -> LiveFrameTiming {
        requiredDelay = max(requiredDelay, ready - anchor + sourcePTS - pts)
        if outputs == 0 {
            if bootstrap {
                if Self.exactBootstrapEnabled {
                    let extra = max(0, bufferedFrames - 1) * outputInterval
                    delay = max(delay, requiredDelay + 0.001 + extra)
                } else {
                    delay = max(delay, requiredDelay + outputInterval * bufferedFrames)
                }
            } else if resumesAfterHold {
                // The first native operation after idle can finish later than the old p95.
                let extra = max(0, bufferedFrames - 1) * outputInterval
                delay = max(delay, requiredDelay + 0.001 + extra)
            }
        }
        outputs += 1
        let immediate = !evaluate || probe
        return LiveFrameTiming(
            pair: self, deadline: immediate ? ready : anchor + delay + pts - sourcePTS,
            requiredDelay: requiredDelay, queuePolicy: immediate ? .latest : .ordered)
    }
}

/// Attached to an immutable image, so a later pair cannot change its deadlines or diagnostics.
struct LiveFrameTiming: Sendable {
    let pair: LivePairTiming
    let deadline: Double
    let requiredDelay: Double
    let queuePolicy: FrameTimeline.QueuePolicy
    var immediate: Bool { queuePolicy == .latest }

    func allowingAudioPlayback(pts: Double, mode: PresentationMode) -> LiveFrameTiming {
        var pair = pair
        pair.delay = max(pair.delay, mode.audioVideoDelayFloor(multiplier: pair.multiplier))
        return LiveFrameTiming(
            pair: pair, deadline: max(deadline, pair.anchor + pair.delay + pts - pair.sourcePTS),
            requiredDelay: requiredDelay, queuePolicy: queuePolicy == .latest ? .trimMidpoints : queuePolicy)
    }
}

/// Serial FrameProcessor-owned policy. Only native completion/read-only publication counts as readiness.
struct LivePresentationController: Sendable {
    static let minimumSevereExecution = 0.1
    private static let readinessWindow = 1.0
    private static let maximumReadinessHold = 2.0
    private static let minimumReadinessSamples = 8

    private struct Sample: Sendable {
        let time: Double
        let required: Double
    }
    private struct WorkSample: Sendable {
        let finished: Double
        let cost: Double
        let budget: Double
        let severe: Bool
    }
    private var samples: [Sample] = []
    private var resumeSampleWindow: (oldest: Double, expires: Double)?
    private var needsResumeSeed = false
    private var passthroughActive = false
    private var selectedDelay = 0.0
    private var shrinkNotBefore = 0.0
    private var settlingAfterBootstrap = false
    private var overrunEndedAt: Double?
    private var previousInterval = 0.0
    private var work: [WorkSample] = []
    private var hasWorkInCurrentTiming = false
    private var nextProbe = 0.0
    private var recoveryCosts: [Double] = []
    private var probeBackoff = 1.0
    private(set) var held = false
    private(set) var probes = 0
    private(set) var bypassedPairs = 0
    private(set) var transitions = 0
    private(set) var clock = CaptureClock()
    var sampleCount: Int { samples.count }

    mutating func resetTiming(retainingReadinessAt now: Double? = nil) {
        clock = CaptureClock()
        recoveryCosts.removeAll()
        hasWorkInCurrentTiming = false
        overrunEndedAt = nil
        // Keep the overload hold and its probe schedule across reference resets.
        guard let now, let last = samples.last?.time, now >= last, now - last <= Self.maximumReadinessHold else {
            clearReadiness()
            previousInterval = 0
            return
        }
        if now - last > ContentCadence.maximumInterpolationGap {
            // Keep the last active window while fresh pairs replace it after a short static hold.
            let relearningTime = Double(Self.minimumReadinessSamples + 2) * previousInterval
            resumeSampleWindow = (last - Self.readinessWindow, now + min(Self.readinessWindow, relearningTime))
            needsResumeSeed = true
        }
    }

    private mutating func clearReadiness() {
        samples.removeAll(keepingCapacity: true)
        resumeSampleWindow = nil
        needsResumeSeed = false
        passthroughActive = false
        selectedDelay = 0
        shrinkNotBefore = 0
        settlingAfterBootstrap = false
        overrunEndedAt = nil
        hasWorkInCurrentTiming = false
    }

    mutating func anchor(pts: Double, arrival: Double, interval: Double) -> Double {
        clock.anchor(pts: pts, arrival: arrival, interval: interval)
    }

    /// Schedules a native 1× frame inside a 2× session (e.g., 60 fps menu inside 30→60) on the shared
    /// `anchor + selectedDelay` timeline without decaying learned 2× readiness samples or interval history.
    mutating func passthroughFrame(
        sequence: Int64, pts: Double, anchor: Double, outputInterval: Double,
        bufferedFrames: Double, now: Double, activatePassthrough: Bool = true,
        compactColdDelay: Bool = ContentCadence.interactiveSixtyGuardEnabled
    ) -> LiveFrameTiming {
        let interval = max(0.001, outputInterval)
        let extra = max(0, bufferedFrames - 1) * interval
        let coldDelay = compactColdDelay ? (interval + extra) : (interval * 2 + extra)
        let delay = selectedDelay > 0 ? selectedDelay : coldDelay
        if activatePassthrough { passthroughActive = true }
        let pair = LivePairTiming(
            sequence: sequence, sourcePTS: pts, anchor: anchor, interval: interval,
            multiplier: 1, probe: false, evaluate: false, bootstrap: false, delay: delay)
        return LiveFrameTiming(
            pair: pair, deadline: anchor + delay, requiredDelay: max(0, now - anchor),
            queuePolicy: .ordered)
    }

    mutating func beginPair(
        sequence: Int64, pts: Double, anchor: Double, interval: Double,
        multiplier: Int, bufferedFrames: Double, now: Double
    ) -> LivePairTiming {
        if previousInterval > 0, abs(interval - previousInterval) > max(0.002, previousInterval * 0.3) {
            clearReadiness()
            recoveryCosts.removeAll()
            if held {
                nextProbe = now
                probeBackoff = 1
            }
        }
        previousInterval = interval
        if passthroughActive {
            passthroughActive = false
            if let last = samples.last?.time, samples.count >= Self.minimumReadinessSamples,
                now >= last, selectedDelay > 0
            {
                // Preserve learned 2× readiness across arbitrarily long 60 fps passthrough spans
                // so returning to 30 fps does not re-enter bootstrap or drop the first midpoint.
                let relearningTime = Double(Self.minimumReadinessSamples + 2) * interval
                resumeSampleWindow = (last - Self.readinessWindow, now + min(Self.readinessWindow, relearningTime))
            }
        }
        if let resumeSampleWindow, now >= resumeSampleWindow.expires { self.resumeSampleWindow = nil }
        let oldest = min(now - Self.readinessWindow, resumeSampleWindow?.oldest ?? now)
        samples.removeAll { $0.time < oldest || now < $0.time }
        let outputInterval = interval / Double(multiplier)
        let extra = max(0, bufferedFrames - 1) * outputInterval
        let bootstrap = samples.count < Self.minimumReadinessSamples
        let required = samples.map(\.required).sorted()
        var p95 =
            required.isEmpty
            ? interval : required[min(required.count - 1, Int(ceil(Double(required.count) * 0.95)) - 1)]
        let healthyTail = samples.suffix(Self.minimumReadinessSamples)
        let recoveringFromOverrun: Bool
        if multiplier == 2, bufferedFrames == 1, let overrunEndedAt,
            now - overrunEndedAt <= 2.0, !bootstrap, let first = healthyTail.first, first.time > overrunEndedAt,
            let recentRequired = healthyTail.lazy.map(\.required).max()
        {
            // After a full run of on-budget pairs, stop carrying the old burst in the delay target.
            p95 = min(p95, recentRequired)
            recoveringFromOverrun = true
        } else {
            recoveringFromOverrun = false
        }
        // At most two source intervals: sustained overload must bypass FG, never buy unlimited delay.
        let target = min(interval * 2, max(outputInterval, p95 + 0.001 + extra))
        if bootstrap {
            selectedDelay = interval + extra
            shrinkNotBefore = now + 0.25
            settlingAfterBootstrap = true
        } else if target >= selectedDelay {
            if target > selectedDelay + 0.0001 { shrinkNotBefore = now + 0.25 }
            selectedDelay = target
            settlingAfterBootstrap = false
        } else {
            selectedDelay = min(interval * 2, selectedDelay)
            let excess = selectedDelay - target
            if excess <= 0.004 { settlingAfterBootstrap = false }
            if now >= shrinkNotBefore {
                let step = recoveringFromOverrun ? 0.001 : (settlingAfterBootstrap ? min(0.001, excess / 4) : 0.00025)
                selectedDelay = max(target, selectedDelay - min(step, outputInterval / 8))
            }
        }
        let probe = held && now >= nextProbe
        if probe { probes += 1 }
        if held && !probe { bypassedPairs += 1 }
        let resumesAfterHold = needsResumeSeed
        needsResumeSeed = false
        return LivePairTiming(
            sequence: sequence, sourcePTS: pts, anchor: anchor, interval: interval,
            multiplier: multiplier, probe: probe, evaluate: !held || probe, bootstrap: bootstrap,
            delay: selectedDelay, resumesAfterHold: resumesAfterHold)
    }

    mutating func complete(
        _ pair: LivePairTiming, requiredDelay: Double, execution: Double, now: Double,
        transportIntervalWhenDropping: Double? = nil, inputArrival: Double? = nil,
        contentHitch: Bool = false
    ) {
        guard pair.evaluate, execution.isFinite, execution >= 0 else { return }
        let previous = work.last
        if !held, pair.multiplier == 2, inputArrival != nil, execution > pair.interval {
            overrunEndedAt = now
        }
        // Exclude steady-state hitch/transport-slip pairs from the p95 readiness window so periodic
        // 3-copy/1-copy phase slips do not ratchet normal pairs' target delay upward.
        let recordReadiness = !contentHitch || pair.bootstrap || samples.count < Self.minimumReadinessSamples
        if !held, recordReadiness, requiredDelay.isFinite, requiredDelay > 0, requiredDelay < 2 {
            let queueDelay: Double
            if hasWorkInCurrentTiming, !pair.bootstrap, !pair.resumesAfterHold, pair.multiplier == 2,
                let inputArrival, inputArrival.isFinite,
                let previous, previous.cost > previous.budget, !previous.severe,
                execution <= pair.interval * 0.9, transportIntervalWhenDropping == nil,
                previous.finished > inputArrival, previous.finished <= now,
                previous.finished - inputArrival <= pair.interval
            {
                // Learn from the healthy pair without counting the preceding overrun twice.
                queueDelay = previous.finished - inputArrival
            } else {
                queueDelay = 0
            }
            samples.append(Sample(time: now, required: max(0, requiredDelay - queueDelay)))
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
            if pair.bootstrap { selectedDelay = pair.delay }
        }
        // Keep a bounded native probe window. One moderate scheduling spike must not
        // throw away all progress, while sustained or severe overload still backs off.
        if pair.probe {
            let ratio = execution / pair.interval
            recoveryCosts.append(ratio)
            if recoveryCosts.count > 8 { recoveryCosts.removeFirst() }
            let good = recoveryCosts.filter { $0 <= 0.9 }.count
            let mean = recoveryCosts.reduce(0, +) / Double(recoveryCosts.count)
            if recoveryCosts.count == 8, good >= 7, mean <= 0.9,
                recoveryCosts.suffix(2).allSatisfy({ $0 <= 0.9 })
            {
                held = false
                transitions += 1
                clearReadiness()
                work.removeAll(keepingCapacity: true)
                probeBackoff = 1
                recoveryCosts.removeAll()
            } else if ratio <= 1.25
                && (recoveryCosts.count < 3 || recoveryCosts.suffix(3).contains(where: { $0 <= 0.9 }))
            {
                nextProbe = now
            } else {
                recoveryCosts.removeAll()
                nextProbe = now + probeBackoff
                probeBackoff = min(4, probeBackoff * 2)
            }
        } else {
            let windowStart = now - 1.25
            work.removeAll { $0.finished < windowStart || now < $0.finished }
            // Backpressure can widen the gap between accepted frames. Allow two transport ticks
            // for content carried as duplicate pairs when estimating the budget under input loss.
            let severeBudget = min(pair.interval, transportIntervalWhenDropping.map { $0 * 2 } ?? pair.interval)
            let severe = execution >= Self.minimumSevereExecution && execution >= severeBudget * 2
            work.append(WorkSample(finished: now, cost: execution, budget: pair.interval, severe: severe))
            hasWorkInCurrentTiming = true
            if work.count > 128 { work.removeFirst(work.count - 128) }
            var surplus = 0.0
            var slowPairs = 0
            var severePairs = 0
            var severeWork = 0.0
            for sample in work {
                surplus += sample.cost - sample.budget * 1.05
                if sample.cost > sample.budget { slowPairs += 1 }
                if sample.severe {
                    severePairs += 1
                    severeWork += min(sample.cost, sample.finished - windowStart)
                } else {
                    severeWork -= max(0, sample.budget - sample.cost)
                }
            }
            // Slow completions can leave too few samples for the ordinary overload rule.
            let repeatedSevere = severePairs >= 2 && severeWork >= 0.5
            // One operation can span the entire window. Keep evidence of the immediately
            // preceding severe operation when the processor stayed busy across the boundary.
            let continuousSevere =
                severe && execution >= 1
                && (previous.map { $0.severe && $0.finished <= now && now - $0.finished <= execution + 0.25 } ?? false)
            let sustainedOverload = now - (work.first?.finished ?? now) >= 1 && slowPairs >= 8 && surplus > 0
            if repeatedSevere || continuousSevere || sustainedOverload {
                held = true
                transitions += 1
                work.removeAll(keepingCapacity: true)
                recoveryCosts.removeAll()
                nextProbe = now + 1
            }
        }
    }
}
