import XCTest
@testable import OpenWhisper

final class ElevenLabsTests: XCTestCase {
    func testDefaultsAndSavedChoicesRoundTrip() throws {
        XCTAssertEqual(Configuration().provider, .openai)
        XCTAssertEqual(Provider.allCases.first, .openai)
        let saved = Data(#"{"provider":"elevenlabs","mode":"streaming","languageCodes":["en","fr"],"openAISettings":{"keywordText":"GPT"}}"#.utf8)
        let config = try JSONDecoder().decode(Configuration.self, from: saved)
        XCTAssertEqual(config.provider, .elevenlabs)
        XCTAssertEqual(config.mode, .streaming)
        XCTAssertEqual(config.languageCodes, ["en", "fr"])
        XCTAssertEqual(config.openAISettings.keywords, ["GPT"])
        XCTAssertTrue(config.elevenLabsSettings.noVerbatim)
        var later = config; later.provider = .muse
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(later)).provider, .muse)
    }
    func testUnknownFieldsAreIgnoredWhenDecoding() throws {
        let data = Data(#"{"elevenLabsSettings":{"somethingNew":true,"noVerbatim":false,"speech":{"keywordText":"eSIM"}}}"#.utf8)
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertFalse(config.elevenLabsSettings.noVerbatim)
        XCTAssertEqual(config.elevenLabsSettings.speech.keywords, ["eSIM"])
    }
    func testRealtimeUsesVADAndRepeatedLanguageAndKeytermParameters() throws {
        var config = Configuration()
        config.languageCodes = ["en", "fr", "zh"]
        config.elevenLabsSettings.speech.keywordText = "Acme Mobile, A&B + 5G"
        let url = try ElevenLabsRequest.liveURL(config)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        XCTAssertEqual(values("commit_strategy"), ["vad"])
        XCTAssertEqual(values("vad_silence_threshold_secs"), ["0.5"])
        XCTAssertEqual(values("audio_format"), ["pcm_24000"])
        XCTAssertEqual(values("language_code"), ["en"])
        XCTAssertEqual(values("secondary_languages"), ["fr", "zh"])
        XCTAssertEqual(values("keyterms"), ["Acme Mobile", "A&B + 5G"])
        XCTAssertEqual(values("no_verbatim"), ["true"])
        for removed in ["transcript_edit", "filter_background_audio", "token", "include_timestamps"] {
            XCTAssertTrue(values(removed).isEmpty, removed)
        }
        XCTAssertEqual(ElevenLabsRequest.audio(Data([1, 2]))["commit"] as? Bool, false)
        config.elevenLabsSettings.noVerbatim = false
        XCTAssertEqual(URLComponents(url: try ElevenLabsRequest.liveURL(config), resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "no_verbatim" }?.value, "false")
    }
    func testBatchFieldsUseOnlySupportedFeatures() throws {
        var config = Configuration()
        config.languageCodes = ["en", "fr"]
        config.elevenLabsSettings.speech.keywordText = "eSIM, 5G"
        let fields = try ElevenLabsRequest.fileFields(config)
        XCTAssertFalse(fields.contains { ["language_code", "filter_background_audio", "commit_strategy", "transcript_edit"].contains($0.0) })
        XCTAssertEqual(fields.filter { $0.0 == "keyterms" }.map { $0.1 }, ["eSIM", "5G"])
        XCTAssertEqual(try ElevenLabsRequest.fileText(["text": "July twelfth 2026", "edited_transcript": ["kind": "transcript", "text": "ignored"]]), "July twelfth 2026")
        XCTAssertThrowsError(try ElevenLabsRequest.fileText(["language_code": "en"]))
    }
    func testCommittedSegmentsAppendAndAuxiliaryEventsAreIgnored() {
        var transcript = ElevenLabsTranscript()
        _ = transcript.consume(["message_type": "partial_transcript", "text": "Meeting on July"])
        _ = transcript.consume(["message_type": "committed_transcript", "text": "Meeting on July twelfth 2026."])
        _ = transcript.consume(["message_type": "partial_transcript", "text": "Next topic 👩‍💻"])
        XCTAssertEqual(transcript.text, "Meeting on July twelfth 2026. Next topic 👩‍💻")
        XCTAssertTrue(transcript.hasPendingPartial)
        XCTAssertNil(transcript.consume(["message_type": "committed_transcript_with_timestamps", "text": "Meeting on July twelfth 2026."]))
        XCTAssertNil(transcript.consume(["message_type": "edited_transcript", "text": "Meeting on July twelfth 2026.", "edited_text": "x"]))
        XCTAssertEqual(transcript.commitCount, 1)
    }
    func testChineseSegmentsAndRetractedNoiseHypothesis() {
        var transcript = ElevenLabsTranscript()
        _ = transcript.consume(["message_type": "partial_transcript", "text": "背景"])
        _ = transcript.consume(["message_type": "partial_transcript", "text": ""])
        XCTAssertEqual(transcript.text, "")
        _ = transcript.consume(["message_type": "committed_transcript", "text": "你好。"])
        _ = transcript.consume(["message_type": "partial_transcript", "text": "下一段"])
        XCTAssertEqual(transcript.text, "你好。下一段")
    }
}
