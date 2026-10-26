# Sussu

Hold fn + control, talk, let go. The text lands in whatever input has focus.

Transcription runs on this Mac with Whisper large-v3-turbo through WhisperKit (Core ML). Settings lets you switch between the full 1.6 GB build and the quantized 632 MB one (the default). Nothing leaves the machine after the one-time model download.

## Install

```sh
./build.sh
```

This builds `Sussu.app`, signs it with your Apple Development identity, copies it to `~/Applications` and launches it. You get a mic icon in the menu bar and a small pill in the bottom-right corner of the screen.

First launch:

1. Allow microphone access when asked.
2. Turn on Sussu in System Settings > Privacy & Security > Accessibility. The settings window opens on its own until both permissions are in place. The hotkey starts working within two seconds of granting, no relaunch needed.
3. Wait for the model. The first run downloads it to `~/Library/Application Support/Sussu` and compiles it for the Neural Engine, which takes a few minutes. The pill is dimmed until it's ready.
4. Set System Settings > Keyboard > "Press 🌐 key to" to "Do Nothing", or fn can open the emoji picker.

Reopen the app or pick Settings… from the menu bar icon to change the hotkey or model.

## How it works

| File | Job |
| --- | --- |
| `AppDelegate.swift` | Wires hotkey, recorder, transcriber and paster together; owns the menu bar item. |
| `AppState.swift` | Observable state the menu, pill and settings render from. |
| `Hotkey.swift` | Hotkey model, saved in UserDefaults, and the "press new keys" recorder. |
| `HotkeyMonitor.swift` | CGEvent tap. Fires when the hotkey goes down and comes up; swallows the key of keyed shortcuts. |
| `Recorder.swift` | AVAudioEngine tap, resampled to 16 kHz mono, plus a loudness level for the waveform. |
| `Transcriber.swift` | WhisperKit with language auto-detect, then strips `[BLANK_AUDIO]`-style tags and filler words. |
| `Paster.swift` | Puts the text on the clipboard, sends ⌘V, restores the old clipboard 0.5 s later. |
| `Pill.swift` | Bottom-right indicator: standby pill, waveform while recording, flat bars while transcribing. |
| `SettingsWindow.swift` | Status, model picker, hotkey, launch at login, permissions. |

Presses under 0.3 s and silent clips are dropped. A modifier-only hotkey that turns into a regular shortcut (fn ⌃ ←) throws the recording away. If a paste misses (no text field had focus), use "Copy Last Transcript" from the menu.

To pin a language instead of auto-detecting, pass `language: "pt"` (or `"en"`) to `DecodingOptions` in `Transcriber.swift`.

The bundle ID is still `com.arthurrolim.dictate` from before the rename, so macOS keeps the microphone and Accessibility grants.
