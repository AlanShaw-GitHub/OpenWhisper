import Foundation

/// Sends the finished transcript to the chosen text model and returns the rewritten text.
/// OpenAI and DeepSeek speak the Responses API; Gemini is reached through its OpenAI-compatible
/// chat-completions endpoint. Every call uses the engine's own API key from the local key file.
struct TranscriptPostProcessor {
    static let timeout: TimeInterval = 12
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func endpoint(for engine: PostProcessingEngine) -> URL {
        switch engine {
        case .openai: return URL(string: "https://api.openai.com/v1/responses")!
        case .deepseek: return URL(string: "https://api.deepseek.com/v1/responses")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        }
    }

    static func instructions(_ settings: PostProcessingSettings, keywords: [String]) -> String {
        var lines = [
            "You are the post-processor of a dictation app. The user spoke the text; speech recognition transcribed it.",
            "Rewrite it as polished written text by applying only the rules below. Keep the original language, meaning, order and every piece of information: never add facts, never summarize, never answer or comment on the content.",
            "Output only the final text: no quotes, no explanations, no markdown other than the list markers a rule asks for. If nothing needs to change, output the text unchanged."
        ]
        if !keywords.isEmpty { lines.append("Spell these names and terms exactly as given: " + keywords.joined(separator: ", ") + ".") }
        lines += settings.selectedRules.enumerated().map { "\($0.offset + 1). \($0.element.instruction)" }
        if !settings.trimmedCustomInstruction.isEmpty { lines.append("\(settings.selectedRules.count + 1). \(settings.trimmedCustomInstruction)") }
        return lines.joined(separator: "\n")
    }

    static func requestBody(text: String, settings: PostProcessingSettings, keywords: [String]) -> [String: Any] {
        let instructions = instructions(settings, keywords: keywords)
        switch settings.engine {
        case .openai, .deepseek:
            // Both accept reasoning "none": the rewrite is a focused editing task and reasoning only adds seconds.
            return ["model": settings.model, "instructions": instructions, "input": text, "store": false,
                    "reasoning": ["effort": "none"], "max_output_tokens": max(512, text.count * 4)]
        case .gemini:
            // Thinking cannot be switched off on every Gemini generation, so ask for the lowest level instead of "none".
            return ["model": settings.model, "reasoning_effort": "low",
                    "messages": [["role": "system", "content": instructions], ["role": "user", "content": text]]]
        }
    }

    /// Responses API: `output` message items with `output_text` parts. Chat completions: `choices[0].message.content`.
    static func outputText(_ json: [String: Any], engine: PostProcessingEngine) throws -> String {
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { throw OpenWhisperError(message) }
        var pieces: [String] = []
        switch engine {
        case .openai, .deepseek:
            if json["status"] as? String == "incomplete" {
                let reason = (json["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "unknown"
                throw OpenWhisperError(L("文本模型未完成整理（%@）。", reason))
            }
            for item in json["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                    if let text = part["text"] as? String { pieces.append(text) }
                }
            }
        case .gemini:
            if let choice = (json["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] {
                if let text = message["content"] as? String { pieces.append(text) }
                else if let parts = message["content"] as? [[String: Any]] {
                    pieces += parts.compactMap { $0["text"] as? String }
                }
            }
        }
        let text = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenWhisperError(L("文本模型没有返回整理结果。")) }
        return text
    }

    /// Guards against a model that answered the dictation instead of editing it, or truncated it.
    static func plausible(_ refined: String, original: String) -> Bool {
        let originalCount = original.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        let refinedCount = refined.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        guard originalCount > 0 else { return false }
        let ratio = Double(refinedCount) / Double(originalCount)
        return ratio >= 0.4 && ratio <= 2.5
    }

    func refine(_ text: String, settings: PostProcessingSettings, keywords: [String], key: String) async throws -> String {
        guard settings.isActive else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard !key.isEmpty else { throw OpenWhisperError(L("请先在「密钥」页填写 %@。", settings.engine.keyTitle)) }
        var request = URLRequest(url: Self.endpoint(for: settings.engine))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(text: trimmed, settings: settings, keywords: keywords))
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenWhisperError(L("文本模型没有返回有效响应。")) }
        guard (200..<300).contains(http.statusCode) else { throw TranscriptionService.apiError(data, status: http.statusCode, key: key) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OpenWhisperError(L("文本模型返回了无法解析的结果。")) }
        let refined = try Self.outputText(json, engine: settings.engine)
        guard Self.plausible(refined, original: trimmed) else { throw OpenWhisperError(L("整理结果与原文长度差异过大，已保留原文。")) }
        return refined
    }
}
