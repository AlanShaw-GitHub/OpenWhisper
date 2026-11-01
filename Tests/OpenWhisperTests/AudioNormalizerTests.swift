import XCTest
@testable import OpenWhisper

final class AudioNormalizerTests: XCTestCase {
    private let rate = 48_000.0
    private let frames = 1920
    /// A 200 Hz tone at the given peak amplitude, one tap buffer long.
    private func tone(_ amplitude: Float) -> [Float] {
        (0..<frames).map { amplitude * sin(Float($0) * 2 * .pi * 200 / 48_000) }
    }
    private func noise(_ amplitude: Float, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }
    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    func testQuietSpeechIsLiftedTowardsTheTargetWithoutClipping() {
        var normalizer = AudioLevelNormalizer()
        var last: [Float] = []
        for _ in 0..<10 { var quiet = noise(0.0005, seed: 1); normalizer.process(&quiet, sampleRate: rate) }
        for _ in 0..<75 { last = tone(0.01); normalizer.process(&last, sampleRate: rate) }   // 3 s of -43 dBFS speech
        XCTAssertGreaterThan(normalizer.gain, 8, "a -43 dBFS tone should drive the gain near its +20 dB ceiling")
        XCTAssertLessThanOrEqual(last.map(abs).max() ?? 0, 0.97)
        XCTAssertGreaterThan(rms(last), 0.05, "output should sit far above the raw -43 dBFS input")
    }
    func testLoudInputIsLeftAlone() {
        var normalizer = AudioLevelNormalizer()
        let original = tone(0.5)
        var samples = original
        for _ in 0..<50 { samples = original; normalizer.process(&samples, sampleRate: rate) }
        XCTAssertEqual(normalizer.gain, 1)
        XCTAssertEqual(samples, original)
    }
    func testRoomNoiseAloneNeverRaisesTheGain() {
        var normalizer = AudioLevelNormalizer()
        for seed in 0..<100 { var samples = noise(0.004, seed: UInt64(seed)); normalizer.process(&samples, sampleRate: rate) }   // -45 dBFS hiss
        XCTAssertEqual(normalizer.gain, 1, "steady noise is the floor, not speech")
    }
    func testSpeechBarelyAboveTheNoiseFloorDoesNotPumpTheNoise() {
        var normalizer = AudioLevelNormalizer()
        for seed in 0..<50 { var samples = noise(0.02, seed: UInt64(seed)); normalizer.process(&samples, sampleRate: rate) }
        for _ in 0..<50 { var samples = tone(0.03); normalizer.process(&samples, sampleRate: rate) }   // ~1 dB above the hiss
        XCTAssertEqual(normalizer.gain, 1)
    }
    func testGainHoldsThroughSilenceAndDropsQuicklyForLoudPassages() {
        var normalizer = AudioLevelNormalizer()
        for _ in 0..<10 { var quiet = noise(0.0005, seed: 2); normalizer.process(&quiet, sampleRate: rate) }
        for _ in 0..<75 { var samples = tone(0.02); normalizer.process(&samples, sampleRate: rate) }
        let learned = normalizer.gain
        XCTAssertGreaterThan(learned, 4)
        for _ in 0..<50 { var silence = noise(0.0005, seed: 3); normalizer.process(&silence, sampleRate: rate) }   // 2 s pause
        XCTAssertEqual(normalizer.gain, learned, accuracy: 0.01, "a pause must not change the gain")
        var loud = tone(0.6)
        for _ in 0..<10 { loud = tone(0.6); normalizer.process(&loud, sampleRate: rate) }   // 400 ms of loud speech
        XCTAssertLessThan(normalizer.gain, 1.2)
        XCTAssertLessThanOrEqual(loud.map(abs).max() ?? 0, 0.97, "the limiter protects the first loud buffers")
    }
    func testLimiterCapsSuddenPeaksWhileTheGainIsHigh() {
        var normalizer = AudioLevelNormalizer()
        for _ in 0..<10 { var quiet = noise(0.0005, seed: 4); normalizer.process(&quiet, sampleRate: rate) }
        for _ in 0..<75 { var samples = tone(0.01); normalizer.process(&samples, sampleRate: rate) }
        var burst = tone(0.3)
        normalizer.process(&burst, sampleRate: rate)
        XCTAssertLessThanOrEqual(burst.map(abs).max() ?? 0, 0.97)
    }
}
