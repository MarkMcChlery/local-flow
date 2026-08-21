import AVFoundation

/// Captures microphone audio while active and returns it as
/// 16 kHz mono Float32 samples, the format Whisper expects.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private(set) var isRecording = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LFError.noMicrophone
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        let captured = samples
        samples.removeAll()
        lock.unlock()
        return captured
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
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
}
