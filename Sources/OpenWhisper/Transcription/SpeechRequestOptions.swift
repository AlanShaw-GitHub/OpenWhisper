import Foundation

enum SpeechRequestOptions {
    static func muse(_ configuration: Configuration, encoding: String, key: String? = nil) throws -> [String: Any] {
        let settings = configuration.museSettings
        try settings.validate()
        var result: [String: Any] = ["mode": "PUSH_TO_TALK", "model": configuration.museModel, "audioEncoding": encoding]
        if !configuration.languageCodes.isEmpty {
            let names = configuration.languageCodes.compactMap { code in SpeechLanguage.shared.first { $0.code == code }?.museName }
            guard names.count == configuration.languageCodes.count else { throw OpenWhisperError(L("所选语言不受 Muse 支持，请重新选择。")) }
            result["languageBias"] = names
        }
        if !settings.keywords.isEmpty { result["keywords"] = settings.keywords }
        if let key {
            result["authorization"] = ["accessToken": "Bearer \(key)"]
            result["partialMode"] = "CUMULATIVE"; result["emitAudioProgress"] = false
        }
        return result
    }
    static func openAIFileFields(_ configuration: Configuration) throws -> [(String, String)] {
        let settings = configuration.openAISettings
        try settings.validate()
        var result = [("model", configuration.openAIBatchModel), ("response_format", "json")]
        let prompt = configuration.trimmedOpenAIPrompt
        if configuration.openAIBatchModel == "gpt-transcribe" {
            result += configuration.languageCodes.map { ("languages[]", $0) }
            result += settings.keywords.map { ("keywords[]", $0) }
            if !prompt.isEmpty { result.append(("prompt", prompt)) }
        } else {
            guard configuration.languageCodes.count <= 1 else { throw OpenWhisperError(L("当前完整录音模型只支持单一语言提示。多语言提示请使用 gpt-transcribe。")) }
            if let code = configuration.languageCodes.first { result.append(("language", code)) }
            // Older models have no keyword field; fold the terms into the prompt after the free-text context.
            let combined = [prompt, settings.keywords.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " ")
            if !combined.isEmpty { result.append(("prompt", combined)) }
        }
        return result
    }
    static func openAILive(_ configuration: Configuration) throws -> [String: Any] {
        let settings = configuration.openAISettings
        try settings.validate()
        var result: [String: Any] = ["model": configuration.openAILiveModel]
        if !configuration.languageCodes.isEmpty { result["languages"] = configuration.languageCodes }
        if !settings.keywords.isEmpty { result["keywords"] = settings.keywords }
        if !configuration.trimmedOpenAIPrompt.isEmpty { result["prompt"] = configuration.trimmedOpenAIPrompt }
        // `delay` is documented for gpt-live-transcribe and gpt-transcribe realtime sessions only.
        if ["gpt-live-transcribe", "gpt-transcribe"].contains(configuration.openAILiveModel) {
            let allowed = OpenAIRealtimeOption.delays.map(\.value)
            result["delay"] = allowed.contains(configuration.openAILiveDelay) ? configuration.openAILiveDelay : "low"
        }
        return result
    }

}
