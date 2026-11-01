import Foundation

@MainActor
final class RealtimeTranscriptionService {
    private let configuration: Configuration
    private let key: String
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // WebSocket tasks: this is the idle limit between received messages. A silent user or a provider without
        // keepalives (OpenAI, Muse) can go far longer than 20 s without any server event.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 660
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config)
    }()
    private var reader: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var transcript = LiveTranscript()
    private var finishedInput = false
    private var cancelled = false
    private var drain: Task<Void, Never>?
    private var lastElevenEvent: ContinuousClock.Instant?
    private var elevenSilenceSeen = false
    private var elevenCommitSeen = false
    var onTranscript: ((String, Bool) async -> Void)?
    var onError: ((Error) -> Void)?
    var onComplete: (() -> Void)?
    #if OPENWHISPER_DIAGNOSTICS
    var testDelayOverride: String?
    var onEventForTesting: (([String: Any]) -> Void)?
    #endif

    init(configuration: Configuration, key: String) {
        self.configuration = configuration; self.key = key
        session = Self.sharedSession
        let url: URL
        switch configuration.provider {
        case .muse: url = URL(string: "wss://api.meta.ai/v1/asr/realtime")!
        case .openai: url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        case .elevenlabs:
            // Validation is repeated in connect so invalid settings fail before any audio upload.
            url = (try? ElevenLabsRequest.liveURL(configuration)) ?? URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        }
        var request = URLRequest(url: url)
        if configuration.provider == .openai { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if configuration.provider == .elevenlabs { request.setValue(key, forHTTPHeaderField: "xi-api-key") }
        socket = session.webSocketTask(with: request)
    }
    func connect() async throws {
        if configuration.provider == .elevenlabs { _ = try ElevenLabsRequest.liveURL(configuration) }
        socket.resume()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout?.cancel(); timeout = nil }
        if configuration.provider == .muse {
            let handshake = try SpeechRequestOptions.muse(configuration, encoding: "PCM_24KHZ", key: key)
            try await sendJSON(handshake)
            let event = try await receive()
            try checkError(event)
            guard event["sessionId"] is String else { throw OpenWhisperError(L("Muse 未确认语音连接。")) }
        } else if configuration.provider == .openai {
            var transcription = try SpeechRequestOptions.openAILive(configuration)
            #if OPENWHISPER_DIAGNOSTICS
            if let testDelayOverride { transcription["delay"] = testDelayOverride }
            #endif
            let input: [String: Any] = ["format": ["type": "audio/pcm", "rate": 24000], "transcription": transcription, "turn_detection": NSNull()]
            try await sendJSON(["type": "session.update", "session": ["type": "transcription", "audio": ["input": input]]])
            while true {
                let event = try await receive(); try checkError(event)
                if ["session.updated", "transcription_session.updated"].contains(event["type"] as? String ?? "") { break }
            }
        } else {
            while true {
                let event = try await receive(); try checkError(event)
                #if OPENWHISPER_DIAGNOSTICS
                onEventForTesting?(event)
                #endif
                if event["message_type"] as? String == "session_started" { break }
            }
        }
        reader = Task { [weak self] in await self?.readLoop() }
    }
    func send(_ pcm: Data) async throws {
        guard !cancelled, !finishedInput else { throw CancellationError() }
        switch configuration.provider {
        case .muse: try await socket.send(.data(pcm))
        case .openai: try await sendJSON(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
        case .elevenlabs: try await sendJSON(ElevenLabsRequest.audio(pcm))
        }
    }
    func finish() async throws {
        guard !finishedInput, !cancelled else { return }
        finishedInput = true
        if configuration.provider == .elevenlabs {
            try await finishElevenLabs(); return
        }
        try await sendJSON(["type": configuration.provider == .muse ? "endStream" : "input_audio_buffer.commit"])
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.onError?(OpenWhisperError(L("等待转写超时，请检查网络后重试。")))
            self?.cancel()
        }
    }
    func cancel() {
        cancelled = true; timeout?.cancel(); drain?.cancel(); reader?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
    }
    private func readLoop() async {
        do {
            while !Task.isCancelled {
                let event = try await receive(); try checkError(event)
                #if OPENWHISPER_DIAGNOSTICS
                onEventForTesting?(event)
                #endif
                if configuration.provider == .elevenlabs {
                    lastElevenEvent = .now
                    if finishedInput {
                        if event["message_type"] as? String == "committed_transcript" { elevenCommitSeen = true }
                        else if event["message_type"] as? String == "partial_transcript", event["text"] as? String == "" { elevenSilenceSeen = true }
                    }
                }
                if let update = transcript.consume(event, provider: configuration.provider) {
                    // ElevenLabs commits finalize a segment, not the whole session.
                    // Keep reading events while the output worker applies/coalesces revisions.
                    await onTranscript?(update.text, configuration.provider == .elevenlabs ? false : update.final)
                    if update.final && finishedInput && configuration.provider != .elevenlabs {
                        timeout?.cancel(); onComplete?(); cancel(); return
                    }
                }
            }
        } catch {
            guard !cancelled, !Task.isCancelled else { return }
            onError?(error); cancel()
        }
    }
    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func receive() async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw OpenWhisperError(L("无法读取语音事件。")) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OpenWhisperError(L("语音服务返回了无效事件。")) }
        return object
    }
    private func checkError(_ event: [String: Any]) throws {
        let type = event["type"] as? String ?? event["message_type"] as? String ?? ""
        let elevenErrors: Set<String> = ["auth_error", "quota_exceeded", "transcriber_error", "input_error", "invalid_request", "commit_throttled", "unaccepted_terms", "rate_limited", "queue_overflow", "resource_exhausted", "session_time_limit_exceeded", "chunk_size_exceeded", "insufficient_audio_activity"]
        if type == "error" || type == "conversation.item.input_audio_transcription.failed" || (configuration.provider == .elevenlabs && elevenErrors.contains(type)) {
            let nested = event["error"] as? [String: Any]
            let message = nested?["message"] as? String ?? event["error"] as? String ?? event["message"] as? String ?? L("语音服务发生错误。")
            throw OpenWhisperError(message.replacingOccurrences(of: key, with: "[•••]"))
        }
    }

    private func finishElevenLabs() async throws {
        // Keep VAD enabled: silence flushes the last utterance, including short recordings
        // below the model's initial two-second buffer. No manual-commit strategy is used.
        let padding = 105_600 // 2.2 seconds of 24 kHz PCM16 silence.
        for offset in stride(from: 0, to: padding, by: 9_600) {
            guard !cancelled else { throw CancellationError() }
            try await sendJSON(ElevenLabsRequest.audio(Data(repeating: 0, count: min(9_600, padding - offset))))
        }
        let started = ContinuousClock.now
        drain = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.cancelled {
                let elapsed = started.duration(to: .now)
                let quiet = self.lastElevenEvent.map { $0.duration(to: .now) >= .milliseconds(250) } ?? false
                // There is no session-final event. The trailing silence makes VAD commit the last segment; that commit
                // ends the drain at once. An emptied partial can precede its commit by a few milliseconds, so it only
                // counts once the socket has been quiet for a moment.
                if !self.transcript.elevenLabsHasPartial &&
                   (self.elevenCommitSeen || (self.elevenSilenceSeen && quiet) ||
                    self.transcript.elevenLabsCommits > 0 && quiet && elapsed >= .milliseconds(800) || elapsed >= .seconds(4)) {
                    await self.onTranscript?(self.transcript.text, true)
                    guard !self.cancelled else { return }
                    self.onComplete?(); self.cancel(); return
                }
                if elapsed >= .seconds(12) {
                    self.onError?(OpenWhisperError(L("等待 ElevenLabs 的 VAD 最终转写超时，请重试。"))); self.cancel(); return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
