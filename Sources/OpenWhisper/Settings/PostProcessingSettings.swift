import Foundation

/// Whole-transcript rewriting by a text model after the recording stops, shared by every speech
/// service. Unlike per-segment edits, the model sees the full context, so list formatting is reliable.
enum PostProcessingRule: String, Codable, CaseIterable, Identifiable {
    case misrecognitions, fillers, punctuation, numericValues, dates, spokenLists
    var id: String { rawValue }
    var title: String {
        switch self {
        case .misrecognitions: return L("纠正同音、近音的识别错误")
        case .fillers: return L("去除语气词、口误与重复")
        case .punctuation: return L("整理标点与空格")
        case .numericValues: return L("数量、金额与百分比 → 数字")
        case .dates: return L("完整日期 → 该语言的书面格式")
        case .spokenLists: return L("明确的列表 → 分行项目")
        }
    }
    var instruction: String {
        switch self {
        case .misrecognitions:
            // Live recognisers commit early words before the sentence that disambiguates them has been heard; the
            // rewrite sees the whole dictation, so it can restore the intended word from later context.
            return "Fix speech-recognition errors: a word that sounds like what was said but makes no sense in context (homophones and near-homophones, misheard names, technical terms, or English words inside Chinese speech, such as \"过你和\" → \"过拟合\" or \"clear the cash\" → \"clear the cache\"). Use the whole text, including later sentences, and the listed names and terms to restore the word the speaker meant. Change only words that are clearly wrong in context; when unsure, keep them."
        case .fillers:
            return "Remove filler words, false starts, stutters and immediate self-corrections, keeping the speaker's final wording (\"我们、我们明天\" → \"我们明天\"; \"um, so\" is dropped)."
        case .punctuation:
            return "Fix punctuation, capitalization and spacing following the conventions of the language (Chinese uses full-width punctuation and no spaces between Chinese words)."
        case .numericValues:
            return "Write counts, quantities, money and percentages with digits (\"五十万元\" → \"50万元\"; \"twenty five percent\" → \"25%\"). Keep idioms such as \"a dozen\" or \"a couple\"."
        case .dates:
            return "Write spoken dates in the conventional written form of the text's language (Chinese: 2026年7月12日; English: July 12, 2026). Keep exactly the parts that were spoken; never add a year, month or day."
        case .spokenLists:
            return "When the speaker explicitly enumerates items (first/second/third, 第一/第二/第三, 一是/二是, \"three things: …\"), put each item on its own line starting with \"- \" and keep the introductory sentence on its own line. Ordinary prose stays a paragraph."
        }
    }
    static let defaultRules: [PostProcessingRule] = allCases
}

/// Text model used for the rewrite. On a typical dictation DeepSeek Flash answers in about 1 s and OpenAI gpt-6-luna
/// in 1.5–2 s.
enum PostProcessingEngine: String, Codable, CaseIterable, Identifiable {
    case deepseek, openai, gemini
    var id: String { rawValue }
    var title: String {
        switch self { case .deepseek: return "DeepSeek Flash"; case .openai: return "OpenAI"; case .gemini: return "Gemini" }
    }
    /// Credential slot in the local key file; OpenAI shares the speech service's key.
    var keyID: String { rawValue }
    var keyTitle: String {
        switch self { case .deepseek: return L("%@ API key", "DeepSeek"); case .openai: return L("%@ API key", "OpenAI"); case .gemini: return L("%@ API key", "Gemini") }
    }
    var defaultModel: String {
        switch self { case .deepseek: return "deepseek-flash"; case .openai: return "gpt-6-luna"; case .gemini: return "gemini-3.5-flash-lite" }
    }
    var allowsCustomModel: Bool { self != .deepseek }
}

struct PostProcessingSettings: Codable, Equatable {
    var enabled = false
    var engine = PostProcessingEngine.deepseek
    var rules = PostProcessingRule.defaultRules.map(\.rawValue)
    var customInstruction = ""
    var openAIModel = ""
    var geminiModel = ""

    init() {}
    private enum CodingKeys: String, CodingKey { case enabled, engine, rules, customInstruction, openAIModel, geminiModel }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        engine = (try? values.decodeIfPresent(PostProcessingEngine.self, forKey: .engine)) ?? .deepseek
        // A rule this build does not know is dropped.
        let known = Set(PostProcessingRule.allCases.map(\.rawValue))
        rules = (try values.decodeIfPresent([String].self, forKey: .rules) ?? rules).filter { known.contains($0) }
        customInstruction = try values.decodeIfPresent(String.self, forKey: .customInstruction) ?? ""
        openAIModel = try values.decodeIfPresent(String.self, forKey: .openAIModel) ?? ""
        geminiModel = try values.decodeIfPresent(String.self, forKey: .geminiModel) ?? ""
    }
    var selectedRules: [PostProcessingRule] { PostProcessingRule.allCases.filter { rules.contains($0.rawValue) } }
    var trimmedCustomInstruction: String { customInstruction.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Enabled with at least one rule or a custom instruction.
    var isActive: Bool { enabled && (!selectedRules.isEmpty || !trimmedCustomInstruction.isEmpty) }
    /// DeepSeek is fixed to Flash; the others fall back to their default when the field is empty.
    var model: String {
        let custom: String
        switch engine {
        case .deepseek: return engine.defaultModel
        case .openai: custom = openAIModel
        case .gemini: custom = geminiModel
        }
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? engine.defaultModel : trimmed
    }
}
