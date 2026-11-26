import AVFoundation
import AudioToolbox
import CoreAudio
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

actor CaptureCatalog {
    /// Non-capture audio transports that must never be auto-matched as a capture card's companion audio.
    private static let nonExternalAudioTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn,
        kAudioDeviceTransportTypeVirtual,
        kAudioDeviceTransportTypeAggregate,
        kAudioDeviceTransportTypeAutoAggregate,
        kAudioDeviceTransportTypeBluetooth,
        kAudioDeviceTransportTypeBluetoothLE,
        kAudioDeviceTransportTypeAirPlay,
        0x6363_7764,  // 'ccwd' Continuity Camera wireless audio
    ]

    static func isExternalCaptureAudio(transportType: Int32, uniqueID: String) -> Bool {
        guard uniqueID != "BuiltInMicrophoneDevice" else { return false }
        let transport = UInt32(bitPattern: transportType)
        return !nonExternalAudioTransports.contains(transport)
    }

    func audioDevices() -> [CaptureAudioDeviceDescriptor] {
        Self.availableAudioDevices().map {
            CaptureAudioDeviceDescriptor(
                id: $0.uniqueID, name: $0.localizedName,
                isExternal: Self.isExternalCaptureAudio(transportType: $0.transportType, uniqueID: $0.uniqueID),
                manufacturer: $0.manufacturer)
        }
    }

    func audioOutputDevices() -> [AudioOutputDeviceDescriptor] {
        Self.availableAudioOutputDevices()
    }

    static func availableAudioOutputDevices() -> [AudioOutputDeviceDescriptor] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var defaultID = AudioObjectID(kAudioObjectUnknown)
        var defaultSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(systemObject, &defaultAddress, 0, nil, &defaultSize, &defaultID)

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &devicesAddress, 0, nil, &byteSize) == noErr,
            byteSize > 0
        else { return [] }
        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.stride
        var ids = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = ids.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(systemObject, &devicesAddress, 0, nil, &byteSize, base)
        }
        guard status == noErr else { return [] }

        var descriptors: [AudioOutputDeviceDescriptor] = []
        for deviceID in ids where outputChannelCount(deviceID: deviceID) > 0 {
            guard let uid = coreAudioString(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID),
                !uid.isEmpty
            else { continue }
            let name = coreAudioString(objectID: deviceID, selector: kAudioObjectPropertyName) ?? uid
            descriptors.append(AudioOutputDeviceDescriptor(id: uid, name: name, isDefault: deviceID == defaultID))
        }
        return descriptors.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func outputChannelCount(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteSize) == noErr,
            byteSize >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteSize, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func coreAudioString(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }

    static func availableAudioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    static let frameRateMatchTolerance = 0.002

    static func supports(
        duration: CMTime, in ranges: [(minFPS: Double, maxFPS: Double, minDuration: CMTime, maxDuration: CMTime)]
    ) -> Bool {
        guard duration.isNumeric, duration.seconds > 0 else { return false }
        let fps = 1 / duration.seconds
        guard fps.isFinite, fps > 0, fps <= 60.01 else { return false }
        return ranges.contains { range in
            (range.minDuration.isNumeric && range.maxDuration.isNumeric
                && CMTimeCompare(duration, range.minDuration) >= 0 && CMTimeCompare(duration, range.maxDuration) <= 0)
                || (fps >= range.minFPS - frameRateMatchTolerance && fps <= range.maxFPS + frameRateMatchTolerance)
        }
    }

    func devices() -> [CaptureDeviceDescriptor] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.map { device in
                var choices: [CaptureFormatDescriptor] = []
                for (index, format) in device.formats.enumerated() {
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    guard dimensions.width > 0, dimensions.height > 0,
                        dimensions.width <= 3840, dimensions.height <= 2160
                    else { continue }
                    let size = VideoSize(width: Int(dimensions.width), height: Int(dimensions.height))
                    let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    let ranges = format.videoSupportedFrameRateRanges.map {
                        (
                            minFPS: $0.minFrameRate, maxFPS: $0.maxFrameRate,
                            minDuration: $0.minFrameDuration, maxDuration: $0.maxFrameDuration
                        )
                    }
                    // Prefer the driver's exact discrete durations before standard candidates for continuous ranges.
                    var durations: [CMTime] = []
                    for range in format.videoSupportedFrameRateRanges where range.maxFrameRate <= 60.01 {
                        durations.append(range.minFrameDuration)
                    }
                    durations.append(contentsOf: [
                        CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 60),
                        CMTime(value: 1001, timescale: 30000), CMTime(value: 1001, timescale: 60000),
                    ])
                    for duration in durations {
                        guard Self.supports(duration: duration, in: ranges) else { continue }
                        let id = "\(index):\(duration.value):\(duration.timescale)"
                        if !choices.contains(where: {
                            $0.index == index && abs($0.duration.seconds - duration.seconds) < 0.000001
                        }) {
                            choices.append(
                                CaptureFormatDescriptor(
                                    id: id, index: index, size: size, subtype: subtype, duration: duration))
                        }
                    }
                }
                return CaptureDeviceDescriptor(
                    id: device.uniqueID, name: device.localizedName, formats: choices,
                    hasBuiltInAudio: device.hasMediaType(.audio))
            }
    }
}

actor AVFoundationCaptureSource: VideoCaptureSource {
    /// Four-slot bounded ingress absorbs a 2-to-3 frame UVC micro-burst (0.02–1.1 ms apart under 4K HDR)
    /// or a single ~16.8 ms processing overlap without overwriting newly arrived frames, while keeping
    /// backpressure strictly bounded.
    static let streamBufferCapacity = 4

    private let deviceID: String
    private let format: CaptureFormatDescriptor
    private let mailbox: FrameMailbox
    private let generation: UUID
    private let audioEnabled: Bool
    private let audioDeviceID: String
    private let colorMode: InputColorMode
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.eliosxie.PlayGlide.capture.samples", qos: .userInteractive)
    private var delegate: CaptureDelegate?
    private let audioQueue = DispatchQueue(label: "com.eliosxie.PlayGlide.capture.audio", qos: .userInteractive)
    private var audioDelegate: CaptureAudioDelegate?
    private var audioMonitor: CaptureAudioMonitor?
    private var activeDevice: AVCaptureDevice?
    private var observedDeviceIDs: Set<String> = []
    private var recoveryPolicy = CaptureSessionRecoveryPolicy()
    private var recoveryTask: Task<Void, Never>?
    private var stopRequested = false
    private var continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation?
    private var observations: [any NSObjectProtocol] = []

    init(
        deviceID: String, format: CaptureFormatDescriptor, mailbox: FrameMailbox, generation: UUID,
        audioEnabled: Bool = false, audioDeviceID: String = "", colorMode: InputColorMode = .sdrRec709
    ) {
        self.deviceID = deviceID
        self.format = format
        self.mailbox = mailbox
        self.generation = generation
        self.audioEnabled = audioEnabled
        self.audioDeviceID = audioDeviceID
        self.colorMode = colorMode
    }

    func start() async throws -> AsyncThrowingStream<VideoFrame, Error> {
        guard continuation == nil, !stopRequested else {
            throw PipelineError(AppText("采集已经启动或已停止", "Capture has already started or stopped."))
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard authorized else {
            throw PipelineError(
                AppText(
                    "相机权限未允许；请在系统设置 → 隐私与安全性 → 相机中允许 PlayGlide",
                    "Allow PlayGlide to use the camera in System Settings → Privacy & Security → Camera."))
        }
        try Task.checkCancellation()
        guard !stopRequested else { throw CancellationError() }
        guard
            let device = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: .video,
                position: .unspecified
            ).devices.first(where: { $0.uniqueID == deviceID })
        else {
            throw PipelineError(
                AppText("所选外接视频设备已断开，请刷新设备列表", "The selected video device disconnected. Refresh the device list."))
        }
        guard !device.isInUseByAnotherApplication else {
            throw PipelineError(AppText("采集设备正被其他应用占用", "Another app is using the capture device."))
        }
        guard device.formats.indices.contains(format.index) else {
            throw PipelineError(
                AppText("设备格式已变化，请刷新并重新选择", "The device formats changed. Refresh and select a format again."))
        }
        let selected = device.formats[format.index]
        let dimensions = CMVideoFormatDescriptionGetDimensions(selected.formatDescription)
        guard Int(dimensions.width) == format.size.width, Int(dimensions.height) == format.size.height,
            CMFormatDescriptionGetMediaSubType(selected.formatDescription) == format.subtype
        else {
            throw PipelineError(
                AppText("所选格式与设备当前能力不一致，请刷新格式", "The selected format is unavailable. Refresh the format list."))
        }
        let ranges = selected.videoSupportedFrameRateRanges.map {
            (
                minFPS: $0.minFrameRate, maxFPS: $0.maxFrameRate,
                minDuration: $0.minFrameDuration, maxDuration: $0.maxFrameDuration
            )
        }
        guard CaptureCatalog.supports(duration: format.duration, in: ranges)
        else { throw PipelineError(AppText("设备不支持所选帧时长", "The device does not support the selected frame duration.")) }
        var selectedAudioDevice: AVCaptureDevice?
        if audioEnabled {
            let audioDevice: AVCaptureDevice
            if audioDeviceID.isEmpty || audioDeviceID == deviceID {
                guard device.hasMediaType(.audio) else {
                    throw PipelineError(
                        AppText(
                            "所选视频设备没有音频端口；请在音频输入中选择采集卡对应的 HDMI 音频设备",
                            "The selected video device has no audio port. Choose the capture card's HDMI audio device under Audio Input."
                        ))
                }
                audioDevice = device
            } else {
                guard
                    let selectedAudio = CaptureCatalog.availableAudioDevices().first(where: {
                        $0.uniqueID == audioDeviceID
                    })
                else {
                    throw PipelineError(
                        AppText(
                            "所选音频设备已断开，请刷新并重新选择采集卡音频输入",
                            "The audio device disconnected. Refresh and select the capture audio input again."))
                }
                audioDevice = selectedAudio
            }
            guard !audioDevice.isInUseByAnotherApplication else {
                throw PipelineError(AppText("采集卡音频设备正被其他应用占用", "Another app is using the capture-card audio device."))
            }
            let audioAuthorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: audioAuthorized = true
            case .notDetermined: audioAuthorized = await AVCaptureDevice.requestAccess(for: .audio)
            default: audioAuthorized = false
            }
            guard audioAuthorized else {
                throw PipelineError(
                    AppText(
                        "音频权限未允许；请在系统设置 → 隐私与安全性 → 麦克风中允许 PlayGlide，或关闭采集卡音频",
                        "Allow PlayGlide to use the microphone in System Settings → Privacy & Security → Microphone, or turn off capture audio."
                    ))
            }
            try Task.checkCancellation()
            guard !stopRequested else { throw CancellationError() }
            selectedAudioDevice = audioDevice
        }
        guard !stopRequested else { throw CancellationError() }
        // Construct inputs only after all requested permissions have been granted.
        let input = try AVCaptureDeviceInput(device: device)
        let audioInput: AVCaptureDeviceInput?
        if let selectedAudioDevice {
            if selectedAudioDevice.uniqueID == deviceID {
                audioInput = input
            } else {
                audioInput = try AVCaptureDeviceInput(device: selectedAudioDevice)
            }
        } else {
            audioInput = nil
        }
        let output = AVCaptureVideoDataOutput()
        let pair = AsyncThrowingStream<VideoFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.streamBufferCapacity))
        continuation = pair.continuation
        let sink = CaptureDelegate(
            continuation: pair.continuation, format: format, mailbox: mailbox, generation: generation,
            colorMode: colorMode)
        delegate = sink
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw PipelineError(AppText("无法连接视频输入", "Could not connect the video input."))
        }
        session.addInput(input)
        device.activeFormat = selected
        device.activeVideoMinFrameDuration = format.duration
        device.activeVideoMaxFrameDuration = format.duration
        if selected.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
        // UVC capture cards (e.g. Elgato 4K X under 4K HDR) deliver 2-to-3 frame micro-bursts 0.02–1.1 ms
        // apart while copyPlanes runs for ~0.55 ms; letting AVCaptureVideoDataOutput discard "late" callbacks
        // drops 10% of valid frames. Bounded queuing is enforced by AsyncThrowingStream(.bufferingNewest(4)).
        output.alwaysDiscardsLateVideoFrames =
            ProcessInfo.processInfo.environment["PLAYGLIDE_DISCARD_LATE_UVC"] == "1"
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw PipelineError(AppText("无法创建逐帧视频输出", "Could not create the frame-by-frame video output."))
        }
        session.addOutput(output)
        let preferred = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let pixelFormat: OSType
        if output.availableVideoPixelFormatTypes.contains(preferred) {
            pixelFormat = preferred
        } else if output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
            pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            session.commitConfiguration()
            throw PipelineError(
                AppText("设备无法输出第一版支持的 SDR YUV/BGRA 格式", "The device could not output a supported YUV or BGRA format."))
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        output.setSampleBufferDelegate(sink, queue: queue)
        observedDeviceIDs = [deviceID]
        if let audioInput {
            if audioInput !== input {
                guard session.canAddInput(audioInput) else {
                    session.commitConfiguration()
                    throw PipelineError(
                        AppText(
                            "无法将所选音频输入加入同一采集会话", "Could not add the selected audio input to the video capture session.")
                    )
                }
                session.addInput(audioInput)
            }
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            guard session.canAddOutput(audioOutput) else {
                session.commitConfiguration()
                throw PipelineError(AppText("无法创建采集卡音频输出", "Could not create capture-card audio output."))
            }
            // Explicit ports prevent a multiplexed video device from stealing a separately selected audio input.
            session.addOutputWithNoConnections(audioOutput)
            let ports = audioInput.ports.filter { $0.mediaType == .audio }
            guard !ports.isEmpty else {
                session.commitConfiguration()
                throw PipelineError(AppText("所选音频输入没有可用音频端口", "The selected audio input has no available audio port."))
            }
            let connection = AVCaptureConnection(inputPorts: ports, output: audioOutput)
            guard session.canAddConnection(connection) else {
                session.commitConfiguration()
                throw PipelineError(
                    AppText("驱动无法在当前视频格式下同时提供音频", "The driver could not provide audio with the selected video format."))
            }
            session.addConnection(connection)
            let monitor = CaptureAudioMonitor(
                mailbox: mailbox, generation: generation,
                failure: { pair.continuation.finish(throwing: PipelineError($0)) })
            let audioSink = CaptureAudioDelegate(monitor: monitor)
            audioMonitor = monitor
            audioDelegate = audioSink
            audioOutput.setSampleBufferDelegate(audioSink, queue: audioQueue)
            monitor.start(on: audioQueue)
            observedDeviceIDs.insert(audioInput.device.uniqueID)
        }
        session.commitConfiguration()
        activeDevice = device
        installObservations()
        try Task.checkCancellation()
        // Keep the configuration lock through startRunning on macOS; never execute this on MainActor.
        session.startRunning()
        guard session.isRunning else {
            throw PipelineError(
                AppText(
                    "设备无法启动，可能被占用或驱动不可用",
                    "The device could not start. It may be in use, or its driver may be unavailable."))
        }
        let actual = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard actual.width == dimensions.width, actual.height == dimensions.height,
            abs(device.activeVideoMinFrameDuration.seconds - format.duration.seconds) < 0.00001
        else {
            throw PipelineError(
                AppText(
                    "驱动替换了所选输入格式，已停止采集；请重新选择真实可用格式",
                    "The driver substituted the selected format. Select an available format and start capture again."))
        }
        return pair.stream
    }

    private func installObservations() {
        let ids = observedDeviceIDs
        observations.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil, queue: nil
            ) { [weak self] notification in
                guard let id = (notification.object as? AVCaptureDevice)?.uniqueID, ids.contains(id) else { return }
                Task {
                    await self?.fail(
                        AppText("采集卡已断开，请重新连接后刷新设备", "The capture card disconnected. Reconnect it and refresh devices.")
                    )
                }
            })
        observations.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session, queue: nil
            ) { [weak self] notification in
                let detail =
                    (notification.userInfo?[AVCaptureSessionErrorKey] as? Error).map { AppText(error: $0) }
                    ?? AppText("未知采集错误", "Unknown capture error")
                Task { await self?.handleRuntimeError(detail) }
            })
    }

    private func handleRuntimeError(_ detail: AppText) {
        guard !stopRequested, continuation != nil else { return }
        guard recoveryTask == nil else { return }
        let connected = activeDevice?.isConnected ?? false
        guard let delayMs = recoveryPolicy.nextDelayMilliseconds(at: mediaHostTime(), deviceConnected: connected) else {
            fail(AppText("采集会话错误：\(detail.chinese)", "Capture session error: \(detail.english)"))
            return
        }
        mailbox.flush(generation)
        mailbox.mutate(generation) {
            $0.signalWarning = AppText("HDMI 信号异常，正在自动恢复…", "HDMI signal interrupted. Trying to recover…")
        }
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            await self?.attemptSessionRecovery(detail)
        }
    }

    private func attemptSessionRecovery(_ detail: AppText) {
        recoveryTask = nil
        guard !stopRequested, continuation != nil else { return }
        guard activeDevice?.isConnected == true else {
            fail(AppText("采集卡已断开，请重新连接后刷新设备", "The capture card disconnected. Reconnect it and refresh devices."))
            return
        }
        // runtimeErrorNotification can fire while session.isRunning still reports true;
        // stop first so CMIOGraph tears down the stalled stream before restarting.
        if session.isRunning {
            session.stopRunning()
        }
        session.startRunning()
        if session.isRunning {
            mailbox.mutate(generation) { $0.captureRecoveries += 1 }
        } else {
            handleRuntimeError(detail)
        }
    }

    private func fail(_ message: AppText) {
        recoveryTask?.cancel()
        recoveryTask = nil
        continuation?.finish(throwing: PipelineError(message))
    }

    func stop() async {
        stopRequested = true
        recoveryTask?.cancel()
        recoveryTask = nil
        audioMonitor?.stop()
        continuation?.finish()
        continuation = nil
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
        observations.removeAll()
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
        }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        // Drain the serial callback queue before releasing its actor-owned delegate/converter.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await withCheckedContinuation { continuation in audioQueue.async { continuation.resume() } }
        activeDevice = nil
        delegate = nil
        audioDelegate = nil
        audioMonitor = nil
    }
}

/// AVFoundation invokes these methods on exactly one configured serial queue.
private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation
    let format: CaptureFormatDescriptor
    let mailbox: FrameMailbox
    let generation: UUID
    let colorMode: InputColorMode
    private let ingest: CaptureFrameIngest
    private var gate = CaptureSampleGate()
    private var sequence: Int64 = 0
    private var activeWarning: AppText?

    init(
        continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation, format: CaptureFormatDescriptor,
        mailbox: FrameMailbox, generation: UUID, colorMode: InputColorMode = .sdrRec709
    ) {
        self.continuation = continuation
        self.format = format
        self.mailbox = mailbox
        self.generation = generation
        self.colorMode = colorMode
        self.ingest = CaptureFrameIngest(colorMode: colorMode)
    }
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        let arrival = mediaHostTime()
        autoreleasepool {
            do {
                let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                let size = buffer.map {
                    VideoSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
                }
                let transfer = buffer.flatMap {
                    CVBufferCopyAttachment($0, kCVImageBufferTransferFunctionKey, nil) as? String
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let decision = gate.evaluate(
                    hasImage: buffer != nil, size: size, transferFunction: transfer, timestampValid: time.isNumeric,
                    allowsHDR: colorMode != .sdrRec709)
                switch decision {
                case .dropTransient(let hdr, let warning):
                    sequence += 1
                    let warningChanged = warning != nil && activeWarning != warning
                    if let warning { activeWarning = warning }
                    mailbox.mutate(generation) {
                        $0.ingressDropped += 1
                        if hdr { $0.hdrFramesSkipped += 1 }
                        if warningChanged { $0.signalWarning = warning }
                    }
                    return
                case .accept(let rehandshaked):
                    guard let buffer else { return }
                    let rawDuration = CMSampleBufferGetDuration(sampleBuffer)
                    let duration = rawDuration.isNumeric && rawDuration.seconds > 0 ? rawDuration : format.duration
                    // Establish an owned immutable boundary; capture-pool aliases never cross executors.
                    // A matching SDR Rec.709 surface is copied plane by plane instead of a GPU round trip.
                    let owned = try ingest.ingest(buffer)
                    let frame = VideoFrame(
                        pixelBuffer: owned.pixelBuffer, presentationTime: time, duration: duration,
                        sequence: sequence, arrivalTime: arrival)
                    sequence += 1
                    activeWarning = nil
                    mailbox.recordCaptureIngest(
                        copied: owned.copied, seconds: mediaHostTime() - arrival,
                        surface: owned.changedDescription?.summary, rehandshaked: rehandshaked,
                        detectedHDR10: owned.isHDR10PQ, generation: generation)
                    mailbox.capture(frame, generation: generation)
                    switch continuation.yield(frame) {
                    case .dropped(let dropped): mailbox.recordInputOverwrite(dropped, generation: generation)
                    case .terminated: break
                    case .enqueued: break
                    @unknown default: break
                    }
                }
            } catch let error as CVError where error == .wouldExceedAllocationThreshold {
                sequence += 1
                mailbox.mutate(generation) { $0.ingressDropped += 1 }
            } catch { continuation.finish(throwing: error) }
        }
    }
    func captureOutput(
        _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        sequence += 1
        mailbox.mutate(generation) { $0.ingressDropped += 1 }
    }
}

private final class CaptureAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    let monitor: CaptureAudioMonitor

    init(monitor: CaptureAudioMonitor) { self.monitor = monitor }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        monitor.receive(sampleBuffer)
    }
}

/// The lock owns all mutable audio state. Only app-owned, read-only PCM enters the queue.
/// A bounded timer feeds up to 80 ms ahead plus one packet; backpressure cannot grow a task queue.
final class CaptureAudioMonitor: Sendable {
    /// Pump newly received capture audio packets immediately under the same lock instead of waiting
    /// up to 5 ms for the periodic timer (`PLAYGLIDE_AUDIO_IMMEDIATE_PUMP=1` or `PLAYGLIDE_FAST_PASSTHROUGH=1`).
    static var immediatePumpEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_AUDIO_IMMEDIATE_PUMP"] == "1"
            || PresentationMode.fastPassthroughEnabled
    }

    private struct PCM: Sendable {
        let data: CMReadOnlyDataBlockBuffer
        let format: CMFormatDescription
        let sampleCount: Int

        func enqueue(to output: any CaptureAudioPlayback, at pts: CMTime) -> Bool {
            data.withUnsafeBlockBuffer { data in
                var buffer: CMSampleBuffer?
                guard
                    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                        allocator: nil, dataBuffer: data, formatDescription: format, sampleCount: sampleCount,
                        presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &buffer
                    ) == noErr, let buffer
                else { return false }
                output.enqueue(buffer)
                return true
            }
        }
    }

    private struct PublishedAudioTelemetry: Equatable {
        let status: AppText
        let rate: Float
        let muted: Bool
        let volume: Float
        let offsetMilliseconds: Double
    }

    private struct State {
        var active = false
        var playback: (any CaptureAudioPlayback)?
        var timer: (any DispatchSourceTimer)?
        var buffers = AudioBufferQueue<PCM>()
        var controller = AudioSyncController()
        var alignmentWaitStartedAt: Double?
        var nextSequence: Int64 = 0
        var lastReceived: Double = 0
        var sampleRate: Double = 0
        var channels: UInt32 = 0
        var appliedGain: (volume: Float, muted: Bool)?
        var appliedOutputRequested: String?
        var appliedOutputUID: String?
        var lastOutputRouteCheck: Double = 0
        var lastTelemetry: PublishedAudioTelemetry?
        var lastTelemetryError: Double?
        var lastTelemetryTime: Double = 0
    }
    private let state = Mutex(State())
    private let mailbox: FrameMailbox
    private let generation: UUID
    private let failure: @Sendable (AppText) -> Void
    private let makePlayback: @Sendable () -> any CaptureAudioPlayback
    private let resolveOutputDevice: @Sendable (String) -> String?
    private let hostTime: @Sendable () -> Double
    private let immediatePump: Bool

    init(
        mailbox: FrameMailbox, generation: UUID,
        makePlayback: @escaping @Sendable () -> any CaptureAudioPlayback = { SampleBufferAudioPlayback() },
        resolveOutputDevice: @escaping @Sendable (String) -> String? = { requested in
            AudioOutputRouteResolver.resolvedDeviceUID(
                requested: requested, available: CaptureCatalog.availableAudioOutputDevices())
        },
        hostTime: @escaping @Sendable () -> Double = { mediaHostTime() },
        immediatePump: Bool = CaptureAudioMonitor.immediatePumpEnabled,
        failure: @escaping @Sendable (AppText) -> Void
    ) {
        self.mailbox = mailbox
        self.generation = generation
        self.failure = failure
        self.makePlayback = makePlayback
        self.resolveOutputDevice = resolveOutputDevice
        self.hostTime = hostTime
        self.immediatePump = immediatePump
    }

    func start(on queue: DispatchQueue? = nil) {
        let controls = mailbox.audioControls()
        let requestedOutput = controls.normalizedOutputDeviceID
        let resolvedOutput = resolveOutputDevice(requestedOutput)
        let startedAt = hostTime()
        state.withLock {
            guard !$0.active else { return }
            let output = makePlayback()
            let gain = (volume: controls.clampedVolume, muted: controls.muted)
            output.setOutputDevice(uniqueID: resolvedOutput)
            output.setGain(volume: gain.volume, muted: gain.muted)
            $0.appliedGain = gain
            $0.appliedOutputRequested = requestedOutput
            $0.appliedOutputUID = resolvedOutput
            $0.lastOutputRouteCheck = startedAt
            $0.playback = output
            $0.active = true
            if let queue {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.pump() }
                $0.timer = timer
                timer.resume()
            }
        }
        mailbox.mutate(generation) {
            $0.audioStatus = AppText("等待音频与视频呈现", "Waiting for audio and video")
            $0.audioMuted = controls.muted
            $0.audioVolume = controls.clampedVolume
            $0.audioOffsetMilliseconds = controls.clampedOffsetMilliseconds
        }
    }

    func receive(_ buffer: CMSampleBuffer) {
        let controls = immediatePump ? mailbox.audioControls() : nil
        state.withLock {
            guard $0.active else { return }
            guard CMSampleBufferDataIsReady(buffer),
                let format = CMSampleBufferGetFormatDescription(buffer),
                let audio = format.audioStreamBasicDescription
            else {
                // Transient empty/unready audio packets during HDMI handshake must not kill video.
                resetPlayback(&$0, clearBuffers: false)
                mailbox.mutate(generation) {
                    $0.audioDropped += 1
                    $0.audioStatus = AppText("等待音频重同步", "Waiting to resync audio")
                }
                return
            }
            guard audio.mFormatID == kAudioFormatLinearPCM,
                audio.mSampleRate.isFinite, audio.mSampleRate >= 8_000, audio.mSampleRate <= 192_000,
                audio.mChannelsPerFrame > 0, audio.mChannelsPerFrame <= 8
            else {
                fail(
                    AppText(
                        "采集卡音频必须为 8–192 kHz、最多 8 声道的 PCM", "Capture audio must be 8–192 kHz PCM with up to 8 channels."),
                    state: &$0)
                return
            }
            let changed =
                $0.sampleRate != 0
                && ($0.sampleRate != audio.mSampleRate || $0.channels != audio.mChannelsPerFrame)
            if changed { resetPlayback(&$0, clearBuffers: true) }
            $0.sampleRate = audio.mSampleRate
            $0.channels = audio.mChannelsPerFrame
            // PCM sample count is authoritative, including drivers which omit the buffer duration.
            let sampleCount = CMSampleBufferGetNumSamples(buffer)
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let duration = CMTime(
                value: Int64(sampleCount), timescale: Int32(audio.mSampleRate.rounded()))
            guard pts.isNumeric, pts.seconds >= 0, sampleCount > 0, duration.seconds <= 0.1 else {
                resetPlayback(&$0, clearBuffers: false)
                mailbox.mutate(generation) {
                    $0.audioDropped += 1
                    $0.audioStatus = AppText("等待音频重同步", "Waiting to resync audio")
                }
                return
            }
            guard let data = Self.copyPCM(buffer) else {
                resetPlayback(&$0, clearBuffers: false)
                mailbox.mutate(generation) {
                    $0.audioDropped += 1
                    $0.audioStatus = AppText("等待音频重同步", "Waiting to resync audio")
                }
                return
            }
            let result = $0.buffers.append(
                time: pts, duration: duration, payload: PCM(data: data, format: format, sampleCount: sampleCount))
            if result.reset { resetPlayback(&$0, clearBuffers: false) }
            $0.lastReceived = hostTime()
            mailbox.mutate(generation) {
                $0.audioReceived += 1
                $0.audioDropped += result.dropped
                $0.audioFormat = AppText(
                    "\(Int(audio.mSampleRate)) Hz · \(audio.mChannelsPerFrame) 声道 PCM",
                    "\(Int(audio.mSampleRate)) Hz · \(audio.mChannelsPerFrame)-channel PCM")
            }
            if let controls {
                pumpLocked(&$0, controls: controls)
            }
        }
    }

    private static func copyPCM(_ buffer: CMSampleBuffer) -> CMReadOnlyDataBlockBuffer? {
        guard let source = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let length = CMBlockBufferGetDataLength(source)
        guard length > 0, length <= 1_048_576 else { return nil }
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            guard let destination = bytes.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(source, atOffset: 0, dataLength: length, destination: destination)
                == noErr
        }
        return copied ? CMReadOnlyDataBlockBuffer(data) : nil
    }

    func pump() {
        let controls = mailbox.audioControls()
        state.withLock {
            pumpLocked(&$0, controls: controls)
        }
    }

    private func pumpLocked(_ state: inout State, controls: AudioPlaybackControls) {
        guard state.active, var output = state.playback else { return }
        let now = hostTime()
        let gain = (volume: controls.clampedVolume, muted: controls.muted)
        if state.appliedGain?.volume != gain.volume || state.appliedGain?.muted != gain.muted {
            output.setGain(volume: gain.volume, muted: gain.muted)
            state.appliedGain = gain
        }
        let requestedOutput = controls.normalizedOutputDeviceID
        let flushed = output.consumeAutomaticFlush()
        let shouldCheckRoute =
            flushed || state.appliedOutputRequested != requestedOutput
            || (!requestedOutput.isEmpty && now - state.lastOutputRouteCheck >= 1.0)
        if shouldCheckRoute {
            let resolvedOutput = resolveOutputDevice(requestedOutput)
            let routeChanged = resolvedOutput != state.appliedOutputUID
            state.appliedOutputRequested = requestedOutput
            state.lastOutputRouteCheck = now
            if routeChanged {
                output.setOutputDevice(uniqueID: resolvedOutput)
                state.appliedOutputUID = resolvedOutput
            }
            if flushed || (routeChanged && state.controller.rate > 0) {
                resetPlayback(&state, clearBuffers: false)
            }
        }
        if let error = output.failure {
            if state.appliedOutputUID != nil {
                // Dedicated output device failed or unplugged: recreate playback on system default.
                resetPlayback(&state, clearBuffers: false)
                let fallback = makePlayback()
                fallback.setOutputDevice(uniqueID: nil)
                fallback.setGain(volume: gain.volume, muted: gain.muted)
                state.playback = fallback
                state.appliedOutputUID = nil
                state.lastOutputRouteCheck = now
                output = fallback
            } else {
                fail(
                    AppText("音频播放失败：\(error.chinese)", "Audio playback failed: \(error.english)"),
                    state: &state)
                return
            }
        }
        let anchor = now - state.lastReceived <= 0.25 ? mailbox.audioReference(generation, now: now) : nil
        let offsetSeconds = controls.offsetSeconds
        let offsetTime = CMTime(seconds: offsetSeconds, preferredTimescale: 1_000_000_000)
        // Require a covered start point when aligning. Steady playback can use already enqueued PCM.
        let buffers = state.buffers
        let playback = output.currentTime
        // A proposed alignment becomes the active clock only after playback is scheduled.
        var controller = state.controller
        let action = controller.update(
            anchor: anchor, playbackTime: playback, now: now, offsetSeconds: offsetSeconds,
            canAlign: anchor.map {
                buffers.contains(CMTimeSubtract($0.mediaTime(at: now + AudioSyncController.startLead), offsetTime))
            } ?? false)
        var alignment: (CMTime, Double)?
        switch action {
        case .pause:
            resetPlayback(&state, clearBuffers: false)
        case .align(let time, let hostTime):
            if state.controller.rate > 0 { resetPlayback(&state, clearBuffers: false) }
            state.nextSequence = state.buffers.entries.first?.sequence ?? 0
            alignment = (time, hostTime)
        case .rate(let rate):
            // Anchor rate slews to the current (media, host) pair; passing invalid times stalls
            // AVSampleBufferRenderSynchronizer's timebase by ~21 ms per call on macOS (R8).
            if playback.isNumeric {
                output.setRate(
                    rate, time: playback,
                    hostTime: CMTime(seconds: now, preferredTimescale: 1_000_000_000))
            } else {
                output.setRate(rate, time: .invalid, hostTime: .invalid)
            }
        case .none: break
        }
        let fastPath = FrameMailbox.fastPathEnabled
        guard let anchor, controller.rate > 0 else {
            state.controller = controller
            if state.alignmentWaitStartedAt != nil { finishAlignmentWait(&state, at: now, failed: true) }
            let telemetry = PublishedAudioTelemetry(
                status: AppText("等待音频与视频呈现", "Waiting for audio and video"), rate: 0, muted: controls.muted,
                volume: controls.clampedVolume, offsetMilliseconds: controls.clampedOffsetMilliseconds)
            if !fastPath || state.lastTelemetry != telemetry || state.lastTelemetryError != nil
                || now - state.lastTelemetryTime >= 0.05
            {
                state.lastTelemetry = telemetry
                state.lastTelemetryError = nil
                state.lastTelemetryTime = now
                mailbox.mutate(generation) {
                    $0.audioStatus = telemetry.status
                    $0.audioRate = telemetry.rate
                    $0.audioSyncErrorMilliseconds = nil
                    $0.audioMuted = telemetry.muted
                    $0.audioVolume = telemetry.volume
                    $0.audioOffsetMilliseconds = telemetry.offsetMilliseconds
                }
            }
            return
        }
        let start = alignment?.0 ?? playback
        let horizon = CMTimeSubtract(anchor.mediaTime(at: max(now, hostTime()) + 0.08), offsetTime)
        var enqueuedCount = 0
        for entry in state.buffers.entries where entry.sequence >= state.nextSequence {
            if CMTimeCompare(entry.end, start) <= 0 {
                state.nextSequence = entry.sequence + 1
                continue
            }
            guard CMTimeCompare(entry.time, horizon) <= 0, output.isReady else { break }
            guard entry.payload.enqueue(to: output, at: entry.time) else {
                fail(
                    AppText("无法构建采集卡音频播放缓冲", "Could not create the capture audio playback buffer."),
                    state: &state, aligning: alignment != nil)
                return
            }
            enqueuedCount += 1
            state.nextSequence = entry.sequence + 1
        }
        if let (time, hostTime) = alignment {
            guard enqueuedCount > 0 else {
                let started = state.alignmentWaitStartedAt ?? now
                state.alignmentWaitStartedAt = started
                let telemetry = PublishedAudioTelemetry(
                    status: AppText("等待音频输出", "Waiting for audio output"), rate: 0, muted: controls.muted,
                    volume: controls.clampedVolume, offsetMilliseconds: controls.clampedOffsetMilliseconds)
                state.lastTelemetry = telemetry
                state.lastTelemetryError = nil
                state.lastTelemetryTime = now
                mailbox.mutate(generation) {
                    $0.audioStatus = telemetry.status
                    $0.audioRate = telemetry.rate
                    $0.audioSyncErrorMilliseconds = nil
                    $0.audioAlignmentWaitMilliseconds = (now - started) * 1000
                    $0.audioMuted = telemetry.muted
                    $0.audioVolume = telemetry.volume
                    $0.audioOffsetMilliseconds = telemetry.offsetMilliseconds
                }
                return
            }
            if let error = output.failure {
                fail(
                    AppText("音频播放失败：\(error.chinese)", "Audio playback failed: \(error.english)"),
                    state: &state, aligning: true)
                return
            }
            output.setRate(1, time: time, hostTime: CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000))
            finishAlignmentWait(&state, at: now)
        }
        state.controller = controller
        let status =
            controls.muted
            ? AppText("按视频呈现同步播放（已静音）", "Synced to video (muted)") : AppText("按视频呈现同步播放", "Synced to video")
        let telemetry = PublishedAudioTelemetry(
            status: status, rate: controller.rate, muted: controls.muted,
            volume: controls.clampedVolume, offsetMilliseconds: controls.clampedOffsetMilliseconds)
        let errorChanged: Bool
        switch (state.lastTelemetryError, controller.errorSeconds) {
        case (nil, nil): errorChanged = false
        case (let old?, let current?): errorChanged = abs(old - current) >= 0.0001
        default: errorChanged = true
        }
        if !fastPath || enqueuedCount > 0 || alignment != nil || state.lastTelemetry != telemetry
            || errorChanged || now - state.lastTelemetryTime >= 0.05
        {
            state.lastTelemetry = telemetry
            state.lastTelemetryError = controller.errorSeconds
            state.lastTelemetryTime = now
            mailbox.mutate(generation) {
                if enqueuedCount > 0 { $0.audioEnqueued += enqueuedCount }
                if alignment != nil { $0.audioResyncs += 1 }
                $0.audioStatus = telemetry.status
                $0.audioRate = telemetry.rate
                $0.audioSyncErrorMilliseconds = controller.errorSeconds.map { $0 * 1000 }
                $0.audioMuted = telemetry.muted
                $0.audioVolume = telemetry.volume
                $0.audioOffsetMilliseconds = telemetry.offsetMilliseconds
            }
        }
    }

    private func finishAlignmentWait(_ value: inout State, at now: Double, failed: Bool = false) {
        let started = value.alignmentWaitStartedAt
        value.alignmentWaitStartedAt = nil
        guard started != nil || failed else { return }
        mailbox.mutate(generation) {
            if let started { $0.audioAlignmentWaitMilliseconds = (now - started) * 1000 }
            if failed { $0.audioAlignmentFailures += 1 }
        }
    }

    private func resetPlayback(_ value: inout State, clearBuffers: Bool) {
        if value.alignmentWaitStartedAt != nil { finishAlignmentWait(&value, at: hostTime()) }
        value.playback?.setRate(0, time: .invalid, hostTime: .invalid)
        value.playback?.flush()
        value.controller = AudioSyncController()
        if clearBuffers { value.buffers.removeAll() }
        value.nextSequence = value.buffers.entries.first?.sequence ?? 0
    }

    private func fail(_ message: AppText, state value: inout State, aligning: Bool = false) {
        if aligning || value.alignmentWaitStartedAt != nil {
            finishAlignmentWait(&value, at: hostTime(), failed: true)
        }
        resetPlayback(&value, clearBuffers: true)
        value.active = false
        value.timer?.cancel()
        mailbox.mutate(generation) {
            $0.audioStatus = message
            $0.audioRate = 0
            $0.audioSyncErrorMilliseconds = nil
        }
        failure(message)
    }

    func stop() {
        state.withLock {
            $0.active = false
            $0.timer?.cancel()
            $0.timer = nil
            resetPlayback(&$0, clearBuffers: true)
            $0.playback = nil
        }
        mailbox.mutate(generation) {
            $0.audioStatus = AppText("已停止", "Stopped")
            $0.audioRate = 0
        }
    }
}

/// Kept behind an injectable boundary so synchronization tests never open an audio output device.
protocol CaptureAudioPlayback: AnyObject {
    var currentTime: CMTime { get }
    var isReady: Bool { get }
    var failure: AppText? { get }
    func setRate(_ rate: Float, time: CMTime, hostTime: CMTime)
    func setGain(volume: Float, muted: Bool)
    func setOutputDevice(uniqueID: String?)
    func consumeAutomaticFlush() -> Bool
    func enqueue(_ buffer: CMSampleBuffer)
    func flush()
}

final class SampleBufferAudioPlayback: CaptureAudioPlayback {
    private final class FlushFlag: Sendable {
        let value = Mutex(false)
    }
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let flushedAutomatically = FlushFlag()
    private var flushObserver: (any NSObjectProtocol)?

    init() {
        synchronizer.addRenderer(renderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        renderer.audioTimePitchAlgorithm = .varispeed
        let flag = flushedAutomatically
        flushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil
        ) { _ in
            flag.value.withLock { $0 = true }
        }
    }

    deinit {
        if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
    }

    var currentTime: CMTime { synchronizer.currentTime() }
    var isReady: Bool { renderer.isReadyForMoreMediaData }
    var failure: AppText? {
        renderer.status == .failed
            ? renderer.error.map { AppText(error: $0) } ?? AppText("系统音频输出不可用", "System audio output is unavailable.")
            : nil
    }
    func setRate(_ rate: Float, time: CMTime, hostTime: CMTime) {
        synchronizer.setRate(rate, time: time, atHostTime: hostTime)
    }
    func setGain(volume: Float, muted: Bool) {
        let clamped = volume.isFinite ? min(1, max(0, volume)) : 1
        if renderer.volume != clamped { renderer.volume = clamped }
        if renderer.isMuted != muted { renderer.isMuted = muted }
    }
    func setOutputDevice(uniqueID: String?) {
        if renderer.audioOutputDeviceUniqueID != uniqueID {
            renderer.audioOutputDeviceUniqueID = uniqueID
        }
    }
    func consumeAutomaticFlush() -> Bool {
        flushedAutomatically.value.withLock {
            let value = $0
            $0 = false
            return value
        }
    }
    func enqueue(_ buffer: CMSampleBuffer) { renderer.enqueue(buffer) }
    func flush() { renderer.flush() }
}
