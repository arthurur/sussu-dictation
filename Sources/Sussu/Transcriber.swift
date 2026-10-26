import FluidAudio
import Foundation
import WhisperKit

/// The models you can pick in settings: two builds of Whisper large-v3-turbo (the smaller is quantized)
/// and NVIDIA's Parakeet TDT v3.
enum SpeechModel: String, CaseIterable, Identifiable {
    case whisperTurbo = "openai_whisper-large-v3-v20240930_turbo"
    case whisperTurboCompressed = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case parakeet = "parakeet-tdt-0.6b-v3"

    var id: Self { self }

    var label: String {
        switch self {
        case .whisperTurbo: "Whisper turbo · 1.6 GB"
        case .whisperTurboCompressed: "Whisper turbo · 632 MB"
        case .parakeet: "Parakeet v3 · 480 MB"
        }
    }
}

/// Picks, loads and runs the selected model on this Mac (Core ML on the Neural Engine).
/// Main-actor bound so model swaps can't race; the engines' own async work runs off the main thread.
@MainActor
final class Transcriber {
    /// Models download here on first use: ~/Library/Application Support/Sussu/models
    private static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Sussu")

    private var engine: (any SpeechEngine)?
    private var loading: SpeechModel?

    /// Downloads the model if needed, then loads and warms it up.
    /// Calling it again swaps models; if loads overlap, the last one requested wins.
    func load(_ model: SpeechModel) async throws {
        loading = model
        engine = nil
        let engine: any SpeechEngine
        switch model {
        case .whisperTurbo, .whisperTurboCompressed:
            engine = try await WhisperEngine.load(model.rawValue, base: Self.directory)
        case .parakeet:
            engine = try await ParakeetEngine.load(base: Self.directory)
        }
        // The first run is slow; pay for it now instead of on the first dictation.
        _ = try await engine.transcribe([Float](repeating: 0, count: Recorder.sampleRate))
        guard loading == model else { throw CancellationError() }
        self.engine = engine
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        // Whisper invents text ("Thank you.") for silence, so skip clips that never rise above
        // room noise (about 0.0015 on a MacBook mic at low input volume).
        let peak = audio.lazy.map(abs).max() ?? 0
        guard let engine, peak > 0.006 else { return "" }
        // A low input volume leaves speech too faint for the models, so bring it up to a normal level.
        let normalized = peak < 0.5 ? audio.map { $0 * 0.5 / peak } : audio
        return Cleanup.apply(try await engine.transcribe(normalized))
    }
}

/// A loaded model that turns 16 kHz mono samples into text.
private protocol SpeechEngine {
    func transcribe(_ audio: [Float]) async throws -> String
}

private final class WhisperEngine: SpeechEngine {
    private let whisper: WhisperKit

    private init(_ whisper: WhisperKit) { self.whisper = whisper }

    static func load(_ name: String, base: URL) async throws -> WhisperEngine {
        WhisperEngine(try await WhisperKit(WhisperKitConfig(
            model: name,
            downloadBase: base,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true
        )))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        let options = DecodingOptions(language: nil, detectLanguage: true, skipSpecialTokens: true, withoutTimestamps: true)
        return try await whisper.transcribe(audioArray: audio, decodeOptions: options)
            .map(\.text)
            .joined(separator: " ")
    }
}

private final class ParakeetEngine: SpeechEngine {
    private static let version = AsrModelVersion.v3
    private let manager: AsrManager

    private init(_ manager: AsrManager) { self.manager = manager }

    static func load(base: URL) async throws -> ParakeetEngine {
        // FluidAudio expects the folder to be named after the Hugging Face repo.
        let repo = AsrModels.defaultCacheDirectory(for: version).lastPathComponent
        let models = try await AsrModels.downloadAndLoad(
            to: base.appending(path: "models/FluidInference/\(repo)"), version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetEngine(manager)
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        var state = try TdtDecoderState(decoderLayers: Self.version.decoderLayers)
        return try await manager.transcribe(audio, decoderState: &state).text
    }
}

/// Light post-processing: drops Whisper's non-speech tags and filler words.
enum Cleanup {
    static func apply(_ text: String) -> String {
        let cleaned = text
            .replacing(/\[[A-Z_ ]+\]|\((?i:music|silence|inaudible|applause|laughs?)\)/, with: "")
            .replacing(/(?i)\b(?:u+m+|u+h+|e+r+m+|h+m+)\b[,.]?\s*/, with: "")
            .replacing(/\s{2,}/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }
}
