#if OPENWHISPER_DIAGNOSTICS
import AppKit
import AVFoundation
import ApplicationServices

/// Explicit development-only integration tests. Never logs or includes credentials in reports.
@MainActor
enum DiagnosticRunner {
    static func runIfRequested(state: AppState) -> Bool {
        let arguments = CommandLine.arguments
        func argument(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
            return arguments[index + 1]
        }
        // A diagnostic instance must not react to the user's recording shortcut while it runs its own flow.
        if arguments.contains(where: { $0.hasPrefix("--test-") || $0 == "--mock-mic" || $0 == "--show-menu" || $0 == "--preview-hud" || $0 == "--preview-status-item" }) {
            state.shortcutService.suspend()
        }
        TextInsertionService.pasteOnlyIntoForTesting = argument("--test-paste-only-into")
        if let path = argument("--import-test-keys") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let values = try JSONDecoder().decode([String: String].self, from: data)
                for provider in Provider.allCases {
                    if let value = values[provider.rawValue] {
                        state.testKeys[provider] = value
                        if arguments.contains("--save-test-keys") { try state.saveKey(value, id: provider.rawValue) }
                    }
                }
                try FileManager.default.removeItem(atPath: path)
            } catch { state.showHUDNotice("测试 key 导入失败：\(error.localizedDescription)") }
        }
        // UI review helpers: open the settings popover or the HUD preview right after launch.
        if arguments.contains("--show-menu") {
            Task { try? await Task.sleep(for: .milliseconds(1500)); state.showMenu?() }
            return true
        }
        if arguments.contains("--preview-hud") { state.previewHUD(text: argument("--preview-text") ?? ""); return true }
        // Menu bar icon review: force idle/active, report where the item sits (AppKit and top-left coordinates), stay up for a screenshot.
        if let look = argument("--preview-status-item"), let report = argument("--test-report") {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                let frame = state.statusItemPreview?(look == "active") ?? .zero
                let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                let object: [String: Any] = ["look": look, "frame": [frame.minX, frame.minY, frame.width, frame.height],
                                             "capture": [frame.minX, screenHeight - frame.maxY, frame.width, frame.height]]
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: report), options: .atomic)
                }
                try? await Task.sleep(for: .seconds(4))
                NSApp.terminate(nil)
            }
            return true
        }
        // Full production flow (shortcut toggle -> HUD -> realtime service -> frontmost app) with a mock microphone.
        if let audio = argument("--mock-mic"), let report = argument("--test-report") {
            Task {
                do {
                    state.mockMicrophoneAudio = try readPCM(audio)
                    var config = state.configuration
                    if let provider = argument("--test-provider").flatMap(Provider.init(rawValue:)) { config.provider = provider }
                    if let mode = argument("--test-mode").flatMap(OutputMode.init(rawValue:)) { config.mode = mode }
                    config.postProcessing = arguments.contains("--test-postprocess") ? testPostProcessing : PostProcessingSettings()
                    state.configurationOverride = config
                    let target = argument("--test-insertion-target")
                    if let target {
                        for _ in 0..<25 {
                            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target { break }
                            try await Task.sleep(for: .milliseconds(200))
                        }
                        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target else { throw OpenWhisperError("测试目标应用不在前台，没有开始录音。") }
                    }
                    // Menu bar panel during dictation: open it before starting (`--test-menu-before`), or at a time after
                    // the start (`--test-menu-at`), optionally activating OpenWhisper as a click into the panel does
                    // (`--test-menu-activate`), and press the panel's Stop button (`--test-menu-stop-at`).
                    if arguments.contains("--test-menu-before") {
                        // The status item needs a moment after launch to take its place in the menu bar.
                        try await Task.sleep(for: .seconds(1))
                        state.showMenu?()
                        try await Task.sleep(for: .seconds(1))
                    }
                    if let at = argument("--test-menu-at").flatMap(Double.init) {
                        Task { try? await Task.sleep(for: .seconds(at)); state.showMenu?(); if arguments.contains("--test-menu-activate") { NSApp.activate(ignoringOtherApps: true) } }
                    }
                    if let at = argument("--test-menu-stop-at").flatMap(Double.init) {
                        Task { try? await Task.sleep(for: .seconds(at)); state.stopFromMenu() }
                    }
                    let started = ContinuousClock.now
                    var timeline: [[String: Any]] = []
                    var lastPhase = state.phase, lastTranscript = "", lastClipboard = false
                    state.toggle()
                    var sawRecording = false
                    while started.duration(to: .now) < .seconds(90) {
                        try await Task.sleep(for: .milliseconds(50))
                        if state.phase != lastPhase || state.transcript != lastTranscript || state.copiedToClipboard != lastClipboard {
                            lastPhase = state.phase; lastTranscript = state.transcript; lastClipboard = state.copiedToClipboard
                            timeline.append(["ms": Int(started.duration(to: .now).seconds * 1000), "phase": "\(state.phase)",
                                "transcript": state.transcript, "clipboard": state.copiedToClipboard, "notice": state.hudNotice.text ?? ""])
                        }
                        if state.phase == .recording { sawRecording = true }
                        if state.phase == .success || state.phase == .failed { break }
                    }
                    try await Task.sleep(for: .milliseconds(300))
                    write(["test": "mock-microphone-full-flow", "passed": state.phase == .success && !state.copiedToClipboard,
                        "phase": "\(state.phase)", "sawRecording": sawRecording, "copiedToClipboard": state.copiedToClipboard,
                        "transcript": state.transcript, "targetName": state.targetName,
                        "fallbackReason": state.lastOutputFailureReason ?? "", "hudNotice": state.hudNotice.text ?? "",
                        "snapshot": target.map { focusedSnapshot($0) } ?? [:], "timeline": timeline,
                        "provider": config.provider.rawValue, "mode": config.mode.rawValue, "startupTimings": Probe.milestones], to: report)
                } catch { write(["test": "mock-microphone-full-flow", "passed": false, "error": error.localizedDescription], to: report) }
            }
            return true
        }
        if let notice = argument("--test-hud-notice"), let report = argument("--test-report") {
            Task {
                state.phase = .recording; state.elapsed = 4
                state.showHUDNotice(notice)
                try? await Task.sleep(for: .milliseconds(2200))
                write(["test": "hud-notice-local-only", "passed": state.hudNotice.text == nil], to: report)
                try? await Task.sleep(for: .seconds(2))
                state.cancel()
            }
            return true
        }
        if arguments.contains("--test-recording-start"), let report = argument("--test-report") {
            Task {
                state.localRecordingProbe = true
                // Optionally force the system voice processor on or off and let the engine re-prepare first.
                if arguments.contains("--test-voice-processing") || arguments.contains("--test-no-voice-processing") || argument("--test-input-device") != nil {
                    var config = state.configuration
                    if arguments.contains("--test-voice-processing") || arguments.contains("--test-no-voice-processing") {
                        config.systemVoiceProcessing = arguments.contains("--test-voice-processing")
                    }
                    if let device = argument("--test-input-device") { config.inputDeviceUID = device }
                    state.configurationOverride = config
                    state.prepareMicrophone()
                    try? await Task.sleep(for: .seconds(2))
                }
                state.toggle()
                try? await Task.sleep(for: .seconds(3))
                let timings = Probe.milestones
                state.cancel()
                let idle = await state.microphoneIdleForTesting()
                state.toggle()
                try? await Task.sleep(for: .seconds(2))
                let resumed = Probe.milestones
                state.cancel()
                _ = await state.microphoneIdleForTesting()
                state.toggle(); state.cancel()
                let earlyCancelIdle = await state.microphoneIdleForTesting()
                let passed = (timings["pcmBytes"] ?? 0) > 48_000 && (timings["hudShownMs"] ?? 9999) < 150 && idle && earlyCancelIdle && (resumed["pcmBytes"] ?? 0) > 48_000
                write(["test": "recording-start-local-only", "passed": passed, "timings": timings,
                    "resumedTimings": resumed, "idleAfterStop": idle, "idleAfterEarlyCancel": earlyCancelIdle], to: report)
            }
            return true
        }
        if arguments.contains("--test-stream-latency"), let audio = argument("--test-audio"), let report = argument("--test-report") {
            Task {
                var results: [[String: Any]] = []
                do {
                    let pcm = try readPCM(audio)
                    for provider in Provider.allCases {
                        var config = state.configuration; config.provider = provider
                        let key = state.testKeys[provider] ?? state.credentials.read(provider)
                        let result = try await testLive(pcm: pcm, configuration: config, key: key)
                        results.append(["provider": provider.rawValue, "passed": !result.text.isEmpty,
                            "partialEvents": result.partials, "timing": result.timing, "transcript": result.text])
                    }
                } catch { results.append(["passed": false, "error": error.localizedDescription]) }
                write(["test": "synthetic-service-latency", "results": results], to: report)
            }
            return true
        }
        if arguments.contains("--test-partial-sequence"), let report = argument("--test-report"),
           let target = argument("--test-insertion-target") {
            Task {
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target else {
                    write(["passed": false, "error": "专用测试窗口不在前台"], to: report); return
                }
                var copied: [String] = []
                let output = TranscriptOutputService(input: TextInsertionService(), copy: { copied.append($0) })
                await output.prepare()
                // The updates stand for a streaming session: partial hypotheses, then the final text. Without
                // `--test-live` only the final text is pasted; with it they are written live (append only).
                // `--test-refined <text>` stands for smart cleanup's version of the final text. Default: appends and a short correction. Spaces: English with trailing spaces (web editors keep
                // them as U+00A0). Revisions: ElevenLabs-style partials that rewrite earlier text ("3 点半" ↔ "3点半").
                var updates: [String]
                if let path = argument("--test-updates"), let data = FileManager.default.contents(atPath: path),
                   let custom = try? JSONDecoder().decode([String].self, from: data) { updates = custom }
                else if arguments.contains("--test-spaces") { updates = ["Hello", "Hello wor", "Hello world ", "Hello world and", "Hello world and more."] }
                else if arguments.contains("--test-revisions") { updates = ["我们", "我们明天下午 3 点半", "我们明天下午3点半在会议室。", "我们明天下午3点半在会议室开会，讨论第3节。", "我们明天下午 3 点半在会议室开会，讨论第三季度的预算。"] }
                else { updates = ["你好", "你好世界", "你好，世界", "你好，世界👩‍💻。"] }
                var snapshots: [[String: Any]] = [focusedSnapshot(target)]
                let raw = updates.last ?? "", final = argument("--test-refined") ?? raw
                if arguments.contains("--test-live") {
                    for text in updates.dropLast() {
                        await output.appendLive(text)
                        snapshots.append(focusedSnapshot(target))
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                    await output.finishLive(raw: raw, final: final)
                } else {
                    await output.deliver(final)
                }
                // The paste lands when the host processes ⌘V.
                try? await Task.sleep(for: .milliseconds(500))
                snapshots.append(focusedSnapshot(target))
                write(["passed": !output.usesClipboard, "usedClipboard": output.usesClipboard, "copied": copied,
                    "notice": output.consumeNotice() ?? "", "fallbackReason": output.lastFailureReason ?? "", "snapshots": snapshots], to: report)
            }
            return true
        }
        if let text = argument("--test-insertion"), let report = argument("--test-report") {
            Task {
                var result: [String: Any] = [:]
                do {
                    let insertion = TextInsertionService()
                    if let requiredApp = argument("--test-insertion-target"), NSWorkspace.shared.frontmostApplication?.bundleIdentifier != requiredApp {
                        throw OpenWhisperError("测试目标应用不在前台，没有写入测试文字。")
                    }
                    await insertion.prepare()
                    try await insertion.paste(text, live: false)
                    result = ["passed": true, "target": insertion.targetName, "text": text]
                } catch { result = ["passed": false, "error": error.localizedDescription] }
                write(result, to: report)
            }
            return true
        }
        // Synthetic audio -> real WebSocket -> production output service -> dedicated test app.
        if arguments.contains("--test-live-output"), let audio = argument("--test-audio"),
           let report = argument("--test-report"), let target = argument("--test-insertion-target") {
            Task {
                do {
                    for _ in 0..<25 {
                        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target { break }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target else {
                        throw OpenWhisperError("测试目标应用不在前台，没有写入测试文字。")
                    }
                    let output = TranscriptOutputService(input: TextInsertionService())
                    await output.prepare()
                    var config = state.configuration
                    if let provider = argument("--test-provider").flatMap(Provider.init(rawValue:)) { config.provider = provider }
                    let key = state.testKeys[config.provider] ?? state.credentials.read(config.provider)
                    var updates = 0
                    let result = try await testLive(pcm: readPCM(audio), configuration: config, key: key) { text in
                        if arguments.contains("--test-live") { await output.appendLive(text) }
                        updates += 1
                    }
                    if arguments.contains("--test-live") { await output.finishLive(raw: result.text, final: result.text) }
                    else { await output.deliver(result.text) }
                    write(["provider": config.provider.rawValue, "passed": !output.usesClipboard && !result.text.isEmpty,
                        "partialEvents": result.partials, "partialBeforeStop": result.beforeStop, "outputUpdates": updates,
                        "usedClipboard": output.usesClipboard, "target": output.targetName, "transcript": result.text,
                        "timing": result.timing, "events": result.events,
                        "fallbackReason": output.lastFailureReason ?? ""], to: report)
                } catch { write(["passed": false, "error": error.localizedDescription], to: report) }
            }
            return true
        }
        // Text-only check of the post-processing rules: one dictation per line, every rule on.
        if let file = argument("--test-refine-file"), let report = argument("--test-report") {
            Task {
                let settings = testPostProcessing
                let key = state.credentials.read(id: settings.engine.keyID)
                let keywords = argument("--test-keywords")?.split(separator: ",").map(String.init) ?? []
                var results: [[String: Any]] = []
                let lines = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                for line in lines {
                    let started = ContinuousClock.now
                    do {
                        let refined = try await TranscriptPostProcessor().refine(line, settings: settings, keywords: keywords, key: key)
                        results.append(["input": line, "refined": refined, "ms": Int(started.duration(to: .now).seconds * 1000)])
                    } catch { results.append(["input": line, "error": error.localizedDescription]) }
                }
                write(["engine": settings.engine.rawValue, "model": settings.model, "results": results], to: report)
            }
            return true
        }
        // Read-only: find the focused text field of a running app exactly as a dictation start does; nothing is written.
        if let bundle = argument("--test-capture"), let report = argument("--test-report") {
            Task {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
                    write(["passed": false, "error": "not running"], to: report); return
                }
                let started = ContinuousClock.now
                do {
                    try await FocusedTextField.check(pid: app.processIdentifier)
                    write(["passed": true, "ms": Int(started.duration(to: .now).seconds * 1000)], to: report)
                } catch {
                    write(["passed": false, "ms": Int(started.duration(to: .now).seconds * 1000), "error": error.localizedDescription], to: report)
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--list-input-devices"), let report = argument("--test-report") {
            Task {
                // List what the settings show in normal use: after the app has prepared its (voice-processing) input graph.
                try? await Task.sleep(for: .seconds(3))
                let inProcess = AudioInputDevices.enumerate().map(\.name)
                write(["devices": await AudioInputDevices.microphones().map { ["uid": $0.uid, "name": $0.name] }, "inProcess": inProcess,
                       "defaultDeviceID": AudioInputDevices.defaultInputDeviceID().map(Int.init) ?? -1], to: report)
            }
            return true
        }
        // Isolated local-only hardware check: this branch never creates a network client.
        if arguments.contains("--test-microphone"), let report = argument("--test-report"), argument("--test-audio") == nil {
            Task {
                do {
                    let capture = AudioCaptureService()
                    let voice = arguments.contains("--test-voice-processing")
                    let device = argument("--test-input-device") ?? ""
                    let seconds = argument("--test-seconds").flatMap(Double.init) ?? 3
                    if let agc = argument("--test-agc") { capture.voiceProcessingAGCOverride = agc == "on" }
                    let stream = capture.start(voiceProcessing: voice, inputDeviceUID: device) { _ in }
                    let stopper = Task {
                        try? await Task.sleep(for: .seconds(seconds))
                        capture.stop()
                    }
                    var bytes = 0, peak = 0, sumSquares = 0.0, samples = 0
                    for try await chunk in stream {
                        bytes += chunk.count
                        chunk.withUnsafeBytes { raw in
                            for sample in raw.bindMemory(to: Int16.self) {
                                let value = Int(sample); peak = max(peak, abs(value)); sumSquares += Double(value * value); samples += 1
                            }
                        }
                    }
                    stopper.cancel()
                    let rms = samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0
                    let stats = capture.probe.snapshot
                    let agcEnabled = voice ? await capture.voiceProcessingAGCEnabled() : false
                    write(["test": "microphone-local-only", "passed": bytes > 48_000, "pcmBytes": bytes, "sampleRate": 24_000, "voiceProcessing": voice,
                        "peak": peak, "rms": Int(rms), "inputDevice": device, "seconds": seconds,
                        "inputRMS": Int(stats.inputRMS * 32768), "gain": Double(round(stats.gain * 100) / 100), "firstBufferMs": stats.firstBufferMs ?? -1, "agcEnabled": agcEnabled,
                        "microphoneAuthorized": state.permissions.microphone, "accessibilityAuthorized": state.permissions.accessibility], to: report)
                } catch { write(["test": "microphone-local-only", "passed": false, "error": error.localizedDescription], to: report) }
            }
            return true
        }
        guard let audio = argument("--test-audio"), let report = argument("--test-report") else { return false }
        Task {
            var results: [[String: Any]] = []
            do {
                let pcm = try readPCM(audio)
                let providers = argument("--test-provider").flatMap(Provider.init(rawValue:)).map { [$0] } ?? Provider.allCases
                for provider in providers {
                    let key = state.testKeys[provider] ?? state.credentials.read(provider)
                    guard !key.isEmpty else { continue }
                    var config = state.configuration; config.provider = provider
                    if let codes = argument("--test-languages") { config.languageCodes = codes == "auto" ? [] : codes.split(separator: ",").map(String.init) }
                    // Custom vocabulary for this run: a comma-separated list, or "none" to send no keywords.
                    if let words = argument("--test-speech-keywords") { config.speechSettings.keywordText = words == "none" ? "" : words }
                    let postprocess = arguments.contains("--test-postprocess")
                    config.postProcessing = postprocess ? testPostProcessing : PostProcessingSettings()
                    let modelKey = state.credentials.read(id: config.postProcessing.engine.keyID)
                    let keywords = config.speechSettings.keywords
                    func refined(_ text: String) async -> [String: Any] {
                        guard postprocess else { return [:] }
                        let settings = config.postProcessing
                        let started = ContinuousClock.now
                        do {
                            let value = try await TranscriptPostProcessor().refine(text, settings: settings, keywords: keywords, key: modelKey)
                            return ["refined": value, "postProcessMs": Int(started.duration(to: .now).seconds * 1000),
                                    "postProcessModel": settings.model, "postProcessEngine": settings.engine.rawValue]
                        } catch { return ["refinedError": error.localizedDescription] }
                    }
                    do {
                        let batch = TranscriptionService()
                        let text = try await batch.transcribe(pcm: pcm, configuration: config, key: key)
                        results.append(["provider": provider.rawValue, "mode": "complete", "passed": !text.isEmpty, "transcript": text,
                            "languages": config.languageCodes, "keywords": config.speechSettings.keywords].merging(await refined(text)) { $1 })
                    } catch { results.append(["provider": provider.rawValue, "mode": "complete", "passed": false, "error": error.localizedDescription]) }
                    if arguments.contains("--test-only-batch") { continue }
                    do {
                        let liveResult = try await testLive(pcm: pcm, configuration: config, key: key)
                        results.append(["provider": provider.rawValue, "mode": "streaming", "passed": !liveResult.text.isEmpty, "transcript": liveResult.text,
                            "partialEvents": liveResult.partials, "partialBeforeStop": liveResult.beforeStop, "timing": liveResult.timing,
                            "connectionMs": liveResult.connectionMs, "finalWaitMs": liveResult.finalWaitMs,
                            "events": liveResult.events,
                            "audioBufferedBeforeConnection": liveResult.bufferedBytes,
                            "languages": config.languageCodes, "keywords": config.speechSettings.keywords].merging(await refined(liveResult.text)) { $1 })
                    } catch { results.append(["provider": provider.rawValue, "mode": "streaming", "passed": false, "error": error.localizedDescription]) }
                }
            } catch { results.append(["passed": false, "error": error.localizedDescription]) }
            write(["results": results], to: report)
            state.showHUDNotice("接口测试完成，报告已保存。")
        }
        return true
    }
    private static func focusedSnapshot(_ bundle: String) -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundle else { return ["focusChanged": true] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            var names: CFArray?
            _ = AXUIElementCopyAttributeNames(root, &names)
            return ["focusError": status.rawValue, "attributes": names as? [String] ?? [], "applicationActive": app.isActive]
        }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var result: [String: Any] = [:]
        for name in [kAXRoleAttribute, kAXValueAttribute, kAXSelectedTextAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success { result[name] = value as? String ?? "" }
        }
        var selection: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
           let selection, CFGetTypeID(selection) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeBitCast(selection, to: AXValue.self), .cfRange, &range) { result["range"] = [range.location, range.length] }
        }
        return result
    }
    private static func readPCM(_ path: String) throws -> Data {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
        let converter = AVAudioConverter(from: format, to: outputFormat)!
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(file.length) * 24_000 / format.sampleRate) + 64))!
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        let buffer = output.audioBufferList.pointee.mBuffers
        return Data(bytes: buffer.mData!, count: Int(output.frameLength) * 2)
    }
    private static func testLive(pcm: Data, configuration: Configuration, key: String, onOutput: ((String) async -> Void)? = nil) async throws -> (text: String, partials: Int, beforeStop: Bool, connectionMs: Int, finalWaitMs: Int, bufferedBytes: Int, timing: [String: Any], events: [String: Int]) {
        let live = RealtimeTranscriptionService(configuration: configuration, key: key)
        if let index = CommandLine.arguments.firstIndex(of: "--test-live-delay"), CommandLine.arguments.count > index + 1 {
            live.testDelayOverride = CommandLine.arguments[index + 1]
        }
        let started = ContinuousClock.now
        var text = "", partials = 0, beforeStop = false, stopped = false
        var completion: Result<Void, Error>?
        var stoppedAt: ContinuousClock.Instant?, completedAt: ContinuousClock.Instant?
        var firstPartialMs = -1, firstAudioSentMs = -1, firstOutputMs = -1
        var receivedAt: [String: ContinuousClock.Instant] = [:]
        var outputDelays: [Int] = [], writes: [Int] = [], receiveTimes: [Int] = [], sendDelays: [Int] = []
        var producedAt: [Int: ContinuousClock.Instant] = [:], sentBytes = 0
        var events: [String: Int] = [:]
        var eventTimeline: [[String: Any]] = [], sessionConfiguration: [String: Any] = [:]
        live.onEventForTesting = { event in
            let type = event["message_type"] as? String ?? event["type"] as? String ?? "unknown"
            events[type, default: 0] += 1
            eventTimeline.append(["type": type, "ms": Int(started.duration(to: .now).seconds * 1000)])
            if type == "session_started", let config = event["config"] as? [String: Any] {
                for name in ["model_id", "audio_format", "sample_rate", "commit_strategy", "no_verbatim", "filter_background_audio", "keepalive_interval_ms", "language_code", "secondary_languages"] {
                    if let value = config[name] { sessionConfiguration[name] = value }
                }
            }
        }
        let delivery = onOutput.map { onOutput in StreamingTextDelivery { value in
            let writeStarted = ContinuousClock.now
            await onOutput(value)
            let now = ContinuousClock.now
            if firstOutputMs < 0 { firstOutputMs = Int(started.duration(to: now).seconds * 1000) }
            writes.append(Int(writeStarted.duration(to: now).seconds * 1000))
            if let received = receivedAt[value] { outputDelays.append(Int(received.duration(to: now).seconds * 1000)) }
        } }
        live.onTranscript = { value, final in
            text = value
            if !value.isEmpty {
                let ms = Int(started.duration(to: .now).seconds * 1000)
                if firstPartialMs < 0 { firstPartialMs = ms }
                receivedAt[value] = .now; receiveTimes.append(ms)
            }
            if !final { partials += 1; if !stopped { beforeStop = true } }
            if final { await delivery?.finish(value) } else { delivery?.submit(value) }
        }
        live.onError = { completion = .failure($0) }
        live.onComplete = { completedAt = .now; completion = .success(()) }
        defer { live.cancel() }
        var producedBytes = 0, bufferedBytes = 0, connectionMs = 0
        let (stream, source) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(2048))
        // Simulate the production microphone while connecting; no real microphone is opened.
        let producer = Task {
            do {
                var offset = 0
                while offset < pcm.count {
                    try Task.checkCancellation()
                    let end = min(offset + 3840, pcm.count)
                    source.yield(pcm.subdata(in: offset..<end))
                    producedBytes += end - offset; offset = end; producedAt[producedBytes] = .now
                    try await Task.sleep(for: .milliseconds(80))
                }
                for _ in 0..<(CommandLine.arguments.contains("--test-no-trailing-silence") ? 0 : 15) {
                    source.yield(Data(repeating: 0, count: 3840)); producedBytes += 3840; producedAt[producedBytes] = .now
                    try await Task.sleep(for: .milliseconds(80))
                }
                stopped = true; source.finish()
            } catch { source.finish(throwing: error) }
        }
        defer { producer.cancel() }
        _ = try await RealtimeAudioPipeline.forward(stream, connect: { try await live.connect() }, ready: {
            connectionMs = Int(started.duration(to: .now).seconds * 1000)
            bufferedBytes = producedBytes
        }, send: { chunk in
            if let completion { try completion.get() }
            if firstAudioSentMs < 0 { firstAudioSentMs = Int(started.duration(to: .now).seconds * 1000) }
            sentBytes += chunk.count
            if let produced = producedAt[sentBytes] { sendDelays.append(Int(produced.duration(to: .now).seconds * 1000)) }
            try await live.send(chunk)
        }, finish: {
            stoppedAt = .now; try await live.finish()
        })
        let deadline = Date().addingTimeInterval(50)
        while completion == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard let completion else { throw OpenWhisperError("测试等待最终事件超时。") }
        try completion.get()
        let finalWaitMs = stoppedAt.flatMap { start in completedAt.map { Int(start.duration(to: $0).seconds * 1000) } } ?? 0
        func median(_ values: [Int]) -> Int { let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[sorted.count / 2] }
        let intervals = zip(receiveTimes, receiveTimes.dropFirst()).map { $1 - $0 }
        let timing: [String: Any] = ["connectionMs": connectionMs, "firstAudioSentMs": firstAudioSentMs,
            "firstTranscriptMs": firstPartialMs, "firstOutputMs": firstOutputMs,
            "serviceFirstTranscriptAfterFirstAudioMs": firstPartialMs - firstAudioSentMs,
            "medianAudioQueueMs": median(sendDelays), "maxAudioQueueMs": sendDelays.max() ?? 0,
            "medianReceiveIntervalMs": median(intervals), "medianReceiveToVerifiedInputMs": median(outputDelays),
            "maxReceiveToVerifiedInputMs": outputDelays.max() ?? 0, "medianWriteMs": median(writes),
            "eventTimeline": eventTimeline, "sessionConfiguration": sessionConfiguration,
            "finalWaitMs": finalWaitMs, "audioDurationMs": pcm.count / 48,
            "delay": live.testDelayOverride ?? (configuration.provider == .openai ? "low" : "service-default")]
        return (text, partials, beforeStop, connectionMs, finalWaitMs, bufferedBytes, timing, events)
    }
    private static var testPostProcessing: PostProcessingSettings {
        var settings = PostProcessingSettings(); settings.enabled = true
        settings.rules = PostProcessingRule.allCases.map(\.rawValue)
        if let engine = argument("--test-postprocess-engine").flatMap(PostProcessingEngine.init(rawValue:)) { settings.engine = engine }
        if let model = argument("--test-postprocess-model") {
            if settings.engine == .openai { settings.openAIModel = model } else if settings.engine == .gemini { settings.geminiModel = model }
        }
        return settings
    }
    private static func argument(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }
    /// Reports end the diagnostic process so test launches never leave a second menu bar instance behind.
    private static func write(_ object: [String: Any], to path: String) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        }
    }
}
#endif
