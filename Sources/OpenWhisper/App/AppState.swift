import AppKit
import Observation
import OSLog
import ServiceManagement

@Observable @MainActor
final class AppState {
    let preferences = PreferencesStore()
    let credentials = CredentialsStore()
    let permissions = PermissionService()
    var phase: AppPhase = .idle
    var level = 0.0
    /// True once the microphone has delivered audio for this session; the hardware needs 0.5–1 s after start.
    var microphoneLive = false
    var elapsed = 0
    var transcript = ""
    /// Most recent first, at most five, kept only in memory for this process.
    var history: [String] = []
    var targetName = ""
    /// Whether a credential is saved, by credential id (speech providers use their raw value).
    var keyPresent: [String: Bool] = [:]
    var shortcutError: String?
    var launchAtLogin = false
    var inputDevices: [AudioInputDevice] = []
    var copiedToClipboard = false
    /// Streaming mode: the HUD shows the live transcript.
    var hudShowsTranscript = false
    let hudNotice = HUDNotice()
    var closeMenu: (() -> Void)?
    var showMenu: (() -> Void)?
    /// The app that was frontmost when the menu bar panel opened.
    @ObservationIgnored var appBeforeMenu: NSRunningApplication?
    #if OPENWHISPER_DIAGNOSTICS
    @ObservationIgnored var testKeys: [Provider: String] = [:]
    /// Records from the microphone without creating any network client or transcription service.
    @ObservationIgnored var localRecordingProbe = false
    /// PCM that replaces the microphone so the full dictation flow runs without speech.
    @ObservationIgnored var mockMicrophoneAudio: Data?
    @ObservationIgnored var configurationOverride: Configuration?
    @ObservationIgnored private var mockMicrophone: AsyncThrowingStream<Data, Error>.Continuation?
    @ObservationIgnored private var mockMicrophoneTask: Task<Void, Never>?
    /// Forces the menu bar icon into its idle or recording look and reports the item's screen frame.
    @ObservationIgnored var statusItemPreview: ((Bool) -> CGRect?)?
    var lastOutputFailureReason: String? { output.lastFailureReason }
    #endif
    @ObservationIgnored let shortcutService = GlobalShortcutService()
    @ObservationIgnored private let output = TranscriptOutputService()
    @ObservationIgnored private let postProcessor = TranscriptPostProcessor()
    @ObservationIgnored private let capture = AudioCaptureService()
    @ObservationIgnored private var realtime: RealtimeTranscriptionService?
    @ObservationIgnored private var liveDelivery: StreamingTextDelivery?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var hud: RecordingHUDController?
    @ObservationIgnored private var stoppedAt: ContinuousClock.Instant?
    @ObservationIgnored private var targetPreparation: Task<Void, Never>?
    @ObservationIgnored private var microphoneSetup = ""
    @ObservationIgnored private let logger = Logger(subsystem: "com.alan.wisper", category: "dictation")

    var configuration: Configuration {
        get { preferences.configuration }
        set { preferences.configuration = newValue }
    }
    /// What a recording uses; the diagnostics build can override it per test.
    private var activeConfiguration: Configuration {
        #if OPENWHISPER_DIAGNOSTICS
        return configurationOverride ?? configuration
        #else
        return configuration
        #endif
    }
    var timeLabel: String { String(format: "%02d:%02d", elapsed / 60, elapsed % 60) }
    var canStopRecording: Bool { phase == .recording || phase == .connecting }
    func hasKey(_ provider: Provider) -> Bool { keyPresent[provider.rawValue] == true }

    func setup() {
        hud = RecordingHUDController(state: self)
        shortcutService.onPress = { [weak self] in self?.toggle() }
        registerShortcut(); refreshKeys()
        permissions.refresh()
        prepareMicrophone(); refreshInputDevices()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
    /// Builds the input graph ahead of the first recording (no audio is captured). Called from settings changes
    /// and whenever the menu opens; only acts when something relevant changed.
    func prepareMicrophone() {
        #if OPENWHISPER_DIAGNOSTICS
        // The microphone diagnostic runs its own engine; a second one in the same process would reconfigure the device under it.
        if CommandLine.arguments.contains("--test-microphone") { return }
        #endif
        guard permissions.microphone, !phase.active else { return }
        let config = activeConfiguration
        let setup = "\(config.systemVoiceProcessing)|\(config.inputDeviceUID)"
        guard setup != microphoneSetup else { return }
        microphoneSetup = setup
        capture.prepare(voiceProcessing: config.systemVoiceProcessing, inputDeviceUID: config.inputDeviceUID)
    }
    func refreshInputDevices() {
        Task { [weak self] in
            let devices = await AudioInputDevices.microphones()
            if self?.inputDevices != devices { self?.inputDevices = devices }
        }
    }
    func refreshKeys() {
        let ids = Set(Provider.allCases.map(\.rawValue) + PostProcessingEngine.allCases.map(\.keyID))
        keyPresent = Dictionary(uniqueKeysWithValues: ids.map { ($0, credentials.contains(id: $0)) })
    }
    func saveKey(_ key: String, id: String) throws {
        try credentials.save(key, id: id)
        refreshKeys()
    }
    func registerShortcut(clearError: Bool = true) {
        do { try shortcutService.register(configuration.shortcut); if clearError { shortcutError = nil } }
        catch { shortcutError = error.localizedDescription }
    }
    func setShortcut(_ shortcut: Shortcut) {
        let previous = configuration.shortcut
        do { try shortcutService.register(shortcut); configuration.shortcut = shortcut; shortcutError = nil }
        catch {
            shortcutError = error.localizedDescription
            try? shortcutService.register(previous)
        }
    }
    func toggle() {
        switch phase {
        case .recording, .connecting: stop()
        case .processing: break
        default: begin()
        }
    }
    private func begin() {
        let startedAt = ContinuousClock.now
        permissions.refresh()
        guard permissions.microphone else {
            showHUDNotice(L("请先允许麦克风访问"))
            showMenu?(); return
        }
        let config = activeConfiguration
        #if OPENWHISPER_DIAGNOSTICS
        let key = testKeys[config.provider] ?? credentials.read(config.provider)
        #else
        let key = credentials.read(config.provider)
        #endif
        guard !key.isEmpty else {
            showHUDNotice(L("请先填写 %@ 的 API key。", config.provider.title)); showMenu?(); return
        }
        hudNotice.clear(); transcript = ""; elapsed = 0; level = 0; microphoneLive = false; copiedToClipboard = false; targetName = ""
        hudShowsTranscript = config.mode == .streaming
        sessionID = UUID(); let id = sessionID
        stoppedAt = nil
        phase = .connecting; hud?.show()
        // After the phase change, so closing the panel hands the focus back (`menuClosed`).
        closeMenu?()
        Probe.reset(); Probe.mark("hudShownMs", since: startedAt)
        let stream = startMicrophone(config, session: id, startedAt: startedAt)
        Probe.mark("microphoneRequestedMs", since: startedAt)
        startClock(id: id)
        // Where the text goes is decided when it is ready (the cursor may move into a field while the user speaks).
        targetPreparation = Task { [weak self] in await self?.output.prepare() }
        #if OPENWHISPER_DIAGNOSTICS
        if localRecordingProbe {
            phase = .recording
            work = Task { [weak self] in
                do {
                    var bytes = 0
                    for try await chunk in stream {
                        guard let self, self.sessionID == id, !Task.isCancelled else { return }
                        if bytes == 0 { Probe.mark("firstAudioMs", since: startedAt) }
                        bytes += chunk.count; Probe.milestones["pcmBytes"] = bytes
                    }
                } catch { self?.fail(error) }
            }
            return
        }
        #endif
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                if config.mode == .streaming {
                    try await self.stream(stream, config: config, key: key, session: id, startedAt: startedAt)
                } else {
                    try await self.transcribeWhenStopped(stream, config: config, key: key, session: id)
                }
            } catch {
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }
    private func startMicrophone(_ config: Configuration, session id: UUID, startedAt: ContinuousClock.Instant) -> AsyncThrowingStream<Data, Error> {
        #if OPENWHISPER_DIAGNOSTICS
        if let mockAudio = mockMicrophoneAudio { return startMockMicrophone(mockAudio, session: id) }
        #endif
        return capture.start(bufferLimit: config.mode == .streaming ? 2048 : 64, voiceProcessing: config.systemVoiceProcessing,
                             inputDeviceUID: config.inputDeviceUID) { [weak self] value in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                self.level = value
                if !self.microphoneLive {
                    self.microphoneLive = true
                    Probe.mark("microphoneAudioMs", since: startedAt)
                }
            }
        }
    }
    /// Streaming mode: the microphone keeps buffering while the socket connects, then text follows the speech.
    private func stream(_ stream: AsyncThrowingStream<Data, Error>, config: Configuration, key: String, session id: UUID, startedAt: ContinuousClock.Instant) async throws {
        let service = RealtimeTranscriptionService(configuration: config, key: key)
        realtime = service
        // The live text shows in the HUD. Only the experimental live writing puts it into the field while the user
        // speaks, and then only by appending.
        let live = config.liveInsertion ? StreamingTextDelivery { [weak self] text in await self?.appendLive(text, session: id) } : nil
        liveDelivery = live
        service.onTranscript = { [weak self] text, final in
            guard let self, self.sessionID == id else { return }
            self.transcript = text
            // A final result before the stop (one utterance of several) is still part of the live text.
            guard final, self.phase == .processing else { live?.submit(text); return }
            let refined = await self.refineIfNeeded(text, configuration: config, session: id)
            guard self.sessionID == id else { return }
            self.transcript = refined
            if let live {
                await live.finish(text)
                await self.finishLive(raw: text, final: refined, session: id)
            } else {
                await self.deliver(refined, session: id)
            }
        }
        service.onError = { [weak self] error in
            guard let self, self.sessionID == id else { return }
            self.fail(error)
        }
        service.onComplete = { [weak self] in
            guard let self, self.sessionID == id else { return }
            self.complete()
        }
        _ = try await RealtimeAudioPipeline.forward(stream, connect: { try await service.connect() }, ready: {
            Probe.mark("realtimeConnectedMs", since: startedAt)
            if self.phase == .connecting { self.phase = .recording }
        }, send: { try await service.send($0) }, finish: { try await service.finish() }, progress: { bytes in
            if bytes >= Self.maxRecordingBytes { self.stop() }
        }, maxLead: config.provider == .muse ? 2 : nil)
    }
    /// 8 minutes of 24 kHz PCM16 stays below every provider's upload cap.
    private static let maxRecordingBytes = 24_000 * 2 * 480
    /// Complete mode: collect the whole recording, then upload it once.
    private func transcribeWhenStopped(_ stream: AsyncThrowingStream<Data, Error>, config: Configuration, key: String, session id: UUID) async throws {
        if phase == .connecting { phase = .recording }
        var pcm = Data()
        for try await chunk in stream {
            try Task.checkCancellation()
            guard sessionID == id else { return }
            pcm.append(chunk)
            if pcm.count >= Self.maxRecordingBytes { stop() }
        }
        try Task.checkCancellation()
        guard sessionID == id else { return }
        guard pcm.count >= 24_000 else { throw OpenWhisperError(L("录音太短，请至少说半秒钟再停止。")) }
        let text = try await TranscriptionService().transcribe(pcm: pcm, configuration: config, key: key)
        try Task.checkCancellation()
        guard sessionID == id else { return }
        transcript = text
        let refined = await refineIfNeeded(text, configuration: config, session: id)
        guard sessionID == id else { return }
        transcript = refined
        await deliver(refined, session: id)
        guard sessionID == id else { return }
        complete()
    }
    /// Whole-text rewrite by the provider's text model; any failure keeps the raw transcript.
    private func refineIfNeeded(_ text: String, configuration config: Configuration, session id: UUID) async -> String {
        let settings = config.postProcessing
        guard settings.isActive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        hudNotice.show(L("正在整理文字"), duration: .seconds(TranscriptPostProcessor.timeout + 1))
        let started = ContinuousClock.now
        let modelKey = credentials.read(id: settings.engine.keyID)
        do {
            let refined = try await postProcessor.refine(text, settings: settings, keywords: config.speechSettings.keywords, key: modelKey)
            guard sessionID == id else { return text }
            Probe.mark("postProcessingMs", since: started)
            hudNotice.clear()
            return refined
        } catch {
            guard sessionID == id, !(error is CancellationError) else { return text }
            logger.notice("Post-processing failed: \(error.localizedDescription, privacy: .public)")
            hudNotice.show(L("整理失败，已输出原文"))
            return text
        }
    }
    private func deliver(_ text: String, session id: UUID) async {
        await withTarget(session: id) { await self.output.deliver(text) }
    }
    private func appendLive(_ text: String, session id: UUID) async {
        await withTarget(session: id) { await self.output.appendLive(text) }
    }
    private func finishLive(raw: String, final: String, session id: UUID) async {
        await withTarget(session: id) { await self.output.finishLive(raw: raw, final: final) }
    }
    /// Output waits for the target field to be known, and reports where the text went.
    private func withTarget(session id: UUID, _ write: () async -> Void) async {
        guard sessionID == id else { return }
        await targetPreparation?.value
        guard sessionID == id, !Task.isCancelled else { return }
        await write()
        guard sessionID == id, !Task.isCancelled else { return }
        copiedToClipboard = output.usesClipboard
        targetName = output.targetName
        hudNotice.show(output.consumeNotice())
    }
    /// On quit: the pasteboard gets the user's contents back now instead of after the delay.
    func restorePasteboard() { output.restorePasteboard() }
    func stop() {
        guard canStopRecording else { return }
        stoppedAt = .now
        phase = .processing; level = 0; clock?.cancel(); stopMicrophone()
    }
    /// The panel's Stop button: the text belongs in the app being dictated into, so the panel gets out of the way.
    func stopFromMenu() {
        stop(); closeMenu?()
    }
    /// Opening the panel (or clicking into it) makes OpenWhisper the active app. When it closes and OpenWhisper is still in
    /// front (Esc, Stop, dictation started from it), the app it was opened over gets the focus back: that is where
    /// the next or current dictation writes. Closing it by clicking another app leaves that app in front.
    func menuClosed() {
        registerShortcut(clearError: false)
        if NSApp.isActive, let app = appBeforeMenu, !app.isTerminated { app.activate(options: []) }
    }
    func cancel() {
        sessionID = UUID(); work?.cancel(); clock?.cancel(); stopMicrophone(); realtime?.cancel(); realtime = nil
        liveDelivery?.cancel(); liveDelivery = nil
        targetPreparation?.cancel(); targetPreparation = nil
        level = 0; phase = .idle; hud?.hide(); output.reset(); hudNotice.clear()
    }
    private func complete() {
        clock?.cancel(); realtime = nil; liveDelivery = nil
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hudNotice.show(L("没有识别到语音，请检查麦克风"))
            phase = .failed
        } else {
            phase = .success
            history.insert(transcript, at: 0)
            if history.count > 5 { history.removeLast(history.count - 5) }
        }
        hud?.hide(after: phase == .failed ? 2 : 0)
        output.reset()
        if let stoppedAt { Probe.mark("finalAfterStopMs", since: stoppedAt) }
    }
    private func fail(_ error: Error) {
        stopMicrophone(); clock?.cancel(); realtime?.cancel(); realtime = nil; work?.cancel()
        liveDelivery?.cancel(); liveDelivery = nil
        targetPreparation?.cancel(); targetPreparation = nil; output.reset()
        hudNotice.show(error.localizedDescription); phase = .failed; level = 0
        hud?.hide(after: 2)
        logger.error("Dictation failed; details displayed in HUD")
    }
    private func stopMicrophone() {
        capture.stop()
        #if OPENWHISPER_DIAGNOSTICS
        mockMicrophone?.finish(); mockMicrophone = nil
        mockMicrophoneTask?.cancel(); mockMicrophoneTask = nil
        #endif
    }
    private func startClock(id: UUID) {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self?.sessionID == id else { return }
                self?.elapsed += 1
            }
        }
    }
    func showHUDNotice(_ text: String) {
        hudNotice.show(text)
        hud?.show()
        if !phase.active { hud?.hide(after: 2) }
    }

    #if OPENWHISPER_DIAGNOSTICS
    /// `text` stands for the live transcript of a streaming dictation.
    func previewHUD(text: String = "") {
        guard !phase.active else { return }
        transcript = text
        hud?.show(preview: true)
        hud?.hide(after: 8)
    }
    func microphoneIdleForTesting() async -> Bool { await capture.isIdleForTesting() }
    /// Feeds the recorded PCM at real-time pace, then trailing silence, then stops exactly like the stop shortcut.
    private func startMockMicrophone(_ pcm: Data, session id: UUID) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(2048))
        mockMicrophone = continuation
        mockMicrophoneTask = Task { [weak self] in
            let chunk = 3840 // 80 ms of 24 kHz PCM16
            var offset = 0
            while offset < pcm.count, !Task.isCancelled {
                let end = min(offset + chunk, pcm.count)
                continuation.yield(pcm.subdata(in: offset..<end)); offset = end
                if let self, self.sessionID == id { self.level = 0.6; self.microphoneLive = true }
                try? await Task.sleep(for: .milliseconds(80))
            }
            for _ in 0..<12 where !Task.isCancelled {
                continuation.yield(Data(repeating: 0, count: chunk))
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled, let self, self.sessionID == id else { return }
            self.stop()
        }
        return stream
    }
    #endif
}
