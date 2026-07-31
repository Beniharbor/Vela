import AVFoundation
import os

/// Captures microphone audio and accumulates 16 kHz mono Float32 samples for Whisper (F1).
final class AudioRecorder {
    /// Built per take, released on stop(). Deliberately not a long-lived `let`:
    /// an AVAudioEngine whose inputNode has been touched keeps the input device
    /// claimed for as long as the object exists, and CoreAudio then holds the
    /// route in its capture-capable mode — which on Bluetooth means the headset
    /// stays in the low-quality duplex profile and music sounds ducked/degraded
    /// while Vela merely sits in the menu bar. Idle Vela must own no engine.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.vela.app", category: "audio")

    /// Called on the audio thread with a normalized 0–1 mic level per buffer (~10/s).
    var onLevel: (@Sendable (Float) -> Void)?
    /// Called on the audio thread with each raw (native-format) buffer, e.g. for
    /// the "watermelon" watchword listener — separate from the Whisper-bound,
    /// downsampled `samples` this class accumulates.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

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
        // A previous take's engine would still be holding the device.
        releaseEngine()
        lock.lock()
        samples.removeAll()
        lock.unlock()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw VelaError.audio("No input device available")
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Don't leave a half-open engine (and a claimed input device) behind.
            input.removeTap(onBus: 0)
            converter = nil
            throw error
        }
        self.engine = engine
        log.info("Recording started (\(inputFormat.sampleRate, privacy: .public) Hz input)")
    }

    /// Pauses capture without tearing down the engine — no samples accumulate
    /// until resume(). The tap stays installed.
    func pause() {
        guard let engine, engine.isRunning else { return }
        engine.pause()
        lock.lock()
        let captured = samples.count
        lock.unlock()
        log.info("Recording paused (\(Double(captured) / AudioRecorder.targetSampleRate, format: .fixed(precision: 1))s captured)")
    }

    func resume() throws {
        guard let engine else { throw VelaError.audio("Nothing to resume") }
        try engine.start()
        log.info("Recording resumed")
    }

    /// Stops the engine and returns everything captured, as 16 kHz mono Float32.
    func stop() -> [Float] {
        releaseEngine()
        lock.lock()
        defer { lock.unlock() }
        log.info("Recording stopped: \(self.samples.count) samples (\(Double(self.samples.count) / AudioRecorder.targetSampleRate, format: .fixed(precision: 1))s)")
        return samples
    }

    /// Hands the microphone back to the system. Dropping the engine is the part
    /// that matters — stopping it alone leaves the input unit instantiated and the
    /// device claimed, which is what keeps other apps' audio degraded afterwards.
    private func releaseEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
        converter = nil
    }

    /// Result of the silence-guard analysis (F7a), with the numbers behind the
    /// decision so a tripped guard is diagnosable from the logs.
    struct SpeechCheck {
        let voicedSeconds: Double
        let noiseFloor: Float
        let threshold: Float
        let peakRMS: Float
        /// Voiced-time test, plus an escape hatch: strong dynamic range (a clear
        /// peak well above the floor) is speech-like even if quiet overall —
        /// eating a real dictation is worse than a rare hallucination.
        var containsSpeech: Bool {
            voicedSeconds >= 0.2 || (peakRMS > max(0.01, noiseFloor * 6))
        }
    }

    /// Silence guard (F7a): Whisper hallucinates text on silent/noise-only audio, so
    /// the pipeline discards recordings with no speech-like energy instead of
    /// injecting phantom text.
    ///
    /// Energy VAD: 30 ms frames count as voiced when their RMS clears a threshold set
    /// above the recording's own noise floor (20th percentile), so a fan or hum
    /// doesn't count as speech, with an absolute floor for very quiet rooms.
    static func analyzeSpeech(_ samples: [Float]) -> SpeechCheck {
        let frameSize = Int(targetSampleRate * 0.03) // 30 ms frames
        guard samples.count >= frameSize else {
            return SpeechCheck(voicedSeconds: 0, noiseFloor: 0, threshold: 0, peakRMS: 0)
        }

        var frameRMS: [Float] = []
        frameRMS.reserveCapacity(samples.count / frameSize)
        var index = 0
        while index + frameSize <= samples.count {
            var sum: Float = 0
            for sample in samples[index..<(index + frameSize)] { sum += sample * sample }
            frameRMS.append(sqrt(sum / Float(frameSize)))
            index += frameSize
        }

        let sorted = frameRMS.sorted()
        let noiseFloor = sorted[sorted.count / 5]
        let threshold = max(0.006, noiseFloor * 2.5)
        return SpeechCheck(
            voicedSeconds: Double(frameRMS.filter { $0 > threshold }.count) * 0.03,
            noiseFloor: noiseFloor,
            threshold: threshold,
            peakRMS: sorted.last ?? 0
        )
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
