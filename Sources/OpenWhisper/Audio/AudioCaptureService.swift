import Accelerate
import AVFoundation
import Foundation
import OSLog

/// The audio callback owns conversion. AsyncStream preserves PCM chunk ordering.
final class AudioCaptureService: @unchecked Sendable {
    private let engineQueue = DispatchQueue(label: "com.alan.wisper.audio", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let captureState = AudioCaptureState()
    private let gain = GainStage()
    private let logger = Logger(subsystem: "com.alan.wisper", category: "audio")
    private var installed = false
    private var preparedFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?
    private var voiceProcessing = false
    private var inputDeviceUID = ""
    private var appliedDeviceUID: String?
    /// The engine stops and uninitialises itself whenever the hardware format changes, then posts a notification.
    /// A few restarts per session are normal (our own device or voice-processor switches); more means a device
    /// that keeps flapping, and the recording ends with an error instead of looping.
    private var restarts = 0
    private var restartWindowStart = DispatchTime.now()
    #if OPENWHISPER_DIAGNOSTICS
    /// Force the voice processor's automatic gain control on or off.
    var voiceProcessingAGCOverride: Bool?
    let probe = AudioProbe()
    #endif
    init() {
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.engineQueue.async { self.handleConfigurationChange() }
        }
    }
    /// The engine has already stopped itself. Rebuild the tap for the new format and, if a recording is under
    /// way, start again on the same stream so the caller only loses the gap.
    private func handleConfigurationChange() {
        let active = captureState.current() != nil
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0) }
        installed = false; preparedFormat = nil
        logger.notice("Audio engine configuration changed (recording: \(active)); rebuilding the input graph")
        guard active else { return }
        if DispatchTime.now() > restartWindowStart + 5 { restarts = 0; restartWindowStart = .now() }
        restarts += 1
        guard restarts <= 3 else {
            captureState.take()?.continuation.finish(throwing: OpenWhisperError(L("音频设备已改变，请重新开始录音。")))
            return
        }
        do {
            try prepareEngine()
            converter?.reset()
            try engine.start()
        } catch {
            captureState.take()?.continuation.finish(throwing: OpenWhisperError(L("音频设备已改变，请重新开始录音。")))
        }
    }
    /// Allocate the input graph without starting hardware or collecting microphone audio. Switching the
    /// system voice processor takes about a second, so this never blocks the caller.
    func prepare(voiceProcessing: Bool = false, inputDeviceUID: String = "") {
        engineQueue.async { self.voiceProcessing = voiceProcessing; self.inputDeviceUID = inputDeviceUID; try? self.prepareEngine() }
    }
    private func prepareEngine() throws {
        let input = engine.inputNode
        if appliedDeviceUID != inputDeviceUID {
            engine.stop()
            if installed { input.removeTap(onBus: 0); installed = false }
            // The engine pairs the default microphone with the default output itself (a private aggregate device),
            // and some display microphones only stream while the display's speakers run. So leave the engine
            // alone for "system default" unless we previously pointed the unit at a specific microphone.
            let chosen = inputDeviceUID.isEmpty ? (appliedDeviceUID == nil ? nil : AudioInputDevices.defaultInputDeviceID())
                                                : (AudioInputDevices.deviceID(forUID: inputDeviceUID) ?? AudioInputDevices.defaultInputDeviceID())
            if let unit = input.audioUnit, var device = chosen {
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            appliedDeviceUID = inputDeviceUID; preparedFormat = nil
        }
        if input.isVoiceProcessingEnabled != voiceProcessing {
            // Switching the system voice processor rebuilds the input format, so tear the tap down first.
            engine.stop()
            if installed { input.removeTap(onBus: 0); installed = false }
            try input.setVoiceProcessingEnabled(voiceProcessing)
            preparedFormat = nil
        }
        let hardware = input.outputFormat(forBus: 0)
        #if OPENWHISPER_DIAGNOSTICS
        if voiceProcessing, let agc = voiceProcessingAGCOverride, input.isVoiceProcessingAGCEnabled != agc {
            input.isVoiceProcessingAGCEnabled = agc
        }
        if let unit = input.audioUnit {
            var device = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
            logger.notice("Preparing input: device \(device) format \(hardware.sampleRate, format: .fixed(precision: 0)) Hz × \(hardware.channelCount) ch, voiceProcessing \(self.voiceProcessing), installed \(self.installed)")
        }
        #endif
        // The voice processor exposes a multichannel stream (often five channels). Asking the tap for mono
        // lets the engine fold the channels itself; converting the raw multichannel buffer yields silence.
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate, channels: 1, interleaved: false) else {
            throw OpenWhisperError(L("无法打开麦克风，请检查系统的声音输入设备。"))
        }
        if installed, preparedFormat?.isEqual(format) == true { return }
        if installed { engine.stop(); input.removeTap(onBus: 0); installed = false }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw OpenWhisperError(L("无法打开麦克风，请检查系统的声音输入设备。"))
        }
        self.converter = converter
        let captureState = captureState, gain = gain
        #if OPENWHISPER_DIAGNOSTICS
        let probe = probe, logger = logger, voice = voiceProcessing
        #endif
        input.installTap(onBus: 0, bufferSize: 1920, format: format) { buffer, _ in
            guard let sink = captureState.current(), let channel = buffer.floatChannelData?[0] else { return }
            let continuation = sink.continuation
            let frames = Int(buffer.frameLength)
            // Level the signal before conversion so quiet speakers reach the recognisers (and the meter) at a steady volume.
            gain.normalizer.process(channel, count: frames, sampleRate: format.sampleRate)
            #if OPENWHISPER_DIAGNOSTICS
            if let delay = probe.record(rms: gain.normalizer.lastRMS, frames: frames, gain: gain.normalizer.gain) {
                logger.notice("Microphone delivered its first buffer \(delay) ms after start (engine.start \(probe.engineStartMs) ms, voiceProcessing: \(voice))")
            }
            #endif
            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frames))
            sink.onLevel(min(1, max(0, (20 * log10(Double(max(rms, 0.00001))) + 55) / 55)))
            let capacity = AVAudioFrameCount(ceil(Double(frames) * target.sampleRate / format.sampleRate) + 32)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let result = converter.convert(to: output, error: &conversionError) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            if result == .error {
                continuation.finish(throwing: conversionError ?? OpenWhisperError(L("音频转换失败。")) as NSError)
                return
            }
            let list = output.audioBufferList.pointee.mBuffers
            guard output.frameLength > 0, let bytes = list.mData else { return }
            if case .dropped = continuation.yield(Data(bytes: bytes, count: Int(output.frameLength) * 2)) {
                continuation.finish(throwing: OpenWhisperError(L("网络发送太慢，录音已停止。请检查连接后重试。")))
            }
        }
        installed = true; preparedFormat = format
        engine.prepare()
    }
    func start(bufferLimit: Int = 64, voiceProcessing: Bool = false, inputDeviceUID: String = "", onLevel: @escaping @Sendable (Double) -> Void) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(bufferLimit))
        let sink = AudioCaptureSink(continuation: continuation, onLevel: onLevel)
        captureState.set(sink)
        engineQueue.async {
            guard self.captureState.matches(sink.id) else { return }
            do {
                self.voiceProcessing = voiceProcessing; self.inputDeviceUID = inputDeviceUID
                try self.prepareEngine()
                self.converter?.reset()
                guard self.captureState.arm(sink.id) else { return }
                #if OPENWHISPER_DIAGNOSTICS
                self.probe.willStart()
                let startedAt = DispatchTime.now()
                try self.engine.start()
                self.probe.engineStartMs = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
                #else
                try self.engine.start()
                #endif
                guard self.captureState.matches(sink.id) else { self.engine.pause(); return }
            } catch {
                if self.captureState.matches(sink.id) { self.captureState.take()?.continuation.finish(throwing: error) }
                self.engine.pause()
            }
        }
        return stream
    }
    func stop() {
        guard let sink = captureState.take() else { return }
        sink.continuation.finish()
        // Hardware startup/shutdown stays off the UI thread. Keep resources while idle.
        engineQueue.async {
            self.engine.pause()
            #if OPENWHISPER_DIAGNOSTICS
            let snapshot = self.probe.snapshot
            let level = snapshot.inputRMS > 0 ? Int(20 * log10(snapshot.inputRMS)) : -120
            self.logger.notice("Microphone session ended: input \(level) dBFS, gain \(snapshot.gain, format: .fixed(precision: 2)), first buffer \(snapshot.firstBufferMs ?? -1) ms")
            #endif
        }
    }
    #if OPENWHISPER_DIAGNOSTICS
    func voiceProcessingAGCEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            engineQueue.async { continuation.resume(returning: self.engine.inputNode.isVoiceProcessingAGCEnabled) }
        }
    }
    func isIdleForTesting() async -> Bool {
        await withCheckedContinuation { continuation in
            engineQueue.async { continuation.resume(returning: !self.engine.isRunning && self.captureState.current() == nil) }
        }
    }
    #endif
    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        captureState.take()?.continuation.finish()
        engine.stop()
    }
}

private struct AudioCaptureSink {
    let id = UUID()
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    let onLevel: @Sendable (Double) -> Void
}

/// The main thread changes sessions; the real-time tap reads an immutable sink snapshot.
private final class AudioCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: AudioCaptureSink?
    private var armed = false
    func set(_ sink: AudioCaptureSink) { lock.withLock { self.sink = sink; armed = false } }
    func current() -> AudioCaptureSink? { lock.withLock { armed ? sink : nil } }
    func matches(_ id: UUID) -> Bool { lock.withLock { sink?.id == id } }
    func arm(_ id: UUID) -> Bool { lock.withLock { guard sink?.id == id else { return false }; armed = true; return true } }
    func take() -> AudioCaptureSink? { lock.withLock { let value = sink; sink = nil; armed = false; return value } }
}

/// Automatic gain, read and written only by the real-time tap. It outlives tap reinstalls (format changes), so the
/// learned gain carries from one recording to the next.
private final class GainStage: @unchecked Sendable {
    var normalizer = AudioLevelNormalizer()
}

#if OPENWHISPER_DIAGNOSTICS
/// Start-up delay and input level per recording, shared between the tap and the diagnostics report.
final class AudioProbe: @unchecked Sendable {
    struct Snapshot {
        var gain: Float
        /// Average RMS of the raw microphone signal since the last start, full scale = 1.
        var inputRMS: Float
        var firstBufferMs: Int?
    }
    private let lock = NSLock()
    /// How long the last `engine.start()` blocked; written before the first buffer can arrive.
    var engineStartMs = 0
    private var startedAt: DispatchTime?
    private var firstBufferMs: Int?
    private var inputSquares: Double = 0
    private var inputSamples = 0
    private var gain: Float = 1
    func willStart() {
        lock.withLock { startedAt = .now(); firstBufferMs = nil; inputSquares = 0; inputSamples = 0 }
    }
    /// Returns the start-up delay in milliseconds for the first buffer after `willStart`.
    func record(rms: Float, frames: Int, gain: Float) -> Int? {
        lock.withLock {
            inputSquares += Double(rms * rms) * Double(frames); inputSamples += frames; self.gain = gain
            guard let startedAt, firstBufferMs == nil else { return nil }
            let delay = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
            firstBufferMs = delay
            return delay
        }
    }
    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(gain: gain, inputRMS: inputSamples > 0 ? Float((inputSquares / Double(inputSamples)).squareRoot()) : 0, firstBufferMs: firstBufferMs)
        }
    }
}
#endif
