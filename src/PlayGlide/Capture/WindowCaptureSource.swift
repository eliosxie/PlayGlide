import AppKit
import CoreImage
import CoreMedia
import CoreVideo
// ScreenCaptureKit's Objective-C control objects lack Swift Sendable annotations.
// Filter/stream lifecycle stays on WindowCaptureSource; pixel data stays on its serial callback queue.
@preconcurrency import ScreenCaptureKit
import Synchronization

final class WindowCaptureDimensions: Sendable {
    private let size = Mutex<VideoSize?>(nil)
    func read() -> VideoSize? { size.withLock { $0 } }
    func store(_ value: VideoSize) { size.withLock { $0 = value } }
}

/// ScreenCaptureKit describes content in surface points, with a top-left origin.
/// Convert once to pixel coordinates; contentScale has already been applied by the stream.
struct WindowFrameGeometry: Sendable, Equatable {
    let surface: CGRect
    let content: CGRect
    let scaleFactor: CGFloat

    init?(size: VideoSize, contentRect: CGRect?, scaleFactor: CGFloat?) {
        surface = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard size.width > 0, size.height > 0 else { return nil }
        guard let contentRect else {
            content = surface
            self.scaleFactor = 1
            return
        }
        guard let scaleFactor, scaleFactor.isFinite, scaleFactor > 0,
            [contentRect.origin.x, contentRect.origin.y, contentRect.width, contentRect.height].allSatisfy(\.isFinite),
            contentRect.width > 0, contentRect.height > 0
        else { return nil }
        let pixels = contentRect.applying(CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        guard [pixels.minX, pixels.minY, pixels.maxX, pixels.maxY].allSatisfy(\.isFinite) else { return nil }
        // Core Image's origin is bottom-left; desktop/screen coordinates must never be used here.
        let rectangle = CGRect(
            x: pixels.minX, y: surface.height - pixels.maxY, width: pixels.width, height: pixels.height)
        let clipped = rectangle.intersection(surface)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        content = clipped
        self.scaleFactor = scaleFactor
    }

    func fittedRect(output: VideoSize) -> CGRect {
        let factor = min(CGFloat(output.width) / content.width, CGFloat(output.height) / content.height)
        return CGRect(
            x: (CGFloat(output.width) - content.width * factor) / 2,
            y: (CGFloat(output.height) - content.height * factor) / 2,
            width: content.width * factor, height: content.height * factor)
    }

    func fittedImage(_ image: CIImage, output: VideoSize) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        let target = fittedRect(output: output)
        let factor = target.width / content.width
        let transform = CGAffineTransform(
            a: factor, b: 0, c: 0, d: factor,
            tx: target.minX - content.minX * factor, ty: target.minY - content.minY * factor)
        let fitted = image.cropped(to: content).transformed(by: transform)
        return fitted.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
    }

    var summary: AppText {
        func format(_ template: String) -> String {
            String(
                format: template,
                surface.width, surface.height, content.minX, content.minY, content.width, content.height, scaleFactor)
        }
        return AppText(
            format("缓冲 %.0f×%.0f · 内容像素 (%.0f, %.0f) %.0f×%.0f · 点像素比 %.2f"),
            format("Buffer %.0f×%.0f · Content (%.0f, %.0f) %.0f×%.0f px · Scale %.2f"))
    }
}

/// Tracks SCStream surface arrivals so fixed-rate sampling locks safely after each arrival without beat drops.
struct WindowSamplingPhaseLock: Sendable {
    let period: Double
    let targetOffset: Double
    let maxSlewPerTick: Double
    private(set) var nextTick: Double?
    private var lastObservedArrival: Double?
    private var filteredPhaseError: Double?
    private var hasSnapped = false

    init(period: Double, targetOffset: Double? = nil, maxSlewPerTick: Double? = nil) {
        let clampedPeriod = period.isFinite && period > 0 ? period : (1.0 / 30.0)
        self.period = clampedPeriod
        self.targetOffset = targetOffset ?? min(0.005, max(0.002, clampedPeriod * 0.15))
        self.maxSlewPerTick = maxSlewPerTick ?? min(0.0015, clampedPeriod * 0.05)
    }

    mutating func observeArrival(_ arrival: Double) {
        guard arrival.isFinite else { return }
        if !hasSnapped || lastObservedArrival.map({ arrival - $0 > period * 2.5 || arrival < $0 }) == true {
            hasSnapped = true
            lastObservedArrival = arrival
            nextTick = arrival + targetOffset
            filteredPhaseError = 0
            return
        }
        // Ignore sub-cadence compositor redraws (e.g. 60 Hz UI overlays during 30 fps video).
        if let last = lastObservedArrival, arrival - last < period * 0.60 {
            return
        }
        lastObservedArrival = arrival
        guard let nextTick else {
            self.nextTick = arrival + targetOffset
            filteredPhaseError = 0
            return
        }
        let rawDiff = (arrival + targetOffset) - nextTick
        let wrapped = rawDiff - (rawDiff / period).rounded() * period
        let previous = filteredPhaseError ?? 0
        filteredPhaseError = previous + 0.25 * (wrapped - previous)
    }

    mutating func nextSampleTime(after now: Double) -> Double {
        guard now.isFinite else { return 0 }
        guard var current = nextTick else {
            let initial = now + period
            nextTick = initial
            return initial
        }
        if current <= now {
            var candidate = current + period
            if let phase = filteredPhaseError {
                let correction = min(maxSlewPerTick, max(-maxSlewPerTick, phase * 0.5))
                candidate += correction
                filteredPhaseError = phase - correction
            }
            if candidate <= now {
                let steps = ceil((now - candidate) / period)
                candidate += max(1, steps) * period
            }
            current = candidate
            nextTick = current
        }
        return current
    }
}

/// Deferred SCStream surface retained only until consumed or replaced by a newer arrival.
struct PendingWindowSurface: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let geometry: WindowFrameGeometry
    let outputSize: VideoSize
    let presentationTime: CMTime
    let duration: CMTime
    let sequence: Int64
    let arrivalTime: Double
    let epoch: UInt64
}

/// One immutable latest surface. Sampling does not manufacture new content when the window is unchanged.
final class WindowFrameSampler: Sendable {
    /// Align fixed-rate window sampling phase with SCStream surface arrivals and defer CoreImage rendering
    /// until a surface is actually sampled (`PLAYGLIDE_WINDOW_PHASE_LOCK=0` opts out for A/B rollback).
    static var phaseLockEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_WINDOW_PHASE_LOCK"] != "0"
    }

    private struct State {
        var latest: VideoFrame?
        var pending: PendingWindowSurface?
        var phaseLock: WindowSamplingPhaseLock
        var surfacesConverted = 0
        var surfacesSkipped = 0
    }

    let duration: CMTime
    let phaseLockActive: Bool
    private let state: Mutex<State>

    init(duration: CMTime, phaseLock: Bool = WindowFrameSampler.phaseLockEnabled) {
        self.duration = duration
        self.phaseLockActive = phaseLock
        self.state = Mutex(State(phaseLock: WindowSamplingPhaseLock(period: duration.seconds)))
    }

    var surfacesConverted: Int { state.withLock(\.surfacesConverted) }
    var surfacesSkipped: Int { state.withLock(\.surfacesSkipped) }

    func store(_ frame: VideoFrame) {
        state.withLock {
            $0.latest = frame
            $0.pending = nil
            if phaseLockActive { $0.phaseLock.observeArrival(frame.arrivalTime) }
        }
    }

    func storePending(_ pending: PendingWindowSurface) {
        state.withLock {
            if $0.pending != nil { $0.surfacesSkipped += 1 }
            $0.pending = pending
            if phaseLockActive { $0.phaseLock.observeArrival(pending.arrivalTime) }
        }
    }

    func clearPending() {
        state.withLock { $0.pending = nil }
    }

    func nextSampleTime(after now: Double) -> Double {
        state.withLock { $0.phaseLock.nextSampleTime(after: now) }
    }

    func hasSurface() -> Bool {
        state.withLock { $0.latest != nil || $0.pending != nil }
    }

    func sample(sequence: Int64) -> VideoFrame? {
        state.withLock {
            guard let frame = $0.latest else { return nil }
            return VideoFrame(
                pixelBuffer: frame.pixelBuffer,
                presentationTime: CMTime(value: duration.value * sequence, timescale: duration.timescale),
                duration: duration, sequence: sequence, arrivalTime: frame.arrivalTime,
                contentRect: frame.contentRect, windowStamp: frame.windowStamp)
        }
    }

    func sample(
        sequence: Int64,
        convert: (PendingWindowSurface) throws -> VideoFrame
    ) throws -> VideoFrame? {
        let takenPending = state.withLock { state -> PendingWindowSurface? in
            let next = state.pending
            state.pending = nil
            return next
        }
        if let takenPending {
            let rendered = try convert(takenPending)
            state.withLock {
                $0.latest = rendered
                $0.surfacesConverted += 1
            }
        }
        return sample(sequence: sequence)
    }
}

struct WindowTimestampTracker {
    private var lastAccepted: CMTime?
    private var rollbackCandidate: CMTime?
    private(set) var epoch: UInt64 = 0

    mutating func accepts(_ pts: CMTime) -> Bool {
        guard pts.isNumeric else { return false }
        if let lastAccepted, CMTimeCompare(pts, lastAccepted) <= 0 {
            let rollback = CMTimeSubtract(lastAccepted, pts).seconds
            guard rollback > 0.25 else {
                rollbackCandidate = nil
                return false
            }
            let step = rollbackCandidate.map { CMTimeSubtract(pts, $0).seconds }
            rollbackCandidate = pts
            guard let step, step > 0, step <= 0.25 else { return false }
            epoch += 1
        }
        self.lastAccepted = pts
        rollbackCandidate = nil
        return true
    }
}

/// UI only: the system authorizes one selected window. No capture starts during app launch.
@MainActor
final class WindowSharingPicker: NSObject, SCContentSharingPickerObserver {
    var onSelection: (@MainActor (WindowCaptureSource) -> Void)?
    var onDismiss: (@MainActor (AppText?) -> Void)?
    private var choosing = false
    private var observing = false

    func present() {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else {
            onDismiss?(
                AppText(
                    "系统当前不允许窗口采集，请检查屏幕使用限制后重试。",
                    "macOS is blocking window capture. Check screen capture restrictions and try again."))
            return
        }
        if !observing {
            picker.add(self)
            observing = true
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleWindow
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "com.eliosxie.PlayGlide"]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        choosing = true
        picker.isActive = true
        picker.present(using: .window)
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
    ) {
        // Transfer the opaque filter into one actor; never share native buffers or a mutable filter with UI.
        let source = WindowCaptureSource(filter: filter)
        Task { @MainActor [weak self] in
            guard let self, self.choosing else { return }
            self.choosing = false
            self.onSelection?(source)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, self.choosing else { return }
            self.choosing = false
            self.onDismiss?(nil)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.choosing = false
            self?.onDismiss?(AppText("无法打开窗口选择器：\(message)", "Could not open the window picker: \(message)"))
        }
    }
}

actor WindowCaptureSource: VideoCaptureSource {
    nonisolated let id = UUID()
    nonisolated let title: String
    private let filter: SCContentFilter
    private let backgroundColor = CGColor(gray: 0, alpha: 1)
    private let queue = DispatchQueue(label: "com.eliosxie.PlayGlide.window.samples", qos: .userInteractive)
    private var size = InputPreset.hd1080.size
    private var sampling = WindowSamplingRate.fps30
    private var mailbox: FrameMailbox?
    private var generation = UUID()
    private var stream: SCStream?
    private var sink: WindowFrameReceiver?
    private var continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation?
    private var starting: Task<Void, Error>?
    private var stopping: Task<Void, Never>?
    private var producer: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var updating: Task<Void, Error>?
    private var resolution = WindowResolutionMode.fixed
    private var configuredSize = InputPreset.hd1080.size
    private let dimensions = WindowCaptureDimensions()

    init(filter: SCContentFilter) {
        let window = filter.includedWindows.first
        title = [window?.owningApplication?.applicationName, window?.title]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        self.filter = filter
        let points = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        if points.width > 0, points.height > 0, scale > 0 {
            dimensions.store(
                VideoSize(width: Int((points.width * scale).rounded()), height: Int((points.height * scale).rounded())))
        }
    }

    func configure(
        size: VideoSize, sampling: WindowSamplingRate, mailbox: FrameMailbox, generation: UUID,
        resolution: WindowResolutionMode = .fixed
    ) throws {
        guard continuation == nil, stream == nil, stopping == nil else {
            throw PipelineError(AppText("窗口采集仍在停止，请稍后重试", "Window capture is still stopping. Try again in a moment."))
        }
        guard filter.style == .window else {
            throw PipelineError(AppText("请选择一个浏览器窗口，不支持整屏输入", "Choose a single window in the system picker."))
        }
        self.size = size
        self.sampling = sampling
        self.mailbox = mailbox
        self.generation = generation
        self.resolution = resolution
    }

    func start() async throws -> AsyncThrowingStream<VideoFrame, Error> {
        guard continuation == nil, let mailbox else {
            throw PipelineError(AppText("窗口采集尚未配置或已经启动", "Window capture is unconfigured or already running."))
        }
        try Task.checkCancellation()
        let pair = AsyncThrowingStream<VideoFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        let sampler = sampling.duration.map { WindowFrameSampler(duration: $0) }
        let receiver = WindowFrameReceiver(
            size: size, continuation: pair.continuation, mailbox: mailbox, generation: generation, sampler: sampler,
            adaptive: resolution != .fixed, dimensions: dimensions)
        sink = receiver
        configuredSize = resolution != .fixed ? desiredSize() : size
        let configuration = captureConfiguration(size: configuredSize)
        mailbox.mutate(generation) { $0.requestedWindowSize = configuredSize }
        let native = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        stream = native
        try native.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
        // Shield the native start from cancellation, then drain it before stopping/releasing the stream.
        let request = Task { try await self.beginCapture() }
        starting = request
        do {
            try await request.value
            starting = nil
            try Task.checkCancellation()
            guard stopping == nil else { throw CancellationError() }
            if let sampler {
                producer = Task { await self.produce(sampler, to: pair.continuation) }
            }
            if resolution != .fixed { resolutionTask = Task { await self.followPreview() } }
            return pair.stream
        } catch {
            starting = nil
            throw error
        }
    }

    private func captureConfiguration(size: VideoSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureDynamicRange = .SDR
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.backgroundColor = backgroundColor
        configuration.preservesAspectRatio = true
        configuration.scalesToFit = resolution == .fixed
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.streamName = "PlayGlide"
        return configuration
    }

    private func desiredSize() -> VideoSize {
        WindowCaptureSizing.target(
            preview: mailbox?.previewPixelSize, native: dimensions.read() ?? size, fallback: size,
            preserveNativePixels: resolution == .nativePixels)
    }

    private func followPreview() async {
        var settler = WindowResolutionSettler(applied: configuredSize)
        while !Task.isCancelled {
            if let next = settler.propose(desiredSize(), now: mediaHostTime()) {
                // Native configuration updates are shielded and drained before stopping the stream.
                let change = Task { try await self.changeSize(to: next) }
                updating = change
                defer { updating = nil }
                do {
                    try await change.value
                    settler.acknowledge(next)
                } catch {
                    if Task.isCancelled || stopping != nil { return }
                    mailbox?.mutate(generation) { $0.windowResolutionError = AppText(error: error) }
                    settler.retry(now: mediaHostTime())
                }
            }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
    }

    private func changeSize(to size: VideoSize) async throws {
        guard let stream, stopping == nil else { throw CancellationError() }
        try await stream.updateConfiguration(captureConfiguration(size: size))
        configuredSize = size
        mailbox?.mutate(generation) {
            $0.requestedWindowSize = size
            $0.windowResolutionUpdates += 1
            $0.windowResolutionError = nil
        }
    }

    private func beginCapture() async throws {
        guard let stream else { throw PipelineError(AppText("窗口采集流尚未建立", "The window stream has not started.")) }
        try await stream.startCapture()
    }

    private func produce(
        _ sampler: WindowFrameSampler, to continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation
    ) async {
        defer { sampler.clearPending() }
        let clock = ContinuousClock()
        let start = clock.now
        let converter = PixelConverter()
        var pool: PixelBufferPool?
        var sequence: Int64 = 0
        var lastSampled: Int64?
        let mailbox = self.mailbox
        let generation = self.generation
        let convertPending: (PendingWindowSurface) throws -> VideoFrame = { pending in
            guard let pixel = CMSampleBufferGetImageBuffer(pending.sampleBuffer) else {
                throw PipelineError(AppText("窗口采集没有图像缓冲", "Window capture returned no image buffer."))
            }
            if pool?.size != pending.outputSize {
                pool = try PixelBufferPool(size: pending.outputSize, format: kCVPixelFormatType_32BGRA)
            }
            guard let pool else {
                throw PipelineError(AppText("无法建立窗口像素池", "Could not create the window pixel buffer pool."))
            }
            let image = CIImage(cvPixelBuffer: pixel, options: [.applyCleanAperture: false])
            let rendered = VideoFrame(
                pixelBuffer: try converter.render(
                    pending.geometry.fittedImage(image, output: pending.outputSize), pool: pool),
                presentationTime: pending.presentationTime,
                duration: pending.duration, sequence: pending.sequence, arrivalTime: pending.arrivalTime,
                contentRect: pending.geometry.fittedRect(output: pending.outputSize),
                windowStamp: WindowFrameStamp(
                    sequence: pending.sequence, pts: pending.presentationTime, epoch: pending.epoch))
            mailbox?.capture(rendered, generation: generation, tracksTimeline: false)
            return rendered
        }
        do {
            while !Task.isCancelled {
                if sampler.phaseLockActive && !sampler.hasSurface() {
                    try await clock.sleep(for: .milliseconds(4), tolerance: .microseconds(500))
                    continue
                }
                if let frame = try sampler.sample(sequence: sequence, convert: convertPending) {
                    if let capture = frame.windowStamp {
                        mailbox?.recordWindowSample(
                            frame, generation: generation, newSurface: capture.sequence != lastSampled)
                        lastSampled = capture.sequence
                    }
                    switch continuation.yield(frame) {
                    case .terminated: return
                    case .dropped(let dropped): mailbox?.recordInputOverwrite(dropped, generation: generation)
                    default: break
                    }
                }
                sequence += 1
                if sampler.phaseLockActive {
                    let now = mediaHostTime()
                    let nextHost = sampler.nextSampleTime(after: now)
                    let sleepSeconds = max(0.001, nextHost - now)
                    try await clock.sleep(for: .seconds(sleepSeconds), tolerance: .microseconds(500))
                } else {
                    try await clock.sleep(
                        until: start.advanced(by: .seconds(Double(sequence) * sampler.duration.seconds)),
                        tolerance: .microseconds(500))
                    let elapsed = start.duration(to: clock.now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    sequence = max(sequence, Int64(seconds / sampler.duration.seconds))
                }
            }
        } catch is CancellationError {
            // Native callbacks and all processing resources are drained by stop().
        } catch { continuation.finish(throwing: error) }
    }

    func stop() async {
        if let stopping {
            await stopping.value
            return
        }
        let request = Task { await self.drain() }
        stopping = request
        await request.value
        stopping = nil
    }

    private func drain() async {
        continuation?.finish()
        resolutionTask?.cancel()
        await resolutionTask?.value
        resolutionTask = nil
        if let updating { _ = try? await updating.value }
        updating = nil
        producer?.cancel()
        await producer?.value
        producer = nil
        if let starting { _ = try? await starting.value }
        starting = nil
        if let stream {
            try? await stream.stopCapture()
            if let sink { try? stream.removeStreamOutput(sink, type: .screen) }
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        sink = nil
        stream = nil
        continuation = nil
    }
}

/// All image work and mutable buffers belong to the single SCStream sample-handler queue.
final class WindowFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    private let size: VideoSize
    private let continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation
    private let mailbox: FrameMailbox
    private let generation: UUID
    private let sampler: WindowFrameSampler?
    private let converter = PixelConverter()
    private var pool: PixelBufferPool?
    private var sequence: Int64 = 0
    private var timestamps = WindowTimestampTracker()
    private var previousGeometry: WindowFrameGeometry?
    private let adaptive: Bool
    private let dimensions: WindowCaptureDimensions?

    init(
        size: VideoSize, continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation,
        mailbox: FrameMailbox, generation: UUID, sampler: WindowFrameSampler? = nil,
        adaptive: Bool = false, dimensions: WindowCaptureDimensions? = nil
    ) {
        self.size = size
        self.continuation = continuation
        self.mailbox = mailbox
        self.generation = generation
        self.sampler = sampler
        self.adaptive = adaptive
        self.dimensions = dimensions
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        receive(sampleBuffer)
    }

    func receive(_ sampleBuffer: CMSampleBuffer) {
        let arrival = mediaHostTime()
        autoreleasepool {
            do {
                guard sampleBuffer.isValid,
                    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                        as? [[SCStreamFrameInfo: Any]],
                    let info = attachments.first,
                    let rawStatus = info[.status] as? Int,
                    SCFrameStatus(rawValue: rawStatus) == .complete
                else { return }  // Idle/blank/suspended surfaces are not new video content.
                guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    throw PipelineError(AppText("窗口采集没有图像缓冲", "Window capture returned no image buffer."))
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard time.isNumeric else {
                    throw PipelineError(AppText("窗口采集没有有效时间戳", "Window capture returned an invalid timestamp."))
                }
                let actual = VideoSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
                let contentRect = (info[.contentRect] as? [String: Any])
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                // Ignore transient invalid geometry during a window resize, retaining the last good image.
                guard info[.contentRect] == nil || contentRect != nil,
                    let geometry = WindowFrameGeometry(
                        size: actual, contentRect: contentRect,
                        scaleFactor: (info[.scaleFactor] as? NSNumber).map { CGFloat($0.doubleValue) })
                else { return }
                guard timestamps.accepts(time) else { return }
                if let contentScale = (info[.contentScale] as? NSNumber)?.doubleValue,
                    contentScale.isFinite, contentScale > 0
                {
                    let width = geometry.content.width / contentScale
                    let height = geometry.content.height / contentScale
                    if width >= 2, height >= 2, width <= 100_000, height <= 100_000 {
                        let native = VideoSize(width: Int(width.rounded()), height: Int(height.rounded()))
                        dimensions?.store(native)
                        mailbox.mutate(generation) { $0.nativeWindowSize = native }
                    }
                }
                let outputSize = adaptive ? actual : size
                let duration = CMSampleBufferGetDuration(sampleBuffer)
                let resolvedDuration =
                    duration.isNumeric && duration.seconds > 0 ? duration : CMTime(value: 1, timescale: 60)
                if geometry != previousGeometry {
                    previousGeometry = geometry
                    mailbox.mutate(generation) { $0.windowGeometry = geometry.summary }
                }
                if let sampler, sampler.phaseLockActive {
                    // Defer CoreImage rendering until the phase-locked sampler actually consumes this surface,
                    // avoiding wasted GPU conversions for unconsumed intermediate SCStream callbacks.
                    let pending = PendingWindowSurface(
                        sampleBuffer: sampleBuffer, geometry: geometry, outputSize: outputSize,
                        presentationTime: time, duration: resolvedDuration, sequence: sequence,
                        arrivalTime: arrival, epoch: timestamps.epoch)
                    sequence += 1
                    sampler.storePending(pending)
                    return
                }
                if pool?.size != outputSize {
                    pool = try PixelBufferPool(size: outputSize, format: kCVPixelFormatType_32BGRA)
                }
                guard let pool else {
                    throw PipelineError(AppText("无法建立窗口像素池", "Could not create the window pixel buffer pool."))
                }
                let image = CIImage(cvPixelBuffer: pixel, options: [.applyCleanAperture: false])
                let frame = VideoFrame(
                    // Copy into an owned surface before returning the system's reusable capture buffer.
                    pixelBuffer: try converter.render(geometry.fittedImage(image, output: outputSize), pool: pool),
                    presentationTime: time,
                    duration: resolvedDuration,
                    sequence: sequence, arrivalTime: arrival, contentRect: geometry.fittedRect(output: outputSize),
                    windowStamp: WindowFrameStamp(sequence: sequence, pts: time, epoch: timestamps.epoch))
                sequence += 1
                mailbox.capture(frame, generation: generation, tracksTimeline: false)
                if let sampler {
                    sampler.store(frame)
                } else if case .dropped(let dropped) = continuation.yield(frame) {
                    mailbox.recordInputOverwrite(dropped, generation: generation)
                }
            } catch let error as CVError where error == .wouldExceedAllocationThreshold {
                sequence += 1
                mailbox.mutate(generation) { $0.ingressDropped += 1 }
            } catch { continuation.finish(throwing: error) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish(
            throwing: PipelineError(
                AppText(
                    "窗口采集已停止：\(error.localizedDescription)", "Window capture stopped: \(error.localizedDescription)")))
    }

    func streamDidBecomeInactive(_ stream: SCStream) {
        continuation.finish(
            throwing: PipelineError(
                AppText("选中的窗口已关闭，请重新选择浏览器窗口", "The selected window closed. Choose a new window to continue.")))
    }
}
