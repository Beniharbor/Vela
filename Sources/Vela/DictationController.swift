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

    @Published private(set) var state: State = .idle {
        didSet {
            if state == .recording {
                micLevels = Array(repeating: 0, count: Self.levelBarCount)
                hud.show()
            } else if oldValue == .recording {
                hud.hide()
            }
        }
    }
    @Published private(set) var lastError: String?
    /// Rolling mic-level history for the recording HUD (newest at the end).
    @Published private(set) var micLevels: [Float] = Array(repeating: 0, count: DictationController.levelBarCount)
    private static let levelBarCount = 24
    private let hud = RecordingHUD()
    @Published private(set) var lastLatency: TimeInterval?
    @Published private(set) var lastTranscript: String?
    /// e.g. "Downloading model" + 0.42 while working; nil when idle.
    @Published private(set) var progressPhase: String?
    @Published private(set) var progressFraction: Double?

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let fnMonitor = FnKeyMonitor()
    private let log = Logger(subsystem: "com.vela.app", category: "pipeline")

    private var triggerName: String {
        AppSettings.triggerMode == .fnKey ? "Fn" : "the shortcut"
    }

    var statusLine: String {
        if let lastError { return "⚠️ \(lastError)" }
        switch state {
        case .idle: return "Vela — press \(triggerName) to dictate"
        case .recording: return "Recording… (press \(triggerName) again to insert)"
        case .transcribing:
            if let progressPhase {
                if let progressFraction {
                    return "\(progressPhase)… \(Int(progressFraction * 100))%"
                }
                return "\(progressPhase)…"
            }
            return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        }
    }

    /// Short percent string for the menu bar label while working (nil hides it).
    var menuBarPercent: String? {
        guard state == .transcribing, let progressFraction, progressFraction > 0 else { return nil }
        return "\(Int(progressFraction * 100))%"
    }

    var lastLatencyDescription: String? {
        guard let lastLatency else { return nil }
        return String(format: "Last dictation: %.2fs after release", lastLatency)
    }

    func registerHotkey() {
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.pushLevel(level) }
        }

        // Both triggers are press-to-toggle; the active one is checked at press time
        // so switching modes in Settings takes effect immediately.
        fnMonitor.onToggle = { [weak self] in
            guard AppSettings.triggerMode == .fnKey else { return }
            self?.toggleDictation()
        }
        fnMonitor.start()

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            guard AppSettings.triggerMode == .customShortcut else { return }
            self?.toggleDictation()
        }

        // The Fn monitor only receives events once Accessibility is granted —
        // surface the prompt at launch so the hotkey works out of the box.
        if AppSettings.triggerMode == .fnKey {
            TextInjector.ensureAccessibility(prompt: true)
        }
        log.info("Dictation triggers registered (mode: \(AppSettings.triggerMode.rawValue, privacy: .public))")
    }

    private func pushLevel(_ level: Float) {
        guard state == .recording else { return }
        micLevels.removeFirst()
        micLevels.append(level)
    }

    func toggleDictation() {
        switch state {
        case .idle: startRecording()
        case .recording: stopAndProcess()
        case .transcribing, .cleaning: break // pipeline already running; ignore
        }
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
                let raw = try await self.transcriber.transcribe(samples: samples, glossaryTerms: glossary) { phase, fraction in
                    Task { @MainActor in
                        self.progressPhase = phase
                        self.progressFraction = fraction
                    }
                }
                self.progressPhase = nil
                self.progressFraction = nil
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
                self.progressPhase = nil
                self.progressFraction = nil
                self.state = .idle
            }
        }
    }

    func unloadModels() async {
        await transcriber.unload()
    }
}
