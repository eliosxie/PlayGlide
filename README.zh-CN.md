# PlayGlide

[English](README.md)

用一张 USB HDMI 采集卡，就能把 Mac 当作 PlayStation、Xbox 或 Nintendo Switch 的显示器。PlayGlide 支持窗口和全屏游玩，游戏声音也可以从 Mac 播放。其他 HDMI 设备的接法相同。

**2× 补帧**可以让 30 帧游戏在 Mac 上以 60 帧预览。即使采集卡输出的是 60 Hz 信号，PlayGlide 也能识别其中重复的游戏画面，在相邻两帧之间补出一帧。打开「原画对照」，左半边是原画，右半边是补帧效果。想按原始帧率游玩时，关掉补帧即可。

## 开始使用

你需要一台搭载 **Apple 芯片、运行 macOS 27 或更高版本的 Mac**，以及一张 **macOS 能识别的 USB HDMI 采集卡**。

1. 从 [GitHub Releases](https://github.com/eliosxie/PlayGlide/releases) 下载 macOS arm64 的 **DMG**。双击打开，将 **PlayGlide.app** 拖到「Applications（应用程序）」文件夹。当前构建使用临时签名，未经 Apple 公证，macOS 可能会阻止首次启动。[Apple 关于打开下载应用的说明](https://support.apple.com/zh-cn/102445)
2. 将主机的 HDMI 输出接到采集卡的 HDMI 输入，再用 USB 把采集卡连到 Mac。采集需要未受 HDCP 保护的 HDMI 信号。
3. 打开 PlayGlide，选择采集卡和采集格式，点击「开始采集」，按提示允许相机访问。要播放游戏声音，请勾选「播放采集卡音频并同步视频」，并允许麦克风访问。

## 画面与声音

- **画面放大与 HDR。** 采集分辨率较低时，可以用 MetalFX 放大画面。预览 HDR10 需要 HDR 信号、能将 HDR 信号传给 Mac 的采集卡，以及支持 HDR 的显示器。
- **音画同步。** 可以选择扬声器或耳机作为输出。如果声音比画面快或慢，可以手动调整音频偏移。

## 从源码运行

使用 Xcode 27 或更高版本及 macOS 27 SDK 打开 [PlayGlide.xcodeproj](PlayGlide.xcodeproj)，选择 **PlayGlide** 方案，按 **⌘R** 运行。

## 许可证

[GNU 通用公共许可证第 3 版](LICENSE)
