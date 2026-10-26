import AVFoundation
import ApplicationServices
import Observation
import ServiceManagement

/// Everything the menu, settings window and pill render from.
@MainActor
@Observable
final class AppState {
    enum Phase { case loading, idle, recording, transcribing }

    var phase = Phase.loading { didSet { log.info("phase \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.phase), privacy: .public)") } }
    /// Last error worth showing (model or microphone); cleared by the next successful dictation.
    var problem: String?
    /// Recent mic levels, 0...1, newest first. The pill draws them from its center outward.
    var levels = [Float](repeating: 0, count: 6)
    var hotkey = Hotkey.load() { didSet { hotkey.save() } }
    /// True while the settings window is recording a new hotkey; dictation pauses meanwhile.
    var isCapturingHotkey = false
    var micAllowed = false
    var accessibilityAllowed = false
    var lastTranscript = ""
    /// How long the model took on the last dictation, to compare models.
    var lastDuration: Duration?

    var model = SpeechModel(rawValue: UserDefaults.standard.string(forKey: "model") ?? "") ?? .whisperTurboCompressed {
        didSet {
            UserDefaults.standard.set(model.rawValue, forKey: "model")
            if model != oldValue { onModelChange?(model) }
        }
    }
    /// Set by the app delegate, which owns the transcriber.
    @ObservationIgnored var onModelChange: ((SpeechModel) -> Void)?

    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                problem = "Launch at login: \(error.localizedDescription)"
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var needsSetup: Bool { !micAllowed || !accessibilityAllowed }

    func refreshPermissions() {
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = AXIsProcessTrusted()
    }

    func push(level: Float) {
        levels.removeLast()
        levels.insert(level, at: 0)
    }
}
