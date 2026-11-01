import XCTest
@testable import OpenWhisper

final class TranscriptionTests: XCTestCase {
    func testMuseRevisionsReplaceRatherThanAppend() {
        var state = LiveTranscript()
        _ = state.consume(["type": "transcript", "transcript": "I scream", "final": false], provider: .muse)
        let result = state.consume(["type": "transcript", "transcript": "Ice cream.", "final": true], provider: .muse)
        XCTAssertEqual(state.text, "Ice cream.")
        XCTAssertEqual(result?.final, true)
    }
    func testOpenAICompletionCorrectsDeltaWithoutDuplication() {
        var state = LiveTranscript()
        _ = state.consume(["type": "input_audio_buffer.committed", "item_id": "a"], provider: .openai)
        _ = state.consume(["type": "conversation.item.input_audio_transcription.delta", "item_id": "a", "delta": "hello"], provider: .openai)
        _ = state.consume(["type": "conversation.item.input_audio_transcription.delta", "item_id": "a", "delta": " world"], provider: .openai)
        XCTAssertEqual(state.text, "hello world")
        _ = state.consume(["type": "conversation.item.input_audio_transcription.completed", "item_id": "a", "transcript": "Hello, world."], provider: .openai)
        XCTAssertEqual(state.text, "Hello, world.")
    }
    func testOutOfOrderOpenAICompletionsKeepTurnOrder() {
        var state = LiveTranscript()
        _ = state.consume(["type": "input_audio_buffer.committed", "item_id": "a"], provider: .openai)
        _ = state.consume(["type": "input_audio_buffer.committed", "item_id": "b", "previous_item_id": "a"], provider: .openai)
        _ = state.consume(["type": "conversation.item.input_audio_transcription.completed", "item_id": "b", "transcript": "Second."], provider: .openai)
        _ = state.consume(["type": "conversation.item.input_audio_transcription.completed", "item_id": "a", "transcript": "First. "], provider: .openai)
        XCTAssertEqual(state.text, "First. Second.")
    }
    func testLiveAppendWorksOnWholeCharacters() {
        var emoji = LiveAppend()
        XCTAssertEqual(emoji.next("你好👩‍💻"), "你好👩‍💻")
        XCTAssertEqual(emoji.next("你好👩‍💻新"), "新")
        var accent = LiveAppend()
        _ = accent.next("café")
        XCTAssertEqual(accent.next("café!"), "!")
        var correction = LiveAppend()
        _ = correction.next("你好，世届")
        XCTAssertNil(correction.next("你好，世界。"), "a corrected character is never deleted in the field")
        XCTAssertTrue(correction.stopped)
    }
    func testPCMHeaderMatchesMono24kHzPayload() {
        let pcm = Data(repeating: 0, count: 48_000)
        let wav = AudioData.wav(pcm)
        XCTAssertEqual(wav.count, 48_044)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(Array(wav[24..<28]), [0xC0, 0x5D, 0, 0])
        XCTAssertEqual(Array(wav[40..<44]), [0x80, 0xBB, 0, 0])
    }
    func testProviderErrorsRedactCredential() {
        let error = TranscriptionService.apiError(Data("{\"error\":{\"message\":\"invalid secret-test\"}}".utf8), status: 401, key: "secret-test")
        XCTAssertFalse(error.localizedDescription.contains("secret-test"))
        XCTAssertTrue(error.localizedDescription.contains("401"))
    }

    func testSharedLanguagesUseEachProvidersWireFormat() throws {
        var config = Configuration()
        config.languageCodes = ["en", "fr", "zh"]
        let muse = try SpeechRequestOptions.muse(config, encoding: "WAV")
        XCTAssertEqual(muse["languageBias"] as? [String], ["English", "French", "Mandarin Chinese"])
        config.provider = .openai
        let fields = try SpeechRequestOptions.openAIFileFields(config)
        XCTAssertEqual(fields.filter { $0.0 == "languages[]" }.map { $0.1 }, ["en", "fr", "zh"])
        XCTAssertFalse(fields.contains { $0.0 == "language" })
        let live = try SpeechRequestOptions.openAILive(config)
        XCTAssertEqual(live["languages"] as? [String], ["en", "fr", "zh"])
    }

    func testOpenAIRealtimeDelayFollowsTheDocumentedValues() throws {
        var config = Configuration(); config.provider = .openai
        XCTAssertEqual(try SpeechRequestOptions.openAILive(config)["delay"] as? String, "low")
        config.openAILiveDelay = "xhigh"
        XCTAssertEqual(try SpeechRequestOptions.openAILive(config)["delay"] as? String, "xhigh")
        config.openAILiveDelay = "bogus"
        XCTAssertEqual(try SpeechRequestOptions.openAILive(config)["delay"] as? String, "low")
        config.openAILiveModel = "gpt-4o-transcribe"
        XCTAssertNil(try SpeechRequestOptions.openAILive(config)["delay"])
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.openAILiveDelay, "bogus")
        let legacy = try JSONDecoder().decode(Configuration.self, from: Data(#"{"provider":"openai","openAINoiseReduction":"far_field"}"#.utf8))
        XCTAssertEqual(legacy.openAILiveDelay, "low")
    }
    func testOpenAIPromptIsSentToBothEndpointsAndFoldedForLegacyModels() throws {
        var config = Configuration(); config.provider = .openai
        XCTAssertFalse(try SpeechRequestOptions.openAIFileFields(config).contains { $0.0 == "prompt" })
        XCTAssertNil(try SpeechRequestOptions.openAILive(config)["prompt"])
        config.openAIPrompt = "  产品评审会议，提到 Acme 和 eSIM。\n"
        config.openAISettings.keywordText = "Acme, eSIM"
        XCTAssertEqual(try SpeechRequestOptions.openAIFileFields(config).first { $0.0 == "prompt" }?.1, "产品评审会议，提到 Acme 和 eSIM。")
        XCTAssertEqual(try SpeechRequestOptions.openAILive(config)["prompt"] as? String, "产品评审会议，提到 Acme 和 eSIM。")
        config.openAIBatchModel = "whisper-1"
        XCTAssertEqual(try SpeechRequestOptions.openAIFileFields(config).first { $0.0 == "prompt" }?.1, "产品评审会议，提到 Acme 和 eSIM。 Acme, eSIM")
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.openAIPrompt, config.openAIPrompt)
    }
    func testMuseBatchDropsADoubledTerminatorButKeepsEllipses() {
        XCTAssertEqual(TranscriptCleanup.removingDuplicateTerminalPunctuation("Please prepare in advance.."), "Please prepare in advance.")
        XCTAssertEqual(TranscriptCleanup.removingDuplicateTerminalPunctuation("请大家提前准备好材料。。"), "请大家提前准备好材料。")
        XCTAssertEqual(TranscriptCleanup.removingDuplicateTerminalPunctuation("请大家提前准备好材料。。 "), "请大家提前准备好材料。")
        for unchanged in ["Wait...", "真的吗？", "好。", "", "嗯……", "Hello!!!", "a..b"] {
            XCTAssertEqual(TranscriptCleanup.removingDuplicateTerminalPunctuation(unchanged), unchanged)
        }
    }
    func testAutoDetectionOmitsLanguageHints() throws {
        var config = Configuration()
        XCTAssertNil(try SpeechRequestOptions.muse(config, encoding: "WAV")["languageBias"])
        config.provider = .openai
        XCTAssertNil(try SpeechRequestOptions.openAILive(config)["languages"])
        XCTAssertFalse(try SpeechRequestOptions.openAIFileFields(config).contains { $0.0.hasPrefix("language") })
    }

    func testServiceKeywordsAreIndependentButModeAndLanguagesAreShared() throws {
        var config = Configuration()
        config.provider = .muse
        config.mode = .streaming; config.languageCodes = ["en", "fr"]
        config.speechSettings.keywordText = "Acme Mobile, eSIM, 5G"
        config.provider = .openai
        config.speechSettings.keywordText = "OpenAI, GPT"
        XCTAssertEqual(config.mode, .streaming)
        XCTAssertEqual(config.languageCodes, ["en", "fr"])
        XCTAssertEqual(try SpeechRequestOptions.openAILive(config)["keywords"] as? [String], ["OpenAI", "GPT"])
        config.provider = .muse
        XCTAssertEqual(try SpeechRequestOptions.muse(config, encoding: "PCM_24KHZ")["keywords"] as? [String], ["Acme Mobile", "eSIM", "5G"])
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.mode, .streaming)
        XCTAssertEqual(restored.languageCodes, ["en", "fr"])
        XCTAssertEqual(restored.openAISettings.keywords, ["OpenAI", "GPT"])
    }

    func testKeywordsPreservePhrasesAndRemoveEmptyDuplicates() {
        var settings = ProviderSettings()
        settings.keywordText = "Acme Mobile，eSIM, 5G\nAcme Mobile;  ; 5G"
        XCTAssertEqual(settings.keywords, ["Acme Mobile", "eSIM", "5G"])
    }

    func testInvalidKeywordsAreRejectedBeforeAPIRequest() {
        var config = Configuration()
        config.provider = .muse
        config.speechSettings.keywordText = "<invalid>"
        XCTAssertThrowsError(try SpeechRequestOptions.muse(config, encoding: "WAV"))
        config.provider = .openai
        config.speechSettings.keywordText = "bad>keyword"
        XCTAssertThrowsError(try SpeechRequestOptions.openAILive(config))
    }

    func testSavedShortcutAndModeSurviveDecoding() throws {
        let data = Data("{\"provider\":\"openai\",\"mode\":\"streaming\",\"shortcut\":{\"keyCode\":2,\"modifiers\":2304,\"keyLabel\":\"D\"}}".utf8)
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(config.mode, .streaming)
        XCTAssertEqual(config.shortcut.keyLabel, "D")
    }
}
