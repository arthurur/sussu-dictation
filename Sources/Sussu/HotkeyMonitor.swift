import AppKit

/// Watches the keyboard system-wide and reports when the configured hotkey goes down and comes back up.
/// Needs Accessibility permission; until it's granted, it re-checks every two seconds.
@MainActor
final class HotkeyMonitor {
    private let state: AppState
    private let onPress: () -> Void
    private let onRelease: () -> Void
    /// The hotkey was part of a regular shortcut (fn ⌃ ←), so the recording should be thrown away.
    private let onCancel: () -> Void
    private var tap: CFMachPort?
    private var isDown = false
    /// Key code whose keyDown we swallowed, so its keyUp gets swallowed too.
    private var swallowed: Int64?

    init(state: AppState, onPress: @escaping () -> Void, onRelease: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.state = state
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(prompt)
        if !install() {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    if self?.install() != false { timer.invalidate() }
                }
            }
        }
    }

    private func install() -> Bool {
        guard AXIsProcessTrusted() else {
            log.info("event tap waiting for Accessibility")
            return false
        }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                // The tap's run loop source lives on the main run loop.
                let keep = MainActor.assumeIsolated { monitor.handle(type, event) }
                return keep ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("event tap creation failed")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        state.accessibilityAllowed = true
        log.info("event tap installed")
        return true
    }

    /// Returns false to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.error("event tap disabled (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        guard !state.isCapturingHotkey else {
            if type == .flagsChanged { log.debug("ignored: recording a new hotkey") }
            return true
        }
        let hotkey = state.hotkey
        let held = Modifiers(event.flags)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            log.debug("flags \(held.symbols.joined(), privacy: .public) want \(hotkey.symbols.joined(), privacy: .public) down=\(self.isDown)")
            if hotkey.keyCode == nil, !isDown, held == hotkey.modifiers {
                press()
            } else if isDown, !held.isSuperset(of: hotkey.modifiers) {
                release()
            }
        case .keyDown:
            if let code = hotkey.keyCode, keyCode == Int64(code) {
                if !isDown, held.subtracting(.function) == hotkey.modifiers { press() }
                guard isDown else { return true }
                swallowed = keyCode
                return false
            }
            if isDown, hotkey.keyCode == nil {
                log.info("hotkey cancelled by key \(keyCode)")
                isDown = false
                onCancel()
            }
        case .keyUp:
            if keyCode == swallowed {
                swallowed = nil
                if isDown { release() }
                return false
            }
        default:
            break
        }
        return true
    }

    private func press() {
        log.info("hotkey down")
        isDown = true
        onPress()
    }

    private func release() {
        log.info("hotkey up")
        isDown = false
        onRelease()
    }
}
