import XCTest
@testable import OpenWhisper

final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let languages: [AppLanguage] = [.english, .traditionalChinese, .japanese, .korean]

    /// Every `L("…")` key in the app's sources, in the order they appear.
    private func sourceKeys() throws -> [String] {
        let sources = Self.root.appendingPathComponent("Sources/OpenWhisper")
        let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" && !file.path.contains("/Diagnostics/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[Range(match.range(at: 1), in: text)!])
                XCTAssertFalse(key.contains("\\("), "Interpolation inside a localization key: \(key)")
                if !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }
    private func table(_ language: AppLanguage) throws -> [String: String] {
        let url = Self.root.appendingPathComponent("Resources/\(language.rawValue).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language.rawValue) table")
    }
    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[@dlu]+"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
            .sorted()
    }

    func testEveryInterfaceStringIsTranslated() throws {
        let keys = try sourceKeys()
        XCTAssertGreaterThan(keys.count, 150)
        for language in Self.languages {
            let strings = try table(language)
            for key in keys {
                guard let value = strings[key] else { XCTFail("\(language.rawValue) is missing “\(key)”"); continue }
                XCTAssertFalse(value.isEmpty, "\(language.rawValue): empty translation for “\(key)”")
                XCTAssertEqual(placeholders(value), placeholders(key), "\(language.rawValue): placeholders differ for “\(key)”")
            }
            XCTAssertEqual(Set(strings.keys).subtracting(keys), [], "\(language.rawValue) has entries no code uses")
        }
    }

    func testMicrophonePromptIsLocalized() throws {
        for language in Self.languages + [.simplifiedChinese] {
            let url = Self.root.appendingPathComponent("Resources/\(language.rawValue).lproj/InfoPlist.strings")
            let strings = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            XCTAssertFalse(strings["NSMicrophoneUsageDescription", default: ""].isEmpty, language.rawValue)
        }
    }

    func testSystemLanguageResolvesToTheClosestSupportedOne() {
        XCTAssertEqual(AppLanguage.matching(["zh-Hans-US", "en-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-HK"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.matching(["yue-Hant-HK"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.matching(["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.matching(["ko-KR"]), .korean)
        // The first supported language in the list wins; unsupported ones are skipped, English is the fallback.
        XCTAssertEqual(AppLanguage.matching(["fr-FR", "ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.matching(["fr-FR", "de-DE"]), .english)
        XCTAssertEqual(AppLanguage.matching([]), .english)
    }

    func testLookupUsesTheChosenTableAndFallsBackToTheKey() throws {
        let bundle = try XCTUnwrap(Bundle(url: Self.root.appendingPathComponent("Resources")))
        defer { Localization.shared.use(.system) }
        Localization.shared.use(.japanese, bundle: bundle)
        XCTAssertEqual(Localization.shared.language, .japanese)
        XCTAssertEqual(L("取消"), "キャンセル")
        XCTAssertEqual(L("按 %@ 开始听写", "⌃⌘"), "⌃⌘ を押して音声入力を開始")
        XCTAssertEqual(L("一个没有翻译的键"), "一个没有翻译的键")
        Localization.shared.use(.simplifiedChinese, bundle: bundle)
        XCTAssertEqual(L("取消"), "取消")
        XCTAssertEqual(L("已选 %d 项", 3), "已选 3 项")
    }

    func testLanguageNamesFollowTheInterfaceLanguage() {
        defer { Localization.shared.use(.system) }
        Localization.shared.use(.english, bundle: Bundle(for: Self.self))
        let french = SpeechLanguage.shared.first { $0.code == "fr" }!
        XCTAssertEqual(french.title, "French · Français")
        Localization.shared.use(.simplifiedChinese, bundle: Bundle(for: Self.self))
        XCTAssertEqual(french.title, "法语 · Français")
        XCTAssertEqual(SpeechLanguage.shared.first { $0.code == "zh" }!.title, "中文")
    }

    func testConfigurationKeepsTheInterfaceLanguage() throws {
        var config = Configuration(); config.interfaceLanguage = .korean
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.interfaceLanguage, .korean)
        let withoutLanguage = try JSONDecoder().decode(Configuration.self, from: Data(#"{"provider":"openai"}"#.utf8))
        XCTAssertEqual(withoutLanguage.interfaceLanguage, .system)
    }
}
