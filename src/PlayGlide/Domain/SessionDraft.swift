import CoreMedia
import Foundation

enum BuildFeatures {
    #if PLAYGLIDE_DEVELOPMENT
        static let developmentTools = true
    #else
        static let developmentTools = false
    #endif
}

struct SessionDraft: Sendable, Equatable {
    var source: InputSource = .captureCard
    var deviceID = ""
    var formatID = ""
    var colorMode: InputColorMode = .sdrRec709
    var hdrDisplayStyle: HDRDisplayStyle = .defaultStyle
    var systemHDRPolicy: SystemHDRPolicy = .fullscreen
    var audioEnabled = false
    // Empty selects the chosen video device's own audio ports, never the default microphone.
    var audioDeviceID = ""
    var windowSelectionID: UUID?
    var windowSampling: WindowSamplingRate = .fps30
    var windowPreset: InputPreset = .qhd1440
    var windowResolution: WindowResolutionMode = .nativePixels
    var inputPreset: InputPreset = .hd1080
    var testSignal: TestSignal = .game30over60
    var contentMode: ContentMode = .automatic
    var interpolation: InterpolationStrategy = .double
    var backend: ProcessingBackend = .automatic
    var hybridQuality: HybridQuality = .hd1080
    var upscaling: UpscalingStrategy = .off
    var outputPreset: OutputPreset = .double
    var presentationMode: PresentationMode = .responsive
    var powerPreference: InterpolationPowerPreference = .lowLatency

    var isAvailableInBuild: Bool {
        BuildFeatures.developmentTools
            || (source == .captureCard && backend == .automatic
                && (interpolation == .off || interpolation == .double
                    || (interpolation == .triple && CaptureCatalog.allow120HzCaptureEnabled)))
    }

    var usesStableWindowCadence: Bool {
        source == .window && windowSampling == .automatic && contentMode == .automatic && interpolation == .double
            && ProcessInfo.processInfo.environment["PLAYGLIDE_WINDOW_CADENCE"] == "stable"
    }

    static var hotReconfigureEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HOT_RECONFIGURE"] != "0"
    }

    var preservesRepeatedTransportCadence: Bool {
        contentMode == .automatic && interpolation == .double && presentationMode == .responsive
            && (source == .captureCard || (source == .testPattern && testSignal.repeats == 2))
    }

    /// True when switching to `next` changes any setting relevant to the active input source.
    /// Background capture-card discovery updating `deviceID`/`formatID` while running a window
    /// or test-pattern session must not flag the running configuration as stale.
    func hasRelevantChanges(comparedTo other: SessionDraft) -> Bool {
        guard self != other else { return false }
        guard source == other.source else { return true }
        let processingDiffers =
            contentMode != other.contentMode || interpolation != other.interpolation
            || backend != other.backend || hybridQuality != other.hybridQuality
            || upscaling != other.upscaling || outputPreset != other.outputPreset
            || presentationMode != other.presentationMode || powerPreference != other.powerPreference
        if processingDiffers { return true }
        switch source {
        case .captureCard:
            return deviceID != other.deviceID || formatID != other.formatID
                || colorMode != other.colorMode || hdrDisplayStyle != other.hdrDisplayStyle
                || systemHDRPolicy != other.systemHDRPolicy || audioEnabled != other.audioEnabled
                || audioDeviceID != other.audioDeviceID
        case .window:
            return windowSelectionID != other.windowSelectionID || windowSampling != other.windowSampling
                || windowPreset != other.windowPreset || windowResolution != other.windowResolution
        case .testPattern:
            return inputPreset != other.inputPreset || testSignal != other.testSignal
        }
    }

    /// True when switching to `next` only changes processing/presentation parameters and can
    /// reconfigure `FrameProcessor` in place without restarting capture or HDMI audio.
    func canHotReconfigure(to next: SessionDraft, enabled: Bool = Self.hotReconfigureEnabled) -> Bool {
        guard enabled, hasRelevantChanges(comparedTo: next) else { return false }
        guard source == next.source else { return false }
        switch source {
        case .captureCard:
            return deviceID == next.deviceID && formatID == next.formatID
                && colorMode == next.colorMode && audioEnabled == next.audioEnabled
                && audioDeviceID == next.audioDeviceID
        case .window:
            return windowSelectionID == next.windowSelectionID && windowSampling == next.windowSampling
                && windowPreset == next.windowPreset && windowResolution == next.windowResolution
        case .testPattern:
            return inputPreset == next.inputPreset && testSignal == next.testSignal
        }
    }
}

struct AudioPlaybackControls: Sendable, Equatable, Codable {
    static let minOffsetMilliseconds = -40.0
    static let maxOffsetMilliseconds = 150.0

    var volume: Float = 1.0
    var muted = false
    /// Positive delays audio relative to video; negative advances audio within buffered headroom.
    var offsetMilliseconds: Double = 0.0
    /// CoreAudio output device UID; empty follows macOS system default output.
    var outputDeviceID = ""

    init(volume: Float = 1.0, muted: Bool = false, offsetMilliseconds: Double = 0.0, outputDeviceID: String = "") {
        self.volume = volume
        self.muted = muted
        self.offsetMilliseconds = offsetMilliseconds
        self.outputDeviceID = outputDeviceID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        offsetMilliseconds = try container.decodeIfPresent(Double.self, forKey: .offsetMilliseconds) ?? 0.0
        outputDeviceID = try container.decodeIfPresent(String.self, forKey: .outputDeviceID) ?? ""
    }

    var clampedVolume: Float {
        volume.isFinite ? min(1, max(0, volume)) : 1
    }
    var clampedOffsetMilliseconds: Double {
        offsetMilliseconds.isFinite
            ? min(Self.maxOffsetMilliseconds, max(Self.minOffsetMilliseconds, offsetMilliseconds)) : 0
    }
    var offsetSeconds: Double { clampedOffsetMilliseconds / 1000 }
    var normalizedOutputDeviceID: String { outputDeviceID.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct SessionPreferences: Sendable, Equatable, Codable {
    static let storageKey = "com.eliosxie.PlayGlide.sessionPreferences.v1"

    var source: InputSource = .captureCard
    var deviceID = ""
    var formatID = ""
    var colorMode: InputColorMode = .sdrRec709
    var hdrDisplayStyle: HDRDisplayStyle = .defaultStyle
    var systemHDRPolicy: SystemHDRPolicy = .fullscreen
    var audioEnabled = false
    var audioDeviceID = ""
    var contentMode: ContentMode = .automatic
    var interpolation: InterpolationStrategy = .double
    var backend: ProcessingBackend = .automatic
    var hybridQuality: HybridQuality = .hd1080
    var upscaling: UpscalingStrategy = .off
    var outputPreset: OutputPreset = .double
    var presentationMode: PresentationMode = .responsive
    var powerPreference: InterpolationPowerPreference = .lowLatency
    var audioControls = AudioPlaybackControls()

    init() {}

    init(draft: SessionDraft, audioControls: AudioPlaybackControls) {
        // Window sharing sessions do not persist across launches.
        source = draft.source == .window ? .captureCard : draft.source
        deviceID = draft.deviceID
        formatID = draft.formatID
        colorMode = draft.colorMode
        hdrDisplayStyle = draft.hdrDisplayStyle
        systemHDRPolicy = draft.systemHDRPolicy
        audioEnabled = draft.audioEnabled
        audioDeviceID = draft.audioDeviceID
        contentMode = draft.contentMode
        interpolation = draft.interpolation
        backend = draft.backend
        hybridQuality = draft.hybridQuality
        upscaling = draft.upscaling
        outputPreset = draft.outputPreset
        presentationMode = draft.presentationMode
        powerPreference = draft.powerPreference
        self.audioControls = AudioPlaybackControls(
            volume: audioControls.clampedVolume,
            muted: audioControls.muted,
            offsetMilliseconds: audioControls.clampedOffsetMilliseconds,
            outputDeviceID: audioControls.normalizedOutputDeviceID)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(InputSource.self, forKey: .source) ?? .captureCard
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        formatID = try container.decodeIfPresent(String.self, forKey: .formatID) ?? ""
        colorMode = try container.decodeIfPresent(InputColorMode.self, forKey: .colorMode) ?? .sdrRec709
        hdrDisplayStyle =
            try container.decodeIfPresent(HDRDisplayStyle.self, forKey: .hdrDisplayStyle)
            ?? HDRDisplayStyle.defaultStyle
        systemHDRPolicy =
            try container.decodeIfPresent(SystemHDRPolicy.self, forKey: .systemHDRPolicy) ?? .fullscreen
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? false
        audioDeviceID = try container.decodeIfPresent(String.self, forKey: .audioDeviceID) ?? ""
        contentMode = try container.decodeIfPresent(ContentMode.self, forKey: .contentMode) ?? .automatic
        interpolation = try container.decodeIfPresent(InterpolationStrategy.self, forKey: .interpolation) ?? .double
        backend = try container.decodeIfPresent(ProcessingBackend.self, forKey: .backend) ?? .automatic
        hybridQuality = try container.decodeIfPresent(HybridQuality.self, forKey: .hybridQuality) ?? .hd1080
        upscaling = try container.decodeIfPresent(UpscalingStrategy.self, forKey: .upscaling) ?? .off
        outputPreset = try container.decodeIfPresent(OutputPreset.self, forKey: .outputPreset) ?? .double
        presentationMode =
            try container.decodeIfPresent(PresentationMode.self, forKey: .presentationMode) ?? .responsive
        powerPreference =
            try container.decodeIfPresent(InterpolationPowerPreference.self, forKey: .powerPreference) ?? .lowLatency
        audioControls =
            try container.decodeIfPresent(AudioPlaybackControls.self, forKey: .audioControls)
            ?? AudioPlaybackControls()
    }

    func apply(to draft: inout SessionDraft) {
        draft.source = BuildFeatures.developmentTools && source != .window ? source : .captureCard
        draft.deviceID = deviceID
        draft.formatID = formatID
        draft.colorMode = colorMode
        draft.hdrDisplayStyle = hdrDisplayStyle
        draft.systemHDRPolicy = systemHDRPolicy
        draft.audioEnabled = audioEnabled
        draft.audioDeviceID = audioDeviceID
        draft.contentMode = contentMode
        let unsupportedMultiplier =
            !BuildFeatures.developmentTools
            && (interpolation == .quadruple
                || (interpolation == .triple && !CaptureCatalog.allow120HzCaptureEnabled))
        draft.interpolation = unsupportedMultiplier ? .double : interpolation
        draft.backend = BuildFeatures.developmentTools ? backend : .automatic
        draft.hybridQuality = hybridQuality
        draft.upscaling = upscaling
        draft.outputPreset = outputPreset
        draft.presentationMode = presentationMode
        draft.powerPreference = powerPreference
    }

    static func load(from defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func save(draft: SessionDraft, audioControls: AudioPlaybackControls, to defaults: UserDefaults) {
        let snapshot = Self(draft: draft, audioControls: audioControls)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

enum PresentationMode: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Lower 1× passthrough audio-video delay floor and enable late selection across 1×/4× modes
    /// (`PLAYGLIDE_FAST_PASSTHROUGH=0` opts out for A/B rollback).
    static var fastPassthroughEnabled: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_FAST_PASSTHROUGH"] != "0"
    }

    case responsive, steady
    var id: Self { self }
    var title: AppText { self == .responsive ? AppText("低延迟", "Low Latency") : AppText("平稳优先", "Steady Playback") }
    var bufferedFrames: Double { self == .responsive ? 1 : 2 }
    var audioVideoDelayFloor: Double { audioVideoDelayFloor(multiplier: 2) }
    func audioVideoDelayFloor(
        multiplier: Int, fastPassthrough: Bool = PresentationMode.fastPassthroughEnabled
    ) -> Double {
        guard self == .responsive else { return 0.08 }
        if multiplier >= 4 { return 0.03 }
        if multiplier == 3 { return 0.025 }
        if multiplier <= 1, fastPassthrough { return 0.008 }
        return 0.022
    }
    func refreshRate(outputInterval: Double, maximumFPS: Float) -> Float {
        let maximum = maximumFPS.isFinite && maximumFPS >= 1 ? maximumFPS : 60
        guard self == .steady else { return maximum }
        let output = outputInterval.isFinite && outputInterval > 0 ? Float(1 / outputInterval) : 60
        return min(maximum, output)
    }
}

enum InterpolationPowerPreference: String, CaseIterable, Identifiable, Sendable, Codable {
    case lowLatency, powerSaving
    var id: Self { self }
    var title: AppText {
        switch self {
        case .lowLatency: AppText("低延迟优先（保持性能状态）", "Low Latency (Performance Hold)")
        case .powerSaving: AppText("省电优先（关闭帧间忙等）", "Power Saving (No Idle Spin)")
        }
    }
    var allowsPerformanceHold: Bool { self == .lowLatency }
}

struct PreviewDisplayTiming: Sendable {
    var outputInterval = 1.0 / 60
    var mode: PresentationMode = .steady
    var prefersLateSelection = false
    var maximumFPS: Float = 120

    var requestedFPS: Float { mode.refreshRate(outputInterval: outputInterval, maximumFPS: maximumFPS) }
    var lateSelection: Bool { prefersLateSelection && mode == .responsive && maximumFPS >= 120 }

    static func prefersLateSelection(
        for interpolation: InterpolationStrategy?, inputSize: VideoSize?,
        fastPassthrough: Bool = PresentationMode.fastPassthroughEnabled
    ) -> Bool {
        guard let interpolation, PreviewLateSelection.configured.applies(to: inputSize) else { return false }
        return fastPassthrough || interpolation == .double
    }
}

enum WindowSamplingRate: String, CaseIterable, Identifiable, Sendable {
    case fps30, fractional, automatic
    var id: Self { self }
    var title: AppText {
        switch self {
        case .fps30: AppText("30 fps 视频 · 定时采样", "30 fps Video · Fixed Sampling")
        case .fractional: AppText("29.97 fps 视频 · 定时采样", "29.97 fps Video · Fixed Sampling")
        case .automatic: AppText("按窗口回调 · 实验", "Window Updates · Experimental")
        }
    }
    var duration: CMTime? {
        switch self {
        case .fps30: CMTime(value: 1, timescale: 30)
        case .fractional: CMTime(value: 1001, timescale: 30000)
        case .automatic: nil
        }
    }
}

enum InputSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case captureCard, testPattern, window
    var id: Self { self }
    var title: AppText {
        switch self {
        case .captureCard: AppText("采集卡", "Capture Card")
        case .testPattern: AppText("动态测试源 · 无需采集卡", "Built-In Test Pattern")
        case .window: AppText("网页 / 窗口 · 实验", "Web / Window · Experimental")
        }
    }
}

enum InputColorMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case sdrRec709, hdr10PQ, automatic
    var id: Self { self }
    var title: AppText {
        switch self {
        case .sdrRec709: "SDR · Rec.709"
        case .hdr10PQ: "HDR10 · BT.2020 PQ"
        case .automatic: AppText("自动识别（跟随信号 SDR / HDR10）", "Auto (SDR / HDR10)")
        }
    }
}

enum HDRDisplayStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Use strict ITU-R BT.2100 PQ Y'CbCr → R'G'B' decode without shadow gamma crush or chroma boost
    /// (`PLAYGLIDE_HDR10_REFERENCE_PQ=1` selects `.reference` by default).
    static var defaultStyle: Self {
        ProcessInfo.processInfo.environment["PLAYGLIDE_HDR10_REFERENCE_PQ"] == "1" ? .reference : .enhanced
    }

    case enhanced, reference
    var id: Self { self }
    var title: AppText {
        switch self {
        case .enhanced: AppText("增强对比（默认）", "Enhanced Contrast (Default)")
        case .reference: AppText("精准参考（BT.2100 PQ）", "Reference (BT.2100 PQ)")
        }
    }
}

enum SystemHDRPolicy: String, CaseIterable, Identifiable, Sendable, Codable {
    case fullscreen, session, manual
    var id: Self { self }
    var title: AppText {
        switch self {
        case .fullscreen: AppText("全屏时自动开启（退出恢复 SDR）", "Enable in Fullscreen")
        case .session: AppText("采集时自动开启（停止恢复 SDR）", "Enable During Capture")
        case .manual: AppText("手动（不修改系统设置）", "Manual (Use System Setting)")
        }
    }
}

enum InputPreset: String, CaseIterable, Identifiable, Sendable {
    case hd720, hd1080, qhd1440, uhd4K
    var id: Self { self }
    var size: VideoSize {
        switch self {
        case .hd720: VideoSize(width: 1280, height: 720)
        case .hd1080: VideoSize(width: 1920, height: 1080)
        case .qhd1440: VideoSize(width: 2560, height: 1440)
        case .uhd4K: VideoSize(width: 3840, height: 2160)
        }
    }
    var title: AppText { AppText(verbatim: size.description) }
}

enum TestSignal: String, CaseIterable, Identifiable, Sendable {
    case game30over60, game30Independent, native30, native60, fractional, fractionalIndependent, fractionalHitches
    case dynamic30to60, sceneCuts
    var id: Self { self }
    var title: AppText {
        switch self {
        case .game30over60: AppText("30 fps 内容 / 60 Hz 传输", "30 fps Content / 60 Hz Signal")
        case .game30Independent: AppText("30 / 60 · 独立重复缓冲", "30 / 60 · Separate Repeat Buffers")
        case .native30: AppText("原生 30 fps", "Native 30 fps")
        case .native60: AppText("原生 60 fps", "Native 60 fps")
        case .fractional: AppText("29.97 fps 内容 / 59.94 Hz", "29.97 fps Content / 59.94 Hz Signal")
        case .fractionalIndependent: AppText("29.97 / 59.94 · 独立重复缓冲", "29.97 / 59.94 · Separate Repeat Buffers")
        case .fractionalHitches: AppText("29.97 / 59.94 · 偶发掉帧", "29.97 / 59.94 · Occasional Drops")
        case .dynamic30to60: AppText("29.97 ↔ 59.94 · 动态往返（菜单/实机）", "29.97 ↔ 59.94 · Variable Cadence")
        case .sceneCuts: AppText("30 / 60 · 定期切场", "30 / 60 · Periodic Scene Cuts")
        }
    }
    var transportDuration: CMTime {
        switch self {
        case .native30: CMTime(value: 1, timescale: 30)
        case .fractional, .fractionalIndependent, .fractionalHitches, .dynamic30to60:
            CMTime(value: 1001, timescale: 60000)
        default: CMTime(value: 1, timescale: 60)
        }
    }
    var repeats: Int64 { self == .native30 || self == .native60 ? 1 : 2 }
    var copiesRepeatedBuffers: Bool {
        self == .game30Independent || self == .fractionalIndependent || self == .fractionalHitches
            || self == .dynamic30to60
    }

    /// The picture a transport frame carries, and the transport index where that picture first appeared.
    /// In `fractionalHitches`, every 20th picture stays up for three transport frames, like a 50 ms game hitch.
    /// In `dynamic30to60`, each 360-tick cycle alternates 3 s of 29.97 fps (2-tick) and 3 s of 59.94 fps (1-tick).
    func content(atTransport sequence: Int64) -> (picture: Int64, firstTransport: Int64) {
        switch self {
        case .fractionalHitches:
            let cycle = sequence / 41
            let offset = sequence % 41
            let local: Int64 = offset < 20 ? offset / 2 : (offset < 23 ? 10 : (offset - 1) / 2)
            return (cycle * 20 + local, cycle * 41 + (local <= 10 ? 2 * local : 2 * local + 1))
        case .dynamic30to60:
            let cycle = sequence / 360
            let offset = sequence % 360
            if offset < 180 {
                let local = offset / 2
                return (cycle * 270 + local, cycle * 360 + local * 2)
            }
            let local = 90 + (offset - 180)
            return (cycle * 270 + local, cycle * 360 + offset)
        default:
            let picture = sequence / repeats
            return (picture, picture * repeats)
        }
    }
}

enum ContentMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case automatic, transport
    var id: Self { self }
    var title: AppText {
        self == .automatic ? AppText("识别重复内容", "Detect Repeated Frames") : AppText("保留全部传输帧", "Keep All Input Frames")
    }
}

enum InterpolationStrategy: Int, CaseIterable, Identifiable, Sendable, Codable {
    case off = 1
    case double = 2
    case triple = 3
    case quadruple = 4
    static func availableModes(
        developmentTools: Bool = BuildFeatures.developmentTools,
        allow120Hz: Bool = CaptureCatalog.allow120HzCaptureEnabled
    ) -> [Self] {
        if developmentTools {
            return allow120Hz ? [.off, .double, .triple, .quadruple] : [.off, .double, .quadruple]
        }
        return allow120Hz ? [.off, .double, .triple] : [.off, .double]
    }
    static var availableModes: [Self] { availableModes() }
    var id: Self { self }
    var title: AppText {
        switch self {
        case .off: AppText("关闭 · 原始节奏", "Off · Original Cadence")
        case .double: CaptureCatalog.allow120HzCaptureEnabled ? "2× · 30→60 / 60→120" : "2× · 30 → 60"
        case .triple: "3× · 40 → 120"
        case .quadruple: "4× · 30 → 120"
        }
    }
}

enum ProcessingBackend: String, CaseIterable, Identifiable, Sendable, Codable {
    case automatic, lowLatency, frameRateConversion, opticalFlow
    var id: Self { self }
    var title: AppText {
        switch self {
        case .automatic: AppText("按实际尺寸选择", "Automatic (by Resolution)")
        case .lowLatency: AppText("VT 低延迟视频插值", "VideoToolbox Low Latency")
        case .frameRateConversion: AppText("VT 原尺寸 FRC · 实验", "VideoToolbox Native FRC · Experimental")
        case .opticalFlow: AppText("光流原尺寸重建 · 实验", "Native Optical Flow · Experimental")
        }
    }
}

enum HybridQuality: String, CaseIterable, Identifiable, Sendable, Codable {
    case fast720, hd1080
    var id: Self { self }
    var title: AppText {
        switch self {
        case .fast720: AppText("极速低延迟（720p 引擎）", "Low Latency (720p Engine)")
        case .hd1080: AppText("高清细节（1080p 引擎）", "High Detail (1080p Engine)")
        }
    }
    var maxLowHeight: Int? {
        switch self {
        case .fast720: 720
        case .hd1080: nil
        }
    }
}

enum UpscalingStrategy: String, CaseIterable, Identifiable, Sendable, Codable {
    case off, metalFXSpatial
    var id: Self { self }
    var title: AppText { self == .off ? AppText("关闭 · 保留原尺寸", "Off · Source Resolution") : "MetalFX Spatial" }
}

enum OutputPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case double, qhd1440, uhd4K
    var id: Self { self }
    var title: AppText {
        switch self {
        case .double: AppText("宽高各 2×", "2× Width and Height")
        case .qhd1440: "2560 × 1440"
        case .uhd4K: "3840 × 2160"
        }
    }
    func size(for source: VideoSize) -> VideoSize {
        switch self {
        case .double: VideoSize(width: source.width * 2, height: source.height * 2)
        case .qhd1440: InputPreset.qhd1440.size
        case .uhd4K: InputPreset.uhd4K.size
        }
    }

    func canUpscale(from source: VideoSize) -> Bool {
        let output = size(for: source)
        let limit = InputPreset.uhd4K.size
        return output.width > source.width && output.height > source.height
            && output.width <= limit.width && output.height <= limit.height
    }
}

struct VideoSize: Sendable, Equatable, Hashable, CustomStringConvertible {
    let width: Int
    let height: Int
    var description: String { "\(width) × \(height)" }
    var pixels: Int { width * height }
}

struct PipelineError: LocalizedError, Sendable {
    let message: AppText
    init(_ message: AppText) { self.message = message }
    var errorDescription: String? { message.localized(in: .selected) }
}
