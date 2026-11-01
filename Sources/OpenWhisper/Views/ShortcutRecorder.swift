import SwiftUI
import AppKit
import Carbon

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut
    let onStart: () -> Void
    let onChange: (Shortcut) -> Void
    let onEnd: () -> Void
    func makeNSView(context: Context) -> RecorderButton { let view = RecorderButton(); configure(view); return view }
    func updateNSView(_ view: RecorderButton, context: Context) { configure(view) }
    static func dismantleNSView(_ view: RecorderButton, coordinator: ()) { view.finish() }
    private func configure(_ view: RecorderButton) {
        view.shortcut = shortcut; view.onStart = onStart; view.onChange = onChange; view.onEnd = onEnd
        if !view.recording { view.title = shortcut.display }
    }
    final class RecorderButton: NSButton {
        var shortcut = Shortcut()
        var onStart: (() -> Void)?
        var onChange: ((Shortcut) -> Void)?
        var onEnd: (() -> Void)?
        var recording = false
        private var monitor: Any?
        private var focusObserver: NSObjectProtocol?
        private var capture = ShortcutCapture()
        override var acceptsFirstResponder: Bool { true }
        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded; font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            target = self; action = #selector(start)
            setAccessibilityLabel(L("配置录音快捷键"))
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc private func start() {
            if recording { finish(); return }
            recording = true; title = L("按下组合键…"); onStart?()
            capture = ShortcutCapture()
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
            focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.finish()
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, self.recording else { return event }
                if event.type == .flagsChanged {
                    if let combination = self.capture.flagsChanged(event.modifierFlags) { self.save(combination) }
                    else if let combination = Shortcut.modifierCombination(event.modifierFlags) { self.title = combination.display + "…" }
                    else { self.title = L("按下组合键…") }
                    return nil
                }
                self.record(event)
                return nil
            }
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            record(event)
        }
        private func record(_ event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape) { finish(); return }
            guard let combination = Shortcut.keyCombination(event) else {
                title = L("请加 ⌃ / ⌥ / ⌘"); return
            }
            save(combination)
        }
        private func save(_ combination: Shortcut) {
            onChange?(combination)
            finish()
        }
        override func resignFirstResponder() -> Bool { if recording { finish() }; return super.resignFirstResponder() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { finish() }
            super.viewWillMove(toWindow: newWindow)
        }
        func finish() {
            guard recording else { return }
            recording = false
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }; focusObserver = nil
            title = shortcut.display; onEnd?()
        }
    }
}
