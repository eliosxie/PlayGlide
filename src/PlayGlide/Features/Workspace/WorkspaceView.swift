import AVFoundation
import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: WorkspaceModel
    let language: AppLanguage
    @Binding var languageSelection: AppLanguage
    @Binding var usesLightAppearance: Bool

    private var studioBackground: Color {
        colorScheme == .light
            ? Color(red: 0.93, green: 0.95, blue: 0.97)
            : Color(red: 0.055, green: 0.06, blue: 0.075)
    }

    private var inspectorBackground: Color {
        colorScheme == .light
            ? Color(red: 0.98, green: 0.985, blue: 0.99)
            : Color(red: 0.082, green: 0.088, blue: 0.106)
    }

    private var appearanceActionTitle: String {
        usesLightAppearance
            ? language.text("切换到深色外观", "Switch to Dark Appearance")
            : language.text("切换到浅色外观", "Switch to Light Appearance")
    }

    var body: some View {
        ZStack {
            if model.immersive {
                Color.black.ignoresSafeArea(.container)
            } else {
                workspace
                    .opacity(model.previewOnly ? 0 : 1)
                    .allowsHitTesting(!model.previewOnly)
                    .accessibilityHidden(model.previewOnly)
            }
        }
        .tint(colorScheme.workspaceAccent)
        .background(studioBackground.ignoresSafeArea())
        .overlayPreferenceValue(PreviewBoundsKey.self) { anchor in
            GeometryReader { geometry in
                let bounds =
                    model.previewOnly
                    ? CGRect(origin: .zero, size: geometry.size)
                    : anchor.map { geometry[$0] } ?? .zero
                // Keep one Metal surface alive while only its bounds change.
                // Collapsing the inspector or expanding the preview must not restart capture.
                PreviewPanel(model: model, language: language)
                    .frame(width: bounds.width, height: bounds.height)
                    .position(x: bounds.midX, y: bounds.midY)
                    .opacity(model.previewOnly || anchor != nil ? 1 : 0)
                    .allowsHitTesting(model.previewOnly || anchor != nil)
                    .accessibilityHidden(!model.previewOnly && anchor == nil)
            }
            .ignoresSafeArea(.container, edges: model.immersive ? .all : [])
        }
        .toolbarVisibility(model.immersive ? .hidden : .visible, for: .windowToolbar)
        .onExitCommand {
            if model.previewExpanded { model.previewExpanded = false }
        }
        .task { await model.refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            Task { await model.refreshDevices() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            Task { await model.refreshDevices() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            model.immersive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            model.hideFullscreenControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            model.immersive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.handleApplicationResignedActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.handleApplicationBecameActive()
        }
        .onDisappear { model.stop() }
        .sheet(isPresented: $model.diagnosticsPresented) {
            if BuildFeatures.developerUI {
                PerformanceDiagnosticsView(model: model, language: language)
            }
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            videoStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.inspectorVisible {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 1)
                SessionInspector(model: model, language: language)
                    .frame(width: 316)
                    .background(inspectorBackground, ignoresSafeAreaEdges: .bottom)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.inspectorVisible)
        .toolbarBackground(studioBackground, for: .windowToolbar)
        .toolbar {
            if !model.previewOnly {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        Text("PlayGlide")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 4)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .navigation) {
                        toolbarStatusPill
                    }
                    ToolbarSpacer(.flexible)
                } else {
                    ToolbarItem(placement: .navigation) {
                        Text("PlayGlide")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 4)
                    }
                    ToolbarItem(placement: .navigation) {
                        toolbarStatusPill
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.originalComparison.toggle()
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .foregroundStyle(model.originalComparison ? colorScheme.workspaceAccent : Color.primary)
                    }
                    .disabled(!model.active || model.statistics.lastOutputTime == 0)
                    .help(
                        language.text(
                            "左右分屏对照原画与处理后画面",
                            "Split view comparing original on the left and processed video on the right"
                        ))

                    Button {
                        model.toggleFullScreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                    .help(language.text("全屏预览（⌃⌘F）", "Enter Fullscreen (⌃⌘F)"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(AppLanguage.allCases, id: \.self) { option in
                            Button {
                                languageSelection = option
                            } label: {
                                if languageSelection == option {
                                    Label(option.optionName, systemImage: "checkmark")
                                } else {
                                    Text(option.optionName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text(languageSelection.compactLabel)
                                .font(.caption.weight(.medium))
                        }
                    }
                    .menuIndicator(.hidden)
                    .help(language.text("切换界面语言", "Switch Interface Language"))
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(appearanceActionTitle, systemImage: usesLightAppearance ? "moon.fill" : "sun.max.fill") {
                        usesLightAppearance.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .help(appearanceActionTitle)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.inspectorVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                            .foregroundStyle(model.inspectorVisible ? colorScheme.workspaceAccent : Color.primary)
                    }
                    .help(
                        model.inspectorVisible
                            ? language.text("收起设置栏（⌥⌘I）", "Hide Inspector (⌥⌘I)")
                            : language.text("展开设置栏（⌥⌘I）", "Show Inspector (⌥⌘I)")
                    )
                }
            }
        }
    }

    private var toolbarStatusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusDotColor.opacity(model.state == .running ? 0.7 : 0), radius: 4)
            Text(toolbarStatusText)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(model.state == .running ? .primary : .secondary)
        }
        .padding(.horizontal, 6)
    }

    private var statusDotColor: Color {
        if model.errorMessage != nil || model.signalWarning != nil { return .orange }
        switch model.state {
        case .running: return model.waitingForInput ? .orange : colorScheme.workspaceAccent
        case .starting, .stopping: return .yellow
        case .idle: return Color.primary.opacity(0.35)
        }
    }

    private var toolbarStatusText: String {
        switch model.state {
        case .idle:
            return language.text("待机", "Ready")
        case .starting:
            return language.text("连接中…", "Connecting…")
        case .stopping:
            return language.text("停止中…", "Stopping…")
        case .running:
            if model.waitingForInput {
                return language.text("等待信号", "Waiting for Signal")
            }
            let fpsText = model.presentedFPS > 0.5 ? String(format: "%.1f fps", model.presentedFPS) : "…"
            return "\(fpsText) · \(activeModeTag)"
        }
    }

    private var activeModeTag: String {
        let settings = model.applied ?? model.draft
        if settings.interpolation == .off {
            return language.text("原画直通", "Passthrough")
        }
        if model.statistics.fgHeld {
            return language.text("负载直通", "Auto Passthrough")
        }
        if settings.interpolation == .double,
            model.statistics.passthroughFrames > 0,
            model.statistics.contentInterval > 0, model.statistics.contentInterval < 1.0 / 45.0
        {
            return model.statistics.contentInterval < 1.0 / 90.0
                ? language.text("原生 120 fps", "Native 120 fps")
                : language.text("原生 60 fps", "Native 60 fps")
        }
        switch settings.interpolation {
        case .off:
            return language.text("原画直通", "Passthrough")
        case .double:
            return settings.hybridQuality == .fast720
                ? language.text("2× 极速", "2× Fast")
                : language.text("2× 高清", "2× High")
        case .triple:
            return language.text("3× 高刷", "3× 120 Hz")
        case .quadruple:
            return "4×"
        }
    }

    private var videoStage: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 320)
                    .anchorPreference(key: PreviewBoundsKey.self, value: .bounds) { $0 }

                if let message = model.errorMessage {
                    floatingBanner(
                        text: message.localized(in: language),
                        icon: "exclamationmark.triangle.fill",
                        dismiss: { model.errorMessage = nil })
                } else if let warning = model.signalWarning {
                    floatingBanner(
                        text: warning.localized(in: language),
                        icon: "antenna.radiowaves.left.and.right.slash",
                        dismiss: nil)
                }
            }

            if model.active && model.statistics.lastOutputTime != 0 {
                liveBottomStrip
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func floatingBanner(text: String, icon: String, dismiss: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.top, 14)
        .padding(.horizontal, 20)
    }

    private var liveBottomStrip: some View {
        HStack(spacing: 8) {
            if let size = model.statistics.outputSize {
                stripChip(size.description)
            }
            if model.effectiveHDR10Active {
                stripChip("HDR10", tint: colorScheme.workspaceAccent)
            }
            if model.applied?.upscaling == .metalFXSpatial {
                stripChip("MetalFX", tint: colorScheme.workspaceAccent)
            }
            if model.overloaded {
                Label(
                    model.performanceMessage.localized(in: language),
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(colorScheme == .light ? Color(red: 0.56, green: 0.27, blue: 0) : .orange)
                .lineLimit(1)
            }
            Spacer()
            if model.applied?.source == .captureCard, model.applied?.audioEnabled == true {
                Button {
                    model.toggleAudioMute()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.audioControls.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(model.audioControls.muted ? Color.secondary : colorScheme.workspaceAccent)
                        Text(
                            model.audioControls.muted
                                ? language.text("静音", "Muted")
                                : "\(Int((model.audioControls.clampedVolume * 100).rounded()))%"
                        )
                        .monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.audioControls.muted ? .secondary : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(language.text("静音或恢复音频（⌥⌘M）", "Mute or Unmute Audio (⌥⌘M)"))
            }
            Button {
                model.togglePreviewExpansion()
            } label: {
                Image(systemName: "viewfinder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(language.text("窗口内最大化画面（双击画面 / ⇧⌘M）", "Expand preview in window (Double-click / ⇧⌘M)"))
        }
        .padding(.horizontal, 2)
    }

    private func stripChip(_ title: String, tint: Color = .secondary) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(tint == .secondary ? .primary.opacity(0.85) : tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                (tint == .secondary ? Color.primary.opacity(0.055) : tint.opacity(0.14)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    tint == .secondary ? Color.primary.opacity(0.07) : tint.opacity(0.28),
                    lineWidth: 1)
            )
    }
}

private struct PerformanceDiagnosticsView: View {
    @ObservedObject var model: WorkspaceModel
    let language: AppLanguage

    var body: some View {
        let summary = model.diagnosticSummary(in: language)
        VStack(alignment: .leading, spacing: 18) {
            Text(language.text("开发者性能诊断", "Developer Diagnostics")).font(.title2)
            ScrollView {
                Text(summary)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(language.text("关闭", "Close")) { model.diagnosticsPresented = false }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(minWidth: 620, idealHeight: 760)
    }
}

private struct PreviewPanel: View {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: WorkspaceModel
    let language: AppLanguage

    private var unobstructedFullscreen: Bool {
        model.immersive && model.active && model.statistics.lastOutputTime != 0
            && model.errorMessage == nil && !model.waitingForInput && model.signalWarning == nil
    }

    private var showsFullscreenOverlays: Bool {
        model.immersive && (!unobstructedFullscreen || model.fullscreenControlsVisible)
    }

    private var showsExpandedOverlays: Bool {
        !model.immersive && model.previewExpanded
    }

    private var idleCopy: (icon: String, title: String, detail: String, actionLabel: String?) {
        switch model.draft.source {
        case .window:
            let hasWindow = model.canStart
            return (
                "macwindow",
                hasWindow
                    ? model.windowTitle.localized(in: language)
                    : language.text("选择要增强的窗口", "Choose a Window to Enhance"),
                hasWindow
                    ? language.text("窗口已就绪，点击下方按钮立即开始。", "Window is ready. Click below to start.")
                    : language.text("先在播放器或浏览器中打开视频，再选择对应窗口。", "Start video playback, then select that window."),
                hasWindow
                    ? language.text("开始采集", "Start Capture")
                    : language.text("选择窗口", "Choose Window")
            )
        case .testPattern:
            return (
                "sparkles.tv",
                language.text("内置测试源", "Built-In Test Pattern"),
                language.text("开发者模式合成信号源。", "Developer synthetic test signal."),
                language.text("运行测试源", "Run Test Pattern")
            )
        case .captureCard:
            if model.devices.isEmpty {
                return (
                    "tv.and.mediabox",
                    language.text("未检测到采集卡", "No Capture Card Detected"),
                    language.text(
                        "请将主机 HDMI 接入采集卡，并通过高速 USB 连接到 Mac。",
                        "Connect your console over HDMI to the capture card and plug the card into your Mac."
                    ),
                    nil
                )
            }
            let deviceName = model.devices.first(where: { $0.id == model.draft.deviceID })?.name ?? "Capture Card"
            let formatSummary = model.selectedFormat?.title.localized(in: language) ?? ""
            return (
                "gamecontroller.fill",
                deviceName,
                formatSummary.isEmpty
                    ? language.text("在右侧选择采集格式后即可开始。", "Choose a capture format in the inspector to begin.")
                    : formatSummary,
                model.canStart ? language.text("开始游玩", "Start Session") : nil
            )
        }
    }

    var body: some View {
        let cornerRadius: CGFloat = model.previewOnly ? 0 : 12
        ZStack {
            if !unobstructedFullscreen {
                Color(red: 0.02, green: 0.022, blue: 0.03)
            }
            MetalPreviewSurface(
                mailbox: model.mailbox, active: model.active,
                outputFrameDuration: model.statistics.outputFrameDuration,
                presentationMode: (model.applied ?? model.draft).presentationMode,
                prefersLateSelection: PreviewDisplayTiming.prefersLateSelection(
                    for: model.applied?.interpolation, inputSize: model.statistics.inputSize),
                immersive: model.immersive,
                roundedCorners: !model.previewOnly,
                hdr10Active: model.effectiveHDR10Active,
                hdrDisplayStyle: model.draft.hdrDisplayStyle,
                onPointerMove: { model.revealFullscreenControls() },
                onDisplayIDChange: { model.setPreviewDisplayID($0) }
            )
            .allowsHitTesting(false).accessibilityHidden(true)

            if model.originalComparison && model.active && model.statistics.lastOutputTime != 0 {
                Rectangle().fill(.white.opacity(0.75)).frame(width: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
                VStack {
                    Spacer()
                    HStack(spacing: 0) {
                        comparisonLabel(language.text("原画", "Original"))
                        comparisonLabel(language.text("处理后", "Processed"))
                    }.padding(.bottom, 16)
                }.allowsHitTesting(false)
            }

            if !model.active || model.statistics.lastOutputTime == 0 {
                idleBackdrop
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if !model.previewOnly {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(model.previewOnly ? 0 : (colorScheme == .light ? 0.14 : 0.4)), radius: 18, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture(count: 2) { model.togglePreviewExpansion() }
        .overlay(alignment: .topLeading) {
            if model.immersive && model.active && model.fullscreenHUDVisible && !showsFullscreenOverlays {
                fullscreenHUDBadge
            } else if showsFullscreenOverlays || showsExpandedOverlays {
                fullscreenStatusPill
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsFullscreenOverlays || showsExpandedOverlays {
                fullscreenActionButtons
            }
        }
        .onDisappear { model.hideFullscreenControls() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("视频预览", "Video Preview"))
    }

    private var idleBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .light
                    ? [Color(red: 0.99, green: 0.995, blue: 1), Color(red: 0.93, green: 0.96, blue: 0.98)]
                    : [Color(red: 0.04, green: 0.048, blue: 0.065), Color(red: 0.022, green: 0.025, blue: 0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [colorScheme.workspaceAccent.opacity(0.09), Color.clear],
                center: .center,
                startRadius: 10,
                endRadius: 240
            )
            VStack(spacing: 16) {
                if model.active {
                    ProgressView()
                        .controlSize(.large)
                        .tint(colorScheme.workspaceAccent)
                    Text(
                        model.waitingForInput
                            ? language.text("正在等待 HDMI 信号…", "Waiting for HDMI Signal…")
                            : language.text("正在启动画面…", "Starting Preview…")
                    )
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                } else {
                    let info = idleCopy
                    ZStack {
                        Circle()
                            .fill(colorScheme.workspaceAccent.opacity(0.12))
                            .frame(width: 72, height: 72)
                            .overlay(Circle().strokeBorder(colorScheme.workspaceAccent.opacity(0.28), lineWidth: 1))
                        Image(systemName: info.icon)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(colorScheme.workspaceAccent)
                    }
                    VStack(spacing: 6) {
                        Text(info.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(info.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    if let action = info.actionLabel {
                        let actionIcon = model.draft.source == .window && !model.canStart ? "macwindow" : "play.fill"
                        let actionForeground: Color = colorScheme == .light ? .white : .black
                        Button {
                            if model.draft.source == .window && !model.canStart {
                                model.chooseWindow()
                            } else {
                                model.start()
                            }
                        } label: {
                            Label(action, systemImage: actionIcon)
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(colorScheme.workspaceAccent)
                        .foregroundStyle(appearsActive ? actionForeground : Color.primary)
                        .controlSize(.large)
                        .padding(.top, 4)
                    } else if model.draft.source == .captureCard && model.devices.isEmpty {
                        Button {
                            Task { await model.refreshDevices() }
                        } label: {
                            Label(language.text("重新扫描设备", "Scan Again"), systemImage: "arrow.clockwise")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.top, 4)
                    }
                }
            }
            .padding(28)
        }
    }

    private var fullscreenHUDBadge: some View {
        Text(model.fullscreenHUDSummary(in: language))
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var fullscreenStatusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.signalWarning != nil ? .orange : (model.state == .running ? .mint : .gray))
                .frame(width: 6, height: 6)
            Text(
                model.signalWarning?.localized(in: language)
                    ?? (model.effectiveHDR10Active
                        ? language.text("HDR10 实时预览", "Live HDR10")
                        : language.text("实时预览", "Live Preview"))
            )
            if model.originalComparison {
                Text(language.text("· 左原画 / 右处理", "· Original / Processed")).foregroundStyle(.mint)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .padding(14)
    }

    private var fullscreenActionButtons: some View {
        HStack(spacing: 8) {
            if model.active, model.applied?.source == .captureCard, model.applied?.audioEnabled == true {
                Button {
                    model.toggleAudioMute()
                } label: {
                    Label(
                        model.audioControls.muted ? language.text("取消静音", "Unmute") : language.text("静音", "Mute"),
                        systemImage: model.audioControls.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button {
                if model.immersive { model.toggleFullScreen() } else { model.togglePreviewExpansion() }
            } label: {
                Label(
                    model.immersive
                        ? language.text("退出全屏", "Exit Fullscreen")
                        : language.text("恢复工作区", "Restore Workspace"),
                    systemImage: "arrow.down.right.and.arrow.up.left"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .environment(\.colorScheme, .dark)
        .padding(14)
    }

    private func comparisonLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity)
    }
}

extension ColorScheme {
    var workspaceAccent: Color {
        self == .light ? Color(red: 0.01, green: 0.4, blue: 0.34) : .mint
    }
}

private struct PreviewBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
