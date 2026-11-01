import AppKit

/// Models a paragraph editor whose AX value gains a line terminator after the first input.
final class ParagraphTextView: NSTextView {
    private var observed = ""
    private var previousRange = NSRange(location: 0, length: 0)
    private var rangeDeadline = Date.distantPast
    override func accessibilityValue() -> String? {
        guard var value = super.accessibilityValue(), !value.isEmpty else { return "" }
        // Chromium contenteditable stores a trailing space as a no-break space.
        if CommandLine.arguments.contains("--nbsp-spaces"), value.hasSuffix(" ") { value = String(value.dropLast()) + "\u{00A0}" }
        return CommandLine.arguments.contains("--plain") ? value : value + "\n"
    }
    override func accessibilitySelectedTextRange() -> NSRange {
        let current = super.accessibilitySelectedTextRange()
        guard CommandLine.arguments.contains("--delayed-caret") else { return current }
        if observed != string {
            observed = string; rangeDeadline = Date().addingTimeInterval(0.12)
        }
        if Date() < rangeDeadline { return previousRange }
        previousRange = current; return current
    }
}
final class AXFixtureDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var editor: ParagraphTextView!
    var maxSelection = 0
    var mutationScheduled = false
    var changeLog: [String] = []
    func textDidChange(_ notification: Notification) {
        changeLog.append(editor.string)
        // Busy host: accept the text, reply, then stall the main thread like a heavy re-render would.
        if CommandLine.arguments.contains("--busy-after-input") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { Thread.sleep(forTimeInterval: 0.3) }
        }
        report()
        guard !mutationScheduled, editor.string == "你好" else { return }
        mutationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [self] in
            if CommandLine.arguments.contains("--move-caret") { editor.setSelectedRange(NSRange(location: 0, length: 0)) }
            if CommandLine.arguments.contains("--edit-text") { editor.string = "您好"; editor.setSelectedRange(NSRange(location: 2, length: 0)) }
            report()
        }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        maxSelection = max(maxSelection, editor.selectedRange().length); report()
    }
    func report() {
        let value: [String: Any] = ["text": editor.string, "maximumSelectionLength": maxSelection, "mutationScheduled": mutationScheduled,
                                    "changes": changeLog]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("paragraph-fixture-report.json"), options: .atomic)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 150, y: 200, width: 680, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OpenWhisper 段落编辑器专用测试"
        editor = ParagraphTextView(frame: window.contentView!.bounds)
        editor.isRichText = false; editor.font = .systemFont(ofSize: 22)
        editor.delegate = self; window.contentView = editor
        let menu = NSMenu(), item = NSMenuItem(), edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("复制", "copy:", "c"), ("粘贴", "paste:", "v")] { edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key) }
        item.submenu = edit; menu.addItem(item); NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true); report()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AXFixtureDelegate(); app.delegate = delegate; app.run()
