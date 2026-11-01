import Foundation

/// Lifts quiet speech to a steady level before it reaches the recognisers and the HUD meter.
///
/// The gain only ever rises above unity and a per-buffer limiter keeps the result from clipping. Only
/// speech-like buffers (clearly above the tracked room noise) drive the adaptation, so silence holds the
/// last gain instead of pumping the room noise up to the ceiling. Loud passages pull the gain down within
/// about 80 ms; quiet ones raise it over roughly a second.
struct AudioLevelNormalizer {
    /// Speech envelope the gain aims for (≈ -20 dBFS).
    var targetRMS: Float = 0.1
    /// The most we add: 10× ≈ +20 dB.
    var maxGain: Float = 10
    /// Buffers quieter than this never count as speech (≈ -52 dBFS).
    var minimumSpeechRMS: Float = 0.0025
    /// Speech must sit this far above the tracked floor (10 dB).
    var floorMargin: Float = 3.16
    /// Highest sample the limiter lets through.
    var ceiling: Float = 0.97

    private(set) var gain: Float = 1
    private(set) var envelope: Float = 0
    private(set) var noiseFloor: Float = 1
    private(set) var lastRMS: Float = 0
    private var appliedGain: Float = 1
    private var speechRun = 0

    /// Scales `count` mono samples in place.
    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0, sampleRate > 0 else { return }
        var square: Float = 0, peak: Float = 0
        for index in 0..<count {
            let value = samples[index]
            square += value * value
            peak = max(peak, abs(value))
        }
        let rms = (square / Float(count)).squareRoot()
        lastRMS = rms
        let dt = Float(Double(count) / sampleRate)
        // Envelope: quick to rise, slow to fall, so syllable gaps do not read as quiet speech.
        envelope += (rms - envelope) * (rms > envelope ? coefficient(dt, tau: 0.05) : coefficient(dt, tau: 0.4))
        // Noise floor: drops to the envelope at once, creeps up at 3 dB/s.
        if envelope < noiseFloor { noiseFloor = envelope } else { noiseFloor *= pow(10, dt * 3 / 20) }
        // Gate on this buffer's own level so a decaying tail after speech never reads as quiet speech;
        // the slower envelope decides how much lift the speech needs.
        // A keyboard click fills one buffer; a syllable fills several. Adapt only once sound has lasted ~120 ms.
        speechRun = rms > minimumSpeechRMS && rms > noiseFloor * floorMargin ? speechRun + 1 : 0
        if speechRun >= 3 {
            let desired = min(maxGain, max(1, targetRMS / envelope))
            gain += (desired - gain) * (desired < gain ? coefficient(dt, tau: 0.08) : coefficient(dt, tau: 0.8))
        }
        var effective = gain
        let limited = peak * effective > ceiling
        if limited { effective = ceiling / peak }
        if effective == 1, appliedGain == 1 { return }
        // Ramp across the buffer so gain steps never click, except when the limiter has to catch a peak now.
        if limited, effective < appliedGain { appliedGain = effective }
        let step = (effective - appliedGain) / Float(count)
        var current = appliedGain
        for index in 0..<count {
            current += step
            samples[index] = min(ceiling, max(-ceiling, samples[index] * current))
        }
        appliedGain = effective
    }
    /// Convenience for tests and offline tools.
    mutating func process(_ samples: inout [Float], sampleRate: Double) {
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            process(base, count: buffer.count, sampleRate: sampleRate)
        }
    }
    private func coefficient(_ dt: Float, tau: Float) -> Float { 1 - exp(-dt / tau) }
}
