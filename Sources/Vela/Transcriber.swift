import Foundation
import WhisperKit
import os

/// WhisperKit wrapper with on-demand load and idle auto-unload (G3: light on RAM).
actor Transcriber {
    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    private var unloadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.vela.app", category: "stt")

    /// Progress callback: (phase label, fraction 0–1 or nil for indeterminate).
    typealias ProgressHandler = @Sendable (String, Double?) -> Void

    /// Transcribes 16 kHz mono samples. Loads the model on first use (downloads it on
    /// the very first run — can take a while; subsequent loads come from disk).
    func transcribe(samples: [Float], glossaryTerms: [String], onProgress: @escaping ProgressHandler) async throws -> String {
        unloadTask?.cancel()
        let pipe = try await loadIfNeeded(onProgress: onProgress)

        var options = DecodingOptions()
        options.language = "en"
        options.task = .transcribe
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

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        scheduleUnload()
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.stripTags(text)
    }

    private func loadIfNeeded(onProgress: @escaping ProgressHandler) async throws -> WhisperKit {
        let wanted = AppSettings.whisperModel
        if let whisperKit, loadedModelName == wanted {
            return whisperKit
        }
        whisperKit = nil // release any old model before loading a new one

        // Explicit download step so we can surface progress. Already-downloaded files
        // are skipped (size check), so this returns near-instantly on later runs.
        onProgress("Downloading model", 0)
        let folder = try await WhisperKit.download(variant: wanted) { progress in
            onProgress("Downloading model", progress.fractionCompleted)
        }

        onProgress("Loading model", nil)
        log.info("Loading Whisper model \(wanted, privacy: .public)")
        let start = Date()
        let config = WhisperKitConfig(model: wanted, modelFolder: folder.path)
        let pipe = try await WhisperKit(config)
        log.info("Model loaded in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        whisperKit = pipe
        loadedModelName = wanted
        return pipe
    }

    /// G3: drop the model from RAM after the configured idle period.
    private func scheduleUnload() {
        unloadTask?.cancel()
        let idle = max(AppSettings.modelIdleUnloadSeconds, 10)
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(idle))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    func unload() {
        unloadTask?.cancel()
        unloadTask = nil
        whisperKit = nil
        loadedModelName = nil
        log.info("Whisper model unloaded (idle)")
    }

    /// Whisper emits special markers like <|startoftranscript|> in some edge cases.
    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
