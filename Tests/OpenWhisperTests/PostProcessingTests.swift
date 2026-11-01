import XCTest
@testable import OpenWhisper

final class PostProcessingTests: XCTestCase {
    func testSettingsDefaultsDecodeAndActivity() throws {
        let decoded = try JSONDecoder().decode(PostProcessingSettings.self, from: Data(#"{"enabled":true,"rules":["fillers","dates","bogus"]}"#.utf8))
        XCTAssertEqual(decoded.rules, ["fillers", "dates"], "a rule this build does not know is dropped"); XCTAssertEqual(decoded.engine, .deepseek); XCTAssertTrue(decoded.isActive)
        XCTAssertEqual(PostProcessingSettings().selectedRules, PostProcessingRule.allCases, "every rule is on by default")
        XCTAssertEqual(decoded.model, "deepseek-flash")
        var settings = PostProcessingSettings()
        XCTAssertFalse(settings.isActive)
        XCTAssertEqual(settings.selectedRules, PostProcessingRule.defaultRules)
        settings.enabled = true; settings.rules = []
        XCTAssertFalse(settings.isActive, "no rules and no custom instruction means nothing to do")
        settings.customInstruction = " Keep product names in English. "
        XCTAssertTrue(settings.isActive)
    }
    func testMisrecognitionRuleComesFirstAndAChoiceToTurnItOffPersists() throws {
        XCTAssertEqual(PostProcessingRule.allCases.first, .misrecognitions)
        XCTAssertEqual(PostProcessingSettings().selectedRules.first, .misrecognitions, "new installs have it on")
        var choice = PostProcessingSettings(); choice.rules = ["fillers", "punctuation"]
        let reloaded = try JSONDecoder().decode(PostProcessingSettings.self, from: JSONEncoder().encode(choice))
        XCTAssertEqual(reloaded.selectedRules, [.fillers, .punctuation])
    }
    func testUnknownChoicesFallBackWithoutResettingOtherSettings() throws {
        // A value this build does not know (written by a newer or older build) must not fail the whole decode,
        // which would replace every setting with its default on the next save.
        let json = #"{"provider":"whisper","mode":"dictate","openAIPrompt":"产品评审","systemVoiceProcessing":true,"#
            + #""postProcessing":{"enabled":true,"engine":"spark","rules":["fillers"]}}"#
        let config = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
        XCTAssertEqual(config.provider, .openai)
        XCTAssertEqual(config.mode, .complete)
        XCTAssertEqual(config.postProcessing.engine, .deepseek)
        XCTAssertEqual(config.openAIPrompt, "产品评审")
        XCTAssertTrue(config.systemVoiceProcessing)
        XCTAssertTrue(config.postProcessing.enabled)
        XCTAssertEqual(config.postProcessing.selectedRules, [.fillers])
    }
    func testModelPerEngineAndSharedConfigurationRoundTrip() throws {
        var config = Configuration()
        config.postProcessing.enabled = true
        config.postProcessing.engine = .openai
        XCTAssertEqual(config.postProcessing.model, "gpt-6-luna")
        config.postProcessing.openAIModel = " gpt-6.1-sol "
        XCTAssertEqual(config.postProcessing.model, "gpt-6.1-sol")
        config.postProcessing.engine = .gemini
        XCTAssertEqual(config.postProcessing.model, "gemini-3.5-flash-lite")
        config.postProcessing.engine = .deepseek
        config.postProcessing.geminiModel = "gemini-3.8-flash"
        XCTAssertEqual(config.postProcessing.model, "deepseek-flash", "DeepSeek is fixed to Flash")
        XCTAssertFalse(PostProcessingEngine.deepseek.allowsCustomModel)
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.postProcessing, config.postProcessing)
        config.provider = .elevenlabs
        XCTAssertTrue(config.postProcessing.enabled, "applies to every speech service")
        XCTAssertEqual(PostProcessingEngine.openai.keyID, Provider.openai.rawValue, "OpenAI shares the speech key slot")
    }
    func testRequestShapesPerEngine() {
        var settings = PostProcessingSettings(); settings.enabled = true
        settings.customInstruction = "Write product names in English."
        settings.engine = .deepseek
        let deepseek = TranscriptPostProcessor.requestBody(text: "你好", settings: settings, keywords: ["Acme"])
        XCTAssertEqual(deepseek["model"] as? String, "deepseek-flash")
        XCTAssertEqual((deepseek["reasoning"] as? [String: String])?["effort"], "none")
        XCTAssertEqual(deepseek["store"] as? Bool, false)
        XCTAssertEqual(deepseek["input"] as? String, "你好")
        XCTAssertEqual(TranscriptPostProcessor.endpoint(for: .deepseek).host, "api.deepseek.com")
        settings.engine = .openai
        let openAI = TranscriptPostProcessor.requestBody(text: "你好", settings: settings, keywords: ["Acme"])
        XCTAssertEqual(openAI["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(TranscriptPostProcessor.endpoint(for: .openai).host, "api.openai.com")
        let instructions = openAI["instructions"] as? String ?? ""
        XCTAssertTrue(instructions.contains("Acme"))
        XCTAssertTrue(instructions.contains(PostProcessingRule.spokenLists.instruction))
        XCTAssertTrue(instructions.hasSuffix("7. Write product names in English."))
        XCTAssertTrue(instructions.contains("1. " + PostProcessingRule.misrecognitions.instruction), "misheard words are fixed first")
        XCTAssertTrue(instructions.contains("2026年7月12日"), "dates follow the language's convention, not ISO")
        XCTAssertFalse(instructions.contains("HH:mm"), "the 24-hour rule was removed")
        settings.engine = .gemini
        let gemini = TranscriptPostProcessor.requestBody(text: "你好", settings: settings, keywords: [])
        XCTAssertEqual(gemini["model"] as? String, "gemini-3.5-flash-lite")
        XCTAssertEqual(gemini["reasoning_effort"] as? String, "low")
        let messages = gemini["messages"] as? [[String: String]] ?? []
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.last?["content"], "你好")
        XCTAssertEqual(TranscriptPostProcessor.endpoint(for: .gemini).path, "/v1beta/openai/chat/completions")
    }
    func testOutputParsingAndGuards() throws {
        let responses: [String: Any] = ["output": [
            ["type": "reasoning", "summary": []],
            ["type": "message", "content": [["type": "output_text", "text": " 我们明天要做 3 件事：\n- 准备材料。 "]]]]]
        XCTAssertEqual(try TranscriptPostProcessor.outputText(responses, engine: .deepseek), "我们明天要做 3 件事：\n- 准备材料。")
        XCTAssertThrowsError(try TranscriptPostProcessor.outputText(["output": []], engine: .openai))
        XCTAssertThrowsError(try TranscriptPostProcessor.outputText(["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": []], engine: .openai)) {
            XCTAssertTrue($0.localizedDescription.contains("max_output_tokens"))
        }
        XCTAssertThrowsError(try TranscriptPostProcessor.outputText(["error": ["message": "quota"]], engine: .gemini)) { XCTAssertEqual($0.localizedDescription, "quota") }
        let chat: [String: Any] = ["choices": [["message": ["role": "assistant", "content": "整理后的文字。"]]]]
        XCTAssertEqual(try TranscriptPostProcessor.outputText(chat, engine: .gemini), "整理后的文字。")
        XCTAssertTrue(TranscriptPostProcessor.plausible("我们明天要做3件事：\n- 准备材料。\n- 预订会议室。", original: "嗯，我们、我们明天要做三件事，第一准备材料第二预订会议室"))
        XCTAssertFalse(TranscriptPostProcessor.plausible("好的。", original: "我们明天下午三点半在会议室开会，讨论第三季度的预算。"))
        XCTAssertFalse(TranscriptPostProcessor.plausible(String(repeating: "解释", count: 60), original: "你好。"))
    }
}
