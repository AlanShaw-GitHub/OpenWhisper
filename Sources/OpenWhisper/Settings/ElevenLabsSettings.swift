import Foundation

struct ElevenLabsSettings: Codable, Equatable {
    init() {}
    private enum CodingKeys: String, CodingKey { case speech, noVerbatim }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        speech = try values.decodeIfPresent(ProviderSettings.self, forKey: .speech) ?? ProviderSettings()
        noVerbatim = try values.decodeIfPresent(Bool.self, forKey: .noVerbatim) ?? true
    }
    var speech = ProviderSettings()
    var noVerbatim = true

    func validate(streaming: Bool) throws {
        try speech.validate()
        let limit = streaming ? 50 : 1000
        guard speech.keywords.count <= limit else { throw OpenWhisperError(L("ElevenLabs 当前模式最多支持 %d 个自定义词汇。", limit)) }
        let forbidden = CharacterSet(charactersIn: "<>{}[]\\")
        guard !speech.keywords.contains(where: { $0.rangeOfCharacter(from: forbidden) != nil || $0.count > (streaming ? 20 : 49) || $0.split(whereSeparator: \.isWhitespace).count > 5 }) else {
            throw OpenWhisperError(L("ElevenLabs 词汇请使用简短词语或短语；实时模式每项最多 20 个字符，不能包含括号或反斜杠。"))
        }
    }
}
