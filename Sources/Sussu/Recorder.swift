import AVFoundation

/// Captures the default microphone and resamples it to the 16 kHz mono floats Whisper expects.
final class Recorder {
    static let sampleRate = 16_000

    private enum Failure: LocalizedError {
        case noInput
        var errorDescription: String? { "no input device (is microphone access granted?)" }
    }

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                       channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []

    /// Called on the audio thread with the loudness of each captured chunk, 0...1.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw Failure.noInput
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: converter)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops the microphone and returns everything captured since `start()`.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { samples }
    }

    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let channel = output.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
        onLevel?(Self.loudness(chunk))
    }

    /// RMS mapped from -50...-10 dBFS onto 0...1, which covers quiet to loud speech on a laptop mic.
    private static func loudness(_ chunk: UnsafeBufferPointer<Float>) -> Float {
        guard !chunk.isEmpty else { return 0 }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(max((decibels + 50) / 40, 0), 1)
    }
}
