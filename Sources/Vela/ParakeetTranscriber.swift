import Foundation
import FluidAudio
import NaturalLanguage
import os

/// Parakeet TDT v3 (CoreML, via FluidAudio) — the fast alternative to Whisper.
/// Roughly an order of magnitude quicker on long audio and not prone to
/// Whisper's looping / blank-window failures, at the cost of fewer languages
/// (25 European ones, English and Spanish included) and no prompt biasing.
///
/// Selected through the same "speech model" setting as the Whisper variants;
/// `Transcriber` routes here, so dictation, the local API and voice notes all
/// pick it up. Same RAM discipline as Whisper: loaded on demand, dropped
/// after the idle period (G3).
actor ParakeetTranscriber {
    static let shared = ParakeetTranscriber()
    /// Value of the speech-model setting that selects this engine.
    static let modelID = "parakeet-v3"

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private var unloadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.vela.app", category: "stt-parakeet")

    func preload() async {
        unloadTask?.cancel()
        do {
            _ = try await loadIfNeeded { _, _ in }
        } catch {
            log.warning("Preload failed (will retry at transcribe time): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Transcribes 16 kHz mono samples. `language` is "auto", or a code such
    /// as "en" / "es" used as a hint (keeps look-alike tokens of another
    /// script out; the model itself is multilingual).
    func transcribe(
        samples: [Float],
        language: String,
        onProgress: @escaping Transcriber.ProgressHandler
    ) async throws -> Transcriber.Output {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        let manager = try await loadIfNeeded(onProgress: onProgress)

        // Long audio is chunked internally; the stream reports how far along it is.
        let progress = Task {
            guard let stream = try? await manager.transcriptionProgressStream else { return }
            do {
                for try await fraction in stream {
                    onProgress("Transcribing", fraction)
                }
            } catch {}
        }
        defer { progress.cancel() }
        onProgress("Transcribing", nil)

        // The model needs at least a second of audio.
        var audio = samples
        let minimum = Int(AudioRecorder.targetSampleRate)
        if audio.count < minimum {
            audio.append(contentsOf: repeatElement(0, count: minimum - audio.count))
        }

        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let hint = Language(rawValue: language)
        let result = try await manager.transcribe(audio, decoderState: &state, language: hint)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var output = Transcriber.Output(text: text, language: hint?.rawValue ?? Self.detectLanguage(of: text))
        output.timedWords = buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: $0.word, start: Float($0.startTime), end: Float($0.endTime))
        }
        return output
    }

    /// Parakeet doesn't say which language it heard — read it off the text.
    private static func detectLanguage(of text: String) -> String {
        guard !text.isEmpty else { return "en" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    private func loadIfNeeded(onProgress: @escaping Transcriber.ProgressHandler) async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let log = self.log
        let task = Task { () -> AsrManager in
            let start = Date()
            onProgress("Loading model", nil)
            // First run downloads ~0.5 GB from Hugging Face; later loads are local.
            let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                if progress.fractionCompleted < 1 {
                    onProgress("Downloading model", progress.fractionCompleted)
                }
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            log.info("Parakeet loaded in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
            return manager
        }
        loadTask = task
        defer { loadTask = nil }
        let loaded = try await task.value
        manager = loaded
        return loaded
    }

    func scheduleUnload() {
        unloadTask?.cancel()
        let idle = max(AppSettings.modelIdleUnloadSeconds, 10)
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(idle))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    func unload() async {
        unloadTask?.cancel()
        unloadTask = nil
        guard let manager else { return }
        self.manager = nil
        await manager.cleanup()
        log.info("Parakeet model unloaded (idle)")
    }
}
