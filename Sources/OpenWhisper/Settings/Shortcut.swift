import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    var isModifierOnly: Bool
    init() {
        keyCode = 0; modifiers = UInt32(cmdKey | controlKey); keyLabel = ""; isModifierOnly = true
    }
    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String, isModifierOnly: Bool = false) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel; self.isModifierOnly = isModifierOnly
    }
    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, keyLabel, isModifierOnly }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try values.decode(UInt32.self, forKey: .keyCode)
        modifiers = try values.decode(UInt32.self, forKey: .modifiers)
        keyLabel = try values.decode(String.self, forKey: .keyLabel)
        isModifierOnly = try values.decodeIfPresent(Bool.self, forKey: .isModifierOnly) ?? false
    }
    var display: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        guard !isModifierOnly else { return result }
        // The label is stored when the shortcut is recorded; a word like "Space" follows the current language.
        return result + (keyCode == UInt32(kVK_Space) ? L("空格") : keyLabel)
    }
}

extension Shortcut {
    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
    static func modifierCombination(_ flags: NSEvent.ModifierFlags) -> Shortcut? {
        let flags = flags.intersection(modifierMask)
        guard flags.rawValue.nonzeroBitCount >= 2 else { return nil }
        return Shortcut(keyCode: 0, modifiers: carbonModifiers(flags), keyLabel: "", isModifierOnly: true)
    }
    static func keyCombination(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(modifierMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        let labels: [UInt16: String] = [49: "空格", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        // Ignore Option/Control when reading the key name so ⌥D displays D, not ∂.
        let label = labels[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "#\(event.keyCode)"
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers(flags), keyLabel: label)
    }
}

struct ShortcutCapture {
    private(set) var held: NSEvent.ModifierFlags = []
    mutating func flagsChanged(_ flags: NSEvent.ModifierFlags) -> Shortcut? {
        let next = flags.intersection(Shortcut.modifierMask)
        let previous = held
        held = next
        // Wait for release: pressing ⌘⌃ followed by a letter must record the whole shortcut.
        if next.isStrictSubset(of: previous) { return Shortcut.modifierCombination(previous) }
        return nil
    }
}

struct ModifierShortcutTrigger {
    let required: UInt32
    private var held = false
    init(required: UInt32, current: NSEvent.ModifierFlags = []) {
        self.required = required
        held = Shortcut.carbonModifiers(current) & required == required
    }
    /// Fires once when exactly the required modifiers go down. Reaching them as part of a larger chord (⌘⇧⌃4 for a
    /// screenshot) arms `held` without firing, so letting go of the extra key is not a press either.
    mutating func update(_ flags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = Shortcut.carbonModifiers(flags)
        let pressed = modifiers == required && !held
        held = modifiers & required == required
        return pressed
    }
}
