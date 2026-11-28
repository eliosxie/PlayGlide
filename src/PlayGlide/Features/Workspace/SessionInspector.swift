import AppKit
import SwiftUI

struct SessionInspector: View {
    @ObservedObject var model: WorkspaceModel
    let language: AppLanguage
    @State private var audioDetailsExpanded = false
    @State private var advancedExpanded = false

    private var availableSources: [InputSource] {
        BuildFeatures.developerUI ? InputSource.allCases : [.captureCard, .window]
    }

    private var availableInterpolationModes: [InterpolationStrategy] {
        if model.draft.source == .window {
            return [.off, .double]
        }
        return InterpolationStrategy.availableModes(
            developmentTools: BuildFeatures.developerUI,
            allow120Hz: CaptureCatalog.allow120HzCaptureEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    StudioSegmentedControl(
                        selection: $model.draft.source,
                        options: availableSources.map { ($0, shortSourceTitle($0)) }
                    )
                    .disabled(model.choosingWindow)

                    signalCard
                    motionCard
                    if model.draft.source == .captureCard {
                        audioCard
                    }
                    advancedCard
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            footerBar
                .padding(14)
                .background(Color.black.opacity(0.2))
        }
        .tint(.mint)
        .onChange(of: model.availableUpscalingTargets, initial: true) { _, _ in
            model.updateUpscalingTarget()
        }
        .onChange(of: model.draft.source) { _, nextSource in
            if nextSource == .window && model.draft.interpolation.rawValue > 2 {
                model.draft.interpolation = .double
            }
        }
    }

    private func shortSourceTitle(_ source: InputSource) -> String {
        switch source {
        case .captureCard: language.text("采集卡", "Capture Card")
        case .window: language.text("窗口", "Window")
        case .testPattern: language.text("测试源", "Test")
        }
    }

    private var selectedDeviceLabel: String {
        model.devices.first(where: { $0.id == model.draft.deviceID })?.name
            ?? language.text("未连接采集卡", "No Capture Card")
    }

    private var selectedFormatLabel: String {
        model.selectedFormat?.title.localized(in: language)
            ?? language.text("请先连接采集卡", "Connect a capture card")
    }

    private var deviceMenuOptions: [StudioMenuOption] {
        if model.devices.isEmpty {
            return [StudioMenuOption(language.text("未连接采集卡", "No Capture Card"), isEnabled: false)]
        }
        return model.devices.map { device in
            StudioMenuOption(device.name, isSelected: model.draft.deviceID == device.id) {
                model.draft.deviceID = device.id
                model.deviceChanged()
            }
        }
    }

    private var formatMenuOptions: [StudioMenuOption] {
        if model.formats.isEmpty {
            return [StudioMenuOption(language.text("请先连接采集卡", "Connect a capture card"), isEnabled: false)]
        }
        return model.formats.map { format in
            StudioMenuOption(format.title.localized(in: language), isSelected: model.draft.formatID == format.id) {
                model.draft.formatID = format.id
            }
        }
    }

    private var signalCard: some View {
        InspectorCard(title: language.text("信号与画面", "Signal & Display"), icon: "display") {
            if model.draft.source == .captureCard {
                InspectorField(language.text("设备", "Device")) {
                    HStack(spacing: 6) {
                        StudioMenuButton(title: selectedDeviceLabel, options: deviceMenuOptions)
                        Button {
                            Task { await model.refreshDevices() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 28, height: 28)
                                .background(
                                    Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(language.text("刷新设备与格式", "Refresh Devices and Formats"))
                    }
                }

                InspectorField(language.text("分辨率与帧率", "Format")) {
                    StudioMenuButton(title: selectedFormatLabel, options: formatMenuOptions)
                }

                InspectorField(language.text("色彩模式", "Color Mode")) {
                    StudioSegmentedControl(
                        selection: $model.draft.colorMode,
                        options: [
                            (.sdrRec709, "SDR"),
                            (.hdr10PQ, "HDR10"),
                            (.automatic, language.text("自动", "Auto")),
                        ]
                    )
                }

                if model.draft.colorMode != .sdrRec709 {
                    InspectorField(language.text("HDR 风格", "HDR Tone")) {
                        StudioSegmentedControl(
                            selection: $model.draft.hdrDisplayStyle,
                            options: [
                                (.enhanced, language.text("增强对比", "Enhanced")),
                                (.reference, language.text("精准参考", "Reference")),
                            ]
                        )
                    }
                    InspectorField(language.text("显示器 HDR", "Display HDR")) {
                        StudioMenuButton(
                            title: model.draft.systemHDRPolicy.title.localized(in: language),
                            options: SystemHDRPolicy.allCases.map { policy in
                                StudioMenuOption(
                                    policy.title.localized(in: language),
                                    isSelected: model.draft.systemHDRPolicy == policy
                                ) {
                                    model.draft.systemHDRPolicy = policy
                                    model.syncSystemHDRMode()
                                }
                            }
                        )
                    }
                }
            } else if model.draft.source == .window {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("目标窗口", "Target Window"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.windowTitle.localized(in: language))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        model.chooseWindow()
                    } label: {
                        Text(
                            model.choosingWindow
                                ? language.text("选择中…", "Picking…")
                                : language.text("选择窗口", "Choose")
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.active || model.choosingWindow)
                }

                InspectorField(language.text("画质策略", "Resolution")) {
                    StudioMenuButton(
                        title: model.draft.windowResolution.title.localized(in: language),
                        options: WindowResolutionMode.allCases.map { mode in
                            StudioMenuOption(
                                mode.title.localized(in: language),
                                isSelected: model.draft.windowResolution == mode
                            ) {
                                model.draft.windowResolution = mode
                            }
                        }
                    )
                }

                if model.draft.windowResolution == .fixed {
                    InspectorField(language.text("采集画布", "Canvas")) {
                        StudioSegmentedControl(
                            selection: $model.draft.windowPreset,
                            options: [
                                (.hd1080, "1080p"),
                                (.qhd1440, "1440p"),
                                (.uhd4K, "4K"),
                            ]
                        )
                    }
                }
            } else if BuildFeatures.developerUI {
                InspectorField(language.text("原始尺寸", "Resolution")) {
                    StudioMenuButton(
                        title: model.draft.inputPreset.title.localized(in: language),
                        options: InputPreset.allCases.map { preset in
                            StudioMenuOption(
                                preset.title.localized(in: language),
                                isSelected: model.draft.inputPreset == preset
                            ) {
                                model.draft.inputPreset = preset
                            }
                        }
                    )
                }
                InspectorField(language.text("信号场景", "Pattern")) {
                    StudioMenuButton(
                        title: model.draft.testSignal.title.localized(in: language),
                        options: TestSignal.allCases.map { signal in
                            StudioMenuOption(
                                signal.title.localized(in: language),
                                isSelected: model.draft.testSignal == signal
                            ) {
                                model.draft.testSignal = signal
                            }
                        }
                    )
                }
            }
        }
    }

    private var motionCard: some View {
        InspectorCard(title: language.text("流畅度与画质", "Motion & Clarity"), icon: "sparkles") {
            InspectorField(language.text("补帧模式", "Frame Generation")) {
                StudioSegmentedControl(
                    selection: $model.draft.interpolation,
                    options: availableInterpolationModes.map { ($0, shortInterpolationTitle($0)) }
                )
            }

            if model.draft.interpolation == .double && model.draft.backend == .automatic {
                InspectorField(language.text("补帧档位", "Quality Preset")) {
                    StudioSegmentedControl(
                        selection: $model.draft.hybridQuality,
                        options: [
                            (.hd1080, language.text("高清 · 1080p", "High · 1080p")),
                            (.fast720, language.text("极速 · 720p", "Fast · 720p")),
                        ]
                    )
                }
                .help(
                    language.text(
                        "高清档细节更锐利（⌘1）；极速档延迟更低（⌘2），随时实时切换不断流。",
                        "High maximizes motion detail (⌘1). Fast lowers latency (⌘2). Applies live."
                    ))
            }

            if model.draft.interpolation != .off && model.draft.source != .window {
                InspectorField(language.text("响应与功耗", "Responsiveness")) {
                    StudioSegmentedControl(
                        selection: $model.draft.powerPreference,
                        options: [
                            (.lowLatency, language.text("低延迟", "Low Latency")),
                            (.powerSaving, language.text("省电静音", "Power Saving")),
                        ]
                    )
                }
                .help(
                    language.text(
                        "低延迟保持性能状态以压低尾延迟；省电静音关闭帧间等待大幅降低 CPU 功耗。",
                        "Low Latency holds chip performance state for lower latency; Power Saving significantly reduces CPU power."
                    ))
            }

            let targets = model.availableUpscalingTargets
            if !targets.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                HStack {
                    Text(language.text("MetalFX 超分", "MetalFX Upscaling"))
                        .font(.callout)
                    Spacer()
                    StudioSwitch(
                        isOn: Binding(
                            get: { model.draft.upscaling == .metalFXSpatial },
                            set: { model.draft.upscaling = $0 ? .metalFXSpatial : .off }
                        ))
                }
                if model.draft.upscaling != .off {
                    InspectorField(language.text("输出目标", "Target Size")) {
                        StudioMenuButton(
                            title: model.draft.outputPreset.title.localized(in: language),
                            options: targets.map { target in
                                StudioMenuOption(
                                    target.title.localized(in: language),
                                    isSelected: model.draft.outputPreset == target
                                ) {
                                    model.draft.outputPreset = target
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private func shortInterpolationTitle(_ mode: InterpolationStrategy) -> String {
        switch mode {
        case .off: language.text("直通", "Off")
        case .double: "2×"
        case .triple: "3×"
        case .quadruple: "4×"
        }
    }

    private var selectedAudioInputLabel: String {
        if model.draft.audioDeviceID.isEmpty {
            return language.text("采集卡自带音频", "Capture Card Audio")
        }
        return model.audioDevices.first(where: { $0.id == model.draft.audioDeviceID })?.name
            ?? language.text("已断开", "Disconnected")
    }

    private var audioInputOptions: [StudioMenuOption] {
        var list = [
            StudioMenuOption(
                language.text("采集卡自带音频", "Capture Card Audio"),
                isSelected: model.draft.audioDeviceID.isEmpty
            ) {
                model.draft.audioDeviceID = ""
            }
        ]
        list.append(
            contentsOf: model.audioDevices.map { device in
                StudioMenuOption(device.name, isSelected: model.draft.audioDeviceID == device.id) {
                    model.draft.audioDeviceID = device.id
                }
            })
        return list
    }

    private var audioOutputOptions: [StudioMenuOption] {
        var list = [
            StudioMenuOption(
                language.text("跟随系统默认", "System Default"),
                isSelected: model.audioControls.normalizedOutputDeviceID.isEmpty
            ) {
                model.audioControls.outputDeviceID = ""
            }
        ]
        list.append(
            contentsOf: model.audioOutputDevices.map { device in
                let label =
                    device.isDefault
                    ? language.text("\(device.name)（默认）", "\(device.name) (Default)")
                    : device.name
                return StudioMenuOption(
                    label,
                    isSelected: model.audioControls.normalizedOutputDeviceID == device.id
                ) {
                    model.audioControls.outputDeviceID = device.id
                }
            })
        return list
    }

    private var audioCard: some View {
        InspectorCard(
            title: language.text("音频", "Audio"),
            icon: model.audioControls.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        ) {
            StudioSwitch(isOn: $model.draft.audioEnabled)
                .onChange(of: model.draft.audioEnabled) { _, _ in model.audioEnabledChanged() }
        } content: {
            if model.draft.audioEnabled {
                HStack(spacing: 10) {
                    Button {
                        model.toggleAudioMute()
                    } label: {
                        Image(systemName: model.audioControls.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(model.audioControls.muted ? Color.secondary : Color.mint)
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)
                    Slider(value: $model.audioControls.volume, in: 0...1)
                        .tint(.mint)
                        .disabled(model.audioControls.muted)
                    Text("\(Int((model.audioControls.clampedVolume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }

                StudioDisclosureRow(
                    title: language.text("设备与音画偏移", "Devices & Sync Offset"),
                    isExpanded: $audioDetailsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        InspectorField(language.text("音频输入", "Audio Input")) {
                            StudioMenuButton(title: selectedAudioInputLabel, options: audioInputOptions)
                        }

                        InspectorField(language.text("音频输出", "Audio Output")) {
                            StudioMenuButton(
                                title: model.selectedAudioOutputName.localized(in: language),
                                options: audioOutputOptions
                            )
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(language.text("音画偏移", "Sync Offset"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%+.0f ms", model.audioControls.clampedOffsetMilliseconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if abs(model.audioControls.clampedOffsetMilliseconds) >= 1 {
                                    Button(language.text("归零", "Reset")) { model.resetAudioOffset() }
                                        .buttonStyle(.plain)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.mint)
                                }
                            }
                            Slider(
                                value: $model.audioControls.offsetMilliseconds,
                                in: AudioPlaybackControls
                                    .minOffsetMilliseconds...AudioPlaybackControls
                                    .maxOffsetMilliseconds,
                                step: 5
                            )
                            .tint(.mint)
                        }
                    }
                    .padding(.top, 8)
                }
            } else {
                Text(language.text("开启以同步播放采集卡 HDMI 声音", "Enable to play synced HDMI audio"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioDisclosureRow(
                title: language.text("高级设置", "Advanced"),
                isExpanded: $advancedExpanded
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.draft.interpolation != .off {
                        InspectorField(language.text("呈现策略", "Presentation")) {
                            StudioSegmentedControl(
                                selection: $model.draft.presentationMode,
                                options: PresentationMode.allCases.map { ($0, $0.title.localized(in: language)) }
                            )
                        }
                    }

                    InspectorField(language.text("帧率检测", "Cadence Detection")) {
                        StudioMenuButton(
                            title: model.draft.contentMode.title.localized(in: language),
                            options: ContentMode.allCases.map { mode in
                                StudioMenuOption(
                                    mode.title.localized(in: language),
                                    isSelected: model.draft.contentMode == mode
                                ) {
                                    model.draft.contentMode = mode
                                }
                            }
                        )
                    }

                    if model.draft.source == .window {
                        InspectorField(language.text("窗口采样", "Window Sampling")) {
                            StudioMenuButton(
                                title: model.draft.windowSampling.title.localized(in: language),
                                options: WindowSamplingRate.allCases.map { rate in
                                    StudioMenuOption(
                                        rate.title.localized(in: language),
                                        isSelected: model.draft.windowSampling == rate
                                    ) {
                                        model.draft.windowSampling = rate
                                    }
                                }
                            )
                        }
                    }

                    HStack {
                        Text(language.text("全屏帧率角标", "Fullscreen FPS Badge"))
                            .font(.callout)
                        Spacer()
                        StudioSwitch(isOn: $model.fullscreenHUDVisible)
                    }
                    .help(
                        language.text(
                            "在全屏播放时于左上角显示实时帧率角标（⌥⌘S）。",
                            "Show a subtle live FPS badge in the top-left corner while in fullscreen (⌥⌘S)."
                        ))

                    if BuildFeatures.developerUI {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 1)
                        InspectorField(language.text("开发者处理器", "Developer Engine")) {
                            StudioMenuButton(
                                title: model.draft.backend.title.localized(in: language),
                                options: ProcessingBackend.allCases.map { backend in
                                    StudioMenuOption(
                                        backend.title.localized(in: language),
                                        isSelected: model.draft.backend == backend
                                    ) {
                                        model.draft.backend = backend
                                    }
                                }
                            )
                        }
                        Button(language.text("开发者性能诊断", "Developer Diagnostics")) {
                            model.diagnosticsPresented = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var footerBar: some View {
        VStack(spacing: 8) {
            if model.configurationChanged && model.active && !model.canHotApplyConfiguration {
                Button {
                    Task { await model.restart() }
                } label: {
                    Label(
                        language.text("应用更改并重启", "Apply Changes & Restart"),
                        systemImage: "arrow.trianglehead.2.clockwise"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                if model.active { model.stop() } else { model.start() }
            } label: {
                let isRunning = model.active
                let isDisabled = model.state == .stopping || (!isRunning && !model.canStart)
                let startTitle =
                    model.draft.source == .window
                    ? language.text("开始采集", "Start Capture")
                    : language.text("开始游玩", "Start Session")
                Label(
                    isRunning ? language.text("停止采集", "Stop Session") : startTitle,
                    systemImage: isRunning ? "stop.fill" : "play.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(
                    isDisabled
                        ? Color.white.opacity(0.38)
                        : (isRunning ? Color(red: 1.0, green: 0.45, blue: 0.46) : .black)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    isDisabled
                        ? Color.white.opacity(0.06)
                        : (isRunning ? Color.red.opacity(0.14) : Color.mint),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isDisabled
                                ? Color.white.opacity(0.09)
                                : (isRunning ? Color.red.opacity(0.32) : Color.clear),
                            lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(model.state == .stopping || (!model.active && !model.canStart))
        }
    }
}

private struct StudioSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, item in
                let isSelected = selection == item.value
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selection = item.value
                    }
                } label: {
                    Text(item.title)
                        .font(.caption.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                        .background(
                            isSelected ? Color.mint.opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isSelected ? Color.mint.opacity(0.45) : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct StudioMenuOption {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    init(_ title: String, isSelected: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void = {}) {
        self.title = title
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
    }
}

private struct StudioMenuButton: View {
    let title: String
    let options: [StudioMenuOption]

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .allowsHitTesting(false)

            StudioMenuHitTarget(title: title, options: options)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        }
        .frame(height: 28)
    }
}

private struct StudioMenuHitTarget: NSViewRepresentable {
    let title: String
    let options: [StudioMenuOption]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.sendAction(on: [.leftMouseDown])
        button.setAccessibilityRole(.popUpButton)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.options = options
        nsView.setAccessibilityTitle(title)
    }

    final class Coordinator: NSObject {
        var options: [StudioMenuOption] = []

        @MainActor @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.minimumWidth = sender.bounds.width
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(
                    title: option.title, action: #selector(selectOption(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = option.isSelected ? .on : .off
                item.isEnabled = option.isEnabled
                menu.addItem(item)
            }
            let origin = NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.height + 4 : -4)
            menu.popUp(positioning: nil, at: origin, in: sender)
        }

        @MainActor @objc private func selectOption(_ sender: NSMenuItem) {
            guard options.indices.contains(sender.tag) else { return }
            options[sender.tag].action()
        }
    }
}

private struct StudioSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.mint : Color.white.opacity(0.16))
                    .frame(width: 34, height: 19)
                Circle()
                    .fill(.white)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
    }
}

private struct StudioDisclosureRow<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
    }
}

private struct InspectorCard<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let headerTrailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        icon: String,
        @ViewBuilder headerTrailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.headerTrailing = headerTrailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.mint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.84))
                Spacer()
                headerTrailing()
            }
            content()
        }
        .padding(13)
        .background(Color.white.opacity(0.042), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
        )
    }
}

private struct InspectorField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
