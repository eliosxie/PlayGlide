import Dispatch
import Foundation
import Synchronization

/// Keeps one CPU core busy from the end of an interpolated content pair until the next content frame,
/// so the next pair starts while the SoC is still in a high performance state.
///
/// Holding the performance state can improve interpolation latency at the cost of higher power use.
/// Wait for presentation to settle before spinning, since early late submissions can increase
/// compositor latency for the rest of the session. Set `PLAYGLIDE_PERFORMANCE_HOLD=0` to disable the hold.
final class PerformanceHold: Sendable {
    /// The preview must present to an unchanged drawable this long before a hold starts.
    static let settleSeconds = 3.0
    static let isEnabledByEnvironment = ProcessInfo.processInfo.environment["PLAYGLIDE_PERFORMANCE_HOLD"] != "0"

    /// Interpolated capture-card and test-pattern sessions; window capture is untested.
    static func applies(to settings: SessionDraft) -> Bool {
        isEnabledByEnvironment && settings.interpolation != .off && settings.source != .window
    }

    /// Covers one content gap, ending soon after input stalls.
    static func limit(contentInterval: Double) -> Double {
        guard contentInterval.isFinite, contentInterval > 0 else { return 0.02 }
        return min(0.05, max(0.02, contentInterval * 1.5))
    }

    /// Host-time bit pattern of the hold's end; zero while idle.
    private let until = Atomic<UInt64>(0)
    private let stopped = Atomic<Bool>(false)
    private let running = Atomic<Bool>(true)
    private let spinning = Atomic<Bool>(false)
    private let holds = Atomic<Int>(0)
    private let wake = DispatchSemaphore(value: 0)
    let usesFastPathSpin: Bool

    init(usesFastPathSpin: Bool = FrameMailbox.fastPathEnabled) {
        self.usesFastPathSpin = usesFastPathSpin
        let thread = Thread { [self] in run() }
        thread.name = "PlayGlide.performance.hold"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Spins until `release()`, `stop()` or the given time elapses.
    func hold(for seconds: Double) {
        guard !stopped.load(ordering: .acquiring), seconds > 0 else { return }
        until.store((mediaHostTime() + seconds).bitPattern, ordering: .releasing)
        holds.add(1, ordering: .relaxed)
        wake.signal()
    }

    func release() { until.store(0, ordering: .releasing) }

    /// Ends the thread without waiting; it exits within one spin iteration.
    func stop() {
        stopped.store(true, ordering: .releasing)
        until.store(0, ordering: .releasing)
        wake.signal()
    }

    var isRunning: Bool { running.load(ordering: .acquiring) }
    var isSpinning: Bool { spinning.load(ordering: .acquiring) }
    var holdCount: Int { holds.load(ordering: .relaxed) }

    private func run() {
        let fastPath = usesFastPathSpin
        while !stopped.load(ordering: .acquiring) {
            wake.wait()
            while !stopped.load(ordering: .relaxed) {
                let end = Double(bitPattern: until.load(ordering: .acquiring))
                guard end > 0, mediaHostTime() < end else { break }
                if !spinning.load(ordering: .relaxed) { spinning.store(true, ordering: .releasing) }
                if fastPath {
                    for _ in 0..<128 {
                        if stopped.load(ordering: .relaxed) || until.load(ordering: .relaxed) == 0 { break }
                    }
                }
            }
            spinning.store(false, ordering: .releasing)
        }
        running.store(false, ordering: .releasing)
    }
}

/// How long the preview has presented to one drawable size without an interruption.
struct PresentationSurfaceStability: Sendable {
    /// A longer gap between presentations means the surface was paused, hidden or rebuilt.
    static let interruption = 0.25
    private(set) var since: Double?
    private var size: VideoSize?
    private var last: Double?

    mutating func observe(at time: Double, drawable: VideoSize?) {
        if since == nil || size != drawable || last.map({ time - $0 > Self.interruption }) ?? true {
            since = time
            size = drawable
        }
        last = max(time, last ?? time)
    }

    /// A zero duration does not wait for any presentation.
    func isStable(for seconds: Double, now: Double) -> Bool {
        guard seconds > 0 else { return true }
        guard let since, let last, now - last <= Self.interruption else { return false }
        return now - since >= seconds
    }
}
