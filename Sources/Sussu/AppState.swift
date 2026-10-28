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

    /// UID of the microphone to record from; empty follows the system default.
    var inputUID = UserDefaults.standard.string(forKey: "inputDevice") ?? "" {
        didSet { UserDefaults.standard.set(inputUID, forKey: "inputDevice") }
    }
    var inputDevices: [InputDevice] = []
    /// Turn dictated lists into bullets with the on-device model (Apple Intelligence only).
    var autoLists = UserDefaults.standard.object(forKey: "autoLists") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoLists, forKey: "autoLists") }
    }

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

    /// Off the main thread: coreaudiod answers slowly while a Bluetooth headset changes modes.
    func refreshInputDevices() {
        Task.detached(priority: .userInitiated) {
            let devices = AudioDevices.inputs()
            await MainActor.run { self.inputDevices = devices }
        }
    }

    func push(level: Float) {
        levels.removeLast()
        levels.insert(level, at: 0)
    }
}
