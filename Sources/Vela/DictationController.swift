import AppKit
import KeyboardShortcuts
import os

/// Orchestrates the pipeline: hotkey → record → transcribe → (clean) → inject.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum State {
        case idle
        case recording
        case transcribing
        case cleaning

        var symbolName: String {
            switch self {
            case .idle: return "waveform"
            case .recording: return "waveform.badge.mic"
            case .transcribing: return "waveform.badge.magnifyingglass"
            case .cleaning: return "wand.and.stars"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastLatency: TimeInterval?
    @Published private(set) var lastTranscript: String?

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let log = Logger(subsystem: "com.vela.app", category: "pipeline")

    var statusLine: String {
        if let lastError { return "⚠️ \(lastError)" }
        switch state {
        case .idle: return "Vela — hold hotkey to dictate"
        case .recording: return "Recording… (release to insert)"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        }
    }

    var lastLatencyDescription: String? {
        guard let lastLatency else { return nil }
        return String(format: "Last dictation: %.2fs after release", lastLatency)
    }

    func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            self?.startRecording()
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            self?.stopAndProcess()
        }
        log.info("Push-to-talk hotkey registered")
    }

    func startRecording() {
        guard state == .idle else { return }
        lastError = nil
        Task {
            guard await AudioRecorder.requestMicPermission() else {
                self.lastError = "Microphone permission denied (System Settings → Privacy)"
                return
            }
            // User may have released the key while the permission dialog was up.
            guard self.state == .idle else { return }
            do {
                try self.recorder.start()
                self.state = .recording
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    func stopAndProcess() {
        guard state == .recording else { return }
        let released = Date()
        let samples = recorder.stop()
        state = .transcribing

        // Ignore accidental taps shorter than ~0.3 s of audio.
        guard Double(samples.count) / AudioRecorder.targetSampleRate > 0.3 else {
            state = .idle
            return
        }

        Task {
            do {
                let glossary = AppSettings.glossaryTerms
                let sttStart = Date()
                let raw = try await self.transcriber.transcribe(samples: samples, glossaryTerms: glossary)
                self.log.info("STT took \(Date().timeIntervalSince(sttStart), format: .fixed(precision: 2))s: \(raw, privacy: .public)")

                guard !raw.isEmpty else {
                    self.state = .idle
                    return
                }

                var final = raw
                if AppSettings.cleanupEnabled {
                    self.state = .cleaning
                    do {
                        final = try await OllamaCleanup.clean(raw, glossaryTerms: glossary)
                    } catch {
                        // Cleanup is best-effort: fall back to the raw transcript.
                        self.log.error("Cleanup failed, using raw transcript: \(error.localizedDescription, privacy: .public)")
                    }
                }

                TextInjector.inject(final)
                self.lastTranscript = final
                self.lastLatency = Date().timeIntervalSince(released)
                self.log.info("End-to-end (release → inject): \(self.lastLatency ?? 0, format: .fixed(precision: 2))s")
                self.state = .idle
            } catch {
                self.lastError = error.localizedDescription
                self.log.error("Pipeline failed: \(error.localizedDescription, privacy: .public)")
                self.state = .idle
            }
        }
    }

    func unloadModels() async {
        await transcriber.unload()
    }
}
