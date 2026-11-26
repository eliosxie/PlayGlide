import Foundation

enum WindowResolutionMode: String, CaseIterable, Identifiable, Sendable {
    case nativePixels, adaptive, fixed
    var id: Self { self }
    var title: AppText {
        switch self {
        case .nativePixels: AppText("原像素优先 · 4K像素预算", "Native Pixels · 4K Limit")
        case .adaptive: AppText("跟随预览 · 性能优先", "Match Preview · Performance")
        case .fixed: AppText("固定画布", "Fixed Canvas")
        }
    }
}

struct WindowCaptureSizing {
    /// Preserve the window's aspect ratio, stop at native pixels, and bound work
    /// to a 4K surface (including portrait windows).
    static func target(
        preview: VideoSize?, native: VideoSize, fallback: VideoSize, preserveNativePixels: Bool = false
    ) -> VideoSize {
        guard native.width > 0, native.height > 0 else { return fallback }
        if preserveNativePixels {
            let pixels = Double(native.width) * Double(native.height)
            let scale = min(
                1, 3840 / Double(native.width), 3840 / Double(native.height),
                (Double(InputPreset.uhd4K.size.pixels) / pixels).squareRoot())
            return VideoSize(
                width: max(2, Int(Double(native.width) * scale / 2) * 2),
                height: max(2, Int(Double(native.height) * scale / 2) * 2))
        }
        let destination = preview ?? fallback
        let maximum =
            native.width >= native.height
            ? VideoSize(width: 3840, height: 2160) : VideoSize(width: 2160, height: 3840)
        let scale = min(
            1, Double(maximum.width) / Double(native.width), Double(maximum.height) / Double(native.height),
            Double(max(2, destination.width)) / Double(native.width),
            Double(max(2, destination.height)) / Double(native.height))
        return VideoSize(
            width: max(2, Int(Double(native.width) * scale / 2) * 2),
            height: max(2, Int(Double(native.height) * scale / 2) * 2))
    }
}

/// One pending size, with no queued resize work during interactive window dragging.
struct WindowResolutionSettler {
    private var candidate: VideoSize?
    private var since = 0.0
    private(set) var applied: VideoSize
    init(applied: VideoSize) { self.applied = applied }
    mutating func propose(_ size: VideoSize, now: Double) -> VideoSize? {
        guard size != applied else {
            candidate = nil
            return nil
        }
        if size != candidate {
            candidate = size
            since = now
        }
        guard now - since >= 0.35 else { return nil }
        return size
    }
    mutating func acknowledge(_ size: VideoSize) {
        applied = size
        candidate = nil
    }

    mutating func retry(now: Double) { since = now }
}
