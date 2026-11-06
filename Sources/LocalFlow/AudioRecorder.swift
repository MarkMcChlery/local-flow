import AVFoundation
import CoreAudio

/// Captures microphone audio while active and returns it as
/// 16 kHz mono Float32 samples, the format Whisper expects.
///
/// A fresh AVAudioEngine is created for every recording so it always uses
/// the current default input device. Bluetooth headsets (e.g. AirPods)
/// switch sample rate when their mic opens, which makes macOS reconfigure
/// the engine mid-recording; we catch that and re-attach to the new format
/// instead of silently recording nothing.
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var restarts = 0
    private var startedAt = Date()
    private(set) var isRecording = false

    /// Stats for the most recent recording, for diagnostics and error messages.
    private(set) var lastStats: RecordingStats?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(); lock.unlock()
        restarts = 0
        startedAt = Date()

        let engine = AVAudioEngine()
        self.engine = engine
        do {
            try attachTap(to: engine)
            engine.prepare()
            try engine.start()
        } catch {
            teardown()
            throw error
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        teardown()
        lock.lock()
        let captured = samples
        samples.removeAll()
        lock.unlock()

        lastStats = RecordingStats(
            device: AudioRecorder.defaultInputDeviceName() ?? "unknown device",
            inputFormat: inputFormat.map { "\(Int($0.sampleRate)) Hz, \($0.channelCount) ch" } ?? "unknown",
            wallSeconds: Date().timeIntervalSince(startedAt),
            audioSeconds: Double(captured.count) / targetFormat.sampleRate,
            peak: AudioLevel.peak(captured),
            rms: AudioLevel.rms(captured),
            restarts: restarts
        )
        return captured
    }

    // MARK: - Engine plumbing

    private func attachTap(to engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw LFError.noMicrophone
        }
        lock.lock()
        inputFormat = format
        converter = AVAudioConverter(from: format, to: targetFormat)
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
    }

    /// The input device or its format changed (typically a Bluetooth headset
    /// switching to its mic profile). The engine has stopped itself; re-attach
    /// with the new format and carry on, keeping the samples captured so far.
    private func handleConfigurationChange() {
        guard isRecording, let engine else { return }
        restarts += 1
        engine.inputNode.removeTap(onBus: 0)
        do {
            try attachTap(to: engine)
            engine.prepare()
            try engine.start()
        } catch {
            // Leave it stopped; stop() still returns whatever was captured,
            // and the silence check will tell the user nothing was heard.
        }
    }

    private func teardown() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let converter = self.converter
        lock.unlock()
        // Ignore buffers from a format we have already replaced.
        guard let converter, buffer.format == converter.inputFormat else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var bufferConsumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if bufferConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            bufferConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channelData = output.floatChannelData else { return }

        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    // MARK: - Device name

    static func defaultInputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

struct RecordingStats {
    let device: String
    let inputFormat: String
    let wallSeconds: Double
    let audioSeconds: Double
    let peak: Float
    let rms: Float
    let restarts: Int

    var logLine: String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return String(
            format: "%@  device=\"%@\" format=%@ held=%.1fs audio=%.1fs peak=%.4f rms=%.5f restarts=%d",
            stamp, device, inputFormat, wallSeconds, audioSeconds, peak, rms, restarts
        )
    }

    /// Appends one line per recording to
    /// ~/Library/Application Support/LocalFlow/recordings.log (levels only,
    /// never audio or text), so input problems can be diagnosed.
    func appendToLog() {
        let url = Storage.directory.appendingPathComponent("recordings.log")
        let data = Data((logLine + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// Pure level maths, kept separate so it can be unit tested.
enum AudioLevel {
    /// Below this peak the input is effectively dead (muted mic, wrong
    /// device, or a dropped Bluetooth stream). Real room noise alone peaks
    /// well above it, so quiet speech is never discarded.
    static let silencePeak: Float = 0.005

    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float((sumSquares / Double(samples.count)).squareRoot())
    }

    static func isSilent(_ samples: [Float]) -> Bool {
        peak(samples) < silencePeak
    }
}
