import AppKit

/// A hold-to-talk shortcut: modifiers alone (fn ⌃) or modifiers plus one key (⌥⌘D, F13).
struct Hotkey: Codable, Equatable {
    var modifiers: Modifiers
    var keyCode: UInt16?
    /// What the key looked like when it was recorded ("D", "F13", "Space").
    var keyLabel: String?

    static let standard = Hotkey(modifiers: [.function, .control])

    var symbols: [String] { modifiers.symbols + (keyLabel.map { [$0] } ?? []) }

    private static let defaultsKey = "hotkey"

    static func load() -> Hotkey {
        UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .standard
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    /// Keys that make sense on their own, without modifiers.
    static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func label(for event: NSEvent) -> String {
        functionKeys[event.keyCode] ?? namedKeys[event.keyCode]
            ?? event.charactersIgnoringModifiers?.uppercased() ?? "#\(event.keyCode)"
    }
}

struct Modifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8

    static let function = Modifiers(rawValue: 1 << 0)
    static let control = Modifiers(rawValue: 1 << 1)
    static let option = Modifiers(rawValue: 1 << 2)
    static let shift = Modifiers(rawValue: 1 << 3)
    static let command = Modifiers(rawValue: 1 << 4)

    private static let table: [(NSEvent.ModifierFlags, Modifiers, String)] = [
        (.function, .function, "fn"), (.control, .control, "⌃"), (.option, .option, "⌥"),
        (.shift, .shift, "⇧"), (.command, .command, "⌘"),
    ]

    init(rawValue: UInt8) { self.rawValue = rawValue }

    init(_ flags: NSEvent.ModifierFlags) {
        self = Self.table.reduce(into: []) { result, entry in
            if flags.contains(entry.0) { result.insert(entry.1) }
        }
    }

    // CGEventFlags and NSEvent.ModifierFlags share the same bits.
    init(_ flags: CGEventFlags) { self.init(NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))) }

    var count: Int { rawValue.nonzeroBitCount }
    var symbols: [String] { Self.table.filter { contains($0.1) }.map(\.2) }
}

/// Records the next shortcut typed while a Sussu window has focus.
/// Modifier-only shortcuts commit when all keys come up; a keyed shortcut commits on the key press. Esc cancels.
@MainActor
final class HotkeyCapture {
    private enum Outcome { case recorded(Hotkey), cancelled }

    private var monitor: Any?
    private var peak: Modifiers = []

    /// `isActive` lets the owner abandon a capture (e.g. the window closed); the monitor then removes itself.
    func start(isActive: @escaping () -> Bool, onDone: @escaping (Hotkey?) -> Void) {
        stop()
        peak = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, isActive() else {
                self?.stop()
                return event
            }
            switch self.handle(event) {
            case .recorded(let hotkey): self.stop(); onDone(hotkey)
            case .cancelled: self.stop(); onDone(nil)
            case nil: break
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns nil while the user is still pressing keys.
    private func handle(_ event: NSEvent) -> Outcome? {
        let held = Modifiers(event.modifierFlags)
        switch event.type {
        case .flagsChanged where held.isEmpty && !peak.isEmpty:
            defer { peak = [] }
            // A lone ⌃ or ⌘ would fire on every shortcut; fn alone is fine (it's Wispr's default).
            guard peak.count >= 2 || peak == .function else {
                NSSound.beep()
                return nil
            }
            return .recorded(Hotkey(modifiers: peak))
        case .flagsChanged:
            peak.formUnion(held)
            return nil
        case .keyDown:
            // Arrow and F-keys carry the fn flag on their own; it isn't part of a keyed shortcut.
            let modifiers = held.subtracting(.function)
            if event.keyCode == 53, modifiers.isEmpty { return .cancelled }
            guard !modifiers.isEmpty || Hotkey.functionKeys[event.keyCode] != nil else {
                NSSound.beep()
                return nil
            }
            return .recorded(Hotkey(modifiers: modifiers, keyCode: event.keyCode, keyLabel: Hotkey.label(for: event)))
        default:
            return nil
        }
    }
}
