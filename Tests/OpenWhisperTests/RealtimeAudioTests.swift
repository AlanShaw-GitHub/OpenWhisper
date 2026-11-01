import XCTest
@testable import OpenWhisper

final class RealtimeAudioTests: XCTestCase {
    @MainActor func testStoppingBeforeConnectionStillSendsTheBufferedBeginningInOrder() async throws {
        let (stream, source) = AsyncThrowingStream<Data, Error>.makeStream()
        var handshake: CheckedContinuation<Void, Never>?
        var sent: [Data] = []
        var ready = false, ended = false
        let task = Task {
            try await RealtimeAudioPipeline.forward(stream, connect: {
                await withCheckedContinuation { handshake = $0 }
            }, ready: { ready = true }, send: { sent.append($0) }, finish: { ended = true })
        }
        while handshake == nil { await Task.yield() }
        let first = Data(repeating: 1, count: 12_000), last = Data(repeating: 2, count: 12_000)
        source.yield(first); source.yield(last); source.finish()
        XCTAssertFalse(ready); XCTAssertTrue(sent.isEmpty); XCTAssertFalse(ended)
        handshake?.resume()
        let bytes = try await task.value
        XCTAssertEqual(bytes, 24_000)
        XCTAssertEqual(sent, [first, last]); XCTAssertTrue(ready); XCTAssertTrue(ended)
    }
    @MainActor func testConnectionFailureNeverSendsBufferedAudioOrEndMessage() async {
        let (stream, source) = AsyncThrowingStream<Data, Error>.makeStream()
        source.yield(Data(repeating: 0, count: 24_000)); source.finish()
        var sent = false, ended = false
        do {
            _ = try await RealtimeAudioPipeline.forward(stream, connect: { throw OpenWhisperError("offline") }, ready: {},
                send: { _ in sent = true }, finish: { ended = true })
            XCTFail("Expected connection failure")
        } catch { XCTAssertFalse(sent); XCTAssertFalse(ended) }
    }
    func testCatchUpStaysWithinTwoSecondsOfRealtime() {
        XCTAssertEqual(AudioSendPacing.delay(bytes: 96_000, elapsed: 0), 0)
        XCTAssertEqual(AudioSendPacing.delay(bytes: 480_000, elapsed: 0), 8)
        XCTAssertEqual(AudioSendPacing.delay(bytes: 480_000, elapsed: 8), 0)
        XCTAssertEqual(AudioSendPacing.delay(bytes: 480_000, elapsed: 12), 0)
        XCTAssertEqual(AudioSendPacing.delay(bytes: 480_000, elapsed: 0, maxLead: 10), 0, "only Muse has a lead cap")
    }
}
