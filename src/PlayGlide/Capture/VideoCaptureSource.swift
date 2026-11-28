import CoreMedia
import Foundation

protocol VideoCaptureSource: Actor {
    func start() async throws -> AsyncThrowingStream<VideoFrame, Error>
    func stop() async
}

struct CaptureFormatDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let index: Int
    let size: VideoSize
    let subtype: UInt32
    let duration: CMTime
    var fps: Double { 1 / duration.seconds }
    static func isCompressed(subtype: UInt32) -> Bool {
        switch fourCC(subtype) {
        case "dmb1", "MJPG", "mjpg", "jpeg", "mjpa", "mjpb", "avc1", "avc3", "hvc1", "hev1": true
        default: false
        }
    }
    var isCompressed: Bool { Self.isCompressed(subtype: subtype) }
    var title: AppText {
        let format = "\(size) · \(fps.formatted(.number.precision(.fractionLength(0...2)))) fps · \(fourCC(subtype))"
        guard isCompressed else { return AppText(verbatim: format) }
        return AppText("\(format)（压缩）", "\(format) (Compressed)")
    }

    fileprivate static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.isCompressed != rhs.isCompressed { return !lhs.isCompressed }
        if lhs.size.pixels != rhs.size.pixels { return lhs.size.pixels > rhs.size.pixels }
        let durationOrder = CMTimeCompare(lhs.duration, rhs.duration)
        if durationOrder != 0 { return durationOrder < 0 }
        if lhs.size != rhs.size { return lhs.size.width > rhs.size.width }
        let lhsIsVideoRangeNV12 = lhs.subtype == 0x3432_3076  // 420v
        let rhsIsVideoRangeNV12 = rhs.subtype == 0x3432_3076
        if lhsIsVideoRangeNV12 != rhsIsVideoRangeNV12 { return lhsIsVideoRangeNV12 }
        return lhs.index < rhs.index
    }
}

struct CaptureDeviceDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let formats: [CaptureFormatDescriptor]
    let hasBuiltInAudio: Bool

    init(id: String, name: String, formats: [CaptureFormatDescriptor], hasBuiltInAudio: Bool = false) {
        self.id = id
        self.name = name
        self.hasBuiltInAudio = hasBuiltInAudio
        var unique: [CaptureFormatDescriptor] = []
        for candidate in formats.sorted(by: CaptureFormatDescriptor.precedes) {
            if !unique.contains(where: {
                $0.size == candidate.size && $0.subtype == candidate.subtype
                    && abs($0.duration.seconds - candidate.duration.seconds) < 0.000002
            }) {
                unique.append(candidate)
            }
        }
        self.formats = unique
    }

    /// Prefer 59.94 or 60 Hz capture formats, starting with uncompressed 1080p.
    /// A compressed 1080p mode gives way only to an uncompressed mode at the same rate and at least its size;
    /// USB 2.0 cards often offer raw modes only at low rates or small sizes.
    var preferredFormat: CaptureFormatDescriptor? {
        let hd = InputPreset.hd1080.size
        let fullRate = formats.filter { abs($0.fps - 60) < 0.1 }
        if let raw = fullRate.first(where: { $0.size == hd && !$0.isCompressed }) { return raw }
        if let raw = fullRate.first(where: { $0.size.pixels >= hd.pixels && !$0.isCompressed }) { return raw }
        if let compressed = fullRate.first(where: { $0.size == hd }) { return compressed }
        // `max(by:)` keeps the first of equal sizes, and the sorted list puts raw modes first.
        return fullRate.max { $0.size.pixels < $1.size.pixels } ?? formats.first
    }
}

struct CaptureAudioDeviceDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let isExternal: Bool
    let manufacturer: String

    init(id: String, name: String, isExternal: Bool = true, manufacturer: String = "") {
        self.id = id
        self.name = name
        self.isExternal = isExternal
        self.manufacturer = manufacturer
    }

    private static let genericTokens: Set<String> = [
        "usb", "audio", "video", "capture", "hdmi", "device", "input", "digital", "interface", "game", "card", "hd",
    ]
    private static let builtInExcludedSubstrings: [String] = [
        "macbook", "built-in", "内建", "microphone", "麦克风", "airpods", "iphone", "ipad", "continuity", "teams",
        "zoom", "blackhole", "loopback",
    ]

    /// Finds an external HDMI audio companion matching `videoDevice` without ever auto-selecting a built-in mic.
    static func recommendedMatch(
        for videoDevice: CaptureDeviceDescriptor, in audioDevices: [CaptureAudioDeviceDescriptor]
    ) -> CaptureAudioDeviceDescriptor? {
        let videoNorm = normalizedName(videoDevice.name)
        guard !videoNorm.isEmpty else { return nil }
        let videoTokens = distinctiveTokens(from: videoDevice.name)
        let videoAllTokens = allTokens(from: videoDevice.name)

        let candidates = audioDevices.filter { candidate in
            guard candidate.isExternal else { return false }
            let lower = candidate.name.lowercased()
            if builtInExcludedSubstrings.contains(where: { lower.contains($0) }) { return false }
            return true
        }
        guard !candidates.isEmpty else { return nil }

        // 1. Exact normalized name match (most UVC+UAC cards like Elgato 4K X share the exact localized name).
        if let exact = candidates.first(where: { normalizedName($0.name) == videoNorm }) {
            return exact
        }
        // 2. Substring containment on normalized names (e.g. "Game Capture 4K X" vs "Elgato Game Capture 4K X").
        if let contained = candidates.first(where: {
            let norm = normalizedName($0.name)
            return !norm.isEmpty && (norm.contains(videoNorm) || videoNorm.contains(norm))
        }) {
            return contained
        }
        // 3. Distinctive model-token overlap (e.g. "4k", "elgato", "gc553", "camlink").
        var best: (device: CaptureAudioDeviceDescriptor, score: Int)?
        for candidate in candidates {
            let audioTokens = distinctiveTokens(from: candidate.name)
            let sharedDistinctive = videoTokens.intersection(audioTokens).count
            guard sharedDistinctive > 0 else { continue }
            let sharedAll = videoAllTokens.intersection(allTokens(from: candidate.name)).count
            let manufacturerBonus =
                !candidate.manufacturer.isEmpty
                    && videoNorm.contains(normalizedName(candidate.manufacturer)) ? 2 : 0
            let score = sharedDistinctive * 10 + sharedAll + manufacturerBonus
            if best == nil || score > best!.score {
                best = (candidate, score)
            }
        }
        return best?.device
    }

    private static func normalizedName(_ name: String) -> String {
        allTokens(from: name).joined(separator: " ")
    }

    private static func allTokens(from name: String) -> Set<String> {
        let parts = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { !$0.isEmpty })
    }

    private static func distinctiveTokens(from name: String) -> Set<String> {
        allTokens(from: name).filter { token in
            !genericTokens.contains(token) && (token.count >= 2 || token.first?.isNumber == true)
        }
    }
}

struct AudioOutputDeviceDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let isDefault: Bool
}

enum AudioOutputRouteResolver {
    /// Resolves a requested CoreAudio output device UID against currently available output devices.
    /// Returns `nil` to follow the macOS system default when empty or disconnected.
    static func resolvedDeviceUID(
        requested: String, available: [AudioOutputDeviceDescriptor]
    ) -> String? {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return available.contains(where: { $0.id == trimmed }) ? trimmed : nil
    }
}

/// Pure classifier for incoming capture frames so HDMI hot re-handshakes and transient HDR frames
/// never terminate the session and remain unit-testable without hardware.
struct CaptureSampleGate: Sendable {
    static let maxWidth = 3840
    static let maxHeight = 2160
    static let hdrWarning = AppText(
        "当前色彩模式为 SDR。请将输入切换为 SDR，或为 HDR10 信号选择 HDR10 PQ。",
        "The color mode is SDR. Switch the source to SDR, or select HDR10 PQ for HDR10 input.")

    enum Decision: Sendable, Equatable {
        case accept(rehandshaked: Bool)
        case dropTransient(hdr: Bool, warning: AppText?)
    }

    private(set) var lastObservedSize: VideoSize?

    mutating func evaluate(
        hasImage: Bool, size: VideoSize?, transferFunction: String?, timestampValid: Bool, allowsHDR: Bool = false
    ) -> Decision {
        guard hasImage, let size else {
            return .dropTransient(hdr: false, warning: nil)
        }
        guard size.width > 0, size.height > 0, size.width <= Self.maxWidth, size.height <= Self.maxHeight else {
            return .dropTransient(
                hdr: false,
                warning: AppText(
                    "输入尺寸超出 4K 上限（\(size)），等待信号恢复",
                    "Input size exceeds the 4K limit (\(size)). Waiting for a supported signal."))
        }
        if !allowsHDR, let transferFunction,
            transferFunction == "SMPTE_ST_2084_PQ" || transferFunction == "ITU_R_2100_HLG"
        {
            return .dropTransient(hdr: true, warning: Self.hdrWarning)
        }
        guard timestampValid else {
            return .dropTransient(hdr: false, warning: nil)
        }
        let rehandshaked = lastObservedSize != nil && lastObservedSize != size
        lastObservedSize = size
        return .accept(rehandshaked: rehandshaked)
    }
}

/// Bounded automatic recovery policy for transient AVCaptureSession runtime errors during HDMI handshakes.
struct CaptureSessionRecoveryPolicy: Sendable {
    static let maxAttempts = 3
    static let windowSeconds = 10.0
    static let backoffMilliseconds = [250, 500, 1000]

    private var attempts: [Double] = []

    mutating func nextDelayMilliseconds(at now: Double, deviceConnected: Bool) -> Int? {
        guard deviceConnected, now.isFinite else { return nil }
        attempts.removeAll { now - $0 > Self.windowSeconds || now < $0 }
        guard attempts.count < Self.maxAttempts else { return nil }
        attempts.append(now)
        return Self.backoffMilliseconds[min(attempts.count - 1, Self.backoffMilliseconds.count - 1)]
    }

    mutating func reset() {
        attempts.removeAll()
    }
}

func fourCC(_ value: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }, encoding: .ascii) ?? String(value)
}
