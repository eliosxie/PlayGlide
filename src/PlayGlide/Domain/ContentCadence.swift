import CoreMedia
import Foundation

struct PictureSignature: Sendable, Equatable {
    static let columns = 32
    static let rows = 18
    /// Tolerate ±2 8-bit HDMI/UVC dithering and YUV rounding on repeated 30-over-60 frames.
    static let duplicateByteTolerance = 2
    static let duplicateChangedByteLimit = 4

    let format: UInt32
    let samples: [SIMD3<UInt8>]

    func resembles(_ other: Self, size: VideoSize) -> Bool {
        guard isComparable(to: other) else { return false }
        // Count only unique bytes. A small surface can repeat a pixel across the sampling grid.
        guard size.width >= Self.columns, size.height >= Self.rows else { return true }
        var changed = 0
        for (a, b) in zip(samples, other.samples) where abs(Int(a.x) - Int(b.x)) > Self.duplicateByteTolerance {
            changed += 1
            if changed > Self.duplicateChangedByteLimit { return false }
        }
        return true
    }

    func isSceneCut(from other: Self) -> Bool {
        guard isComparable(to: other) else { return false }
        let difference = zip(samples, other.samples).reduce(0) { sum, pair in
            let (a, b) = pair
            return sum + max(abs(Int(a.x) - Int(b.x)), abs(Int(a.y) - Int(b.y)), abs(Int(a.z) - Int(b.z)))
        }
        return difference > 45 * samples.count
    }

    private func isComparable(to other: Self) -> Bool {
        format == other.format && samples.count == other.samples.count && !samples.isEmpty
    }
}

enum HistoryResetReason: String, Sendable {
    case startup, inputSizeChanged, windowTimestampEpoch, timelineDiscontinuity
    case cadenceChanged, inputGap, staticHold, sceneCut, contentRectChanged
}

private struct WindowCadence: Sendable {
    private(set) var period: CMTime?
    var skippedCapture = false
    private var candidate: CMTime?

    /// Returns nil while the strict rule still applies during period learning.
    mutating func requiresReset(after gap: CMTime, sceneCut: Bool) -> Bool? {
        if sceneCut {
            clearCandidate()
            return period == nil ? nil : false
        }
        guard let period else {
            if let candidate, agrees(gap, with: candidate) {
                self.period = gap
                clearCandidate()
            } else {
                candidate = gap
            }
            return nil
        }
        if agrees(gap, with: period) {
            clearCandidate()
            return false
        }
        let deviation = gap.seconds - period.seconds
        if let candidate, deviation * (candidate.seconds - period.seconds) > 0, agrees(gap, with: candidate) {
            self.period = gap
            clearCandidate()
            return true
        }
        candidate = gap
        // Adjacent display callbacks can shift one capture by half a content period.
        // A wider jump still breaks the pair before a new speed has been confirmed.
        return abs(deviation) > period.seconds / 2 + 0.002
    }

    mutating func clearCandidate() { candidate = nil }

    private func agrees(_ gap: CMTime, with reference: CMTime) -> Bool {
        abs(gap.seconds - reference.seconds) <= max(0.002, reference.seconds * 0.15)
    }
}

struct ContentCadence: Sendable {
    static let maximumInterpolationGap = 0.25
    static var dynamicCadenceCapEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_DYNAMIC_CADENCE_CAP"] != "0"
    }
    static var interactiveSixtyGuardEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_INTERACTIVE_SIXTY_GUARD"] != "0"
    }
    /// Allow symmetric UVC 3+1 / 1+3 burst slips while confirming return from 60 fps passthrough to 30 fps
    /// (`PLAYGLIDE_SLIP_AWARE_THIRTY_RETURN=0` restores strict consecutive-2-tick confirmation for A/B).
    static var slipAwareThirtyReturnEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_SLIP_AWARE_THIRTY_RETURN"] != "0"
    }

    private static let maximumInterpolatableGapTicks = 2.6
    private static let sixtyToThirtyConfirmationThreshold = 8
    private static let sixtyToThirtyPrewarmThreshold = 3

    static func isSixtyHzTransport(_ tick: Double) -> Bool {
        (1.0 / 61.0...1.0 / 59.0).contains(tick)
    }

    private static func isHarmonicThirtyOrSixty(_ gap: Double, tick: Double) -> Bool {
        guard isSixtyHzTransport(tick) else { return false }
        let ticks = (gap / tick).rounded()
        return (ticks == 1 || ticks == 2) && abs(gap - ticks * tick) <= max(0.002, tick * 0.15)
    }

    private static func isWholeTransportTicks(_ gap: Double, tick: Double, count: Double) -> Bool {
        guard isSixtyHzTransport(tick) else { return false }
        return abs(gap - count * tick) <= max(0.002, tick * 0.15)
    }

    /// Generated images between two endpoints: normally equal fractions of the pair. After a held picture,
    /// they keep the established output spacing before `current`, so its deadline and the readiness it
    /// teaches stay those of a normal pair; none is placed at or before `previous`.
    static func interpolationPlacements(
        previous: CMTime, current: CMTime, multiplier: Int, hitchPeriod: CMTime?
    ) -> [(phase: Float, time: CMTime)] {
        let delta = CMTimeSubtract(current, previous)
        let divisor = Int32(multiplier)
        guard let hitchPeriod else {
            return (1..<multiplier).map { index in
                (
                    Float(index) / Float(multiplier),
                    CMTimeAdd(previous, CMTimeMultiplyByRatio(delta, multiplier: Int32(index), divisor: divisor))
                )
            }
        }
        return (1..<multiplier).compactMap { index in
            let time = CMTimeSubtract(
                current, CMTimeMultiplyByRatio(hitchPeriod, multiplier: Int32(multiplier - index), divisor: divisor))
            guard CMTimeCompare(time, previous) > 0 else { return nil }
            return (Float(CMTimeSubtract(time, previous).seconds / delta.seconds), time)
        }
    }

    /// VT low-latency interpolation renders only its native phases at full speed and on target: 0.5 with
    /// one interpolated frame, quarters with two. At 1080p on an M3 Max (2026-11-20) phase 0.5 took
    /// about 21 ms, 0.75 took 36 ms and 0.667 took 50 ms, longer than a 30 fps content interval, and
    /// 4× phases above 0.75 landed near 0.9. A held pair therefore keeps its grid timestamps from
    /// `interpolationPlacements` but uses the native phases nearest the next original, so motion after
    /// the hold advances in equal steps.
    static func lowLatencyPhases(count: Int, multiplier: Int) -> [Float] {
        guard multiplier > 1 else { return [] }
        let native = (1..<multiplier).map { Float($0) / Float(multiplier) }
        return Array(native.suffix(max(0, min(count, native.count))))
    }

    private static let repeatTolerance = 0.001
    private static let maximumSlipSpan = 8
    private static let maximumHitchPairSpan = 3

    private(set) var previousTime: CMTime?
    private(set) var interval: CMTime?
    private(set) var previousSequence: Int64?
    private var lastAcceptedGap: Double?
    private var previousTransportTime: CMTime?
    private var previousContentArrival: Double?
    private var windowCadence: WindowCadence?
    private let preservingRepeatedTransport: Bool
    private var lastRepeatedSequence: Int64?
    private var catchUpPeriod: CMTime?
    private var recoveredSchedulingPeriod: CMTime?
    private let toleratingContentHitches: Bool
    private let adaptiveHarmonicRate: Bool
    private let interactiveSixtyGuard: Bool
    private let slipAwareThirtyReturn: Bool
    private var nominalPeriod: CMTime?
    private var pendingHitchGap: Double?
    private var pendingHitchRemaining = 0
    private var pendingThirtyConfirmation = 0
    private var pendingThirtySlipTicks = 0
    private var harmonicSixtyOffset: CMTime = .zero
    private var slipOffset: CMTime = .zero
    private var slipFramesRemaining = 0
    /// Rational phase shift subtracted from raw capture PTS while compensating a burst-shifted transport slip.
    private(set) var phaseSlipOffset: CMTime = .zero
    /// The established content period while the current picture follows a held one or makes up for it.
    private(set) var hitchPeriod: CMTime?
    private(set) var resetReason: HistoryResetReason?
    private(set) var ingressAffectedCadence = false
    var timelineDiscontinuity: Bool { resetReason == .startup || resetReason == .timelineDiscontinuity }
    var resumedAfterStaticHold: Bool { resetReason == .staticHold }
    var retainsReadinessOnReset: Bool {
        resumedAfterStaticHold || (resetReason == .inputGap && catchUpPeriod != nil)
    }
    var contentHitch: Bool { hitchPeriod != nil }
    var schedulingInterval: CMTime? { windowCadence?.period ?? recoveredSchedulingPeriod ?? hitchPeriod }
    /// True while sustained 2-tick frames are accumulating to exit 60 fps passthrough back to 30 fps,
    /// letting `PipelineSession` pre-warm `PerformanceHold` before the first interpolated VT pair runs.
    var prewarmingReturnToThirty: Bool {
        interactiveSixtyGuard && adaptiveHarmonicRate
            && pendingThirtyConfirmation >= Self.sixtyToThirtyPrewarmThreshold
    }

    init(
        toleratingWindowJitter: Bool = false, preservingRepeatedTransport: Bool = false,
        toleratingContentHitches: Bool = false, adaptiveHarmonicRate: Bool = false,
        interactiveSixtyGuard: Bool = ContentCadence.interactiveSixtyGuardEnabled,
        slipAwareThirtyReturn: Bool = ContentCadence.slipAwareThirtyReturnEnabled
    ) {
        windowCadence = toleratingWindowJitter ? WindowCadence() : nil
        self.preservingRepeatedTransport = preservingRepeatedTransport
        self.toleratingContentHitches = toleratingContentHitches
        self.adaptiveHarmonicRate = adaptiveHarmonicRate
        self.interactiveSixtyGuard = interactiveSixtyGuard
        self.slipAwareThirtyReturn = slipAwareThirtyReturn
    }

    mutating func accept(
        time: CMTime, duration: CMTime, sequence: Int64, duplicate: Bool, sceneCut: Bool = false,
        arrival: Double? = nil
    ) -> CadenceDecision {
        resetReason = nil
        ingressAffectedCadence = false
        hitchPeriod = nil
        let pendingCatchUp = catchUpPeriod
        catchUpPeriod = nil
        recoveredSchedulingPeriod = nil
        guard time.isNumeric, duration.isNumeric, duration.seconds > 0 else {
            reset()
            return .invalid
        }
        let gap = previousTime.map { CMTimeSubtract(time, $0) }
        let transportGap = previousTransportTime.map { CMTimeSubtract(time, $0) }
        let discontinuity = transportGap.map { !$0.isNumeric || $0.seconds <= 0 || $0.seconds > 0.25 } ?? true
        previousTransportTime = time
        let missed = previousSequence.map { sequence != $0 + 1 } ?? false
        let reversed = previousSequence.map { sequence <= $0 } ?? false
        previousSequence = sequence
        if discontinuity || reversed {
            resetReason = transportGap == nil ? .startup : .timelineDiscontinuity
            previousTime = time
            previousContentArrival = arrival
            interval = duration
            lastAcceptedGap = nil
            nominalPeriod = nil
            pendingHitchGap = nil
            pendingHitchRemaining = 0
            pendingThirtyConfirmation = 0
            pendingThirtySlipTicks = 0
            harmonicSixtyOffset = .zero
            slipOffset = .zero
            slipFramesRemaining = 0
            phaseSlipOffset = .zero
            lastRepeatedSequence = nil
            if windowCadence != nil { windowCadence = WindowCadence() }
            return .keep(reset: true, interval: duration)
        }
        if duplicate {
            if missed { windowCadence?.skippedCapture = true }
            if preservingRepeatedTransport, !missed, let gap,
                abs(gap.seconds - duration.seconds) <= Self.repeatTolerance
            {
                lastRepeatedSequence = sequence
            }
            return .duplicate
        }
        guard let gap else { return .invalid }
        let gapSeconds = gap.seconds
        let inputSkipped =
            missed || (gapSeconds <= Self.maximumInterpolationGap && windowCadence?.skippedCapture == true)
        windowCadence?.skippedCapture = false
        let nominalGap = schedulingInterval?.seconds ?? lastAcceptedGap
        let cadenceChanged = nominalGap.map { abs(gapSeconds - $0) > max(0.002, $0 * 0.3) } ?? false
        // A long static hold can leave transport timestamps continuous while interpolation
        // history is too old. Publish this original as a new reference before learning another interval.
        // Losing a repeated HDMI/USB transport copy does not lose a content endpoint.
        // Keep history only when the next distinct image still matches the established cadence.
        if gapSeconds > Self.maximumInterpolationGap || (inputSkipped && (nominalGap == nil || cadenceChanged)) {
            resetReason = inputSkipped ? .inputGap : .staticHold
            if inputSkipped {
                ingressAffectedCadence = nominalGap.map { gapSeconds > $0 + max(0.002, $0 * 0.3) } ?? false
            }
            let tick = duration.seconds
            if preservingRepeatedTransport, missed, !sceneCut, (1.0 / 61...1.0 / 59).contains(tick),
                let lastRepeatedSequence, sequence - lastRepeatedSequence <= 4,
                let nominalGap, abs(nominalGap - 2 * tick) <= Self.repeatTolerance,
                abs(gapSeconds - 3 * tick) <= Self.repeatTolerance
            {
                catchUpPeriod = CMTimeMultiply(duration, multiplier: 2)
            }
            let preserveSixtyMode =
                interactiveSixtyGuard && adaptiveHarmonicRate && windowCadence == nil && !inputSkipped
                && Self.isSixtyHzTransport(tick) && (nominalGap.map { $0 < tick * 1.5 } ?? false)
            previousTime = time
            previousContentArrival = arrival
            interval = duration
            lastAcceptedGap = preserveSixtyMode ? tick : nil
            nominalPeriod = preserveSixtyMode ? duration : nil
            pendingHitchGap = nil
            pendingHitchRemaining = 0
            pendingThirtyConfirmation = 0
            pendingThirtySlipTicks = 0
            harmonicSixtyOffset = .zero
            slipOffset = .zero
            slipFramesRemaining = 0
            phaseSlipOffset = .zero
            windowCadence?.clearCandidate()
            return .keep(reset: true, interval: duration)
        }
        if sceneCut {
            slipOffset = .zero
            slipFramesRemaining = 0
            harmonicSixtyOffset = .zero
            phaseSlipOffset = .zero
            pendingHitchGap = nil
            pendingHitchRemaining = 0
            pendingThirtyConfirmation = 0
            pendingThirtySlipTicks = 0
        }
        let tick = duration.seconds
        if toleratingContentHitches, windowCadence == nil, !inputSkipped, !sceneCut,
            let nominal = nominalGap, let nominalPeriod
        {
            let tolerance = max(0.002, nominal * 0.15)
            if CMTimeCompare(slipOffset, .zero) != 0 {
                let slipSeconds = slipOffset.seconds
                if abs(gapSeconds + slipSeconds - nominal) <= tolerance,
                    Self.spansWholeTransportFrames(gapSeconds, tick: tick)
                {
                    // The compensating short copy closes the burst-shifted 3-2-...-1 slip on the 30 fps grid.
                    slipOffset = .zero
                    slipFramesRemaining = 0
                    phaseSlipOffset = .zero
                    hitchPeriod = nominalPeriod
                    previousTime = time
                    previousContentArrival = arrival
                    interval = nominalPeriod
                    return .keep(reset: false, interval: nominalPeriod)
                }
                if !cadenceChanged {
                    slipFramesRemaining -= 1
                    if slipFramesRemaining > 0 {
                        phaseSlipOffset = slipOffset
                        previousTime = time
                        previousContentArrival = arrival
                        interval = gap
                        return .keep(reset: false, interval: gap)
                    }
                    // No compensating short copy arrived within the horizon; return smoothly to raw PTS.
                    slipOffset = .zero
                    phaseSlipOffset = .zero
                    hitchPeriod = nominalPeriod
                    previousTime = time
                    previousContentArrival = arrival
                    interval = gap
                    return .keep(reset: false, interval: gap)
                }
                if adaptiveHarmonicRate, slipSeconds < 0,
                    Self.isHarmonicThirtyOrSixty(nominal, tick: tick),
                    Self.isHarmonicThirtyOrSixty(gapSeconds, tick: tick), gapSeconds < tick * 1.5
                {
                    // Second 1-tick frame while in a tentative -1 tick shortSlip confirms genuine 60 fps.
                    // Carry the -1 tick offset across 60 fps passthrough so output slots stay continuous.
                    harmonicSixtyOffset = slipOffset
                    phaseSlipOffset = slipOffset
                    slipOffset = .zero
                    slipFramesRemaining = 0
                    pendingHitchGap = nil
                    pendingHitchRemaining = 0
                    previousTime = time
                    previousContentArrival = arrival
                    interval = gap
                    lastAcceptedGap = gapSeconds
                    self.nominalPeriod = gap
                    return .keep(reset: false, interval: gap)
                }
                // A second unexpected deviation while slipped falls through to a genuine cadence change.
                slipOffset = .zero
                slipFramesRemaining = 0
                harmonicSixtyOffset = .zero
                phaseSlipOffset = .zero
            } else if adaptiveHarmonicRate, nominal < tick * 1.5, gapSeconds >= tick * 1.5,
                interactiveSixtyGuard || Self.spansWholeTransportFrames(gapSeconds, tick: tick)
            {
                // In 60 fps passthrough (e.g. an animated menu or unlocked 45-60 fps gameplay), USB burst
                // duplicates, UI ease-out tails, and short pauses produce isolated or brief 2-tick/multi-tick
                // gaps. Keep 1x passthrough until sustained 2-tick frames confirm genuine 30 fps.
                let isTwoTick = Self.isHarmonicThirtyOrSixty(gapSeconds, tick: tick)
                let isThreeTick =
                    slipAwareThirtyReturn && interactiveSixtyGuard
                    && Self.isWholeTransportTicks(gapSeconds, tick: tick, count: 3)
                let carriedOffset = harmonicSixtyOffset
                harmonicSixtyOffset = .zero
                phaseSlipOffset = .zero
                pendingHitchGap = nil
                pendingHitchRemaining = 0
                previousTime = time
                previousContentArrival = arrival
                let effectiveInterval =
                    isTwoTick && CMTimeCompare(carriedOffset, .zero) < 0 ? CMTimeAdd(gap, carriedOffset) : gap
                let requiredConfirmations = interactiveSixtyGuard ? Self.sixtyToThirtyConfirmationThreshold : 2
                if isTwoTick && pendingThirtySlipTicks == 0
                    && pendingThirtyConfirmation + 1 >= requiredConfirmations
                {
                    pendingThirtyConfirmation = 0
                    pendingThirtySlipTicks = 0
                    lastAcceptedGap = gapSeconds
                    self.nominalPeriod = gap
                    interval = effectiveInterval
                    return .keep(reset: false, interval: effectiveInterval)
                }
                if isTwoTick {
                    pendingThirtyConfirmation = min(requiredConfirmations - 1, pendingThirtyConfirmation + 1)
                } else if isThreeTick && pendingThirtySlipTicks <= 0 {
                    // A +1 tick UVC burst slip (3...1 or closing 1...3) preserves the 2-tick 30 fps mean;
                    // require the slip to balance back to zero and exit on a clean 2-tick frame.
                    pendingThirtySlipTicks += 1
                    pendingThirtyConfirmation = min(requiredConfirmations - 1, pendingThirtyConfirmation + 1)
                } else {
                    pendingThirtyConfirmation = 0
                    pendingThirtySlipTicks = 0
                }
                hitchPeriod = nominalPeriod
                interval = effectiveInterval
                return .keep(reset: false, interval: effectiveInterval)
            } else if cadenceChanged, Self.spansWholeTransportFrames(gapSeconds, tick: tick) {
                let arrivalGap = arrival.flatMap { now in previousContentArrival.map { now - $0 } }
                let burstSlip =
                    pendingHitchGap == nil && nominal >= tick * 1.5
                    && abs(gapSeconds - (nominal + tick)) <= tolerance
                    && (arrivalGap.map {
                        $0 > 0 && (gapSeconds - $0) >= tick * 0.45
                            && abs($0 - nominal) <= max(0.006, nominal * 0.25)
                    } ?? false)
                let shortSlip =
                    pendingHitchGap == nil && nominal >= tick * 1.5
                    && abs(gapSeconds - (nominal - tick)) <= tolerance
                    && arrival != nil && previousContentArrival != nil
                if burstSlip || shortSlip {
                    // Compensate both 3-2-...-1 (+1 tick UVC burst) and 1-2-...-3 (-1 tick early make-up)
                    // capture slips onto the established 30 fps content grid.
                    let shift = CMTimeSubtract(gap, nominalPeriod)
                    slipOffset = shift
                    slipFramesRemaining = Self.maximumSlipSpan
                    harmonicSixtyOffset = .zero
                    phaseSlipOffset = shift
                    hitchPeriod = nominalPeriod
                    previousTime = time
                    previousContentArrival = arrival
                    interval = nominalPeriod
                    return .keep(reset: false, interval: nominalPeriod)
                }
                let completesPendingHitch =
                    slipAwareThirtyReturn
                    && (pendingHitchGap.map { abs($0 + gapSeconds - 2 * nominal) <= tolerance } ?? false)
                if adaptiveHarmonicRate, !completesPendingHitch, Self.isHarmonicThirtyOrSixty(nominal, tick: tick),
                    Self.isHarmonicThirtyOrSixty(gapSeconds, tick: tick)
                {
                    // Switching from 30 fps (2 ticks) to 60 fps (1 tick) inside a 60 Hz container
                    // shares the same 60 Hz output grid; preserve references and learned readiness.
                    harmonicSixtyOffset = .zero
                    phaseSlipOffset = .zero
                    pendingHitchGap = nil
                    pendingHitchRemaining = 0
                    pendingThirtyConfirmation = 0
                    pendingThirtySlipTicks = 0
                    previousTime = time
                    previousContentArrival = arrival
                    lastAcceptedGap = gapSeconds
                    self.nominalPeriod = gap
                    interval = gap
                    return .keep(reset: false, interval: gap)
                }
                harmonicSixtyOffset = .zero
                pendingThirtyConfirmation = 0
                pendingThirtySlipTicks = 0
                let pendingHitch = pendingHitchGap
                let sustained = pendingHitch.map { abs(gapSeconds - $0) <= tolerance } ?? false
                let completesPair = pendingHitch.map { abs($0 + gapSeconds - 2 * nominal) <= tolerance } ?? false
                // One held picture inside an established cadence, or the short pair that makes up for it
                // (immediately or after a short run of normal pairs), keeps timing and references.
                if pendingHitch == nil || (completesPair && !sustained) {
                    if pendingHitch == nil {
                        pendingHitchGap = gapSeconds
                        pendingHitchRemaining = Self.maximumHitchPairSpan
                    } else {
                        pendingHitchGap = nil
                        pendingHitchRemaining = 0
                    }
                    hitchPeriod = nominalPeriod
                    phaseSlipOffset = .zero
                    previousTime = time
                    previousContentArrival = arrival
                    interval = gap
                    return .keep(reset: false, interval: gap)
                }
                pendingHitchGap = nil
                pendingHitchRemaining = 0
            } else {
                if slipAwareThirtyReturn && interactiveSixtyGuard && adaptiveHarmonicRate
                    && (nominalGap.map { $0 < tick * 1.5 } ?? false)
                    && Self.isWholeTransportTicks(gapSeconds, tick: tick, count: 1)
                    && (pendingThirtySlipTicks > 0 || (pendingThirtyConfirmation >= 2 && pendingThirtySlipTicks == 0))
                {
                    // A single 1-tick frame either closes an open 3+1 UVC slip or opens a tentative 1+3 slip;
                    // a second consecutive 1-tick (genuine 60 fps) sees pendingThirtySlipTicks == -1 and resets.
                    pendingThirtySlipTicks -= 1
                    let cap = Self.sixtyToThirtyConfirmationThreshold - 1
                    pendingThirtyConfirmation = min(cap, pendingThirtyConfirmation + 1)
                } else {
                    pendingThirtyConfirmation = 0
                    pendingThirtySlipTicks = 0
                }
                if pendingHitchRemaining > 0 {
                    pendingHitchRemaining -= 1
                    if pendingHitchRemaining == 0 { pendingHitchGap = nil }
                }
            }
        } else {
            pendingHitchGap = nil
            pendingHitchRemaining = 0
            pendingThirtyConfirmation = 0
            pendingThirtySlipTicks = 0
            harmonicSixtyOffset = .zero
            slipOffset = .zero
            slipFramesRemaining = 0
        }
        if interactiveSixtyGuard, adaptiveHarmonicRate, windowCadence == nil, !inputSkipped, !sceneCut,
            nominalGap == nil, Self.isSixtyHzTransport(tick),
            gapSeconds > tick * Self.maximumInterpolatableGapTicks
        {
            // Never learn an interactive 50-250 ms menu pause as a 4-20 fps cadence or bootstrap a
            // 50-250 ms presentation delay wall. Keep 1x passthrough on the 60 Hz transport grid.
            harmonicSixtyOffset = .zero
            phaseSlipOffset = .zero
            pendingHitchGap = nil
            pendingHitchRemaining = 0
            pendingThirtyConfirmation = 0
            pendingThirtySlipTicks = 0
            previousTime = time
            previousContentArrival = arrival
            lastAcceptedGap = tick
            nominalPeriod = duration
            hitchPeriod = duration
            interval = gap
            return .keep(reset: false, interval: gap)
        }
        let keepSixtyOffset =
            adaptiveHarmonicRate && !cadenceChanged && CMTimeCompare(harmonicSixtyOffset, .zero) != 0
            && gapSeconds < tick * 1.5
        if !keepSixtyOffset { harmonicSixtyOffset = .zero }
        phaseSlipOffset = keepSixtyOffset ? harmonicSixtyOffset : .zero
        let harmonicTransition =
            adaptiveHarmonicRate && windowCadence == nil && !inputSkipped && !sceneCut && cadenceChanged
            && nominalGap.map { Self.isHarmonicThirtyOrSixty($0, tick: tick) } == true
            && Self.isHarmonicThirtyOrSixty(gapSeconds, tick: tick)
        let resetHistory =
            windowCadence?.requiresReset(after: gap, sceneCut: sceneCut) ?? (cadenceChanged && !harmonicTransition)
        previousTime = time
        previousContentArrival = arrival
        interval = gap
        // A phase slip can leave a short pair immediately after the input gap. Its media timestamps
        // remain exact, while scheduling and the next cadence comparison use the established period.
        if let pendingCatchUp, !inputSkipped, !sceneCut,
            abs(gapSeconds - duration.seconds) <= Self.repeatTolerance,
            abs(pendingCatchUp.seconds - 2 * duration.seconds) <= Self.repeatTolerance
        {
            recoveredSchedulingPeriod = pendingCatchUp
        }
        // After a cadence change the current image is already the new reference.
        // Do not reset again when the next normal interval follows a held/repeated image.
        lastAcceptedGap = resetHistory ? nil : (recoveredSchedulingPeriod?.seconds ?? gapSeconds)
        nominalPeriod = resetHistory ? nil : (recoveredSchedulingPeriod ?? gap)
        if resetHistory { resetReason = .cadenceChanged }
        return .keep(reset: resetHistory, interval: gap)
    }

    private static func spansWholeTransportFrames(_ gap: Double, tick: Double) -> Bool {
        guard tick > 0 else { return false }
        let frames = gap / tick
        return frames.rounded() >= 1 && abs(frames - frames.rounded()) <= 0.1
    }

    mutating func reset() {
        self = ContentCadence(
            toleratingWindowJitter: windowCadence != nil, preservingRepeatedTransport: preservingRepeatedTransport,
            toleratingContentHitches: toleratingContentHitches, adaptiveHarmonicRate: adaptiveHarmonicRate,
            interactiveSixtyGuard: interactiveSixtyGuard)
    }
}

enum CadenceDecision: Equatable {
    case invalid, duplicate
    case keep(reset: Bool, interval: CMTime)
}

struct FrameTimeline: Sendable {
    enum QueuePolicy: Equatable, Sendable {
        case ordered, latest, trimMidpoints
    }
    struct Item: Sendable {
        let time: Double
        let id: UUID
        let latenessAllowance: Double
        let ready: Double
        var generated = false
        var expires = Double.infinity
        var live = false
    }
    private(set) var items: [Item] = []
    private var sourceAnchor: Double?
    private var hostAnchor: Double = 0
    private var lastPTS: Double?
    private var lastLiveTakeTime: Double?
    private(set) var dropped = 0
    private(set) var expiredGenerated = 0
    private(set) var generatedTimedOut = 0
    private(set) var generatedPreempted = 0
    private(set) var generatedFlushed = 0
    private(set) var supersededReal = 0
    private(set) var capacityDropped = 0
    let capacity: Int

    init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    mutating func clearDropCounters() {
        expiredGenerated = 0
        generatedTimedOut = 0
        generatedPreempted = 0
        generatedFlushed = 0
        supersededReal = 0
        capacityDropped = 0
    }

    mutating func pruneStale(before cutoff: Double) -> [UUID] {
        var removed: [UUID] = []
        items.removeAll { item in
            guard item.time < cutoff else { return false }
            removed.append(item.id)
            return true
        }
        dropped += removed.count
        return removed
    }

    /// Live pairs already carry absolute host deadlines. Never re-anchor them to processing completion.
    mutating func enqueue(
        id: UUID, deadline: Double, generated: Bool, outputInterval: Double,
        queuePolicy: QueuePolicy = .ordered, ready: Double = 0
    ) -> [UUID] {
        guard deadline.isFinite, outputInterval.isFinite, outputInterval > 0 else { return [id] }
        var removed: [UUID] = []
        if queuePolicy == .latest {
            removed = items.map(\.id)
            dropped += removed.count
            expiredGenerated += items.filter(\.generated).count
            generatedFlushed += items.filter(\.generated).count
            supersededReal += items.filter { !$0.generated }.count
            items.removeAll()
            lastLiveTakeTime = nil
        } else if queuePolicy == .trimMidpoints {
            var timedOut = 0
            items.removeAll { item in
                guard item.generated else { return false }
                if item.expires < ready {
                    timedOut += 1
                } else if item.time + item.latenessAllowance / 2 <= deadline {
                    return false
                }
                removed.append(item.id)
                return true
            }
            dropped += removed.count
            expiredGenerated += removed.count
            generatedTimedOut += timedOut
            generatedFlushed += removed.count - timedOut
        }
        // This consumer wakes once per display refresh, unlike a precise CPU deadline scheduler.
        // Allow one refresh of lateness. Merely crossing the following real frame's
        // deadline must not erase a midpoint that missed the previous refresh by a fraction.
        let grace = min(0.025, outputInterval + 0.002)
        // A clock snap or a cut may shorten the next phase. Preserve ordered output during that transition.
        let target = max(deadline, items.last.map { $0.time + 0.000001 } ?? deadline)
        items.append(
            Item(
                time: target, id: id, latenessAllowance: outputInterval,
                ready: ready,
                generated: generated, expires: generated ? min(deadline + grace, target + grace) : .infinity, live: true
            ))
        while items.count > capacity {
            removed.append(items.removeFirst().id)
            capacityDropped += 1
            dropped += 1
        }
        return removed
    }

    mutating func enqueue(id: UUID, pts: Double, now: Double, delay: Double) -> [UUID] {
        guard pts.isFinite, now.isFinite else { return [id] }
        var removed: [UUID] = []
        if sourceAnchor == nil || lastPTS.map({ pts <= $0 || pts - $0 > 0.3 }) == true {
            removed = items.map(\.id)
            items.removeAll()
            sourceAnchor = pts
            hostAnchor = now + delay
        }
        var target = hostAnchor + pts - (sourceAnchor ?? pts)
        // Overload cannot grow the queue's age. Rebase only after substantial lateness.
        if target < now - 0.1 {
            removed += items.map(\.id)
            items.removeAll()
            sourceAnchor = pts
            hostAnchor = now + delay
            target = hostAnchor
        }
        lastPTS = pts
        items.append(Item(time: target, id: id, latenessAllowance: max(0, delay) * 1.5, ready: now))
        while items.count > capacity { removed.append(items.removeFirst().id) }
        dropped += removed.count
        return removed
    }

    /// Waiting can end when the live head is due and deadline ordering cannot expire or supersede it.
    /// Frames selected ahead of their deadline retain the opportunity to recover a failed redraw.
    func hasStableDueFrame(at time: Double) -> Bool {
        guard let first = items.first, first.live, first.time <= time else { return false }
        let lateness = time - first.time
        if first.generated {
            return time <= first.expires && lateness < first.latenessAllowance / 2
        }
        return lateness <= first.latenessAllowance
    }

    /// Prevents ±0.35 ms locked clock/sawtooth wobble on a high-refresh display (e.g. 120 Hz showing 60 fps) from
    /// pulling the very next frame one refresh early (8.33 ms interval) right after a 25 ms beat crossing
    /// while that frame's deadline sits within 0.75 ms of the early-selection tolerance edge.
    private func defersEarlyHalfSlot(_ first: Item, at now: Double, refresh: Double?, tolerance: Double) -> Bool {
        guard first.live, let refresh, let lastLiveTakeTime else { return false }
        guard refresh <= first.latenessAllowance / 2 + 0.0001 else { return false }
        guard now - lastLiveTakeTime < first.latenessAllowance * 0.75 else { return false }
        let hysteresis = min(0.00075, tolerance * 0.2)
        guard first.time > now + tolerance - hysteresis else { return false }
        if items.count > 1, items[1].time <= now + refresh + 0.001 { return false }
        return true
    }

    /// Waiting only helps when no frame is queued yet (or the head is a late frame that a fresher
    /// original could still overtake). When `wakeHalfSlot` is enabled, a fresh frame in the half-slot
    /// selection window `(time, time + tolerance]` is already eligible for this refresh and cannot be
    /// overtaken under monotonic deadlines, so waiting ends immediately.
    func shouldWaitForReadyFrame(
        at time: Double, refreshInterval: Double? = nil, wakeHalfSlot: Bool = false
    ) -> Bool {
        guard let first = items.first else { return true }
        guard first.live else { return false }
        if hasStableDueFrame(at: time) { return false }
        let refresh = refreshInterval.flatMap { $0.isFinite && $0 > 0 && $0 <= 0.1 ? $0 : nil }
        let tolerance = min(first.latenessAllowance, refresh ?? first.latenessAllowance) / 2
        if defersEarlyHalfSlot(first, at: time, refresh: refresh, tolerance: tolerance) { return false }
        if wakeHalfSlot && first.time > time && first.time <= time + tolerance { return false }
        return first.time <= time + tolerance
    }

    mutating func take(
        now: Double, refreshInterval: Double? = nil, traceTimeouts: Bool = false,
        preferCurrent: () -> Bool = { false }
    ) -> (selected: UUID?, skipped: [UUID], timedOut: [UUID]) {
        let refresh = refreshInterval.flatMap { $0.isFinite && $0 > 0 && $0 <= 0.1 ? $0 : nil }
        var skipped: [UUID] = []
        var timedOut: [UUID] = []
        var expiredMidpoint = false
        while let first = items.first, first.live {
            if first.generated {
                let expired = now > first.expires
                let overtaken = items.dropFirst().contains {
                    !$0.generated && $0.time + first.latenessAllowance / 2 <= now
                }
                guard expired || overtaken else { break }
                skipped.append(items.removeFirst().id)
                expiredGenerated += 1
                if expired {
                    if traceTimeouts { timedOut.append(first.id) }
                    generatedTimedOut += 1
                    expiredMidpoint = true
                } else {
                    generatedPreempted += 1
                }
            } else if now - first.time > first.latenessAllowance,
                let newer = items.dropFirst().first(where: { !$0.generated && $0.time <= now })
            {
                // After an expired midpoint, two freshly available originals can use successive
                // high-refresh slots. An older or deeper backlog still yields to the newest frame.
                if expiredMidpoint, skipped.count == 1, items.count == 2,
                    let refresh, refresh <= first.latenessAllowance / 2,
                    now - first.time <= first.latenessAllowance * 2,
                    now - first.ready < refresh, now - newer.time < refresh
                {
                    break
                }
                skipped.append(items.removeFirst().id)
                supersededReal += 1
            } else {
                break
            }
        }
        // Do not skip a frame just because the previous display callback was a little
        // early. Consume in order through small jitter; trim only a genuinely late backlog.
        while items.count > 1, !items[0].live, items[1].time <= now,
            now - items[0].time > items[0].latenessAllowance
        {
            skipped.append(items.removeFirst().id)
        }
        dropped += skipped.count
        guard let first = items.first else { return (nil, skipped, timedOut) }
        // Choose the nearest refresh slot for already-ready live images. A deadline
        // a fraction after this callback should not force another full refresh of waiting.
        let tolerance = first.live ? min(first.latenessAllowance, refresh ?? first.latenessAllowance) / 2 : 0
        guard first.time <= now + tolerance else { return (nil, skipped, timedOut) }
        if defersEarlyHalfSlot(first, at: now, refresh: refresh, tolerance: tolerance) {
            return (nil, skipped, timedOut)
        }
        // A redraw may use a refresh that would otherwise select a frame ahead of its deadline.
        if let refresh, first.live, first.time > now, refresh <= first.latenessAllowance / 2 + 0.000001,
            preferCurrent()
        {
            return (nil, skipped, timedOut)
        }
        if first.live { lastLiveTakeTime = now }
        items.removeFirst()
        return (first.id, skipped, timedOut)
    }
}

struct FrameRates: Sendable {
    var input = 0.0
    var content = 0.0
    var generated = 0.0
    var presented = 0.0
}

/// Actual counter deltas over a trailing window, without rounding or synthetic frame counts.
struct FrameRateWindow {
    private struct Sample {
        let time: Double
        let input: Int
        let content: Int
        let generated: Int
        let presented: Int
    }
    private var samples: [Sample] = []
    mutating func record(time: Double, input: Int, content: Int, generated: Int, presented: Int) -> FrameRates {
        let sample = Sample(time: time, input: input, content: content, generated: generated, presented: presented)
        if let last = samples.last, time <= last.time { samples.removeAll() }
        samples.append(sample)
        while samples.count > 2, samples[1].time <= time - 5 { samples.removeFirst() }
        guard let first = samples.first, time > first.time else { return FrameRates() }
        let elapsed = time - first.time
        return FrameRates(
            input: Double(max(0, input - first.input)) / elapsed,
            content: Double(max(0, content - first.content)) / elapsed,
            generated: Double(max(0, generated - first.generated)) / elapsed,
            presented: Double(max(0, presented - first.presented)) / elapsed)
    }
}

/// Align a predicted scanout clock with the producer's host-time anchor.
/// The fixed lead preserves display-clock cadence instead of sampling CPU wakeup jitter.
struct DisplayClock {
    private var lead: Double?
    private var shorterLeads: [Double] = []
    private(set) var previousTarget: Double?
    private var refreshInterval: Double?
    private var longerInterval: Double?

    /// Rejects stale or duplicate display-link callbacks emitted across fullscreen/compositor transitions,
    /// which would otherwise enqueue an extra drawable into the scanout FIFO and add one refresh (+8.33 ms) permanently.
    func isFreshScanoutSlot(target: Double, now: Double, submissionDeadline: Double? = nil) -> Bool {
        guard target.isFinite, now.isFinite, target > now else { return false }
        if let submissionDeadline, submissionDeadline.isFinite, submissionDeadline <= now { return false }
        if let previousTarget, target - previousTarget <= 0.001 { return false }
        return true
    }

    mutating func observeRefresh(target: Double) -> Double? {
        guard target.isFinite else { return refreshInterval }
        defer { previousTarget = target }
        guard let previousTarget else { return nil }
        let measured = target - previousTarget
        guard measured > 0, measured <= 0.1 else {
            refreshInterval = nil
            longerInterval = nil
            return nil
        }
        if let refreshInterval {
            let ratio = measured / refreshInterval
            let multiple = ratio.rounded()
            if multiple >= 2, abs(ratio - multiple) <= 0.1,
                longerInterval.map({ abs(measured - $0) > refreshInterval / 10 }) ?? true
            {
                // A missing callback spans several refreshes. Wait for a second matching
                // interval before using a slower period to decide the nearest refresh slot.
                longerInterval = measured
                return refreshInterval
            }
        }
        refreshInterval = measured
        longerInterval = nil
        return measured
    }

    mutating func sourceTime(target: Double, now: Double) -> Double {
        let currentLead = max(0, target - now)
        // Display-link startup can grow its pipeline lead over several callbacks.
        // Follow that growth, while ignoring a late CPU wakeup that only shortens it.
        if lead == nil || currentLead > (lead ?? 0) || (lead ?? 0) - currentLead > 0.1 {
            lead = currentLead
            shorterLeads.removeAll()
        } else if (lead ?? 0) - currentLead > 0.002 {
            shorterLeads.append(currentLead)
            if shorterLeads.count > 8 { shorterLeads.removeFirst() }
            if shorterLeads.count == 8 {
                let sorted = shorterLeads.sorted()
                // Confirm a sustained compositor change, rather than following one late wakeup.
                if sorted[7] - sorted[0] <= 0.004 {
                    lead = sorted[6]
                    shorterLeads.removeAll()
                }
            }
        } else {
            shorterLeads.removeAll()
        }
        // A shorter system lead may also be a real compositor change, not just a late CPU wakeup.
        // Preserve small clock-phase jitter, but never retain tens of milliseconds of stale lead indefinitely.
        return max(target - (lead ?? 0), now - (refreshInterval ?? (1.0 / 120)))
    }
}

/// Detects when macOS WindowServer steps an already-proven 1-refresh fullscreen Direct-to-Display surface
/// up to 2-refresh compositing (+8.33 ms on 120 Hz) and authorizes a bounded `CAMetalDisplayLink` re-arm.
struct ScanoutLatencyRecovery: Sendable {
    static let triggerStreak = 60
    static let cooldownSeconds = 10.0
    static let maxConsecutiveFailures = 2

    private(set) var observedDirectScanout = false
    private var elevatedStreak = 0
    private var lastAttemptAt = -Double.infinity
    private var pendingVerification = false
    private var consecutiveFailures = 0

    mutating func reset() {
        observedDirectScanout = false
        elevatedStreak = 0
        pendingVerification = false
        consecutiveFailures = 0
    }

    mutating func observe(
        immersive: Bool, refreshInterval: Double?, scanoutLag: Double, now: Double
    ) -> Bool {
        guard immersive, let refreshInterval, refreshInterval.isFinite,
            refreshInterval > 0, refreshInterval <= 0.011, scanoutLag.isFinite, now.isFinite
        else {
            if !immersive { reset() }
            elevatedStreak = 0
            return false
        }
        if scanoutLag <= refreshInterval * 1.25 {
            observedDirectScanout = true
            elevatedStreak = 0
            pendingVerification = false
            consecutiveFailures = 0
            return false
        }
        guard observedDirectScanout, scanoutLag >= refreshInterval * 1.45 else {
            elevatedStreak = 0
            return false
        }
        elevatedStreak += 1
        guard elevatedStreak >= Self.triggerStreak else { return false }
        if pendingVerification {
            consecutiveFailures += 1
            pendingVerification = false
        }
        guard consecutiveFailures < Self.maxConsecutiveFailures,
            now - lastAttemptAt >= Self.cooldownSeconds
        else {
            elevatedStreak = 0
            return false
        }
        lastAttemptAt = now
        elevatedStreak = 0
        pendingVerification = true
        return true
    }
}
