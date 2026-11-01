import Foundation

enum ElevenLabsRequest {
    static func liveURL(_ configuration: Configuration) throws -> URL {
        let settings = configuration.elevenLabsSettings
        try settings.validate(streaming: true)
        var items = [URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_24000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: "0.5"),
            URLQueryItem(name: "keepalive_interval_ms", value: "1000"),
            URLQueryItem(name: "no_verbatim", value: String(settings.noVerbatim))]
        if let primary = configuration.languageCodes.first {
            items.append(URLQueryItem(name: "language_code", value: primary))
            items += configuration.languageCodes.dropFirst().map { URLQueryItem(name: "secondary_languages", value: $0) }
        }
        items += settings.speech.keywords.map { URLQueryItem(name: "keyterms", value: $0) }
        var url = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        // URLComponents leaves "+" bare, which servers decode as a space ("C++" would arrive as "C  ").
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "+&=")
        url.percentEncodedQuery = items.map { item in
            "\(item.name)=\((item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return url.url!
    }
    static func fileFields(_ configuration: Configuration) throws -> [(String, String)] {
        let settings = configuration.elevenLabsSettings
        try settings.validate(streaming: false)
        var fields = [("model_id", "scribe_v2"), ("no_verbatim", String(settings.noVerbatim)),
            ("tag_audio_events", "false"), ("diarize", "false"), ("timestamps_granularity", "none")]
        // Batch accepts one optional language; multiple selections retain auto detection.
        if configuration.languageCodes.count == 1, let code = configuration.languageCodes.first { fields.append(("language_code", code)) }
        fields += settings.speech.keywords.map { ("keyterms", $0) }
        return fields
    }
    static func fileText(_ response: [String: Any]) throws -> String {
        guard let text = response["text"] as? String else { throw OpenWhisperError(L("ElevenLabs 返回了无法识别的转写结果。")) }
        return text
    }
    static func audio(_ pcm: Data) -> [String: Any] {
        ["message_type": "input_audio_chunk", "audio_base_64": pcm.base64EncodedString(), "sample_rate": AudioData.sampleRate, "commit": false]
    }
}
