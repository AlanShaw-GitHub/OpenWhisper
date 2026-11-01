import Foundation

struct TranscriptionService {
    /// No disk cache and no cookies: responses are one-off transcripts that must not linger in ~/Library/Caches.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config)
    }()
    func transcribe(pcm: Data, configuration: Configuration, key: String) async throws -> String {
        let provider = configuration.provider
        let endpoint: String
        switch provider {
        case .muse: endpoint = "https://api.meta.ai/v1/asr/transcribe"
        case .openai: endpoint = "https://api.openai.com/v1/audio/transcriptions"
        case .elevenlabs: endpoint = "https://api.elevenlabs.io/v1/speech-to-text"
        }
        let boundary = "OpenWhisper-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        if provider == .elevenlabs { request.setValue(key, forHTTPHeaderField: "xi-api-key") }
        else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = Data()
        func field(_ name: String, _ value: String, contentType: String? = nil) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n".utf8))
            if let contentType { body.append(Data("Content-Type: \(contentType)\r\n".utf8)) }
            body.append(Data("\r\n\(value)\r\n".utf8))
        }
        if provider == .muse {
            let options = try SpeechRequestOptions.muse(configuration, encoding: "WAV")
            let json = try JSONSerialization.data(withJSONObject: options)
            field("request", String(decoding: json, as: UTF8.self), contentType: "application/json")
        } else if provider == .openai {
            for (name, value) in try SpeechRequestOptions.openAIFileFields(configuration) { field(name, value) }
        } else {
            for (name, value) in try ElevenLabsRequest.fileFields(configuration) { field(name, value) }
        }
        let name = provider == .muse ? "audio" : "file"
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(AudioData.wav(pcm))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (data, response) = try await Self.session.upload(for: request, from: body)
        guard let response = response as? HTTPURLResponse else { throw OpenWhisperError(L("服务没有返回有效响应。")) }
        guard (200..<300).contains(response.statusCode) else { throw Self.apiError(data, status: response.statusCode, key: key) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if provider == .elevenlabs, let json { return try ElevenLabsRequest.fileText(json) }
        guard let text = json?[provider == .muse ? "transcript" : "text"] as? String else { throw OpenWhisperError(L("服务返回了无法识别的转写结果。")) }
        return provider == .muse ? TranscriptCleanup.removingDuplicateTerminalPunctuation(text) : text
    }

    static func apiError(_ data: Data, status: Int, key: String) -> OpenWhisperError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let nested = json?["error"] as? [String: Any]
        let elevenDetail = json?["detail"] as? [String: Any]
        let detail = nested?["message"] as? String ?? elevenDetail?["message"] as? String ?? json?["message"] as? String ?? json?["detail"] as? String ?? L("请检查网络和服务账户。")
        let safe = detail.replacingOccurrences(of: key, with: "[•••]")
        switch status {
        case 401, 403: return OpenWhisperError(L("API key 无效或没有此模型的权限（%d）。", status) + safe.prefix(280))
        case 429: return OpenWhisperError(L("服务额度不足或请求过于频繁（429）。") + safe.prefix(280))
        default: return OpenWhisperError(L("转写请求失败（%d）：", status) + safe.prefix(280))
        }
    }
}
