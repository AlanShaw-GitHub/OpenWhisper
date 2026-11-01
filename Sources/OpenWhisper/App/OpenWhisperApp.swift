import SwiftUI
import AppKit

@main
struct OpenWhisperApp {
    @MainActor static func main() {
        // Listing helper (see `AudioInputDevices.microphones`): print the microphones and exit before any UI exists.
        if CommandLine.arguments.contains(AudioInputDevices.helperFlag) { AudioInputDevices.printForHelper(); exit(0) }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var menu: MenuBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        state = AppState()
        installEditingMenu()
        state.setup()
        menu = MenuBarController(state: state)
        #if OPENWHISPER_DIAGNOSTICS
        if DiagnosticRunner.runIfRequested(state: state) { return }
        #endif
        if !Provider.allCases.contains(where: state.hasKey) { menu?.show() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.cancel(); state?.restorePasteboard(); return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menu?.show()
        return false
    }
    /// A menu-bar app shows no menus, but text fields in the settings need the standard editing key equivalents.
    private func installEditingMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "OpenWhisper")
        appMenu.addItem(withTitle: L("退出 OpenWhisper"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: L("编辑"))
        for (title, selector, key) in [(L("撤销"), "undo:", "z"), (L("剪切"), "cut:", "x"), (L("复制"), "copy:", "c"), (L("粘贴"), "paste:", "v"), (L("全选"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
    }
}
