import SwiftUI

struct SessionInspector: View {
    @ObservedObject var model: WorkspaceModel
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(language.text("输入", "Input")) {
                    if BuildFeatures.developmentTools {
                        Picker(language.text("来源", "Source"), selection: $model.draft.source) {
                            ForEach(InputSource.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                        .disabled(model.choosingWindow)
                    }
                    if model.draft.source == .captureCard {
                        Picker(language.text("设备", "Device"), selection: $model.draft.deviceID) {
                            if model.devices.isEmpty {
                                Text(language.text("未发现外接视频设备", "No external video devices")).tag("")
                            }
                            ForEach(model.devices) { Text($0.name).tag($0.id) }
                        }
                        .onChange(of: model.draft.deviceID) { _, _ in model.deviceChanged() }
                        Picker(language.text("实际格式", "Capture Format"), selection: $model.draft.formatID) {
                            if model.formats.isEmpty {
                                Text(language.text("请连接并选择采集卡", "Connect and select a capture card")).tag("")
                            }
                            ForEach(model.formats) { Text($0.title.localized(in: language)).tag($0.id) }
                        }
                        Picker(language.text("色彩模式", "Color Mode"), selection: $model.draft.colorMode) {
                            ForEach(InputColorMode.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                        if model.draft.colorMode != .sdrRec709 {
                            Picker(
                                language.text("HDR 画面风格", "HDR Tone Style"),
                                selection: $model.draft.hdrDisplayStyle
                            ) {
                                ForEach(HDRDisplayStyle.allCases) { Text($0.title.localized(in: language)).tag($0) }
                            }
                            Picker(language.text("显示器 HDR", "Display HDR"), selection: $model.draft.systemHDRPolicy) {
                                ForEach(SystemHDRPolicy.allCases) { Text($0.title.localized(in: language)).tag($0) }
                            }
                            .onChange(of: model.draft.systemHDRPolicy) { _, _ in model.syncSystemHDRMode() }
                        }
                        Button(language.text("刷新设备与格式", "Refresh Devices and Formats"), systemImage: "arrow.clockwise")
                        { Task { await model.refreshDevices() } }
                        Toggle(
                            language.text("播放采集卡音频并同步视频", "Play and Sync Capture Audio"),
                            isOn: $model.draft.audioEnabled
                        )
                        .onChange(of: model.draft.audioEnabled) { _, _ in model.audioEnabledChanged() }
                        if model.draft.audioEnabled {
                            Picker(language.text("音频输入", "Audio Input"), selection: $model.draft.audioDeviceID) {
                                Text(language.text("所选视频设备自带音频", "Audio from selected video device")).tag("")
                                ForEach(model.audioDevices) { Text($0.name).tag($0.id) }
                                if !model.draft.audioDeviceID.isEmpty,
                                    !model.audioDevices.contains(where: { $0.id == model.draft.audioDeviceID })
                                {
                                    Text(language.text("所选音频设备已断开", "Selected audio device disconnected")).tag(
                                        model.draft.audioDeviceID)
                                }
                            }
                            Picker(
                                language.text("音频输出", "Audio Output"), selection: $model.audioControls.outputDeviceID
                            ) {
                                Text(language.text("跟随系统输出", "System Output")).tag("")
                                ForEach(model.audioOutputDevices) { device in
                                    Text(
                                        device.isDefault
                                            ? language.text("\(device.name)（系统默认）", "\(device.name) (System Default)")
                                            : device.name
                                    ).tag(device.id)
                                }
                                if !model.audioControls.normalizedOutputDeviceID.isEmpty,
                                    !model.audioOutputDevices.contains(where: {
                                        $0.id == model.audioControls.normalizedOutputDeviceID
                                    })
                                {
                                    Text(language.text("已断开（将自动回退系统默认）", "Disconnected (uses system output)")).tag(
                                        model.audioControls.outputDeviceID)
                                }
                            }
                            HStack(spacing: 10) {
                                Button {
                                    model.toggleAudioMute()
                                } label: {
                                    Label(
                                        model.audioControls.muted
                                            ? language.text("已静音", "Muted") : language.text("音量", "Volume"),
                                        systemImage: model.audioControls.muted
                                            ? "speaker.slash.fill" : "speaker.wave.2.fill"
                                    )
                                }
                                .buttonStyle(.borderless)
                                Slider(value: $model.audioControls.volume, in: 0...1)
                                    .disabled(model.audioControls.muted)
                                Text("\(Int((model.audioControls.clampedVolume * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(language.text("音画手动偏移", "Audio Sync Offset"))
                                    Spacer()
                                    Text(String(format: "%+.0f ms", model.audioControls.clampedOffsetMilliseconds))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    if abs(model.audioControls.clampedOffsetMilliseconds) >= 1 {
                                        Button(language.text("归零", "Reset")) { model.resetAudioOffset() }
                                            .buttonStyle(.borderless).font(.caption)
                                    }
                                }
                                Slider(
                                    value: $model.audioControls.offsetMilliseconds,
                                    in: AudioPlaybackControls
                                        .minOffsetMilliseconds...AudioPlaybackControls
                                        .maxOffsetMilliseconds,
                                    step: 5)
                                Text(
                                    language.text(
                                        "正值延后声音（适配高延迟电视/显示器），负值提前声音；实时生效无需重启。",
                                        "Positive values delay audio. Negative values advance it. Changes apply immediately."
                                    )
                                )
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(
                                language.text(
                                    "已自动匹配采集卡伴生 HDMI 音频，不默认选用系统内建麦克风。声音跟随处理后画面的播放时间，通过系统当前音频输出播放。",
                                    "PlayGlide matches the card's HDMI audio and times playback to the processed video."
                                )
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            if BuildFeatures.developmentTools {
                                let floor = model.draft.presentationMode.audioVideoDelayFloor(
                                    multiplier: model.draft.interpolation.rawValue)
                                let milliseconds = Int((floor * 1000).rounded())
                                Text(
                                    language.text(
                                        "当前呈现策略为音频预留至少 \(milliseconds) ms 的视频调度预算。",
                                        "This presentation mode reserves at least \(milliseconds) ms to sync video with audio."
                                    )
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if model.active, model.applied?.source == .captureCard, model.applied?.audioEnabled == true {
                            LabeledContent(
                                language.text("音频状态", "Audio Status"),
                                value: model.statistics.audioStatus.localized(in: language)
                            )
                            .font(.caption)
                        }
                        Text(
                            language.text(
                                "开始采集时申请相机权限；启用音频后同时申请麦克风权限，以读取所选采集卡音频。HDR10 模式需在采集卡软件关闭硬件色调映射并在显示器开启 HDR。",
                                "macOS requests camera access for capture and microphone access for capture-card audio. For HDR10, turn off capture-card tone mapping and enable HDR on the display."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    } else if BuildFeatures.developmentTools, model.draft.source == .window {
                        Text(model.windowTitle.localized(in: language)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                        Button(
                            model.choosingWindow
                                ? language.text("请在系统选择器中选择…", "Choose a window in the system picker…")
                                : language.text("选择窗口并开始采集", "Choose Window and Start Capture"),
                            systemImage: "macwindow"
                        ) {
                            model.chooseWindow()
                        }.disabled(model.active || model.choosingWindow)
                        Picker(language.text("采集分辨率", "Capture Resolution"), selection: $model.draft.windowResolution) {
                            ForEach(WindowResolutionMode.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                        if model.draft.windowResolution == .fixed {
                            Picker(language.text("采集画布", "Capture Canvas"), selection: $model.draft.windowPreset) {
                                ForEach([InputPreset.hd1080, .qhd1440, .uhd4K]) {
                                    Text($0.title.localized(in: language)).tag($0)
                                }
                            }
                            if model.draft.windowPreset == .uhd4K {
                                Text(
                                    language.text(
                                        "2160p的2×使用原尺寸光流实验后端，保留4K处理像素；稳定60fps需实测。源窗口像素不足时，提高画布尺寸不会恢复原始细节。",
                                        "At 2160p, 2× interpolation uses experimental optical flow at native resolution. Actual performance depends on the Mac. A larger canvas cannot recover missing source detail."
                                    )
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if model.draft.windowResolution == .nativePixels {
                            Text(
                                language.text(
                                    "按源窗口比例保留原生像素，不随预览缩小；长边最高3840、总像素不超过4K。放大PlayGlide不再先放大低尺寸采集图。高分辨率性能以实测为准。",
                                    "Preserves the window's aspect ratio and native pixels, up to 3840 pixels on the long edge and 4K in total. High-resolution performance depends on the Mac."
                                )
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(
                                language.text(
                                    "放大预览后自动提高有效采集尺寸；以源窗口实际像素和4K为上限。较高分辨率的补帧性能以实测为准。",
                                    "Capture resolution grows with the preview, up to the window's native resolution or 4K. High-resolution interpolation performance depends on the Mac."
                                )
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker(language.text("网页采样", "Window Sampling"), selection: $model.draft.windowSampling) {
                            ForEach(WindowSamplingRate.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                        Text(
                            language.text(
                                "已知30帧视频按30 fps采样，吸收窗口回调抖动；静止画面仍会去重。其他片源可选按窗口回调，帧率以实际统计为准。",
                                "For 30 fps video, fixed-rate sampling absorbs callback jitter and detects repeated frames. Other sources can follow window updates."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Text(
                            language.text(
                                "先在浏览器播放视频，再选择该窗口，无需铺满显示器。窗口内容保持原比例完整显示；画布多余部分留黑边，窗口内留白也会保留。声音由浏览器播放，未补偿音画延迟。",
                                "Start playback in the browser, then select its window. PlayGlide fits the full window at its original aspect ratio. The browser continues to play audio at its own timing."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Text(
                            language.text(
                                "这是已显示窗口的采集，不是网站原始视频解码。控制条、字幕和网页动画也会被识别为内容变化。",
                                "Window capture includes visible controls, subtitles, and page animations. They count as changes in the captured image."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    } else if BuildFeatures.developmentTools {
                        Picker(language.text("原始尺寸", "Source Resolution"), selection: $model.draft.inputPreset) {
                            ForEach(InputPreset.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                        Picker(language.text("传输场景", "Signal Pattern"), selection: $model.draft.testSignal) {
                            ForEach(TestSignal.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                        Text(
                            language.text(
                                "生成运动图案，可直接体验补帧、原画对照和全屏预览。",
                                "Try interpolation, split comparison, and fullscreen with a generated pattern.")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(language.text("游戏内容与补帧", "Content and Interpolation")) {
                    Picker(language.text("内容节奏", "Content Cadence"), selection: $model.draft.contentMode) {
                        ForEach(ContentMode.allCases) { Text($0.title.localized(in: language)).tag($0) }
                    }
                    Picker(language.text("补帧", "Interpolation"), selection: $model.draft.interpolation) {
                        ForEach(InterpolationStrategy.availableModes) { Text($0.title.localized(in: language)).tag($0) }
                    }
                    if BuildFeatures.developmentTools {
                        Picker(language.text("处理器", "Processing Engine"), selection: $model.draft.backend) {
                            ForEach(ProcessingBackend.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                    }
                    if model.draft.interpolation == .double && model.draft.backend == .automatic
                        && model.draft.source != .window
                    {
                        Picker(language.text("补帧档位", "Interpolation Quality"), selection: $model.draft.hybridQuality) {
                            ForEach(HybridQuality.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                    }
                    if model.draft.interpolation != .off {
                        Picker(language.text("呈现策略", "Presentation Mode"), selection: $model.draft.presentationMode) {
                            ForEach(PresentationMode.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                        Text(
                            language.text(
                                "低延迟优先使用屏幕最高刷新率，减少显示等待；新画面速率仍由内容与补帧倍率决定。平稳优先按输出节奏刷新，多预留一张输出帧吸收抖动。",
                                "Low Latency uses the highest display refresh rate to minimize wait time. Steady Playback follows the output cadence and buffers an extra frame to absorb jitter."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.draft.interpolation != .off && model.draft.source != .window {
                        Picker(language.text("能耗偏好", "Power Preference"), selection: $model.draft.powerPreference) {
                            ForEach(InterpolationPowerPreference.allCases) {
                                Text($0.title.localized(in: language)).tag($0)
                            }
                        }
                        Text(
                            language.text(
                                "低延迟优先在补帧间隙保持芯片性能状态以压低尾延迟；省电优先停用帧间忙等以降低整机功耗与发热。",
                                "Low Latency holds SoC performance state between interpolated pairs to reduce tail latency. Power Saving disables inter-frame spinning to reduce power and heat."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if BuildFeatures.developmentTools {
                        Text(
                            language.text(
                                "自动模式：跟随预览的窗口2×使用原尺寸光流；固定画布与采集卡按实际尺寸选择VT或光流。高分辨率性能与画质以实测为准。",
                                "Automatic mode uses native optical flow for 2× window capture that follows the preview. Fixed canvases and capture cards use an engine suited to their input resolution."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                let targets = model.availableUpscalingTargets
                if !targets.isEmpty {
                    Section(language.text("画面放大", "Upscaling")) {
                        Picker(language.text("超分", "Upscaling Method"), selection: $model.draft.upscaling) {
                            ForEach(UpscalingStrategy.allCases) { Text($0.title.localized(in: language)).tag($0) }
                        }
                        if model.draft.upscaling != .off {
                            Picker(language.text("输出目标", "Output Resolution"), selection: $model.draft.outputPreset) {
                                ForEach(targets) { Text($0.title.localized(in: language)).tag($0) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: model.availableUpscalingTargets, initial: true) { _, _ in
                model.updateUpscalingTarget()
            }

            VStack(alignment: .leading, spacing: 10) {
                if model.configurationChanged && model.active {
                    if model.canHotApplyConfiguration {
                        Text(
                            language.text(
                                "处理设置已修改，可免断流实时生效（不断画面与音频）。", "Updated processing settings can apply during playback.")
                        )
                        .font(.caption).foregroundStyle(.mint)
                        Button(language.text("实时应用（不断流）", "Apply Live"), systemImage: "bolt.fill") {
                            Task { await model.applyConfiguration() }
                        }.frame(maxWidth: .infinity)
                    } else {
                        Text(
                            language.text("设置已修改，重启后应用。正在运行的配置保持独立。", "Restart capture to apply the updated settings.")
                        )
                        .font(.caption).foregroundStyle(.orange)
                        Button(
                            language.text("应用并重启", "Apply and Restart"), systemImage: "arrow.trianglehead.2.clockwise"
                        ) {
                            Task { await model.restart() }
                        }.frame(maxWidth: .infinity)
                    }
                }
                Button {
                    if model.active { model.stop() } else { model.start() }
                } label: {
                    Label(
                        model.active
                            ? language.text("停止", "Stop")
                            : BuildFeatures.developmentTools && model.draft.source == .testPattern
                                ? language.text("运行测试源", "Run Test Pattern") : language.text("开始采集", "Start Capture"),
                        systemImage: model.active ? "stop.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.state == .stopping || (!model.active && !model.canStart))
                if let interpolation = model.applied?.interpolation.title.localized(in: language), model.active {
                    Text(language.text("当前补帧：\(interpolation)", "Current interpolation: \(interpolation)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
    }
}
