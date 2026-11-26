import AVFoundation
import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    let language: AppLanguage

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
        .overlayPreferenceValue(PreviewBoundsKey.self) { anchor in
            GeometryReader { geometry in
                let bounds =
                    model.previewOnly
                    ? CGRect(origin: .zero, size: geometry.size)
                    : anchor.map { geometry[$0] } ?? .zero
                // Keep one Metal surface alive while only its bounds change.
                // Expanding the preview must not restart capture or presentation.
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
            PerformanceDiagnosticsView(model: model, language: language)
        }
    }

    private var workspace: some View {
        session.toolbar {
            if !model.previewOnly {
                ToolbarItem {
                    Label(
                        model.state.title.localized(in: language),
                        systemImage: model.state == .running ? "circle.fill" : "circle.dotted"
                    )
                    .foregroundStyle(model.state == .running ? .green : .secondary)
                }
                ToolbarItem {
                    Button(language.text("全屏", "Fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right") {
                        model.toggleFullScreen()
                    }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                }
            }
        }
    }

    private var session: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(language.text("实时预览", "Live Preview")).font(.title2.weight(.semibold))
                        if BuildFeatures.developmentTools, model.statistics.backend != "—" {
                            Text(model.statistics.backend.localized(in: language))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle(language.text("原画对照", "Compare with Original"), isOn: $model.originalComparison).toggleStyle(
                        .button
                    )
                    .help(
                        language.text(
                            "同一画面左半显示原画，右半显示处理效果；保持完整画面比例",
                            "Compare the original on the left with the processed image on the right at the original aspect ratio."
                        ))
                }
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 260)
                    .anchorPreference(key: PreviewBoundsKey.self, value: .bounds) { $0 }
                if let message = model.errorMessage {
                    HStack(alignment: .top) {
                        Label(message.localized(in: language), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                        Button(language.text("关闭", "Close"), systemImage: "xmark") { model.errorMessage = nil }
                            .labelStyle(.iconOnly)
                    }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                } else if let warning = model.signalWarning {
                    HStack(alignment: .top) {
                        Label(warning.localized(in: language), systemImage: "antenna.radiowaves.left.and.right.slash")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                    }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                Grid(horizontalSpacing: 0, verticalSpacing: 14) {
                    GridRow {
                        metric(
                            language.text("采集传输", "Capture"), value: fps(model.inputFPS),
                            detail: model.statistics.inputSize?.description ?? language.text("尚无输入", "No input"))
                        metric(
                            language.text("内容输入", "Content"), value: fps(model.contentFPS),
                            detail: language.text(
                                "识别重复 \(model.statistics.duplicates)", "\(model.statistics.duplicates) repeats detected"
                            ))
                        metric(
                            language.text("实际呈现 · 5秒均值", "Presented · 5 s avg."), value: fps(model.presentedFPS),
                            detail: language.text(
                                "生成速率 \(model.generatedFPS.formatted(.number.precision(.fractionLength(1)))) fps",
                                "Generated \(model.generatedFPS.formatted(.number.precision(.fractionLength(1)))) fps"))
                    }
                    GridRow {
                        metric(
                            language.text("处理 p95", "Processing p95"),
                            value: model.statistics.content > 0 ? String(format: "%.1f ms", model.statistics.p95) : "—",
                            detail: language.text("检测、适配与补帧耗时", "Detection, adaptation, interpolation"))
                        metric(
                            language.text("输出目标", "Output Resolution"),
                            value: model.statistics.outputSize?.description ?? "—",
                            detail: String(
                                format: language.text("显示 %.1f Hz · GPU %.1f ms", "Display %.1f Hz · GPU %.1f ms"),
                                model.statistics.displayInterval > 0 ? 1 / model.statistics.displayInterval : 0.0,
                                model.statistics.renderMilliseconds))
                        metric(
                            language.text("应用内延迟 p50 / p95", "In-App Latency p50 / p95"), value: latencySummary,
                            detail: language.text("采集回调→呈现；不含采集卡缓冲、面板响应", "Capture callback to presentation")
                        )
                        .help(
                            language.text(
                                "统计最近 600 张原始内容帧从采集回调到系统实际呈现的时间。",
                                "Time from capture callback to presentation for the last 600 original frames."))
                    }
                }
                .padding(.vertical, 14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                Label(
                    model.performanceMessage.localized(in: language),
                    systemImage: model.overloaded && model.active ? "gauge.with.dots.needle.67percent" : "info.circle"
                )
                .font(.caption).foregroundStyle(model.overloaded && model.active ? .orange : .secondary)
                .frame(minHeight: 28, alignment: .leading)
            }
            .padding(22)
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            SessionInspector(model: model, language: language).frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
        }
    }
    private func fps(_ value: Double) -> String { model.active ? String(format: "%.1f fps", value) : "—" }
    private var latencySummary: String {
        guard let p50 = model.statistics.presentationLatency.p50, let p95 = model.statistics.presentationLatency.p95
        else { return "—" }
        return String(format: "%.1f / %.1f ms", p50, p95)
    }
    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(
                0.75)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
    }
}

private struct PerformanceDiagnosticsView: View {
    @ObservedObject var model: WorkspaceModel
    let language: AppLanguage

    var body: some View {
        let summary = model.diagnosticSummary(in: language)
        VStack(alignment: .leading, spacing: 18) {
            Text(language.text("性能与延迟详情", "Performance and Latency")).font(.title2)
            ScrollView {
                Text(summary)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(language.text("实时性能与延迟", "Live Performance and Latency"))
                    .accessibilityValue(summary)
            }
            Button(language.text("关闭", "Close")) { model.diagnosticsPresented = false }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(minWidth: 620, idealHeight: 760)
    }
}

private struct PreviewPanel: View {
    @ObservedObject var model: WorkspaceModel
    let language: AppLanguage

    private var unobstructedFullscreen: Bool {
        model.immersive && model.active && model.statistics.lastOutputTime != 0
            && model.errorMessage == nil && !model.waitingForInput && model.signalWarning == nil
    }

    private var showsOverlays: Bool {
        !unobstructedFullscreen || model.fullscreenControlsVisible
    }

    private var idlePrompt: (title: String, detail: String) {
        if BuildFeatures.developmentTools {
            switch model.draft.source {
            case .window:
                return (
                    language.text("选择视频窗口", "Choose a Video Window"),
                    language.text("开始播放后，在系统选择器中选择该窗口。", "Start playback, then choose the window in the system picker.")
                )
            case .testPattern:
                return (
                    language.text("运行测试源", "Run Test Pattern"),
                    language.text("使用生成画面检查补帧和预览。", "Check interpolation and preview with a generated pattern.")
                )
            case .captureCard:
                break
            }
        }
        if model.devices.isEmpty {
            return (
                language.text("连接采集卡", "Connect a Capture Card"),
                language.text(
                    "将 HDMI 信号源接到采集卡，再通过 USB 将采集卡接入 Mac。",
                    "Connect your HDMI source to the capture card and the card to your Mac over USB.")
            )
        }
        return (
            language.text("准备采集", "Ready to Capture"),
            language.text("选择采集卡和格式，然后开始采集。", "Choose a capture card and format, then start capture.")
        )
    }

    var body: some View {
        ZStack {
            if !unobstructedFullscreen {
                Color(red: 0.02, green: 0.03, blue: 0.05)
            }
            MetalPreviewSurface(
                mailbox: model.mailbox, active: model.active,
                outputFrameDuration: model.statistics.outputFrameDuration,
                presentationMode: (model.applied ?? model.draft).presentationMode,
                prefersLateSelection: model.applied?.interpolation == .double
                    && PreviewLateSelection.configured.applies(to: model.statistics.inputSize),
                immersive: model.immersive,
                roundedCorners: !model.previewOnly,
                hdr10Active: model.effectiveHDR10Active,
                onPointerMove: { model.revealFullscreenControls() }
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
            if !model.active || model.statistics.lastOutputTime == 0 || model.errorMessage != nil {
                Color(red: 0.02, green: 0.03, blue: 0.05)
                VStack(spacing: 14) {
                    if model.active, model.errorMessage == nil {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 40, weight: .light))
                            .foregroundStyle(.mint)
                    }
                    let title = model.active ? model.state.title.localized(in: language) : idlePrompt.title
                    Text(model.errorMessage == nil ? title : language.text("预览异常", "Preview Error")).font(
                        .title3.weight(.medium))
                    Text(
                        model.errorMessage?.localized(in: language)
                            ?? (model.active
                                ? language.text("正在等待视频画面。", "Waiting for video.")
                                : idlePrompt.detail)
                    )
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24)
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture(count: 2) { model.togglePreviewExpansion() }
        .overlay(alignment: .topLeading) {
            if showsOverlays {
                statusBadge
            } else if model.immersive && model.active && model.fullscreenHUDVisible {
                fullscreenHUDBadge
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsOverlays { windowActionButton }
        }
        .onDisappear { model.hideFullscreenControls() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("视频预览", "Video Preview"))
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

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(statusBadgeColor).frame(width: 6, height: 6)
            Text(statusBadgeTitle)
            if model.originalComparison {
                Text(language.text("· 左原画 / 右处理", "· Original left / Processed right")).foregroundStyle(.mint)
            }
        }
        .font(.caption).foregroundStyle(.white.opacity(0.85)).padding(10)
        .background(.black.opacity(0.45), in: Capsule()).padding(14)
    }

    private var statusBadgeColor: Color {
        if model.signalWarning != nil { return .orange }
        return model.state == .running && !model.waitingForInput ? .mint : .gray
    }

    private var statusBadgeTitle: String {
        if let warning = model.signalWarning { return warning.localized(in: language) }
        if model.waitingForInput {
            return language.text("等待输入信号 · HDMI 握手中或尚无新帧", "Waiting for input · HDMI handshake or no new frames")
        }
        switch (model.applied ?? model.draft).source {
        case .testPattern: return language.text("动态测试源", "Test Pattern")
        case .window: return language.text("网页 / 窗口输入 · 实验 · SDR", "Window Capture · Experimental · SDR")
        case .captureCard:
            switch (model.applied ?? model.draft).colorMode {
            case .hdr10PQ: return language.text("外接视频采集 · HDR10 PQ", "Capture Card · HDR10 PQ")
            case .sdrRec709: return language.text("外接视频采集 · SDR", "Capture Card · SDR")
            case .automatic:
                return model.statistics.detectedHDR10
                    ? language.text("外接视频采集 · 自动 · HDR10 PQ", "Capture Card · Auto · HDR10 PQ")
                    : language.text("外接视频采集 · 自动 · SDR", "Capture Card · Auto · SDR")
            }
        }
    }

    private var windowActionButton: some View {
        HStack(spacing: 8) {
            if model.active, model.applied?.source == .captureCard, model.applied?.audioEnabled == true {
                Button(
                    model.audioControls.muted ? language.text("取消静音", "Unmute") : language.text("静音", "Mute"),
                    systemImage: model.audioControls.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                ) {
                    model.toggleAudioMute()
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.black.opacity(0.65), in: Capsule())
            }
            Group {
                if model.immersive {
                    Button(language.text("退出全屏", "Exit Fullscreen"), systemImage: "arrow.down.right.and.arrow.up.left")
                    { model.toggleFullScreen() }
                } else {
                    Button(
                        model.previewExpanded
                            ? language.text("恢复工作区", "Restore Workspace") : language.text("窗口内最大化", "Expand Preview"),
                        systemImage: model.previewExpanded ? "arrow.down.right.and.arrow.up.left" : "viewfinder"
                    ) { model.togglePreviewExpansion() }
                    .help(
                        model.previewExpanded
                            ? language.text("恢复设置与统计（Esc / ⇧⌘M）", "Restore settings and statistics (Esc / ⇧⌘M)")
                            : language.text(
                                "在当前窗口内放大画面（双击画面 / ⇧⌘M）", "Expand the preview within this window (double-click / ⇧⌘M)"))
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.65), in: Capsule())
        }
        .padding(14)
    }

    private func comparisonLabel(_ title: String) -> some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.65), in: Capsule())
            .frame(maxWidth: .infinity)
    }
}

private struct PreviewBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
