import AppKit

/// Types text into whatever has focus by borrowing the clipboard for a moment and sending ⌘V,
/// then puts the previous clipboard back.
enum Paster {
    private static let vKey: CGKeyCode = 0x09
    // Tells clipboard managers to ignore our temporary entry (nspasteboard.org convention).
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @MainActor
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transient)
        let ours = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Leave the clipboard alone if something else wrote to it meanwhile.
            guard pasteboard.changeCount == ours, !saved.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
    }
}
