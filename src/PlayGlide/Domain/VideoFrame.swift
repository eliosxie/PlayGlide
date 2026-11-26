import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import Synchronization

struct WindowFrameStamp: Sendable {
    let sequence: Int64
    let pts: CMTime
    let epoch: UInt64
}

struct VideoFrame: Sendable {
    let pixelBuffer: CVReadOnlyPixelBuffer
    let presentationTime: CMTime
    let duration: CMTime
    let sequence: Int64
    let arrivalTime: Double
    // Valid window content within the processing canvas, in bottom-left pixel coordinates.
    var contentRect: CGRect? = nil
    var windowStamp: WindowFrameStamp? = nil
    var size: VideoSize {
        pixelBuffer.withUnsafeBuffer { VideoSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
    }
    func timed(at time: CMTime, duration: CMTime) -> VideoFrame {
        VideoFrame(
            pixelBuffer: pixelBuffer, presentationTime: time, duration: duration,
            sequence: sequence, arrivalTime: arrivalTime, contentRect: contentRect, windowStamp: windowStamp)
    }
}

/// Immutable inputs for fusing hybrid midpoint composition directly into the Metal preview pass.
/// Eliminates the 12.4 MB 4K 420v intermediate buffer, CPU waitUntilCompleted(), and 8-bit quantization round-trip.
struct HybridPreviewRecipe: Sendable {
    let previous: CVReadOnlyPixelBuffer
    let current: CVReadOnlyPixelBuffer
    let previousLow: CVReadOnlyPixelBuffer
    let currentLow: CVReadOnlyPixelBuffer
    let midpoint: CVReadOnlyPixelBuffer
    let motionBackward: CVReadOnlyPixelBuffer?
    let motionForward: CVReadOnlyPixelBuffer?
    let phase: Float
    let sharpenStrength: Float
    let restoresStaticPixels: Bool
    let lowSize: VideoSize
    let motionSize: VideoSize
    let forwardMotionSize: VideoSize
    let selectSize: VideoSize
    let isHDR10PQ: Bool
}

struct PresentationFrame: Sendable {
    let id = UUID()
    let presentation = FramePresentationStatus()
    let generation: UUID
    let video: VideoFrame
    let original: VideoFrame
    let generated: Bool
    let outputSize: VideoSize
    let spatial: Bool
    let presentationDelay: Double
    // A known web sampling clock must not change the display refresh request after a held image.
    var displayIntervalHint: Double? = nil
    var readyTime: Double = mediaHostTime()
    var timing: LiveFrameTiming? = nil
    var timelineRevision: UInt64 = 0
    var opticalFlowTiming: OpticalFlowTiming? = nil
    var hybridRecipe: HybridPreviewRecipe? = nil
}

/// Shared by copies of one frame and by its drawable callbacks. State lives only as long as those references.
final class FramePresentationStatus: Sendable {
    enum Attempt: Sendable {
        case first, redraw
    }

    struct Observation {
        var firstFailed = false
        var firstValid = false
        var recoveredAt: Double?
    }

    private enum FirstAttempt {
        case notSubmitted, pending, failed, succeeded
    }

    private struct State: Sendable {
        var firstAttempt = FirstAttempt.notSubmitted
        var presentedAt: Double?
        var retriedAfterFailure = false
    }

    private let state = Mutex(State())

    // An idle refresh can redraw again. Only one redraw may defer early selection of the next frame.
    var canPrioritizeRedraw: Bool {
        state.withLock { $0.firstAttempt == .failed && $0.presentedAt == nil && !$0.retriedAfterFailure }
    }

    /// True while the frame still needs an initial presentation or a retry after a failed first attempt.
    var needsSubmission: Bool {
        state.withLock { $0.firstAttempt == .notSubmitted || ($0.firstAttempt == .failed && $0.presentedAt == nil) }
    }

    func submit() -> Attempt? {
        state.withLock {
            guard $0.presentedAt == nil else { return nil }
            guard $0.firstAttempt == .notSubmitted else {
                if $0.firstAttempt == .failed { $0.retriedAfterFailure = true }
                return .redraw
            }
            $0.firstAttempt = .pending
            return .first
        }
    }

    func observe(at time: Double, attempt: Attempt) -> Observation {
        state.withLock {
            let valid = time.isFinite && time > 0
            if attempt == .first {
                guard $0.firstAttempt == .pending || $0.firstAttempt == .notSubmitted else { return Observation() }
                $0.firstAttempt = valid ? .succeeded : .failed
                // A redraw callback can arrive before the first drawable reports failure.
                if !valid { return Observation(firstFailed: true, recoveredAt: $0.presentedAt) }
            }
            guard valid, $0.presentedAt == nil else { return Observation() }
            $0.presentedAt = time
            return Observation(firstValid: true, recoveredAt: $0.firstAttempt == .failed ? time : nil)
        }
    }
}

/// Which 2× sessions wait briefly in the display callback to select a just-ready frame.
/// Every input size by default: with the performance hold on (2026-11-21, 120 Hz fullscreen), it cut off-cadence
/// intervals from 10.2% to 0.7% at 1440p and from 35.4% to 0.4% at 1080p without raising original latency.
/// `PLAYGLIDE_PREVIEW_LATE_SELECTION=4k` restores the earlier native-4K-only scope for A/B runs.
enum PreviewLateSelection: String, Sendable {
    case fourK = "4k"
    case all

    static let configured =
        Self(rawValue: ProcessInfo.processInfo.environment["PLAYGLIDE_PREVIEW_LATE_SELECTION"] ?? "") ?? .all

    func applies(to input: VideoSize?) -> Bool { self == .all || input == InputPreset.uhd4K.size }
}

func mediaHostTime() -> Double { CACurrentMediaTime() }
