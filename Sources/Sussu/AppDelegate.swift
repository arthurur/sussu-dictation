import AppKit
import AVFoundation

/// Wires the hotkey to the recorder, transcriber and paster, and owns the menu bar item, pill and settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private lazy var settings = SettingsWindow(state: state)
    private var pill: PillPanel?
    private var hotkey: HotkeyMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        pill = PillPanel(state: state)
        recorder.onLevel = { [state] level in
            DispatchQueue.main.async { state.push(level: level) }
        }
        hotkey = HotkeyMonitor(state: state,
                               onPress: { [weak self] in self?.start() },
                               onRelease: { [weak self] in self?.stop() },
                               onCancel: { [weak self] in self?.cancel() })
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.state.refreshPermissions() }
        }
        state.onModelChange = { [weak self] model in self?.load(model) }
        state.refreshPermissions()
        if state.needsSetup { settings.show() }
        load(state.model)
    }

    private func load(_ model: SpeechModel) {
        state.phase = .loading
        state.problem = nil
        render()
        Task {
            do {
                try await transcriber.load(model)
                state.phase = .idle
            } catch is CancellationError {
                return // a newer load replaced this one
            } catch {
                log.error("model load failed: \(error.localizedDescription, privacy: .public)")
                state.problem = "Model failed to load: \(error.localizedDescription)"
            }
            render()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    private func start() {
        guard state.phase == .idle else {
            log.info("start ignored, phase is \(String(describing: self.state.phase), privacy: .public)")
            return
        }
        do {
            try recorder.start()
            pill?.place()
            state.phase = .recording
        } catch {
            log.error("recorder failed: \(error.localizedDescription, privacy: .public)")
            state.problem = "Microphone unavailable: \(error.localizedDescription)"
        }
        render()
    }

    private func stop() {
        guard state.phase == .recording else { return }
        state.phase = .transcribing
        render()
        Task {
            defer {
                // A model switch during transcription already moved the phase to loading.
                if state.phase == .transcribing { state.phase = .idle }
                render()
            }
            // Keep listening briefly so the last word isn't clipped when keys come up mid-syllable.
            try? await Task.sleep(for: .milliseconds(150))
            let audio = recorder.stop()
            // Anything under ~0.3s is an accidental tap.
            let peak = audio.lazy.map(abs).max() ?? 0
            let mic = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
            log.info("captured \(audio.count) samples, peak \(peak), mic auth \(mic)")
            guard audio.count > Recorder.sampleRate * 3 / 10 else { return }
            let started = ContinuousClock.now
            let text: String
            do {
                text = try await transcriber.transcribe(audio)
            } catch {
                log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            log.info("transcribed \(text.count) chars in \(ContinuousClock.now - started, privacy: .public)")
            guard !text.isEmpty else { return }
            state.lastDuration = ContinuousClock.now - started
            state.lastTranscript = text
            state.problem = nil
            Paster.paste(text)
        }
    }

    /// The hotkey turned out to be part of another shortcut; drop the audio.
    private func cancel() {
        guard state.phase == .recording else { return }
        _ = recorder.stop()
        state.phase = .idle
        render()
    }

    private func render() {
        let (symbol, line): (String, String) = switch state.phase {
        case .loading: ("arrow.down.circle", "Loading \(state.model.label)")
        case .idle: ("mic", "Hold \(state.hotkey.symbols.joined(separator: " ")) to dictate")
        case .recording: ("mic.fill", "Listening")
        case .transcribing: ("ellipsis.circle", "Transcribing")
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sussu")
        statusLine.title = state.problem ?? line
    }

    private func buildMenu() {
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Copy Last Transcript", action: #selector(copyLast), keyEquivalent: "c").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sussu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openSettings() { settings.show() }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.lastTranscript, forType: .string)
    }
}
