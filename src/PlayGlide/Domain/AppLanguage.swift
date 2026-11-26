import Foundation

enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "com.eliosxie.PlayGlide.language"

    static var selected: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    var resolved: Self {
        guard self == .system else { return self }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    var optionName: String {
        switch self {
        case .system: "System / 跟随系统"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    func text(_ chinese: @autoclosure () -> String, _ english: @autoclosure () -> String) -> String {
        resolved == .simplifiedChinese ? chinese() : english()
    }
}

/// Keeps session messages available in both languages so changing the UI language needs no restart.
struct AppText: Equatable, Sendable, ExpressibleByStringLiteral {
    let chinese: String
    let english: String

    init(_ chinese: String, _ english: String) {
        self.chinese = chinese
        self.english = english
    }

    init(verbatim value: String) { self.init(value, value) }
    init(stringLiteral value: String) { self.init(verbatim: value) }

    init(error: any Error) {
        self = (error as? PipelineError)?.message ?? Self(verbatim: error.localizedDescription)
    }

    func localized(in language: AppLanguage) -> String { language.text(chinese, english) }
}
