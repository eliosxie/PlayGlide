# PlayGlide

[简体中文](README.zh-CN.md)

PlayGlide turns your Mac into a display for your PlayStation, Xbox, or Nintendo Switch through a USB HDMI capture card. Play in a window or fullscreen, with game audio through your Mac. Other HDMI sources work with the same setup.

**2× frame interpolation** gives 30 fps games a smoother, 60 fps preview. Even when a capture card sends 30 fps gameplay as a 60 Hz signal, PlayGlide can recognize the repeated frames and generate the frames in between. Turn on **Compare with Original** to see the original motion on the left and the interpolated result on the right, or switch interpolation off to play at the original frame rate.

## Get started

You'll need an **Apple silicon Mac running macOS 27 or later** and a **USB HDMI capture card recognized by macOS**.

Developed and tested on a Mac with an M3 Max chip running macOS 27.

1. Download the macOS arm64 **DMG** from [GitHub Releases](https://github.com/eliosxie/PlayGlide/releases). Open it and drag **PlayGlide.app** onto **Applications**. Current builds use an ad-hoc signature and have not been notarized by Apple, so macOS may block the first launch. [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)
2. Connect your console's HDMI output to the card's HDMI input, then plug the card into your Mac over USB. Capture requires an HDMI signal without HDCP copy protection.
3. Open PlayGlide, select the card and capture format, and click **Start Capture**. Allow camera access for video. For game audio, enable **Play and Sync Capture Audio** and allow microphone access.

## Picture and sound

- **Scaling and HDR.** Use MetalFX to upscale a lower-resolution capture. HDR10 preview requires an HDR signal, a card that passes HDR through to the Mac, and an HDR display.
- **Audio sync.** Choose your speakers or headphones and adjust the audio offset if the sound arrives early or late.

## Build from source

Open [PlayGlide.xcodeproj](PlayGlide.xcodeproj) in Xcode 27 or later with the macOS 27 SDK. Select the **PlayGlide** scheme and press **⌘R**.

## License

[GNU General Public License v3.0](LICENSE)
