import AppKit
import OSLog

@MainActor
protocol TranscriptTextInput: AnyObject {
    var targetName: String { get }
    func prepare() async
    func paste(_ text: String, live: Bool) async throws
    func reset()
}

/// Delivers a dictation: pasted once at the caret when it is finished, or left on the clipboard when, at that moment,
/// the cursor is not in a text field. With live writing (experimental) the text grows in the field while the user speaks, but
/// only ever by appending.
@MainActor
final class TranscriptOutputService {
    private let input: any TranscriptTextInput
    private let copy: (String) -> Void
    private var generation = UUID()
    private var live = LiveAppend()
    private let logger = Logger(subsystem: "com.alan.wisper", category: "text-input")
    private(set) var usesClipboard = false
    private(set) var notice: String?
    #if OPENWHISPER_DIAGNOSTICS
    private(set) var lastFailureReason: String?
    #endif
    var targetName: String { usesClipboard ? L("剪贴板") : input.targetName }

    init(input: (any TranscriptTextInput)? = nil, copy: @escaping (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }) {
        self.input = input ?? TextInsertionService(); self.copy = copy
    }
    /// Called when recording starts. Nothing is decided yet: the destination is wherever the cursor is when the text is ready.
    func prepare() async {
        generation = UUID()
        notice = nil; usesClipboard = false; live = LiveAppend()
        #if OPENWHISPER_DIAGNOSTICS
        lastFailureReason = nil
        #endif
        await input.prepare()
    }
    /// The finished text: pasted once, or copied to the clipboard when there is no field or the paste cannot be made.
    func deliver(_ text: String) async {
        guard !text.isEmpty else { return }
        let id = generation
        if !usesClipboard {
            do { try await input.paste(text, live: false); return }
            catch { guard generation == id, !(error is CancellationError) else { return }; fallBack(error, notify: false) }
        }
        guard generation == id else { return }
        copy(text)
    }
    /// Live writing: pastes only what extends the text already written. Once the recognizer revises written text,
    /// live writing stops for this dictation; nothing is ever deleted.
    func appendLive(_ hypothesis: String) async {
        guard !usesClipboard, let addition = live.next(hypothesis) else { return }
        let id = generation
        do { try await input.paste(addition, live: true) }
        catch { guard generation == id, !(error is CancellationError) else { return }; fallBack(error, notify: true) }
    }
    /// Ends live writing. The raw text is completed in the field while it still extends what was written; when the
    /// recognizer revised written text, or smart cleanup changed it, the finished text goes to the clipboard.
    func finishLive(raw: String, final: String) async {
        guard live.hasWritten else { await deliver(final); return }
        let id = generation
        await appendLive(raw)
        guard generation == id, !final.isEmpty else { return }
        if usesClipboard { copy(final); return }
        guard live.stopped || final != raw else { return }
        copy(final)
        notice = live.stopped ? L("识别有修正，完整文字已复制到剪贴板") : L("整理后的文字已复制到剪贴板")
    }
    func consumeNotice() -> String? {
        defer { notice = nil }
        return notice
    }
    func reset() { generation = UUID(); input.reset(); live = LiveAppend() }
    func restorePasteboard() { (input as? TextInsertionService)?.restorePasteboard() }

    /// `notify`: say so in the HUD while live writing is under way; at the end the status line already says
    /// "copied to the clipboard".
    private func fallBack(_ error: Error, notify: Bool) {
        let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        usesClipboard = true; input.reset()
        // Notice level persists in the unified log so a field report can be diagnosed with `log show`.
        logger.notice("Input switched to clipboard: \(error.localizedDescription, privacy: .public); target=\(target, privacy: .public)")
        #if OPENWHISPER_DIAGNOSTICS
        lastFailureReason = error.localizedDescription
        #endif
        if notify { notice = L("已切换到剪贴板") }
    }
}

/// What live writing may still add. It only appends: a hypothesis that no longer starts with the written text (the
/// recognizer revised it) stops it, as in other streaming dictation tools; nothing in the field is guessed at.
struct LiveAppend {
    private(set) var written = ""
    private(set) var stopped = false
    var hasWritten: Bool { !written.isEmpty }
    /// The part of `hypothesis` to paste now. Trailing whitespace waits for the next word, since recognizers often drop it.
    mutating func next(_ hypothesis: String) -> String? {
        guard !stopped else { return nil }
        let stable = String(hypothesis.reversed().drop { $0.isWhitespace }.reversed())
        // An empty hypothesis is a retracted noise guess, not a revision of written text.
        guard !stable.isEmpty else { return nil }
        guard stable.hasPrefix(written) else { stopped = true; return nil }
        let addition = String(stable.dropFirst(written.count))
        guard !addition.isEmpty else { return nil }
        written = stable
        return addition
    }
}
