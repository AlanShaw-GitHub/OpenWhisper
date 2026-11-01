import Foundation

struct ProviderSettings: Codable, Equatable {
    var keywordText = ""
    var keywords: [String] {
        var seen = Set<String>()
        return keywordText.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    func validate() throws {
        if keywords.contains(where: { $0.contains("<") || $0.contains(">") }) {
            throw OpenWhisperError(L("自定义词汇不能包含 < 或 >，请修改后重试。"))
        }
    }
}

struct SpeechLanguage: Identifiable, Equatable {
    let code: String
    /// The language's name for itself, shown after the name in the interface language.
    let endonym: String
    let museName: String?
    /// Locale identifier for the interface-language name, when the request code is not one ("zh-cn").
    private let localeID: String?
    var id: String { code }
    init(_ code: String, _ endonym: String, _ museName: String? = nil, localeID: String? = nil) {
        self.code = code; self.endonym = endonym; self.museName = museName; self.localeID = localeID
    }
    /// "French · Français" in English, "法语 · Français" in Chinese; just "日本語" when both names agree.
    var title: String {
        let locale = Localization.shared.locale
        let name = (localeID.flatMap { locale.localizedString(forIdentifier: $0) } ?? locale.localizedString(forLanguageCode: code)) ?? endonym
        return name == endonym ? name : "\(name) · \(endonym)"
    }
    /// The 25 languages documented by Meta; OpenAI also accepts the Chinese locale codes below.
    static let shared: [SpeechLanguage] = [
        .init("zh", "中文", "Mandarin Chinese"),
        .init("en", "English", "English"),
        .init("fr", "Français", "French"),
        .init("de", "Deutsch", "German"),
        .init("ja", "日本語", "Japanese"),
        .init("ko", "한국어", "Korean"),
        .init("es", "Español", "Spanish"),
        .init("pt", "Português", "Portuguese"),
        .init("it", "Italiano", "Italian"),
        .init("nl", "Nederlands", "Dutch"),
        .init("ar", "العربية", "Arabic"),
        .init("bn", "বাংলা", "Bengali"),
        .init("he", "עברית", "Hebrew"),
        .init("hi", "हिन्दी", "Hindi"),
        .init("id", "Indonesia", "Indonesian"),
        .init("kn", "ಕನ್ನಡ", "Kannada"),
        .init("ms", "Melayu", "Malay"),
        .init("mr", "मराठी", "Marathi"),
        .init("pl", "Polski", "Polish"),
        .init("tl", "Tagalog", "Tagalog"),
        .init("ta", "தமிழ்", "Tamil"),
        .init("te", "తెలుగు", "Telugu"),
        .init("th", "ไทย", "Thai"),
        .init("tr", "Türkçe", "Turkish"),
        .init("vi", "Tiếng Việt", "Vietnamese")
    ]
    static func available(for provider: Provider) -> [SpeechLanguage] {
        if provider == .muse { return shared }
        return [.init("zh-cn", "简体中文", localeID: "zh-Hans"), .init("zh-tw", "繁體中文", localeID: "zh-Hant"), .init("yue", "粵語")] + shared
    }
    static func names(for codes: [String], provider: Provider) -> [String] {
        let languages = available(for: provider)
        return codes.map { code in languages.first { $0.code == code }?.title ?? code }
    }
}
