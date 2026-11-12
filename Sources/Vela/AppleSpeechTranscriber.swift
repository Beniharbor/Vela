import Foundation
import Speech
@preconcurrency import AVFoundation
import os

/// Apple's on-device streaming speech engine (macOS 26+): SpeechAnalyzer decodes
/// audio as it arrives, so most of the transcript is already done by the time
/// recording stops — finish() returns near-instantly, unlike WhisperKit's
/// record-then-decode pipeline in Transcriber.
@available(macOS 26, *)
actor AppleSpeechTranscriber {
    static let shared = AppleSpeechTranscriber()

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var finalized = ""
    private var resolvedLanguageCode = "en"
    private let log = Logger(subsystem: "com.vela.app", category: "stt-apple")

    /// Starts a streaming session. Safe to call as soon as recording begins —
    /// audio fed via feed(_:) is decoded live.
    func start(languageOverride: String?, glossaryTerms: [String], onProgress: @escaping Transcriber.ProgressHandler) async throws {
        finalized = ""
        let locale = await Self.resolveLocale(languageOverride: languageOverride)
        resolvedLanguageCode = locale.language.languageCode?.identifier ?? "en"

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // F4: bias recognition toward the user's glossary, same intent as
        // Whisper's prompt tokens in Transcriber.transcribe.
        if !glossaryTerms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = glossaryTerms
            try? await analyzer.setContext(context)
        }

        try await Self.ensureModel(for: transcriber, locale: locale, onProgress: onProgress)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VelaError.transcription("Apple Speech: no compatible audio format")
        }
        analyzerFormat = format
        converter = nil

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation

        recognizerTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    guard result.isFinal else { continue }
                    await self.appendFinal(String(result.text.characters))
                }
            } catch {
                self.log.warning("Apple Speech results stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        try await analyzer.start(inputSequence: stream)
        log.info("Apple Speech session started (\(locale.identifier, privacy: .public))")
    }

    private func appendFinal(_ text: String) {
        finalized += text
    }

    /// Converts and enqueues a native-format buffer. Called live as audio
    /// arrives — conversion failures just drop that buffer, the next one retries.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, let inputBuilder else { return }
        do {
            let converted = try convert(buffer, to: analyzerFormat)
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        } catch {
            log.warning("Apple Speech buffer conversion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ends the session and returns whatever was transcribed so far.
    func finish() async throws -> Transcriber.Output {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        recognizerTask?.cancel()
        let text = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = resolvedLanguageCode
        teardown()
        return Transcriber.Output(text: text, language: language)
    }

    /// Ends the session and discards whatever was transcribed (Esc-cancel).
    func cancel() {
        inputBuilder?.finish()
        recognizerTask?.cancel()
        Task { [analyzer] in try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
        teardown()
    }

    private func teardown() {
        recognizerTask = nil
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        analyzerFormat = nil
        converter = nil
        finalized = ""
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }
        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { throw VelaError.transcription("Apple Speech: couldn't build audio converter") }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw VelaError.transcription("Apple Speech: couldn't allocate output buffer")
        }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return output
    }

    /// "auto" (Vela's per-dictation language detection) has no SpeechAnalyzer
    /// equivalent — it needs a fixed locale up front — so it falls back to the
    /// system language. Otherwise best-matches the setting's ISO code against
    /// what's actually supported.
    private static func resolveLocale(languageOverride: String?) async -> Locale {
        let code = languageOverride ?? AppSettings.dictationLanguage
        guard code != "auto" else { return Locale.current }

        let supported = await SpeechTranscriber.supportedLocales
        if let exact = supported.first(where: { $0.language.languageCode?.identifier == code }) {
            return exact
        }
        return Locale.current
    }

    private static func ensureModel(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        onProgress: @escaping Transcriber.ProgressHandler
    ) async throws {
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if !installed.contains(locale.identifier(.bcp47)) {
            onProgress("Downloading Apple speech model", nil)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
    }
}
