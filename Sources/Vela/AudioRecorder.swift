import AVFoundation
import os

/// Captures microphone audio and accumulates 16 kHz mono Float32 samples for Whisper (F1).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.vela.app", category: "audio")

    /// Called on the audio thread with a normalized 0–1 mic level per buffer (~10/s).
    var onLevel: (@Sendable (Float) -> Void)?

    static let targetSampleRate: Double = 16_000

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    static func requestMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start() throws {
        lock.lock()
        samples.removeAll()
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw VelaError.audio("No input device available")
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        log.info("Recording started (\(inputFormat.sampleRate, privacy: .public) Hz input)")
    }

    /// Stops the engine and returns everything captured, as 16 kHz mono Float32.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        lock.lock()
        defer { lock.unlock() }
        log.info("Recording stopped: \(self.samples.count) samples (\(Double(self.samples.count) / AudioRecorder.targetSampleRate, format: .fixed(precision: 1))s)")
        return samples
    }

    /// Silence guard (F7a): true if the samples contain speech-like energy. Whisper
    /// hallucinates text on silent/noise-only audio, so the pipeline discards anything
    /// that fails this check instead of injecting phantom text.
    ///
    /// Energy VAD: frames count as voiced when their RMS clears a threshold set above
    /// the recording's own noise floor, and we require ≥0.25 s of voiced audio total.
    static func containsSpeech(_ samples: [Float]) -> Bool {
        let frameSize = Int(targetSampleRate * 0.03) // 30 ms frames
        guard samples.count >= frameSize else { return false }

        var frameRMS: [Float] = []
        frameRMS.reserveCapacity(samples.count / frameSize)
        var index = 0
        while index + frameSize <= samples.count {
            var sum: Float = 0
            for sample in samples[index..<(index + frameSize)] { sum += sample * sample }
            frameRMS.append(sqrt(sum / Float(frameSize)))
            index += frameSize
        }

        // Noise floor = 20th percentile; threshold scales with it so a fan or hum
        // doesn't count as speech, with an absolute floor for very quiet rooms.
        let sorted = frameRMS.sorted()
        let noiseFloor = sorted[sorted.count / 5]
        let threshold = max(0.012, noiseFloor * 3)
        let voicedSeconds = Double(frameRMS.filter { $0 > threshold }.count) * 0.03
        return voicedSeconds >= 0.25
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = AudioRecorder.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error {
            log.error("Audio conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        if let onLevel {
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            onLevel(min(1, rms * 12)) // speech RMS is small; scale into a visible 0–1 range
        }
    }
}

enum VelaError: LocalizedError {
    case audio(String)
    case transcription(String)
    case cleanup(String)

    var errorDescription: String? {
        switch self {
        case .audio(let message): return "Audio: \(message)"
        case .transcription(let message): return "Transcription: \(message)"
        case .cleanup(let message): return "Cleanup: \(message)"
        }
    }
}
