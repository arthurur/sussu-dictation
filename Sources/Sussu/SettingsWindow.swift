import AppKit
import AVFoundation
import SwiftUI

/// The one window: status, hotkey, launch at login and permissions. Opens from the menu, when the app
/// is reopened, and on launch whenever a permission is missing.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let state: AppState
    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(state: state)))
        window.title = "Sussu"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // Open on whichever Space the user is looking at. Without this the window shows up on the
        // Space it was last on, which looks like the menu item doing nothing.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.center()
        return window
    }()

    init(state: AppState) {
        self.state = state
    }

    func show() {
        state.refreshPermissions()
        state.refreshInputDevices()
        // The user just clicked a menu bar on some display; open there rather than wherever the
        // window was last left.
        if !window.isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        // Order the window first and force it front: macOS may decline the activation request, and
        // a visible but unfocused window beats no window.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    // Coming back from System Settings is when permissions change.
    func windowDidBecomeKey(_ notification: Notification) {
        state.refreshPermissions()
        state.refreshInputDevices()
    }

    // A pending hotkey capture pauses dictation everywhere, so it can't outlive the window's focus.
    func windowDidResignKey(_ notification: Notification) {
        state.isCapturingHotkey = false
    }
}

private struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.text).lineLimit(2)
                    Spacer()
                    Picker("Model", selection: $state.model) {
                        ForEach(SpeechModel.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(state.phase == .recording || state.phase == .transcribing)
                }
            }
            Section("Dictation") {
                LabeledContent("Hold to talk") { HotkeyField(state: state) }
                Picker("Microphone", selection: inputSelection) {
                    Text("System default").tag("")
                    ForEach(state.inputDevices) { Text($0.name).tag($0.id) }
                }
                .disabled(state.phase == .recording || state.phase == .transcribing)
                Toggle(isOn: $state.autoLists) {
                    Text("Format lists automatically")
                    Text(ListDetector.isAvailable ? "Uses Apple Intelligence on this Mac" : "Needs Apple Intelligence")
                }
                .disabled(!ListDetector.isAvailable)
                Toggle("Launch at login", isOn: $state.launchAtLogin)
            }
            Section("Permissions") {
                PermissionRow(title: "Microphone", allowed: state.micAllowed, action: openMicrophone)
                PermissionRow(title: "Accessibility", allowed: state.accessibilityAllowed) {
                    openPrivacyPane("Privacy_Accessibility")
                }
            }
            if !state.lastTranscript.isEmpty {
                Text("Last: \u{201C}\(state.lastTranscript)\u{201D}\(lastDurationText)")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }

    /// A saved microphone that's unplugged falls back to the system default in the picker.
    private var inputSelection: Binding<String> {
        Binding(
            get: { state.inputDevices.contains { $0.id == state.inputUID } ? state.inputUID : "" },
            set: { state.inputUID = $0 }
        )
    }

    private var lastDurationText: String {
        guard let duration = state.lastDuration else { return "" }
        return " · " + duration.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2)))
    }

    private var status: (text: String, color: Color) {
        if let problem = state.problem { return (problem, .red) }
        if state.needsSetup { return ("Needs permissions", .red) }
        return switch state.phase {
        case .loading: ("Loading model", .orange)
        case .idle: ("Ready", .green)
        case .recording: ("Listening", .green)
        case .transcribing: ("Transcribing", .green)
        }
    }

    private func openMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in state.refreshPermissions() }
            }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

private struct PermissionRow: View {
    let title: String
    let allowed: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(allowed ? .green : .red).frame(width: 7, height: 7)
            Text(title)
            Spacer()
            if allowed {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Open Settings", action: action)
            }
        }
    }
}

/// Shows the current hotkey as key caps; click it, then press the new combination.
private struct HotkeyField: View {
    @Bindable var state: AppState
    @State private var capture = HotkeyCapture()

    var body: some View {
        Button(action: begin) {
            if state.isCapturingHotkey {
                Text("Press keys…").foregroundStyle(Color.accentColor)
            } else {
                HStack(spacing: 3) {
                    ForEach(state.hotkey.symbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.background))
                    }
                }
            }
        }
        .help("Click, then press a new shortcut. Esc cancels.")
    }

    private func begin() {
        state.isCapturingHotkey = true
        capture.start(isActive: { state.isCapturingHotkey }) { hotkey in
            if let hotkey { state.hotkey = hotkey }
            state.isCapturingHotkey = false
        }
    }
}
