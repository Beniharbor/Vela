import Foundation
import WhisperKit
import os

/// WhisperKit wrapper with on-demand load and idle auto-unload (G3: light on RAM).
/// Shared between dictation and voice-note import so the model is only ever
/// resident once. Concurrent callers share one in-flight load (actor methods
/// are reentrant across `await`, so without that a preload and a transcribe
/// could each load a copy). Transcriptions themselves are not serialized: a
/// dictation during a voice-note import runs alongside it on the same model.
actor Transcriber {
    static let shared = Transcriber()

    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    /// The load in flight, if any — joined by every caller wanting the same model.
    private var loadTask: Task<WhisperKit, Error>?
    private var loadingModelName: String?
    private var unloadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.vela.app", category: "stt")

    /// Progress callback: (phase label, fraction 0–1 or nil for indeterminate).
    typealias ProgressHandler = @Sendable (String, Double?) -> Void

    struct Output {
        let text: String
        /// ISO code of the (detected or forced) language, e.g. "en".
        let language: String
        /// Raw WhisperKit results — carry word timings when requested, used to
        /// line words up with speakers in Voice Notes.
        var results: [TranscriptionResult] = []
        /// Parakeet's word timings — the same job as `results` for that engine.
        var timedWords: [TimedWord] = []
    }

    /// Warms the model while the user is still speaking so transcription starts the
    /// instant recording stops. RAM is only held during the dictation — the idle
    /// unload is re-armed by transcribe(), or by scheduleUnload() on cancel (G3).
    func preload() async {
        if AppSettings.usesParakeet {
            await ParakeetTranscriber.shared.preload()
            return
        }
        unloadTask?.cancel()
        do {
            _ = try await loadIfNeeded { _, _ in }
        } catch {
            log.warning("Preload failed (will retry at transcribe time): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Transcribes 16 kHz mono samples. Loads the model on first use (downloads it on
    /// the very first run — can take a while; subsequent loads come from disk).
    /// `languageOverride` bypasses the Languages setting (voice-note import
    /// forces "en"); nil uses the setting as before.
    func transcribe(
        samples: [Float],
        glossaryTerms: [String],
        languageOverride: String? = nil,
        wordTimestamps: Bool = false,
        vadChunking: Bool = false,
        onProgress: @escaping ProgressHandler
    ) async throws -> Output {
        // Word-timed requests (Whisper-format timings) stay on Whisper; Voice
        // Notes calls ParakeetTranscriber directly when it wants Parakeet.
        if AppSettings.usesParakeet, !wordTimestamps {
            return try await ParakeetTranscriber.shared.transcribe(
                samples: samples,
                language: languageOverride ?? AppSettings.dictationLanguage,
                // Dictation and the link API get the same vocabulary boosting
                // as Voice Notes. Unlike Whisper's prompt, it can't blank out
                // long audio, so the API's empty glossaryTerms doesn't apply.
                vocabulary: AppSettings.glossaryEntries,
                onProgress: onProgress
            )
        }
        unloadTask?.cancel()
        // Re-arm the idle unload however this ends — success or throw (G3).
        defer { scheduleUnload() }
        let pipe = try await loadIfNeeded(onProgress: onProgress)

        var options = DecodingOptions()
        // "auto" leaves the language token unset so Whisper detects it from the
        // audio itself (English, Spanish, …). base.en is English-only regardless.
        let language = languageOverride ?? AppSettings.dictationLanguage
        if language == "auto" {
            options.language = nil
            options.detectLanguage = true
        } else {
            options.language = language
        }
        options.task = .transcribe
        options.wordTimestamps = wordTimestamps
        // Opt-in: cut at silences and decode the pieces concurrently, each
        // without the previous one's context. Not the default — see the note
        // on `vad` in LocalAPIServer.
        if vadChunking {
            options.chunkingStrategy = .vad
        }
        // F4: bias recognition toward the user's glossary via the prompt.
        if !glossaryTerms.isEmpty, let tokenizer = pipe.tokenizer {
            let prompt = "Glossary: " + glossaryTerms.joined(separator: ", ") + "."
            let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < specialTokenBegin }
            options.usePrefillPrompt = true
        }

        // WhisperKit tracks overall decode progress across audio windows — poll it
        // so the menu bar can show a live percentage.
        let poller = Task {
            while !Task.isCancelled {
                onProgress("Transcribing", pipe.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }

        var results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        var text = Self.joinedText(results)

        // Glossary biasing is best-effort: some models (large-v3 among them)
        // decode to nothing when a prompt is prefilled — sometimes the whole
        // take, sometimes only some 30 s windows (an 8-min note came back as
        // 14 s of text with every other window blank). Retry bare rather than
        // swallow speech.
        if options.promptTokens != nil, text.isEmpty || Self.hasBlankWindow(results) {
            log.warning("Blank window(s) with glossary prompt — retrying without it")
            options.promptTokens = nil
            options.usePrefillPrompt = false
            results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            text = Self.joinedText(results)
        }

        let detected = results.first?.language ?? (language == "auto" ? "en" : language)
        return Output(text: Self.stripTags(text), language: detected, results: results)
    }

    /// Detects the spoken language from the first 30 s of `samples`. Lets a
    /// long file be pinned to one language up front rather than re-detected
    /// (possibly differently) for every piece. Falls back to "en" for
    /// English-only models.
    /// nil with Parakeet, which is multilingual without a language token —
    /// the caller reads the language off the first transcript instead.
    func detectLanguage(samples: [Float]) async -> String? {
        if AppSettings.usesParakeet { return nil }
        unloadTask?.cancel()
        defer { scheduleUnload() }
        guard let pipe = try? await loadIfNeeded(onProgress: { _, _ in }) else { return "en" }
        let head = Array(samples.prefix(Int(AudioRecorder.targetSampleRate) * 30))
        return (try? await pipe.detectLangauge(audioArray: head).language) ?? "en"
    }

    private func loadIfNeeded(onProgress: @escaping ProgressHandler) async throws -> WhisperKit {
        let wanted = AppSettings.whisperKitModel
        if let whisperKit, loadedModelName == wanted {
            return whisperKit
        }
        if let loadTask, loadingModelName == wanted {
            return try await loadTask.value
        }
        whisperKit = nil // release any old model before loading a new one
        loadedModelName = nil

        let task = Task { try await Self.load(wanted, onProgress: onProgress) }
        loadTask = task
        loadingModelName = wanted
        defer {
            if loadingModelName == wanted {
                loadTask = nil
                loadingModelName = nil
            }
        }
        let pipe = try await task.value
        whisperKit = pipe
        loadedModelName = wanted
        return pipe
    }

    private static func load(_ wanted: String, onProgress: @escaping ProgressHandler) async throws -> WhisperKit {
        let log = Logger(subsystem: "com.vela.app", category: "stt")
        // Use the on-disk copy when present — no network involved (G1: works offline).
        // Only hit Hugging Face when the model has never been downloaded.
        let folder: URL
        if let local = Self.locateLocalModel(wanted) {
            folder = local
        } else {
            onProgress("Downloading model", 0)
            folder = try await WhisperKit.download(variant: wanted) { progress in
                onProgress("Downloading model", progress.fractionCompleted)
            }
        }

        onProgress("Loading model", nil)
        log.info("Loading Whisper model \(wanted, privacy: .public)")
        let start = Date()
        let config = WhisperKitConfig(model: wanted, modelFolder: folder.path)
        let pipe = try await WhisperKit(config)
        log.info("Model loaded in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        return pipe
    }

    /// Finds a previously downloaded model folder on disk. Folder names carry a
    /// repo prefix (e.g. "openai_whisper-large-v3-…", "distil-whisper_distil-large-v3"),
    /// so match by suffix and require a complete download (decoder present).
    private static func locateLocalModel(_ variant: String) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let base = documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries.first {
            $0.lastPathComponent.hasSuffix(variant)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("TextDecoder.mlmodelc").path)
        }
    }

    /// G3: drop the model from RAM after the configured idle period.
    func scheduleUnload() {
        unloadTask?.cancel()
        let idle = max(AppSettings.modelIdleUnloadSeconds, 10)
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(idle))
            guard !Task.isCancelled else { return }
            await self?.unloadWhisper()
        }
    }

    /// "Unload models now": drops whichever engines are resident.
    func unload() async {
        await ParakeetTranscriber.shared.unload()
        unloadWhisper()
    }

    private func unloadWhisper() {
        unloadTask?.cancel()
        unloadTask = nil
        whisperKit = nil
        loadedModelName = nil
        log.info("Whisper model unloaded (idle)")
    }

    /// True when a decoded window (≥ 10 s of audio) produced no words — the
    /// signature of the prompt-induced blank decode, which spans the whole window.
    private static func hasBlankWindow(_ results: [TranscriptionResult]) -> Bool {
        results.flatMap(\.segments).contains { segment in
            segment.end - segment.start >= 10 && stripTags(segment.text).isEmpty
        }
    }

    private static func joinedText(_ results: [TranscriptionResult]) -> String {
        results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper emits special markers like <|startoftranscript|> in some edge cases.
    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
