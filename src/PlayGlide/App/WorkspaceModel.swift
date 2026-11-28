import AppKit
import Combine
import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var draft = SessionDraft() {
        didSet { savePreferences() }
    }
    @Published var audioControls = AudioPlaybackControls() {
        didSet {
            mailbox.setAudioControls(audioControls)
            savePreferences()
        }
    }
    @Published private(set) var devices: [CaptureDeviceDescriptor] = []
    @Published private(set) var audioDevices: [CaptureAudioDeviceDescriptor] = []
    @Published private(set) var audioOutputDevices: [AudioOutputDeviceDescriptor] = []
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var statistics = PipelineStatistics()
    @Published private(set) var inputFPS = 0.0
    @Published private(set) var contentFPS = 0.0
    @Published private(set) var presentedFPS = 0.0
    @Published private(set) var generatedFPS = 0.0
    @Published private(set) var pressure = PipelinePressure.warmingUp
    @Published private(set) var applied: SessionDraft?
    @Published var errorMessage: AppText?
    @Published var originalComparison = false {
        didSet { mailbox.compareOriginal(originalComparison) }
    }
    @Published var immersive = false {
        didSet {
            if immersive {
                if !oldValue { scheduleFullscreenIdleHide() }
            } else {
                hideFullscreenControls()
                refreshStatistics()
            }
            syncSystemHDRMode()
        }
    }
    @Published private(set) var fullscreenControlsVisible = false
    @Published private(set) var waitingForInput = false
    @Published var previewExpanded = false {
        didSet { if !previewExpanded { refreshStatistics() } }
    }
    @Published private(set) var windowTitle = AppText("尚未选择窗口", "No window selected")
    @Published private(set) var choosingWindow = false
    @Published var diagnosticsPresented = false {
        didSet {
            if diagnosticsPresented {
                refreshStatistics()
                cancelFullscreenIdleHide(restoreCursor: true)
            } else if immersive {
                scheduleFullscreenIdleHide()
            }
        }
    }
    /// Opt-in minimal fullscreen performance badge (`⌥⌘S`), disabled by default to preserve
    /// zero-compositing 1-refresh Direct-to-Display scanout.
    @Published var fullscreenHUDVisible = false {
        didSet { if fullscreenHUDVisible { refreshStatistics() } }
    }
    /// Auto-hide the macOS cursor after fullscreen inactivity (`PLAYGLIDE_AUTO_HIDE_CURSOR=0` disables).
    nonisolated static var autoHideCursorByEnvironment: Bool {
        ProcessInfo.processInfo.environment["PLAYGLIDE_AUTO_HIDE_CURSOR"] != "0"
    }
    private(set) var cursorHidden = false
    let mailbox = FrameMailbox()
    private let catalog = CaptureCatalog()
    private let defaults: UserDefaults?
    private let autoHideCursor: Bool
    private let fullscreenControlIdleTimeout: Duration
    private let isApplicationActive: @MainActor () -> Bool
    private let applyCursorHidden: @MainActor (Bool) -> Void
    private var loadingPreferences = false
    private var session: PipelineSession?
    private var runTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var hideControlsTask: Task<Void, Never>?
    private var hudPollTick = 0
    private var generation = UUID()
    private var pressureMonitor = PipelinePressureMonitor()
    private var stopRequested = false
    private var rateWindow = FrameRateWindow()
    private var activity: (any NSObjectProtocol)?
    private let windowPicker = WindowSharingPicker()
    private var windowSource: WindowCaptureSource?
    private var previewDisplayID: Int?

    init(
        defaults: UserDefaults? = nil,
        autoHideCursor: Bool = WorkspaceModel.autoHideCursorByEnvironment,
        fullscreenControlIdleTimeout: Duration = .milliseconds(2500),
        isApplicationActive: @escaping @MainActor () -> Bool = {
            let application: NSApplication? = NSApp
            return application?.isActive == true
        },
        applyCursorHidden: @escaping @MainActor (Bool) -> Void = {
            NSCursor.setHiddenUntilMouseMoves($0)
        }
    ) {
        self.defaults = defaults
        self.autoHideCursor = autoHideCursor
        self.fullscreenControlIdleTimeout = fullscreenControlIdleTimeout
        self.isApplicationActive = isApplicationActive
        self.applyCursorHidden = applyCursorHidden
        if let defaults, let saved = SessionPreferences.load(from: defaults) {
            loadingPreferences = true
            saved.apply(to: &draft)
            audioControls = saved.audioControls
            loadingPreferences = false
        }
        mailbox.setAudioControls(audioControls)
    }

    private func savePreferences() {
        guard !loadingPreferences, let defaults else { return }
        SessionPreferences.save(draft: draft, audioControls: audioControls, to: defaults)
    }

    private var selectedDevice: CaptureDeviceDescriptor? { devices.first { $0.id == draft.deviceID } }
    var formats: [CaptureFormatDescriptor] { selectedDevice?.formats ?? [] }
    var active: Bool { state != .idle }
    var previewOnly: Bool { immersive || previewExpanded }
    var selectedFormat: CaptureFormatDescriptor? { formats.first(where: { $0.id == draft.formatID }) }
    var availableUpscalingTargets: [OutputPreset] {
        guard draft.source == .captureCard else { return OutputPreset.allCases }
        guard let size = selectedFormat?.size else { return [] }
        return OutputPreset.allCases.filter { $0.canUpscale(from: size) }
    }
    var signalWarning: AppText? { active ? statistics.signalWarning : nil }
    var matchedAudioDeviceName: String? {
        guard !draft.audioDeviceID.isEmpty else { return nil }
        return audioDevices.first(where: { $0.id == draft.audioDeviceID })?.name
    }
    var selectedAudioOutputName: AppText {
        let requested = audioControls.normalizedOutputDeviceID
        guard !requested.isEmpty else { return AppText("跟随系统输出", "System Output") }
        if let device = audioOutputDevices.first(where: { $0.id == requested }) {
            return AppText(verbatim: device.name)
        }
        return AppText("已断开（自动回退系统默认）", "Disconnected (uses system output)")
    }
    var canStart: Bool {
        guard !active, !choosingWindow, draft.isAvailableInBuild else { return false }
        switch draft.source {
        case .testPattern: return true
        case .captureCard: return selectedFormat != nil
        case .window: return windowSource != nil && draft.windowSelectionID == windowSource?.id
        }
    }

    func chooseWindow() {
        guard BuildFeatures.developmentTools, !active, !choosingWindow else { return }
        errorMessage = nil
        choosingWindow = true
        windowPicker.onSelection = { [weak self] source in
            guard let self else { return }
            self.windowSource = source
            self.draft.windowSelectionID = source.id
            self.windowTitle =
                source.title.isEmpty ? AppText("已选择窗口", "Window selected") : AppText(verbatim: source.title)
            self.choosingWindow = false
            if self.draft.source == .window, !self.active { self.start() }
        }
        windowPicker.onDismiss = { [weak self] message in
            self?.choosingWindow = false
            if let message { self?.errorMessage = message }
        }
        windowPicker.present()
    }
    var overloaded: Bool { pressure.isWarning }
    var performanceMessage: AppText {
        guard active else { return PipelinePressure.normal.message }
        if pressure == .normal, pressureMonitor.recentReplacements > 0 {
            return AppText(
                "采集有过短暂波动，现已恢复稳定。",
                "Capture briefly skipped frames and has stabilized.")
        }
        return pressure.message
    }
    var configurationChanged: Bool { applied.map { $0.hasRelevantChanges(comparedTo: draft) } == true }
    var canHotApplyConfiguration: Bool {
        active && !stopRequested && draft.isAvailableInBuild && applied.map { $0.canHotReconfigure(to: draft) } == true
    }
    func fullscreenHUDSummary(in language: AppLanguage) -> String {
        Self.formatFullscreenHUDSummary(
            presentedFPS: presentedFPS, settings: applied ?? draft, statistics: statistics, language: language)
    }

    static func formatFullscreenHUDSummary(
        presentedFPS: Double, settings: SessionDraft, statistics: PipelineStatistics, language: AppLanguage
    ) -> String {
        let mode: String
        if settings.interpolation == .off {
            mode = language.text("直通", "Passthrough")
        } else if statistics.fgHeld {
            mode = language.text("过载直出", "Passthrough Under Load")
        } else if settings.interpolation != .off,
            statistics.passthroughFrames > 0,
            statistics.contentInterval > 0, statistics.contentInterval < 1.0 / 90.0
        {
            mode = language.text("1× 原生 120fps", "1× Native 120 fps")
        } else if settings.interpolation == .double,
            statistics.passthroughFrames > 0,
            statistics.contentInterval > 0, statistics.contentInterval < 1.0 / 45.0
        {
            mode = language.text("1× 原生直通", "1× Native Passthrough")
        } else if settings.interpolation == .double {
            if settings.backend == .automatic && settings.source != .window {
                mode =
                    settings.hybridQuality == .fast720
                    ? language.text("2× 极速", "2× Low Latency") : language.text("2× 高清", "2× High Detail")
            } else {
                mode = "2×"
            }
        } else {
            mode = "\(settings.interpolation.rawValue)×"
        }
        var parts = [
            String(format: "%.1f fps", presentedFPS),
            mode,
            statistics.presentationLatency.p50.map { String(format: "p50 %.1f ms", $0) } ?? "p50 —",
        ]
        if settings.source == .captureCard, settings.audioEnabled,
            let sync = statistics.audioSyncErrorMilliseconds
        {
            parts.append(String(format: language.text("音频 %+.1f ms", "Audio %+.1f ms"), sync))
        }
        return parts.joined(separator: " · ")
    }

    func diagnosticSummary(in language: AppLanguage) -> String {
        func values(_ latency: PresentationLatency) -> String {
            guard let p50 = latency.p50, let p95 = latency.p95 else { return "—" }
            return String(format: "%.1f / %.1f ms", p50, p95)
        }
        func discardP95(_ key: KeyPath<GeneratedDiscardTiming, Double>) -> String {
            let samples = statistics.generatedDiscardTimings.map { $0[keyPath: key] }.sorted()
            guard !samples.isEmpty else { return "—" }
            return String(format: "%.2f ms", samples[Int(Double(samples.count - 1) * 0.95)])
        }
        let presentedIntervals = statistics.presentedIntervals
        let intervalSummary =
            statistics.longestPresentedInterval > 0
            ? String(
                format: "%.2f / %.2f / %.2f ms", presentedIntervals.p95 ?? 0, presentedIntervals.p99 ?? 0,
                statistics.longestPresentedInterval * 1000)
            : "—"
        let flow = statistics.opticalFlowLatencies
        let flowSummary: String
        if !flow.hybridVTReady.isEmpty {
            flowSummary = """
                \(language.text("混合插帧阶段耗时 p50 / p95", "Hybrid Interpolation Timing p50 / p95"))
                \(language.text("缩小参考图：", "Reference downscaling: "))\(values(flow.downscale))
                \(language.text("VT 中点就绪：", "VT midpoint ready: "))\(values(flow.hybridVTReady))
                \(language.text("后向运动估计（并发）：", "Backward ME (concurrent): "))\(values(flow.hybridMotionBackward))
                \(language.text("前向运动估计（并发）：", "Forward ME (concurrent): "))\(values(flow.hybridMotionForward))
                \(language.text("等待运动场增量：", "Additional wait for ME: "))\(values(flow.hybridMotionWait))
                \(language.text("合成 / 配方准备：", "Composition / recipe setup: "))\(values(flow.reconstruction))

                """
        } else if !flow.downscale.isEmpty {
            flowSummary = """
                \(language.text("光流阶段耗时 p50 / p95", "Optical Flow Timing p50 / p95"))
                \(language.text("输入格式转换（执行时）：", "Input conversion (when used): "))\(values(flow.conversion))
                \(language.text("缩小参考图：", "Reference downscaling: "))\(values(flow.downscale))
                \(language.text("前向光流：", "Forward optical flow: "))\(values(flow.forward))
                \(language.text("后向光流：", "Backward optical flow: "))\(values(flow.backward))
                \(language.text("原尺寸重建：", "Native-resolution reconstruction: "))\(values(flow.reconstruction))

                """
        } else {
            flowSummary = ""
        }
        return """
            \(language.text("原始帧延迟 p50 / p95", "Original Frame Latency p50 / p95"))
            \(language.text("采集回调 → 实际呈现：", "Capture callback → presentation: "))\(values(statistics.presentationLatency))
            \(language.text("采集回调 → 图像就绪：", "Capture callback → image ready: "))\(values(statistics.inputReadyLatency))
            \(language.text("图像就绪 → 渲染提交：", "Image ready → render submission: "))\(values(statistics.queueSubmitLatency))
            \(language.text("渲染提交 → 实际呈现：", "Render submission → presentation: "))\(values(statistics.submittedPresentationLatency))
            \(language.text("CPU渲染编码：", "CPU render encoding: "))\(values(statistics.renderEncodingLatency))
            \(language.text("预览完整重建 / 缓存刷新：", "Full preview renders / cache hits: "))\(statistics.previewFullRenders) / \(statistics.previewCacheHits)
            \(language.text("提交 → GPU完成回调：", "Submission → GPU completion callback: "))\(values(statistics.commandCompletionLatency))

            \(flowSummary)\(language.text("自适应补帧调度", "Adaptive Interpolation Scheduling"))
            \(language.text("当前目标 / 所需相位：", "Current target / required phase: "))\(String(format: "%.2f / %.2f ms", statistics.targetPairDelayMilliseconds, statistics.requiredPairDelayMilliseconds))
            \(language.text("就绪学习样本 / 回调时钟抖动：", "Readiness samples / capture clock jitter: "))\(statistics.phaseSamples) / \(String(format: "%.2f ms", statistics.captureJitterMilliseconds))
            \(language.text("生成 / 原始帧就绪超期次数：", "Missed readiness deadlines (generated / original): "))\(statistics.generatedDeadlineMisses) / \(statistics.realDeadlineMisses)
            \(language.text("生成帧就绪迟到 p50 / p95：", "Generated-frame readiness lateness p50 / p95: "))\(values(statistics.generatedReadyLateness))
            \(language.text("原始帧就绪迟到 p50 / p95：", "Original-frame readiness lateness p50 / p95: "))\(values(statistics.realReadyLateness))
            \(language.text("超过期限 → 提交 p50 / p95：", "Deadline → late submission p50 / p95: "))\(values(statistics.deadlineSubmitLateness))
            \(language.text("丢弃生成 / 被更新原帧替代 / 容量丢弃：", "Expired generated / superseded originals / capacity drops: "))\(statistics.generatedExpired) / \(statistics.realSuperseded) / \(statistics.capacityDropped)
            \(language.text("生成丢弃细分（超时 / 原帧抢占 / 直出清理）：", "Generated drops (timeout / preemption / passthrough flush): "))\(statistics.generatedTimedOut) / \(statistics.generatedPreempted) / \(statistics.generatedFlushed)
            \(language.text("输入替换伴随内容节奏变化次数：", "Input replacements with cadence disruption: "))\(statistics.ingressCadenceDisruptions)
            \(language.text("游戏单帧卡顿（保留计时）：", "Source hitches (timing preserved): "))\(statistics.contentHitches)
            \(language.text("丢弃生成时序（最近\(statistics.generatedDiscardTimings.count)条）p95", "Generated-frame discard timing (last \(statistics.generatedDiscardTimings.count)) p95"))
            \(language.text("就绪迟到 / 排队等待 / 丢弃时迟到：", "Readiness lateness / queue wait / discard lateness: "))\(discardP95(\.readyLateMilliseconds)) / \(discardP95(\.queuedMilliseconds)) / \(discardP95(\.discardLateMilliseconds))
            \(language.text("过载直出：", "Passthrough under load: "))\(statistics.fgHeld ? language.text("是", "Yes") : language.text("否", "No")) · \(language.text("跳过对 / 探测对 / 状态切换：", "Skipped pairs / probe pairs / transitions: "))\(statistics.fgBypassedPairs) / \(statistics.fgProbePairs) / \(statistics.fgHoldTransitions)
            \(language.text("动态 60fps 原生直通帧数：", "Native 60 fps passthrough frames: "))\(statistics.passthroughFrames)

            \(language.text("后端：", "Engine: "))\(statistics.backend.localized(in: language))
            \(language.text("呈现策略：", "Presentation mode: "))\((applied ?? draft).presentationMode.title.localized(in: language))
            \(language.text("能耗偏好：", "Power preference: "))\((applied ?? draft).powerPreference.title.localized(in: language))
            \(language.text("输出尺寸：", "Output size: "))\(statistics.outputSize?.description ?? "—")
            \(language.text("采集 / 内容 / 生成 / 呈现：", "Capture / content / generated / presented: "))\(String(format: "%.1f / %.1f / %.1f / %.1f fps", inputFPS, contentFPS, generatedFPS, presentedFPS))
            \(language.text("处理 p50 / p95：", "Processing p50 / p95: "))\(String(format: "%.1f / %.1f ms", statistics.p50, statistics.p95))
            \(language.text("采集入口直拷 / 转换：", "Capture ingest copies / conversions: "))\(statistics.captureIngestCopies) / \(statistics.captureIngestConversions) · \(language.text("耗时 p50 / p95：", "Time p50 / p95: "))\(values(statistics.captureIngestLatency))
            \(language.text("采集表面：", "Capture surface: "))\(statistics.captureSurface.localized(in: language))
            \(language.text("HDMI 重握手 / HDR 跳过 / 会话恢复：", "HDMI renegotiations / HDR skips / session recoveries: "))\(statistics.formatRehandshakes) / \(statistics.hdrFramesSkipped) / \(statistics.captureRecoveries)
            \(language.text("信号提醒：", "Signal warning: "))\(statistics.signalWarning?.localized(in: language) ?? language.text("无", "None"))
            \(language.text("去重检测 p50 / p95：", "Duplicate detection p50 / p95: "))\(values(statistics.detectionLatency))
            \(language.text("像素确认 p50 / p95：", "Pixel confirmation p50 / p95: "))\(values(statistics.confirmationLatency))
            \(language.text("队列 / 输入丢弃 / 显示跳过 / 历史重置：", "Queue depth / input drops / skipped presentations / history resets: "))\(statistics.queueDepth) / \(statistics.ingressDropped) / \(statistics.presentationDropped) / \(statistics.historyResets)
            \(language.text("已测延迟样本：", "Latency samples: "))\(statistics.presentationLatency.count)
            \(language.text("显示回调 / GPU忙 / 无到期帧：", "Display callbacks / GPU busy / no frame due: "))\(statistics.displayUpdates) / \(statistics.gpuBusyUpdates) / \(statistics.noDueUpdates)
            \(language.text("提交 / 实际呈现 / 未确认呈现：", "Submitted / presented / unconfirmed: "))\(statistics.submitted) / \(statistics.presented) / \(max(0, statistics.submitted - statistics.presented))
            \(language.text("首次呈现无效 / 重绘补记：", "Unconfirmed first presentations / recovered redraws: "))\(statistics.unpresented) / \(statistics.redrawRecovered)
            \(language.text("实际呈现中点：", "Presented interpolated frames: "))\(statistics.presentedGenerated)
            \(language.text("新画面间隔 p95 / p99 / 最长：", "New-frame interval p95 / p99 / max: "))\(intervalSummary)
            \(language.text("窗口区域：", "Window geometry: "))\(statistics.windowGeometry.localized(in: language))
            \(language.text("窗口原生 / 请求尺寸：", "Native / requested window size: "))\(statistics.nativeWindowSize?.description ?? "—") / \(statistics.requestedWindowSize?.description ?? "—")
            \(language.text("预览实际像素 / 动态更新次数：", "Preview pixels / resolution updates: "))\(mailbox.previewPixelSize?.description ?? "—") / \(statistics.windowResolutionUpdates)
            \(language.text("尺寸更新错误：", "Resolution update error: "))\(statistics.windowResolutionError?.localized(in: language) ?? language.text("无", "None"))
            \(language.text("窗口回调 → 自有图像就绪：", "Window callback → owned image ready: "))\(values(statistics.windowPreparationLatency))
            \(language.text("窗口回调 → 首次定时采样：", "Window callback → first scheduled sample: "))\(values(statistics.windowSampleLatency))
            \(language.text("定时采样选中的窗口表面：", "Window surfaces selected by scheduled sampling: "))\(statistics.windowSampledSurfaces)

            \(language.text("采集卡音频：", "Capture-card audio: "))\(statistics.audioStatus.localized(in: language))
            \(language.text("音频格式：", "Audio format: "))\(statistics.audioFormat.localized(in: language))
            \(language.text("音频接收 / 入播放队列 / 缓冲淘汰 / 对齐成功：", "Audio received / enqueued / evicted / resynced: "))\(statistics.audioReceived) / \(statistics.audioEnqueued) / \(statistics.audioDropped) / \(statistics.audioResyncs)
            \(language.text("最近对齐等待 / 对齐失败：", "Last sync wait / sync failures: "))\(statistics.audioAlignmentWaitMilliseconds.map { String(format: "%.2f ms", $0) } ?? "—") / \(statistics.audioAlignmentFailures)
            \(language.text("音频时钟相对视频偏差：", "Audio clock offset relative to video: "))\(statistics.audioSyncErrorMilliseconds.map { String(format: "%+.2f ms", $0) } ?? "—")
            \(language.text("音频播放速率：", "Audio playback rate: "))\(String(format: "%.5f", statistics.audioRate))
            \(language.text("音频输出设备：", "Audio output device: "))\(selectedAudioOutputName.localized(in: language))
            \(language.text("音频输出：", "Audio output: "))\(audioControls.muted ? language.text("已静音", "Muted") : "\(Int((audioControls.clampedVolume * 100).rounded()))%") · \(language.text("手动偏移", "Manual offset")) \(String(format: "%+.0f ms", audioControls.clampedOffsetMilliseconds))

            \(language.text("生成中点不混入原始帧延迟。各段分位数不必相加等于总分位数。", "Original-frame latency covers source frames only. Percentiles for individual stages may sum to a different total."))
            \(language.text("目标相位是B到达后的调度预算；迟到统计包含零值，不是端到端延迟。", "The target phase is the scheduling budget after frame B arrives. Lateness statistics include frames that were on time."))
            \(language.text("不含交给App前的采集卡/浏览器缓冲和显示面板响应。", "The latency clock starts when the app receives the frame and ends at presentation."))
            \(language.text("音频偏差来自系统播放时钟，不是扬声器出声与屏幕出光的实测误差。", "Audio offset is measured using the system playback clock."))
            """
    }

    func refreshDevices() async {
        let result = await catalog.devices()
        let discoveredAudio = await catalog.audioDevices()
        let discoveredOutputs = await catalog.audioOutputDevices()
        applyDiscoveredDevices(video: result, audio: discoveredAudio, audioOutputs: discoveredOutputs)
    }

    func applyDiscoveredDevices(
        video result: [CaptureDeviceDescriptor], audio discoveredAudio: [CaptureAudioDeviceDescriptor],
        audioOutputs discoveredOutputs: [AudioOutputDeviceDescriptor] = []
    ) {
        audioDevices = discoveredAudio
        audioOutputDevices = discoveredOutputs
        devices = result
        if !result.contains(where: { $0.id == draft.deviceID }) {
            draft.deviceID = result.first?.id ?? ""
            draft.formatID = selectedDevice?.preferredFormat?.id ?? ""
        } else if selectedFormat == nil {
            draft.formatID = selectedDevice?.preferredFormat?.id ?? ""
        }
        autoMatchCompanionAudioIfNeeded()
    }

    func deviceChanged() {
        if selectedFormat == nil {
            draft.formatID = selectedDevice?.preferredFormat?.id ?? ""
        }
        if let device = selectedDevice,
            let matched = CaptureAudioDeviceDescriptor.recommendedMatch(for: device, in: audioDevices)
        {
            draft.audioDeviceID = matched.id
        } else {
            draft.audioDeviceID = ""
        }
    }

    func audioEnabledChanged() {
        guard draft.audioEnabled else { return }
        autoMatchCompanionAudioIfNeeded()
    }

    func toggleAudioMute() {
        audioControls.muted.toggle()
    }

    func resetAudioOffset() {
        audioControls.offsetMilliseconds = 0
    }

    func updateUpscalingTarget() {
        let targets = availableUpscalingTargets
        guard !targets.contains(draft.outputPreset) else { return }
        if let target = targets.first {
            draft.outputPreset = target
        } else if selectedFormat != nil, draft.upscaling != .off {
            draft.upscaling = .off
        }
    }

    private func autoMatchCompanionAudioIfNeeded() {
        guard let device = selectedDevice else { return }
        let selectionConnected =
            !draft.audioDeviceID.isEmpty && audioDevices.contains(where: { $0.id == draft.audioDeviceID })
        guard !selectionConnected else { return }
        if let matched = CaptureAudioDeviceDescriptor.recommendedMatch(for: device, in: audioDevices) {
            draft.audioDeviceID = matched.id
        } else if !draft.audioDeviceID.isEmpty {
            // Keep disconnected ID visible only if user explicitly enabled audio and no companion replaced it.
            if !draft.audioEnabled { draft.audioDeviceID = "" }
        }
    }

    func start() {
        guard canStart else { return }
        updateUpscalingTarget()
        errorMessage = nil
        stopRequested = false
        originalComparison = false
        waitingForInput = false
        state = .starting
        endActivity()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
            reason: AppLanguage.selected.text("实时视频采集、补帧和显示", "Live video capture, interpolation, and display"))
        let token = UUID()
        generation = token
        mailbox.begin(token)
        statistics = PipelineStatistics()
        inputFPS = 0
        contentFPS = 0
        presentedFPS = 0
        generatedFPS = 0
        pressure = .warmingUp
        pressureMonitor = PipelinePressureMonitor()
        rateWindow = FrameRateWindow()
        hudPollTick = 0
        _ = rateWindow.record(time: mediaHostTime(), input: 0, content: 0, generated: 0, presented: 0)
        applied = draft
        syncSystemHDRMode()
        do {
            let pipeline = try PipelineSession(
                settings: draft, format: selectedFormat, generation: token, mailbox: mailbox, windowSource: windowSource
            )
            session = pipeline
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    self?.poll(token)
                }
            }
            runTask = Task { [weak self] in
                do {
                    try await pipeline.run()
                } catch is CancellationError {
                    // Stop is completed only after producers and processor resources are drained.
                } catch {
                    if let self, !self.stopRequested { self.errorMessage = AppText(error: error) }
                }
                guard let self, self.generation == token else { return }
                self.mailbox.finish(token)
                let statistics = self.mailbox.snapshot()
                self.statistics = statistics
                let trace = self.mailbox.frameTrace(token)
                let snapshots = self.mailbox.frameTraceSnapshots(token)
                if let run = self.mailbox.takeFinishedPresentationRun(token) {
                    let settings = self.applied
                    Task.detached(priority: .utility) {
                        if let log = run.log(generation: token, settings: settings, statistics: statistics) {
                            print(log)
                        }
                    }
                }
                if !trace.isEmpty {
                    Task.detached(priority: .utility) {
                        let counts = statistics.historyResetReasons.map { "\($0.key.rawValue)=\($0.value)" }.sorted()
                            .joined(separator: " ")
                        print("PLAYGLIDE_HISTORY_RESETS \(token) \(counts)")
                        let encoded = statistics.previewFullRenders + statistics.previewCacheHits
                        let originalP95 = statistics.presentationLatency.p95.map { String(format: "%.2f", $0) } ?? "-"
                        let intervalP99 = statistics.presentedIntervals.p99.map { String(format: "%.2f", $0) } ?? "-"
                        print(
                            "PLAYGLIDE_PREVIEW \(token) callbacks=\(statistics.displayUpdates) encoded=\(encoded)"
                                + " presentedOriginals=\(statistics.presented - statistics.presentedGenerated)"
                                + " presentedMidpoints=\(statistics.presentedGenerated)"
                                + " recentOriginalP95Ms=\(originalP95) recentIntervalP99Ms=\(intervalP99)")
                        let rows = trace.map(\.csv).joined(separator: "\n")
                        print("PLAYGLIDE_FRAME_TRACE \(token)\n\(FrameTraceEvent.csvHeader)\n\(rows)")
                        for snapshot in snapshots { print(snapshot.log(generation: token)) }
                    }
                }
                self.pollTask?.cancel()
                self.pollTask = nil
                self.session = nil
                self.runTask = nil
                self.endActivity()
                self.waitingForInput = false
                self.state = .idle
                self.syncSystemHDRMode()
                self.inputFPS = 0
                self.contentFPS = 0
                self.presentedFPS = 0
                self.generatedFPS = 0
            }
        } catch {
            mailbox.finish(token)
            endActivity()
            waitingForInput = false
            state = .idle
            syncSystemHDRMode()
            errorMessage = AppText(error: error)
        }
    }
    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
    var effectiveHDR10Active: Bool {
        let activeSettings = applied ?? draft
        guard active, !stopRequested, activeSettings.source == .captureCard else { return false }
        switch activeSettings.colorMode {
        case .sdrRec709: return false
        case .hdr10PQ: return true
        case .automatic: return statistics.detectedHDR10
        }
    }
    func setPreviewDisplayID(_ displayID: Int?) {
        let changed = previewDisplayID != displayID
        previewDisplayID = displayID
        if changed || effectiveHDR10Active {
            syncSystemHDRMode()
        }
    }
    func syncSystemHDRMode() {
        guard defaults === UserDefaults.standard else { return }
        SystemDisplayHDRController.shared.update(
            hdrSessionActive: effectiveHDR10Active,
            policy: draft.systemHDRPolicy,
            immersive: immersive,
            displayID: previewDisplayID
        )
    }
    func stop() {
        guard active, !stopRequested else { return }
        stopRequested = true
        state = .stopping
        syncSystemHDRMode()
        runTask?.cancel()
        let session = session
        Task { await session?.stop() }
    }
    func stopAndWait() async {
        stop()
        let running = runTask
        await running?.value
    }
    func applyConfiguration() async {
        guard active, !stopRequested else { return }
        updateUpscalingTarget()
        guard configurationChanged else { return }
        if canHotApplyConfiguration, let session {
            if let inputSize = statistics.inputSize {
                do {
                    _ = try ProcessingPlan.make(size: inputSize, settings: draft)
                } catch {
                    errorMessage = AppText(error: error)
                    return
                }
            }
            if await session.reconfigure(to: draft) {
                errorMessage = nil
                applied = draft
                syncSystemHDRMode()
                refreshStatistics()
                return
            }
        }
        await restart()
    }
    func selectQuickProfile(interpolation: InterpolationStrategy, hybridQuality: HybridQuality? = nil) {
        draft.interpolation = interpolation
        if let hybridQuality {
            draft.backend = .automatic
            draft.hybridQuality = hybridQuality
        }
        guard active, !stopRequested, canHotApplyConfiguration else { return }
        Task { await applyConfiguration() }
    }
    func restart() async {
        await stopAndWait()
        start()
    }
    private func refreshStatistics() {
        guard active else { return }
        poll(generation, forcePublish: true)
    }

    private func poll(_ token: UUID, forcePublish: Bool = false) {
        guard generation == token else { return }
        let now = mediaHostTime()
        let previous = PreviewPollState(
            starting: state == .starting, active: active, stopping: stopRequested, waitingForInput: waitingForInput,
            inputSize: statistics.inputSize, outputFrameDuration: statistics.outputFrameDuration,
            signalWarning: statistics.signalWarning, detectedHDR10: statistics.detectedHDR10)
        let next: PipelineStatistics
        let wantsHUDRefresh: Bool
        if immersive && fullscreenHUDVisible {
            hudPollTick &+= 1
            wantsHUDRefresh = !hudPollTick.isMultiple(of: 2)
        } else {
            wantsHUDRefresh = false
        }
        // Keep idle fullscreen polls from retaining all of the statistics arrays.
        if !forcePublish && previewOnly && !diagnosticsPresented && !wantsHUDRefresh {
            guard let changed = mailbox.previewSnapshot(token, previous: previous, now: now) else { return }
            next = changed
        } else {
            next = mailbox.snapshot()
        }
        let becameRunning = state == .starting && next.lastOutputTime > 0
        let isWaiting = previous.isWaiting(lastInputTime: next.lastInputTime, now: now)
        let rates = rateWindow.record(
            time: now, input: next.received, content: next.content,
            generated: next.generated, presented: next.presented)
        inputFPS = rates.input
        contentFPS = rates.content
        presentedFPS = rates.presented
        generatedFPS = rates.generated
        pressure = pressureMonitor.update(
            now: now, interval: next.contentInterval, processing: next.processingSamples,
            processed: next.content, ingress: next.ingressDropped, cadence: next.ingressCadenceDisruptions,
            expired: next.generatedExpired, held: next.fgHeld)
        statistics = next
        if previous.detectedHDR10 != next.detectedHDR10 { syncSystemHDRMode() }
        if waitingForInput != isWaiting { waitingForInput = isWaiting }
        if becameRunning { state = .running }
        if let error = next.error, !stopRequested {
            errorMessage = error
            stop()
        }
    }
    func revealFullscreenControls() {
        guard immersive else { return }
        setCursorHidden(false)
        if !fullscreenControlsVisible { fullscreenControlsVisible = true }
        scheduleFullscreenIdleHide()
    }
    func hideFullscreenControls() {
        cancelFullscreenIdleHide(restoreCursor: true)
        if fullscreenControlsVisible { fullscreenControlsVisible = false }
    }
    func handleApplicationResignedActive() {
        cancelFullscreenIdleHide(restoreCursor: true)
    }
    func handleApplicationBecameActive() {
        guard immersive, !diagnosticsPresented else { return }
        scheduleFullscreenIdleHide()
    }
    private func scheduleFullscreenIdleHide() {
        hideControlsTask?.cancel()
        guard immersive else {
            hideControlsTask = nil
            return
        }
        let timeout = fullscreenControlIdleTimeout
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.hideFullscreenControlsForIdle()
        }
    }
    private func cancelFullscreenIdleHide(restoreCursor: Bool) {
        hideControlsTask?.cancel()
        hideControlsTask = nil
        if restoreCursor { setCursorHidden(false) }
    }
    private func hideFullscreenControlsForIdle() {
        hideControlsTask = nil
        if fullscreenControlsVisible { fullscreenControlsVisible = false }
        setCursorHidden(true)
    }
    private func setCursorHidden(_ hidden: Bool) {
        if hidden {
            guard autoHideCursor, immersive, !diagnosticsPresented, isApplicationActive() else { return }
            cursorHidden = true
            applyCursorHidden(true)
        } else if cursorHidden {
            cursorHidden = false
            applyCursorHidden(false)
        }
    }
    func togglePreviewExpansion() {
        guard !immersive else { return }
        previewExpanded.toggle()
    }
    func toggleFullscreenHUD() {
        fullscreenHUDVisible.toggle()
    }

    func toggleFullScreen() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        window?.toggleFullScreen(nil)
    }
}

enum SessionState: String {
    case idle, starting, running, stopping
    var title: AppText {
        switch self {
        case .idle: AppText("未运行", "Idle")
        case .starting: AppText("准备输入与处理器…", "Preparing Capture…")
        case .running: AppText("运行中", "Running")
        case .stopping: AppText("正在停止…", "Stopping…")
        }
    }
}
