import Foundation

/// The microphone starts before this pipeline. Its stream buffers audio during the handshake.
@MainActor
enum RealtimeAudioPipeline {
    static func forward(
        _ stream: AsyncThrowingStream<Data, Error>,
        connect: () async throws -> Void,
        ready: () -> Void,
        send: (Data) async throws -> Void,
        finish: () async throws -> Void,
        progress: (Int) -> Void = { _ in },
        maxLead: Double? = nil
    ) async throws -> Int {
        try await connect()
        try Task.checkCancellation()
        ready()
        let started = ContinuousClock.now
        var bytes = 0
        for try await chunk in stream {
            try Task.checkCancellation()
            // Catch up after connecting; only a provider with a lead cap (Muse: 5 s) is held back from it.
            if let maxLead {
                let elapsed = started.duration(to: .now).seconds
                let delay = AudioSendPacing.delay(bytes: bytes + chunk.count, elapsed: elapsed, maxLead: maxLead)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
            try await send(chunk)
            bytes += chunk.count
            progress(bytes)
        }
        try Task.checkCancellation()
        guard bytes >= 24_000 else { throw OpenWhisperError(L("录音太短，请至少说半秒钟再停止。")) }
        try await finish()
        return bytes
    }
}

enum AudioSendPacing {
    static func delay(bytes: Int, elapsed: Double, maxLead: Double = 2) -> Double {
        max(0, Double(bytes) / 48_000 - elapsed - maxLead)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
