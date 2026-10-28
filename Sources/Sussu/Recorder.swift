import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures one microphone and resamples it to the 16 kHz mono floats the models expect.
///
/// Drives the HAL output unit directly rather than through AVAudioEngine. The engine follows device
/// changes on its own: it stopped recordings a second in when the headset left call mode, and deadlocked
/// the main thread when the input device changed between recordings.
actor Recorder {
    static let sampleRate = 16_000

    private let onLevel: @Sendable (Float) -> Void
    private var capture: Capture?

    /// `onLevel` is called on the audio thread with the loudness of each captured chunk, 0...1.
    init(onLevel: @escaping @Sendable (Float) -> Void) {
        self.onLevel = onLevel
    }

    /// Records from the device with this UID, or the system default when it's empty or no longer connected.
    func start(deviceUID: String = "") throws {
        teardown()
        guard var device = AudioDevices.deviceID(forUID: deviceUID) ?? AudioDevices.defaultInput() else {
            throw RecorderFailure.noInput
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw RecorderFailure.noInput }
        var created: AudioUnit?
        try check("create unit", AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw RecorderFailure.noInput }
        do {
            var on: UInt32 = 1, off: UInt32 = 0
            try check("enable input", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4))
            try check("disable output", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4))
            try check("select device", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size)))
            // The unit can't resample, so take the device's rate and channel count and convert afterwards.
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check("read device format", AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let deviceFormat = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate,
                                                   channels: hardware.mChannelsPerFrame) else {
                throw RecorderFailure.noInput
            }
            var client = deviceFormat.streamDescription.pointee
            try check("set client format", AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size))
            var maxFrames = Capture.maxFrames
            try check("set frame limit", AudioUnitSetProperty(
                unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4))
            let capture = try Capture(unit: unit, format: deviceFormat, onLevel: onLevel)
            var callback = AURenderCallbackStruct(inputProc: renderInput,
                                                  inputProcRefCon: Unmanaged.passUnretained(capture).toOpaque())
            try check("set callback", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check("initialize", AudioUnitInitialize(unit))
            try check("start", AudioOutputUnitStart(unit))
            log.info("recording at \(hardware.mSampleRate) Hz, \(hardware.mChannelsPerFrame) ch")
            self.capture = capture
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    /// Stops the microphone and returns everything captured since `start()`.
    func stop() -> [Float] {
        guard let capture else { return [] }
        AudioOutputUnitStop(capture.unit)
        let samples = capture.drain()
        teardown()
        return samples
    }

    private func teardown() {
        guard let capture else { return }
        AudioOutputUnitStop(capture.unit)
        AudioUnitUninitialize(capture.unit)
        AudioComponentInstanceDispose(capture.unit)
        self.capture = nil
    }
}

private enum RecorderFailure: LocalizedError {
    case noInput
    case audioUnit(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInput: "no input device (is microphone access granted?)"
        case let .audioUnit(step, status): "\(step) failed (\(status))"
        }
    }
}

private func check(_ step: String, _ status: OSStatus) throws {
    guard status == noErr else { throw RecorderFailure.audioUnit(step, status) }
}

private let renderInput: AURenderCallback = { refcon, flags, timestamp, bus, frames, _ in
    Unmanaged<Capture>.fromOpaque(refcon).takeUnretainedValue().render(flags, timestamp, bus, frames)
}

/// The real-time side of a recording: everything the unit's callback touches. Lives outside the actor
/// so the audio thread never waits on it.
private final class Capture: @unchecked Sendable {
    static let maxFrames: UInt32 = 4096

    let unit: AudioUnit
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private let onLevel: @Sendable (Float) -> Void
    private let lock = NSLock()
    private var samples: [Float] = []

    init(unit: AudioUnit, format: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void) throws {
        let target = AVAudioFormat(standardFormatWithSampleRate: Double(Recorder.sampleRate), channels: 1)!
        let outCapacity = AVAudioFrameCount(Double(Self.maxFrames) * target.sampleRate / format.sampleRate) + 1
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maxFrames),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw RecorderFailure.noInput
        }
        self.unit = unit
        self.input = input
        self.output = output
        self.converter = converter
        self.onLevel = onLevel
    }

    func drain() -> [Float] {
        lock.withLock { samples }
    }

    func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timestamp: UnsafePointer<AudioTimeStamp>,
                _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard frames <= input.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        input.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, input.mutableAudioBufferList)
        guard status == noErr else { return status }
        var fed = false
        converter.convert(to: output, error: nil) { [input] _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard let channel = output.floatChannelData?[0] else { return noErr }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
        onLevel(Self.loudness(chunk))
        return noErr
    }

    /// RMS mapped from -50...-10 dBFS onto 0...1, which covers quiet to loud speech on a laptop mic.
    private static func loudness(_ chunk: UnsafeBufferPointer<Float>) -> Float {
        guard !chunk.isEmpty else { return 0 }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(max((decibels + 50) / 40, 0), 1)
    }
}
