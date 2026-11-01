import AppKit
import ApplicationServices

/// Puts dictated text where the caret is, the way macOS dictation apps generally do (VoiceInk, Wispr Flow, OpenWhispr):
/// the text goes on the pasteboard, OpenWhisper presses ⌘V, and the pasteboard gets its earlier contents back afterwards.
/// The field is never read back to check or repair the result. Every host shows text its own way (Chromium leaves
/// line breaks out of its positions, terminals pad wide characters with U+0000, terminal screens scroll), and
/// repairing from what it showed typed text twice. Accessibility only answers whether a text field has the focus.
@MainActor
final class TextInsertionService: TranscriptTextInput {
    private var generation = UUID()
    /// The app live writing went to first; the rest of a live dictation must go there too.
    private var livePID: pid_t?
    private let pasteboard: PasteboardKeeper
    var targetName = ""
    /// Busy hosts answer accessibility queries late, not never; silence is waited out up to this budget.
    nonisolated static let responseBudget: Duration = .milliseconds(2000)
    /// How long a paste waits while OpenWhisper's own menu bar panel is in front; closing it hands the focus back
    /// (`AppState.menuClosed`).
    static let ownPanelBudget: Duration = .seconds(30)
    private static let ownPID = ProcessInfo.processInfo.processIdentifier
    #if OPENWHISPER_DIAGNOSTICS
    /// `--test-paste-only-into <bundle id>`: a test run never pastes into any other app (the user's own windows).
    static var pasteOnlyIntoForTesting: String?
    #endif

    init(pasteboard: PasteboardKeeper? = nil) { self.pasteboard = pasteboard ?? PasteboardKeeper() }

    /// At the start of a dictation nothing is decided: where the text goes is settled when it is ready. This only lets
    /// the app in front build its accessibility tree (web apps take about 2 s) while the user speaks.
    func prepare() async {
        reset()
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != Self.ownPID else { return }
        let pid = app.processIdentifier
        _ = try? await Task.detached(priority: .utility) { try await FocusedTextField.check(pid: pid) }.value
    }

    /// Pastes at the caret of the app in front now, provided its focused element takes text. `live`: one piece of live
    /// writing, which stays in the app its first piece went to.
    func paste(_ text: String, live: Bool) async throws {
        let id = generation
        let app = try await frontmostApp(id: id)
        let pid = app.processIdentifier
        #if OPENWHISPER_DIAGNOSTICS
        if let allowed = Self.pasteOnlyIntoForTesting, app.bundleIdentifier != allowed { throw OpenWhisperError("test: not the test window") }
        #endif
        if live, let livePID, livePID != pid { throw OpenWhisperError(L("你切换了应用。")) }
        // Another application's accessibility IPC can take hundreds of milliseconds; keep it off the UI thread.
        try await Task.detached(priority: .userInitiated) { try await FocusedTextField.check(pid: pid) }.value
        guard generation == id else { throw CancellationError() }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw OpenWhisperError(L("你切换了应用。")) }
        pasteboard.paste(text)
        targetName = app.localizedName ?? L("目标应用")
        if live { livePID = pid }
    }

    func reset() { generation = UUID(); livePID = nil; targetName = "" }
    /// Puts the user's pasteboard back now instead of after the delay (on quit).
    func restorePasteboard() { pasteboard.putBack() }

    /// The app in front, other than OpenWhisper. OpenWhisper's own panel in front only means the user is looking at the
    /// menu; closing it hands the focus back, so that is waited out.
    private func frontmostApp(id: UUID) async throws -> NSRunningApplication {
        let deadline = ContinuousClock.now.advanced(by: Self.ownPanelBudget)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier == Self.ownPID, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            guard generation == id else { throw CancellationError() }
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != Self.ownPID else {
            throw OpenWhisperError(L("当前没有其他应用的文本框。"))
        }
        return app
    }
}

/// Lends the general pasteboard to a paste: keeps what the user had, puts the text there, presses ⌘V, and puts the old
/// contents back once the target has had time to read the paste, unless something else wrote to the pasteboard since.
@MainActor
final class PasteboardKeeper {
    /// Long enough for a busy app to read the paste (VoiceInk defaults to 2 s, adjustable from 0.25 s).
    nonisolated static let restoreDelay: Duration = .milliseconds(1500)
    /// nspasteboard.org: clipboard history apps leave items with this type out of their history.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private let board: NSPasteboard
    private let pressPaste: () -> Void
    private let delay: Duration
    private var saved: [[(NSPasteboard.PasteboardType, Data)]]?
    private var owned: Int?
    private var restore: Task<Void, Never>?

    init(board: NSPasteboard = .general, delay: Duration = PasteboardKeeper.restoreDelay,
         pressPaste: @escaping () -> Void = { Keyboard.press(9, flags: .maskCommand) }) {
        self.board = board; self.delay = delay; self.pressPaste = pressPaste
    }
    func paste(_ text: String) {
        // Anything written since our last paste is the user's; that is what goes back.
        if board.changeCount != owned {
            saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        }
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transient)
        board.writeObjects([item])
        owned = board.changeCount
        pressPaste()
        restore?.cancel()
        restore = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.putBack()
        }
    }
    func putBack() {
        restore?.cancel(); restore = nil
        defer { saved = nil; owned = nil }
        guard let saved, board.changeCount == owned else { return }
        board.clearContents()
        let items = saved.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}

enum Keyboard {
    static func press(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags; event?.post(tap: .cghidEventTap)
        }
    }
}

/// Whether the focused element of an app takes text. AX references are immutable CF objects; this runs off the main actor.
enum FocusedTextField {
    /// Hosts that build their accessibility tree on demand get this long for the first build (about 2 s in a long document).
    static let treeBudget: Duration = .seconds(6)

    static func check(pid: pid_t, budget: Duration = TextInsertionService.responseBudget) async throws {
        guard AXIsProcessTrusted() else { throw OpenWhisperError(L("需要辅助功能权限才能写入其他应用。")) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        let started = ContinuousClock.now
        var deadline = started.advanced(by: budget)
        var announced = false
        // A host that is momentarily busy answers late, not never; keep asking within the budget.
        while true {
            let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
            if status == .success { break }
            // Hosts that build their accessibility tree on demand (Chromium browsers and apps built on Chromium such
            // as ChatGPT, Electron apps such as Claude, VS Code or Slack, Flutter) report no focused element at all
            // until an assistive technology announces itself. Send both standard announcements, whatever the host
            // answers: AXEnhancedUserInterface, which VoiceOver sets on every app (Chromium replies "not implemented"
            // and still complies), and AXManualAccessibility, Electron's own. No app list is involved.
            if status == .noValue, !announced {
                for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
                    _ = AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
                }
                announced = true
                deadline = started.advanced(by: treeBudget)
            }
            guard status == .cannotComplete || announced, ContinuousClock.now < deadline else { throw OpenWhisperError(L("找不到正在编辑的文本框。")) }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw OpenWhisperError(L("找不到正在编辑的文本框。")) }
        let reported = unsafeBitCast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(reported, 0.15)
        // Web views can name a container as the focused element while the caret sits in an editable field inside it
        // (Muse wraps its composer in an element marked as a button, which hides the field from the tree). Where
        // the caret is decides where a paste goes.
        let element = takesText(reported) ? reported : (editableAtCaret(of: reported) ?? reported)
        func read(_ name: String) -> CFTypeRef? { value(element, name) }
        let subrole = read(kAXSubroleAttribute) as? String
        guard subrole != kAXSecureTextFieldSubrole, read("AXProtectedContent") as? Bool != true else {
            throw OpenWhisperError(L("密码输入框不支持自动输入。"))
        }
        guard takesText(element) else { throw OpenWhisperError(L("当前位置不是可编辑文本框。")) }
        if read("AXEditable") as? Bool == false || read(kAXEnabledAttribute) as? Bool == false { throw OpenWhisperError(L("文本框不可编辑。")) }
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private static func takesText(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let selectedTextSettable = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(value(element, kAXRoleAttribute) as? String ?? "") || selectedTextSettable
    }
    /// The editable field holding the caret, found through the web text-marker attributes WebKit and Chromium
    /// expose: the element at the start of the selection, then its editable ancestor. Only a field that has the
    /// focus counts; a selection left behind in a field the user has clicked away from does not.
    private static func editableAtCaret(of element: AXUIElement) -> AXUIElement? {
        var host = element
        if let selection = value(element, "AXSelectedTextMarkerRange"), CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() {
            let start = AXTextMarkerRangeCopyStartMarker(unsafeBitCast(selection, to: AXTextMarkerRange.self))
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, "AXUIElementForTextMarker" as CFString, start, &result) == .success,
               let atCaret = Self.element(result) { host = atCaret }
        }
        guard let editable = takesText(host) ? host : Self.element(value(host, "AXEditableAncestor")) else { return nil }
        AXUIElementSetMessagingTimeout(editable, 0.15)
        guard value(editable, kAXFocusedAttribute) as? Bool != false, takesText(editable) else { return nil }
        return editable
    }
}
