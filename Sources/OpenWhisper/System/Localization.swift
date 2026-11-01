import Foundation

/// Interface languages. Strings are written in Simplified Chinese in the code and translated through
/// `<language>.lproj/Localizable.strings` in the app bundle; `system` follows the macOS language list
/// (including a per-app language chosen in System Settings) and falls back to English.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    var id: String { rawValue }
    /// Every language is listed under its own name so it can be found from any interface language.
    var nativeName: String {
        switch self {
        case .system: return L("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }
    /// The supported language that best matches an ordered list of BCP 47 identifiers; English when none does.
    static func matching(_ identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            let language = Locale.Language(identifier: identifier)
            switch language.languageCode?.identifier {
            case "en": return .english
            case "ja": return .japanese
            case "ko": return .korean
            case "zh", "yue": return language.maximalIdentifier.contains("-Hant") ? .traditionalChinese : .simplifiedChinese
            default: continue
            }
        }
        return .english
    }
}

/// The resolved interface language and its string table. Lookups come from any thread (audio and
/// accessibility errors are built off the main thread); settings change the language on the main thread.
final class Localization: @unchecked Sendable {
    static let shared = Localization()
    private let lock = NSLock()
    private var table: [String: String] = [:]
    private var resolved = AppLanguage.simplifiedChinese
    init() { use(.system) }
    /// Never `.system`: what the choice resolved to.
    var language: AppLanguage { lock.withLock { resolved } }
    var locale: Locale { Locale(identifier: language.rawValue) }
    func use(_ choice: AppLanguage, bundle: Bundle = .main) {
        let language = choice == .system ? AppLanguage.matching(Locale.preferredLanguages) : choice
        // Simplified Chinese is the source language: its keys are the text.
        let strings = language == .simplifiedChinese ? [:] : Self.table(for: language, in: bundle)
        lock.withLock { resolved = language; table = strings }
    }
    func string(_ key: String) -> String { lock.withLock { table[key] } ?? key }
    static func table(for language: AppLanguage, in bundle: Bundle) -> [String: String] {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language.rawValue)
        else { return [:] }
        return NSDictionary(contentsOf: url) as? [String: String] ?? [:]
    }
}

/// Localized interface text. The key is the Simplified Chinese wording.
func L(_ key: String) -> String { Localization.shared.string(key) }
/// Localized format string (`%@`, `%d`); translations may reorder arguments with `%1$@`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.shared.string(key), arguments: arguments)
}
