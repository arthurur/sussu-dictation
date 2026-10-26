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
        window.delegate = self
        window.center()
        return window
    }()

    init(state: AppState) {
        self.state = state
    }

    func show() {
        state.refreshPermissions()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // Coming back from System Settings is when permissions change.
    func windowDidBecomeKey(_ notification: Notification) {
        state.refreshPermissions()
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
