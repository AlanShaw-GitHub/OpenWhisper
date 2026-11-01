import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let state: AppState
    private var showingActive: Bool?
    #if OPENWHISPER_DIAGNOSTICS
    private var previewActive: Bool?
    #endif
    init(state: AppState) {
        self.state = state
        // Variable length: the recording pill is wider than the idle glyph, like other utilities' live indicators.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self; button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: MenuContentView(state: state))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        state.closeMenu = { [weak self] in self?.popover.performClose(nil) }
        state.showMenu = { [weak self] in self?.show() }
        #if OPENWHISPER_DIAGNOSTICS
        state.statusItemPreview = { [weak self] active in
            guard let self, let button = self.item.button else { return nil }
            self.previewActive = active
            self.refresh()
            button.layoutSubtreeIfNeeded()
            return button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
        #endif
        observe()
    }
    /// Follows the phase, shortcut and language as they change; nothing polls while the app sits idle.
    private func observe() {
        withObservationTracking { refresh() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }
    private func refresh() {
        #if OPENWHISPER_DIAGNOSTICS
        let active = previewActive ?? state.phase.active
        #else
        let active = state.phase.active
        #endif
        if active != showingActive {
            showingActive = active
            item.button?.image = active ? StatusIcon.active : StatusIcon.idle
        }
        let shortcut = state.configuration.shortcut.display
        item.button?.toolTip = "OpenWhisper · \(state.phase.title) · \(shortcut)"
        item.button?.setAccessibilityLabel(active ? L("OpenWhisper 正在听写") : L("OpenWhisper 语音输入"))
    }
    @objc private func togglePopover() { if popover.isShown { popover.performClose(nil) } else { show() } }
    func show() {
        guard let button = item.button else { return }
        // Dictation started or stopped from the panel writes into this app; see `AppState.menuClosed`.
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            state.appBeforeMenu = frontmost
        }
        // During a dictation the panel only offers Stop and Cancel. Activating OpenWhisper would take the focus away from
        // the app being dictated into, and the text would then go to the clipboard.
        let activate = !state.phase.active
        if activate { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activate {
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            clearInitialFocus()
        }
    }
    func popoverDidShow(_ notification: Notification) { if !state.phase.active { clearInitialFocus() } }
    private func clearInitialFocus() {
        guard let window = popover.contentViewController?.view.window else { return }
        // Keep the panel ready for keyboard input without choosing an editable field.
        window.initialFirstResponder = nil
        window.makeFirstResponder(nil)
    }
    func popoverDidClose(_ notification: Notification) { state.menuClosed() }
}

/// Menu bar glyphs. Both are template images, so the system paints them in the bar's own foreground colour:
/// white on a dark bar, black on a light one. While recording, the bare waveform becomes a filled pill with
/// the waveform punched out of it, sized like neighbouring utilities' "live" indicators.
enum StatusIcon {
    static let idle: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }()
    static let active: NSImage = {
        let size = NSSize(width: 34, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            if let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let glyphSize = glyph.size
                let origin = NSPoint(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2)
                glyph.draw(in: NSRect(origin: origin, size: glyphSize), from: .zero, operation: .destinationOut, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
