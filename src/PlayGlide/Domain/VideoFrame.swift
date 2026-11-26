import CoreMedia
import CoreVideo
import Foundation
import Metal
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

/// Bounded 3-slot private Metal texture pool + shared event for precomputing hybrid `selectMotion`
/// off the display link without passing `CVMetalTexture` across threads.
final class MotionDetailSlotPool: @unchecked Sendable {
    static let capacity = 3

    private struct Slot {
        let texture: any MTLTexture
        var inUse = false
    }

    private struct State {
        var slots: [Slot] = []
        var nextEventValue: UInt64 = 0
        var epoch: UInt64 = 1
        var exhaustionFallbacks = 0
    }

    let deviceRegistryID: UInt64
    let selectSize: VideoSize
    let sharedEvent: any MTLSharedEvent
    private let device: any MTLDevice
    private let state = Mutex(State())

    init?(device: any MTLDevice, selectSize: VideoSize) {
        guard selectSize.width > 0, selectSize.height > 0, let event = device.makeSharedEvent() else { return nil }
        self.device = device
        self.deviceRegistryID = device.registryID
        self.selectSize = selectSize
        self.sharedEvent = event
    }

    func acquire(hasForward: Bool) -> PrecomputedMotionDetail? {
        let acquired: (index: Int, texture: any MTLTexture, signalValue: UInt64, epoch: UInt64)? = state.withLock {
            state in
            if let existing = state.slots.firstIndex(where: { !$0.inUse }) {
                state.slots[existing].inUse = true
                state.nextEventValue += 1
                return (existing, state.slots[existing].texture, state.nextEventValue, state.epoch)
            }
            guard state.slots.count < Self.capacity else {
                state.exhaustionFallbacks += 1
                return nil
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: selectSize.width, height: selectSize.height, mipmapped: false)
            desc.storageMode = .private
            desc.usage = [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: desc) else {
                state.exhaustionFallbacks += 1
                return nil
            }
            let index = state.slots.count
            state.slots.append(Slot(texture: texture, inUse: true))
            state.nextEventValue += 1
            return (index, texture, state.nextEventValue, state.epoch)
        }
        guard let acquired else { return nil }
        return PrecomputedMotionDetail(
            pool: self, slotIndex: acquired.index, texture: acquired.texture,
            event: sharedEvent, signalValue: acquired.signalValue, epoch: acquired.epoch,
            hasForward: hasForward, deviceRegistryID: deviceRegistryID)
    }

    func release(slotIndex: Int) {
        state.withLock { state in
            guard state.slots.indices.contains(slotIndex) else { return }
            state.slots[slotIndex].inUse = false
        }
    }

    func invalidateAll() {
        state.withLock { $0.epoch &+= 1 }
    }

    func isValid(epoch: UInt64) -> Bool {
        state.withLock { $0.epoch == epoch }
    }

    var exhaustionFallbacks: Int { state.withLock(\.exhaustionFallbacks) }
    var inUseCount: Int { state.withLock { $0.slots.filter(\.inUse).count } }
}

/// Ownership token for one precomputed `selectMotion` texture slot; automatically recycles the slot on deinit
/// after both producer and any consumer GPU command buffers have completed.
final class PrecomputedMotionDetail: @unchecked Sendable {
    private let pool: MotionDetailSlotPool
    private let slotIndex: Int
    let texture: any MTLTexture
    let event: any MTLSharedEvent
    let signalValue: UInt64
    let epoch: UInt64
    let hasForward: Bool
    let deviceRegistryID: UInt64

    init(
        pool: MotionDetailSlotPool, slotIndex: Int, texture: any MTLTexture,
        event: any MTLSharedEvent, signalValue: UInt64, epoch: UInt64,
        hasForward: Bool, deviceRegistryID: UInt64
    ) {
        self.pool = pool
        self.slotIndex = slotIndex
        self.texture = texture
        self.event = event
        self.signalValue = signalValue
        self.epoch = epoch
        self.hasForward = hasForward
        self.deviceRegistryID = deviceRegistryID
    }

    deinit { pool.release(slotIndex: slotIndex) }

    func isValid(forDevice registryID: UInt64) -> Bool {
        deviceRegistryID == registryID && pool.isValid(epoch: epoch)
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
    let inputSize: VideoSize
    let lowSize: VideoSize
    let motionSize: VideoSize
    let forwardMotionSize: VideoSize
    let selectSize: VideoSize
    let isHDR10PQ: Bool
    let precomputedMotionDetail: PrecomputedMotionDetail?

    init(
        previous: CVReadOnlyPixelBuffer, current: CVReadOnlyPixelBuffer,
        previousLow: CVReadOnlyPixelBuffer, currentLow: CVReadOnlyPixelBuffer,
        midpoint: CVReadOnlyPixelBuffer, motionBackward: CVReadOnlyPixelBuffer?,
        motionForward: CVReadOnlyPixelBuffer?, phase: Float, sharpenStrength: Float,
        restoresStaticPixels: Bool, inputSize: VideoSize, lowSize: VideoSize,
        motionSize: VideoSize, forwardMotionSize: VideoSize, selectSize: VideoSize,
        isHDR10PQ: Bool, precomputedMotionDetail: PrecomputedMotionDetail? = nil
    ) {
        self.previous = previous
        self.current = current
        self.previousLow = previousLow
        self.currentLow = currentLow
        self.midpoint = midpoint
        self.motionBackward = motionBackward
        self.motionForward = motionForward
        self.phase = phase
        self.sharpenStrength = sharpenStrength
        self.restoresStaticPixels = restoresStaticPixels
        self.inputSize = inputSize
        self.lowSize = lowSize
        self.motionSize = motionSize
        self.forwardMotionSize = forwardMotionSize
        self.selectSize = selectSize
        self.isHDR10PQ = isHDR10PQ
        self.precomputedMotionDetail = precomputedMotionDetail
    }
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
