import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case openai, elevenlabs, muse
    var id: String { rawValue }
    var title: String {
        switch self { case .elevenlabs: return "ElevenLabs"; case .muse: return "Muse"; case .openai: return "OpenAI" }
    }
    var modelName: String {
        switch self { case .elevenlabs: return "Scribe v2"; case .muse: return "Muse Voice Transcribe"; case .openai: return "GPT Transcribe" }
    }
}

enum OutputMode: String, Codable, CaseIterable, Identifiable {
    case complete, streaming
    var id: String { rawValue }
    var title: String { self == .complete ? L("说完再输出") : L("流式输出") }
    var detail: String { self == .complete ? L("停止录音后一次写入；没有文本框时复制到剪贴板。") : L("说话时文字实时显示在浮条上，停止后一次写入；没有文本框时复制到剪贴板。") }
}

struct Configuration: Codable {
    var trimmedOpenAIPrompt: String { openAIPrompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    var provider: Provider = .openai
    var mode: OutputMode = .complete
    var languageCodes: [String] = []
    var museSettings = ProviderSettings()
    var openAISettings = ProviderSettings()
    var elevenLabsSettings = ElevenLabsSettings()
    var shortcut = Shortcut()
    var openAIBatchModel = "gpt-transcribe"
    var openAILiveModel = "gpt-live-transcribe"
    /// Realtime `delay`: minimal / low / medium / high / xhigh (accuracy vs. latency).
    var openAILiveDelay = "low"
    /// Free-text `prompt` describing the recording, names or terms; sent to both OpenAI endpoints.
    var openAIPrompt = ""
    var museModel = "muse-voice-transcribe-1.0"
    /// Whole-text rewriting after the recording stops; shared by every speech service.
    var postProcessing = PostProcessingSettings()
    /// macOS voice processing on the input node: noise suppression, echo cancellation and gain control
    /// applied by the system before the audio reaches any service.
    var systemVoiceProcessing = false
    /// CoreAudio device UID of the microphone to record from; empty follows the system default input.
    var inputDeviceUID = ""
    var interfaceLanguage = AppLanguage.system
    /// Streaming mode, experimental: the text also grows in the field while the user speaks, by appending only.
    var liveInsertion = false

    var speechSettings: ProviderSettings {
        get {
            switch provider { case .muse: return museSettings; case .openai: return openAISettings; case .elevenlabs: return elevenLabsSettings.speech }
        }
        set {
            switch provider { case .muse: museSettings = newValue; case .openai: openAISettings = newValue; case .elevenlabs: elevenLabsSettings.speech = newValue }
        }
    }
    init() {}
    private enum CodingKeys: String, CodingKey {
        case provider, mode, languageCodes, shortcut, openAIBatchModel, openAILiveModel, openAILiveDelay, openAIPrompt, museModel, postProcessing, systemVoiceProcessing, inputDeviceUID, interfaceLanguage, liveInsertion, museSettings, openAISettings, elevenLabsSettings
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Missing fields keep their defaults. Enums decode leniently: a value this build does not know (from a newer
        // build) falls back to its default instead of failing the whole decode, which would reset every setting.
        provider = (try? values.decodeIfPresent(Provider.self, forKey: .provider)) ?? .openai
        shortcut = try values.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? Shortcut()
        openAIBatchModel = try values.decodeIfPresent(String.self, forKey: .openAIBatchModel) ?? openAIBatchModel
        openAILiveModel = try values.decodeIfPresent(String.self, forKey: .openAILiveModel) ?? openAILiveModel
        openAILiveDelay = try values.decodeIfPresent(String.self, forKey: .openAILiveDelay) ?? openAILiveDelay
        openAIPrompt = try values.decodeIfPresent(String.self, forKey: .openAIPrompt) ?? ""
        museModel = try values.decodeIfPresent(String.self, forKey: .museModel) ?? museModel
        postProcessing = try values.decodeIfPresent(PostProcessingSettings.self, forKey: .postProcessing) ?? PostProcessingSettings()
        systemVoiceProcessing = try values.decodeIfPresent(Bool.self, forKey: .systemVoiceProcessing) ?? false
        inputDeviceUID = try values.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? ""
        interfaceLanguage = (try? values.decodeIfPresent(AppLanguage.self, forKey: .interfaceLanguage)) ?? .system
        liveInsertion = (try? values.decodeIfPresent(Bool.self, forKey: .liveInsertion)) ?? false
        museSettings = try values.decodeIfPresent(ProviderSettings.self, forKey: .museSettings) ?? ProviderSettings()
        openAISettings = try values.decodeIfPresent(ProviderSettings.self, forKey: .openAISettings) ?? ProviderSettings()
        elevenLabsSettings = try values.decodeIfPresent(ElevenLabsSettings.self, forKey: .elevenLabsSettings) ?? ElevenLabsSettings()
        mode = (try? values.decodeIfPresent(OutputMode.self, forKey: .mode)) ?? .complete
        languageCodes = try values.decodeIfPresent([String].self, forKey: .languageCodes) ?? []
    }
}

enum AppPhase: Equatable {
    case idle, connecting, recording, processing, success, failed
    var title: String {
        switch self {
        case .idle: return L("准备好倾听")
        case .connecting: return L("正在连接")
        case .recording: return L("正在录音")
        case .processing: return L("正在转写")
        case .success: return L("文字已送达")
        case .failed: return L("需要你的关注")
        }
    }
    var active: Bool { [.connecting, .recording, .processing].contains(self) }
}

struct OpenWhisperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum OpenAIRealtimeOption {
    static var delays: [(value: String, title: String)] {
        [("minimal", L("最低延迟")), ("low", L("低延迟")), ("medium", L("均衡")), ("high", L("偏重准确")), ("xhigh", L("最高准确"))]
    }
}
