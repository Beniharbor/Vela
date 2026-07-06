import Foundation
import WhisperKit
import os

/// WhisperKit wrapper with on-demand load and idle auto-unload (G3: light on RAM).
actor Transcriber {
    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    private var unloadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.vela.app", category: "stt")

    /// Transcribes 16 kHz mono samples. Loads the model on first use (downloads it on
    /// the very first run — can take a while; subsequent loads come from disk).
    func transcribe(samples: [Float], glossaryTerms: [String]) async throws -> String {
        unloadTask?.cancel()
        let pipe = try await loadIfNeeded()

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

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        scheduleUnload()
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.stripTags(text)
    }

    private func loadIfNeeded() async throws -> WhisperKit {
        let wanted = AppSettings.whisperModel
        if let whisperKit, loadedModelName == wanted {
            return whisperKit
        }
        whisperKit = nil // release any old model before loading a new one
        log.info("Loading Whisper model \(wanted, privacy: .public)")
        let start = Date()
        let config = WhisperKitConfig(model: wanted)
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
