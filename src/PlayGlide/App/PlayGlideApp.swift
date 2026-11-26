import AppKit
import Darwin
import SwiftUI

@main
enum PlayGlideLauncher {
    @MainActor
    static func main() {
        let identifier = Bundle.main.bundleIdentifier ?? "com.eliosxie.PlayGlide"
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(identifier).lock")
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600) } ?? -1
        }
        guard descriptor >= 0 else {
            perror("PlayGlide: could not open the instance lock")
            return
        }
        // Keep the lock file in place. The OS releases the lock when the process exits.
        defer { close(descriptor) }
        let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
            $0.processIdentifier != getpid() && $0.isFinishedLaunching && !$0.isTerminated
        }
        // Launch Services covers normal app launches. The lock also covers direct executable launches.
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK {
                runningApp?.activate(options: [.activateAllWindows])
            } else {
                perror("PlayGlide: could not acquire the instance lock")
            }
            return
        }
        if let runningApp, runningApp.activate(options: [.activateAllWindows]) || !runningApp.isTerminated {
            return
        }
        PlayGlideApp.main()
    }
}

struct PlayGlideApp: App {
    @StateObject private var workspace = WorkspaceModel(defaults: .standard)
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    var body: some Scene {
        let interfaceLanguage = language.resolved
        Window("PlayGlide", id: "workspace") {
            WorkspaceView(model: workspace, language: interfaceLanguage)
                .environment(\.locale, language.locale)
                .frame(minWidth: 1080, minHeight: 760)
                .task {
                    #if PLAYGLIDE_DEVELOPMENT
                        if ProcessInfo.processInfo.arguments.contains("--demo-autostart") {
                            workspace.draft.source = .testPattern
                            workspace.start()
                        }
                    #endif
                }
        }
        .defaultSize(width: 1360, height: 900)
        .windowStyle(.titleBar)
        .restorationBehavior(.disabled)
        .commands {
            CommandMenu("Language / 语言") {
                Picker("Language / 语言", selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { option in
                        Text(option.optionName).tag(option)
                    }
                }
                .pickerStyle(.inline)
            }
            CommandGroup(after: .toolbar) {
                Button(
                    workspace.active
                        ? interfaceLanguage.text("停止采集", "Stop Capture")
                        : interfaceLanguage.text("开始采集", "Start Capture")
                ) {
                    if workspace.active { workspace.stop() } else { workspace.start() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(workspace.state == .stopping || (!workspace.active && !workspace.canStart))
                Button(
                    workspace.previewExpanded
                        ? interfaceLanguage.text("恢复工作区", "Restore Workspace")
                        : interfaceLanguage.text("画面窗口内最大化", "Expand Preview")
                ) {
                    workspace.togglePreviewExpansion()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(workspace.immersive)
                Button(
                    workspace.audioControls.muted
                        ? interfaceLanguage.text("取消静音", "Unmute Capture Audio")
                        : interfaceLanguage.text("静音采集卡音频", "Mute Capture Audio")
                ) {
                    workspace.toggleAudioMute()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(!workspace.draft.audioEnabled && workspace.applied?.audioEnabled != true)
                Divider()
                Button(interfaceLanguage.text("直通 · 关闭补帧", "Passthrough · Interpolation Off")) {
                    workspace.selectQuickProfile(interpolation: .off)
                }
                .keyboardShortcut("0", modifiers: [.command])
                Button(interfaceLanguage.text("2× 高清补帧（1080p 引擎）", "2× High Detail (1080p Engine)")) {
                    workspace.selectQuickProfile(interpolation: .double, hybridQuality: .hd1080)
                }
                .keyboardShortcut("1", modifiers: [.command])
                Button(interfaceLanguage.text("2× 极速补帧（720p 引擎）", "2× Low Latency (720p Engine)")) {
                    workspace.selectQuickProfile(interpolation: .double, hybridQuality: .fast720)
                }
                .keyboardShortcut("2", modifiers: [.command])
            }
            CommandMenu(Text(verbatim: interfaceLanguage.text("性能", "Performance"))) {
                if BuildFeatures.developmentTools {
                    Button(interfaceLanguage.text("性能与延迟详情", "Performance and Latency Details")) {
                        workspace.diagnosticsPresented = true
                    }
                }
                Button(
                    workspace.fullscreenHUDVisible
                        ? interfaceLanguage.text("隐藏全屏帧率与延迟", "Hide Fullscreen FPS and Latency")
                        : interfaceLanguage.text("显示全屏帧率与延迟", "Show Fullscreen FPS and Latency")
                ) {
                    workspace.toggleFullscreenHUD()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
    }
}
