import AppKit
import Carbon

@MainActor
final class GlobalShortcutService {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var handlerStatus: OSStatus = noErr
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var modifierTrigger: ModifierShortcutTrigger?
    private var suspended = true
    private var keyHeld = false
    var onPress: (() -> Void)?

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x57535052, id.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let service = Unmanaged<GlobalShortcutService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in service.handleKey(pressed: pressed) }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut) throws {
        suspend()
        if shortcut.isModifierOnly {
            modifierTrigger = ModifierShortcutTrigger(required: shortcut.modifiers, current: NSEvent.modifierFlags)
            // Other apps' key events reach a global monitor only with Accessibility access. Add it afresh on every
            // registration (each time the settings panel closes) so access granted after launch works without a relaunch.
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleModifiers(event.modifierFlags)
            }
            if localMonitor == nil {
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                    self?.handleModifiers(event.modifierFlags)
                    return event
                }
            }
            guard globalMonitor != nil, localMonitor != nil else { throw OpenWhisperError(L("无法监听组合键，请检查辅助功能权限后重试。")) }
        } else {
            guard handlerStatus == noErr else { throw OpenWhisperError(L("无法注册快捷键监听，请重新启动 OpenWhisper。")) }
            let id = EventHotKeyID(signature: 0x57535052, id: 1)
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
            guard status == noErr else { throw OpenWhisperError(L("快捷键被其他应用占用，请换一个组合键。")) }
        }
        suspended = false
    }
    func suspend() {
        suspended = true; keyHeld = false; modifierTrigger = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
    }
    private func handleKey(pressed: Bool) {
        guard !suspended else { return }
        if pressed && !keyHeld { keyHeld = true; onPress?() }
        if !pressed { keyHeld = false }
    }
    private func handleModifiers(_ flags: NSEvent.ModifierFlags) {
        guard !suspended, modifierTrigger != nil else { return }
        if modifierTrigger?.update(flags) == true { onPress?() }
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
