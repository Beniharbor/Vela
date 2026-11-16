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
            switch state {
            case .recording:
                // A new take interrupts a lingering Done bubble.
                doneFlashTask?.cancel()
                showingDone = false
                micLevels = Array(repeating: 0, count: Self.levelBarCount)
                recordingStarted = Date()
                isPaused = false
                pausedAt = nil
                livePreview = ""
                hud.show()
                MediaPauser.shared.recordingStarted()
            case .transcribing, .cleaning:
                livePreview = ""
                // Keep the HUD up through the pipeline so the loading bar is visible.
                hud.show()
            case .idle:
                livePreview = ""
                if oldValue == .recording {
                    recordingStarted = nil
                    isPaused = false
                    pausedAt = nil
                }
                // flashDone() re-shows the HUD right after, if applicable.
                hud.hide()
                MediaPauser.shared.pipelineFinished()
                takeMode = nil
                takeContext = nil
                rewriteSource = nil
            }
        }
    }
    /// When the current recording began — drives the elapsed timer in the HUD.
    /// Shifted forward on resume so paused time never counts as elapsed.
    @Published private(set) var recordingStarted: Date?
    /// True while recording is paused (bare Control tap toggles it).
    @Published private(set) var isPaused = false
    /// When the current pause began — freezes the HUD timer while paused.
    @Published private(set) var pausedAt: Date?
    /// True while the green "Done" bubble is flashed in the HUD after an insert (F11).
    @Published private(set) var showingDone = false
    private var doneFlashTask: Task<Void, Never>?
    @Published private(set) var lastError: String?
    /// Rolling mic-level history for the recording HUD (newest at the end).
    @Published private(set) var micLevels: [Float] = Array(repeating: 0, count: DictationController.levelBarCount)
    private static let levelBarCount = 24
    /// Rough live transcript of the take in progress, shown above the HUD pill.
    /// Empty when not recording or before the first words are recognized.
    @Published private(set) var livePreview = ""
    private let hud = RecordingHUD()
    @Published private(set) var lastLatency: TimeInterval?
    @Published private(set) var lastTranscript: String?
    /// True when the last dictation had no text field to paste into — the
    /// transcript was left on the clipboard and offered in the menu instead.
    @Published private(set) var lastInsertWasCopyOnly = false
    /// e.g. "Downloading model" + 0.42 while working; nil when idle.
    @Published private(set) var progressPhase: String?
    @Published private(set) var progressFraction: Double?

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber.shared
    private let watchword = WatchwordListener()
    /// Preview-only recognizer used in place of the English one's partials when
    /// the take is expected to be in Spanish (the stop-word stays English).
    private let spanishPreview = WatchwordListener(locales: ["es-ES", "es-MX", "es-US"], detectsWord: false)
    private var previewInSpanish = false
    /// The style this take uses when it isn't the globally selected one: a
    /// per-app rule, or the synthetic "Rewrite" mode. Shown in the HUD chip.
    @Published private(set) var takeMode: DictationMode?
    /// Text already in the target field, for the cleanup LLM (screen context).
    private var takeContext: String?
    /// The selected text a voice-rewrite take will transform.
    private var rewriteSource: String?
    private static let rewriteMode = DictationMode(
        id: "__rewrite", name: "Rewrite", detail: "say how to change the selection",
        systemPrompt: "rewrite"
    )
    private var effectiveMode: DictationMode { takeMode ?? ModeStore.shared.selected }
    /// Which language the live preview should listen for: the dictation
    /// language when it's fixed, otherwise whatever the last dictation was in.
    private var previewLanguage: String {
        let setting = AppSettings.dictationLanguage
        if setting != "auto" { return setting }
        return HistoryStore.shared.records.last?.language.lowercased() == "es" ? "es" : "en"
    }
    /// Which engine the take in progress is using — decided at warmPipeline()
    /// time from the selected mode, so a mid-recording style switch can't
    /// change engines under a running session.
    private var activeEngine: TranscriptionEngineKind = .whisperKit
    /// Set when the current take is ending because "watermelon" was heard, so
    /// stopAndProcess() knows to strip it back out of the transcript.
    private var stoppedByWatchword = false
    private let fnMonitor = FnKeyMonitor()
    private let log = Logger(subsystem: "com.vela.app", category: "pipeline")

    /// F7b: recording hard-stops after this long and proceeds to transcription.
    private static let maxRecordingDuration: TimeInterval = 600
    private var maxDurationTask: Task<Void, Never>?

    /// F10: switching style signals intent to dictate — tracks the last seen value
    /// so the defaults observer only reacts to actual style changes.
    private var lastKnownStyleID = AppSettings.dictationStyleID

    private var triggerName: String {
        AppSettings.triggerMode == .fnKey ? "Fn" : "the shortcut"
    }

    var statusLine: String {
        if let lastError { return "⚠️ \(lastError)" }
        switch state {
        case .idle:
            if lastInsertWasCopyOnly {
                return "Paste didn't land — transcript is on the clipboard (⌘V)"
            }
            return "Vela — press \(triggerName) to dictate"
        case .recording:
            if isPaused {
                return "Paused (Control to resume · \(triggerName) to insert · Esc to cancel)"
            }
            return "Recording… (\(triggerName) to insert · Control to pause · Esc to cancel)"
        case .transcribing:
            if let progressPhase {
                if let progressFraction {
                    return "\(progressPhase)… \(Int(progressFraction * 100))%"
                }
                return "\(progressPhase)…"
            }
            return "Transcribing…"
        case .cleaning: return "Formatting (\(effectiveMode.name))…"
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
        recorder.onBuffer = { [weak self] buffer in
            Task { @MainActor in
                guard let self else { return }
                self.watchword.append(buffer)
                if self.previewInSpanish { self.spanishPreview.append(buffer) }
                if self.activeEngine == .appleSpeech, #available(macOS 26, *) {
                    Task { await AppleSpeechTranscriber.shared.feed(buffer) }
                }
            }
        }
        watchword.onDetected = { [weak self] in self?.watchwordDetected() }
        spanishPreview.onPartial = { [weak self] text in
            guard let self, self.state == .recording, self.previewInSpanish else { return }
            self.livePreview = text
        }
        KeyboardShortcuts.onKeyDown(for: .rewriteSelection) { [weak self] in
            self?.startRewrite()
        }
        watchword.onPartial = { [weak self] text in
            guard let self, self.state == .recording, !self.previewInSpanish else { return }
            self.livePreview = text
        }

        // Both triggers are press-to-toggle; the active one is checked at press time
        // so switching modes in Settings takes effect immediately.
        fnMonitor.onToggle = { [weak self] in
            guard AppSettings.triggerMode == .fnKey else { return }
            self?.toggleDictation()
        }
        // Esc cancels an in-progress recording regardless of trigger mode (F6).
        fnMonitor.onEscape = { [weak self] in
            self?.cancelRecording()
        }
        // Bare Control tap pauses/resumes the current recording (no-op when idle).
        fnMonitor.onControlTap = { [weak self] in
            self?.togglePause()
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

        // F10: picking a different style (menu bar, HUD chip, or dashboard) means
        // "I want to dictate in that style" — start listening without another Fn press.
        lastKnownStyleID = AppSettings.dictationStyleID
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.styleDidChangeIfNeeded() }
        }

        log.info("Dictation triggers registered (mode: \(AppSettings.triggerMode.rawValue, privacy: .public))")
    }

    /// F10: style switch while idle starts a dictation; mid-recording it restarts
    /// the take (discard audio so far, keep listening) — the user is re-doing it in
    /// the new style. A running transcription is left alone.
    private func styleDidChangeIfNeeded() {
        let currentID = AppSettings.dictationStyleID
        guard currentID != lastKnownStyleID else { return }
        lastKnownStyleID = currentID
        let current = ModeStore.shared.selected
        // An explicit pick overrides a per-app rule for the rest of the take.
        if rewriteSource == nil { takeMode = nil }
        switch state {
        case .idle:
            // F10 is for the menu bar / HUD pickers: switching there means "dictate
            // now". Inside the dashboard it's configuration — don't grab the mic.
            if NSApp.keyWindow?.identifier?.rawValue.contains("dashboard") == true {
                log.info("Style switched to \(current.name, privacy: .public) from dashboard — not starting dictation")
                return
            }
            log.info("Style switched to \(current.name, privacy: .public) — starting dictation")
            startRecording()
        case .recording:
            log.info("Style switched to \(current.name, privacy: .public) mid-recording — restarting take")
            _ = recorder.stop()
            do {
                try recorder.start()
                micLevels = Array(repeating: 0, count: Self.levelBarCount)
                recordingStarted = Date() // the take restarted — restart the timer too
                isPaused = false
                pausedAt = nil
                scheduleMaxDurationStop()
                // The new style may need the LLM that the old one didn't.
                if current.usesLLM {
                    Task { await OllamaCleanup.prewarm() }
                }
            } catch {
                state = .idle
                lastError = error.localizedDescription
            }
        case .transcribing, .cleaning:
            break
        }
    }

    private func pushLevel(_ level: Float) {
        guard state == .recording, !isPaused else { return }
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

    /// Voice rewrite: grab the selection, then record a spoken instruction
    /// ("make this shorter", "translate to Spanish") that replaces it.
    func startRewrite() {
        guard state == .idle else { return }
        Task {
            guard OllamaCleanup.isAvailable else {
                self.lastError = "Voice rewrite needs the built-in AI model (Settings → Style → Download)"
                return
            }
            guard let selection = await TextInjector.selectedText() else {
                self.lastError = "Select some text first, then press the rewrite shortcut"
                return
            }
            guard self.state == .idle else { return }
            self.startRecording(rewriting: selection)
        }
    }

    func startRecording(rewriting selection: String? = nil) {
        guard state == .idle else { return }
        lastError = nil
        lastInsertWasCopyOnly = false
        // A correction made since the last dictation is checked before this
        // one replaces what is being watched.
        VocabularyLearner.shared.check()
        rewriteSource = selection
        takeMode = selection != nil ? Self.rewriteMode : AppStyleRules.modeForFrontmostApp()
        takeContext = (selection == nil && AppSettings.screenContext && effectiveMode.usesLLM)
            ? FocusContext.textBeforeCaret() : nil
        Task {
            guard await AudioRecorder.requestMicPermission() else {
                self.lastError = "Microphone permission denied (System Settings → Privacy)"
                self.takeMode = nil
                self.rewriteSource = nil
                return
            }
            // Supplementary feature — a "no" here just means no voice stop-word
            // for this take, not a blocked dictation.
            let watchwordAuthorized = await WatchwordListener.requestAuthorization()
            // User may have released the key while the permission dialog was up.
            guard self.state == .idle else { return }
            do {
                // Cue first, so the engine isn't already recording its own beep
                // through the speakers for the whole length of the sound.
                SoundCue.start.play()
                try self.recorder.start()
                self.state = .recording
                if watchwordAuthorized {
                    self.watchword.start()
                    self.previewInSpanish = self.previewLanguage == "es" && self.spanishPreview.start()
                }
                self.scheduleMaxDurationStop()
                self.warmPipeline()
            } catch {
                self.lastError = error.localizedDescription
                self.takeMode = nil
                self.rewriteSource = nil
            }
        }
    }

    /// Voice stop-word: saying "watermelon" mid-dictation ends recording and
    /// pastes what came before it, like releasing the trigger key.
    private func watchwordDetected() {
        guard state == .recording else { return }
        stoppedByWatchword = true
        log.info("Stop-word \"watermelon\" detected — stopping recording")
        stopAndProcess()
    }

    /// Bare Control tap while recording: pause capture; tap again to resume.
    /// Paused time doesn't count toward the elapsed timer or the 10-min cap.
    func togglePause() {
        guard state == .recording else { return }
        if isPaused {
            do {
                try recorder.resume()
            } catch {
                lastError = "Couldn't resume: \(error.localizedDescription)"
                log.error("Resume failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            // Shift the start forward by the pause length so elapsed stays honest.
            if let pausedAt, let started = recordingStarted {
                recordingStarted = started.addingTimeInterval(Date().timeIntervalSince(pausedAt))
            }
            pausedAt = nil
            isPaused = false
            scheduleMaxDurationStop()
            log.info("Recording resumed via Control")
        } else {
            recorder.pause()
            pausedAt = Date()
            isPaused = true
            maxDurationTask?.cancel()
            maxDurationTask = nil
            micLevels = Array(repeating: 0, count: Self.levelBarCount)
            log.info("Recording paused via Control")
        }
    }

    /// F6: Esc while recording — stop capture, discard audio, insert nothing.
    func cancelRecording() {
        guard state == .recording else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        _ = recorder.stop()
        watchword.stop()
        spanishPreview.stop()
        previewInSpanish = false
        stoppedByWatchword = false
        state = .idle
        log.info("Recording cancelled via Esc — audio discarded")
        releaseWarmEngine()
    }

    /// Undo warmPipeline() when a take ends without transcribing (Esc, too-short
    /// tap, silence guard). preload() cancels the idle unload, so without this
    /// the Whisper model would stay resident until the next dictation (G3); an
    /// open Apple Speech session would never be closed.
    private func releaseWarmEngine() {
        if activeEngine == .appleSpeech, #available(macOS 26, *) {
            Task { await AppleSpeechTranscriber.shared.cancel() }
        } else {
            Task { await transcriber.scheduleUnload() }
        }
    }

    /// Latency: load the Whisper model (and the LLM for styles that use it) while
    /// the user is speaking, so processing starts the instant recording stops.
    /// For Flow Apple, this instead opens the SpeechAnalyzer session so audio is
    /// decoded live — by the time recording stops, most of the work is done.
    private func warmPipeline() {
        let mode = effectiveMode
        if mode.engine == .appleSpeech, #available(macOS 26, *) {
            activeEngine = .appleSpeech
            Task {
                do {
                    try await AppleSpeechTranscriber.shared.start(
                        languageOverride: nil,
                        glossaryTerms: AppSettings.glossaryTerms
                    ) { phase, fraction in
                        Task { @MainActor in
                            self.progressPhase = phase
                            self.progressFraction = fraction
                        }
                    }
                } catch {
                    self.log.error("Apple Speech start failed, falling back to WhisperKit: \(error.localizedDescription, privacy: .public)")
                    self.activeEngine = .whisperKit
                    await self.transcriber.preload()
                }
            }
        } else {
            activeEngine = .whisperKit
            Task { await transcriber.preload() }
        }
        if mode.usesLLM {
            Task { await OllamaCleanup.prewarm() }
        }
    }

    /// F7b: hard-stop after 10 minutes and proceed to transcription.
    private func scheduleMaxDurationStop() {
        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxRecordingDuration))
            guard !Task.isCancelled, let self, self.state == .recording else { return }
            self.log.info("Max recording duration reached (\(Self.maxRecordingDuration, privacy: .public)s) — auto-stopping")
            self.stopAndProcess()
        }
    }

    func stopAndProcess() {
        guard state == .recording else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        let released = Date()
        let samples = recorder.stop()
        watchword.stop()
        spanishPreview.stop()
        previewInSpanish = false
        SoundCue.stop.play()
        let mode = effectiveMode
        let rewriteSource = self.rewriteSource
        let context = takeContext
        state = .transcribing
        let wasStoppedByWatchword = stoppedByWatchword
        stoppedByWatchword = false

        // Ignore accidental taps shorter than ~0.3 s of audio.
        guard Double(samples.count) / AudioRecorder.targetSampleRate > 0.3 else {
            state = .idle
            releaseWarmEngine()
            return
        }

        // F7a silence guard: never hand silence/noise to Whisper — it hallucinates
        // text, and that text would be pasted into the focused app.
        let speech = AudioRecorder.analyzeSpeech(samples)
        let vadStats = String(
            format: "voiced=%.2fs threshold=%.4f noiseFloor=%.4f peakRMS=%.4f",
            speech.voicedSeconds, speech.threshold, speech.noiseFloor, speech.peakRMS
        )
        guard speech.containsSpeech else {
            state = .idle
            releaseWarmEngine()
            lastError = "No speech detected — nothing inserted"
            log.info("Silence guard tripped (\(vadStats, privacy: .public)): \(samples.count) samples discarded")
            return
        }
        log.info("VAD passed: \(vadStats, privacy: .public)")

        Task {
            do {
                let glossary = AppSettings.glossaryTerms
                let sttStart = Date()
                let stt: Transcriber.Output
                if self.activeEngine == .appleSpeech, #available(macOS 26, *) {
                    stt = try await AppleSpeechTranscriber.shared.finish()
                } else {
                    stt = try await self.transcriber.transcribe(samples: samples, glossaryTerms: glossary) { phase, fraction in
                        Task { @MainActor in
                            self.progressPhase = phase
                            self.progressFraction = fraction
                        }
                    }
                }
                // F12: strip ums/uhs and awkward spacing for every style — Flow
                // included, which never sees the LLM.
                var raw = TranscriptFilter.clean(stt.text)
                if wasStoppedByWatchword {
                    raw = TranscriptFilter.strippingTrailingStopWord(raw, word: WatchwordListener.word)
                }
                self.progressPhase = nil
                self.progressFraction = nil
                self.log.info("STT took \(Date().timeIntervalSince(sttStart), format: .fixed(precision: 2))s: \(raw, privacy: .public)")

                var sendAfter = false
                var final: String
                if let rewriteSource {
                    // The transcript is the instruction; the selection is the text.
                    guard !raw.isEmpty else {
                        self.state = .idle
                        return
                    }
                    self.state = .cleaning
                    final = try await OllamaCleanup.rewrite(rewriteSource, instruction: raw)
                    guard !final.isEmpty else {
                        throw VelaError.cleanup("Rewrite returned nothing — your text was left unchanged")
                    }
                } else {
                    if AppSettings.spokenPunctuation {
                        raw = TranscriptFilter.applyingSpokenCommands(raw)
                    }
                    if AppSettings.voiceSendCommand {
                        (raw, sendAfter) = TranscriptFilter.extractingSendCommand(raw)
                    }
                    guard !raw.isEmpty else {
                        // "Send it" on its own: send what is already typed.
                        if sendAfter { TextInjector.pressReturn() }
                        self.state = .idle
                        return
                    }
                    final = raw
                }

                if rewriteSource == nil, mode.usesLLM {
                    self.state = .cleaning
                    do {
                        let cleaned = try await OllamaCleanup.clean(raw, mode: mode, glossaryTerms: glossary, language: stt.language, context: context)
                        if cleaned.isEmpty {
                            // An empty reply would otherwise paste nothing and
                            // still flash Done — keep what was actually said.
                            self.log.error("\(mode.name, privacy: .public) styling returned nothing, using raw transcript")
                        } else {
                            final = cleaned
                        }
                    } catch {
                        // Styling is best-effort: fall back to the raw transcript.
                        self.log.error("\(mode.name, privacy: .public) styling failed, using raw transcript: \(error.localizedDescription, privacy: .public)")
                    }
                }

                var outcome = TextInjector.inject(final) { [weak self] in
                    // Read-back says the paste never landed: the transcript was
                    // left on the clipboard, so flip Done → Copied and say why.
                    guard let self else { return }
                    self.lastInsertWasCopyOnly = true
                    self.log.info("Paste verification: text did not land — left on clipboard")
                }
                let pasteFailed = outcome == .failed
                if pasteFailed {
                    // Couldn't paste (Accessibility not granted): never drop the
                    // text — leave it on the clipboard and say so instead of Done.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(final, forType: .string)
                    self.lastError = "Couldn't paste (check Accessibility permission) — transcript is on the clipboard"
                    outcome = .copiedOnly
                }
                if sendAfter, outcome == .pasted {
                    // Give the paste a moment to land before pressing Return.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        TextInjector.pressReturn()
                    }
                }
                self.lastInsertWasCopyOnly = (outcome == .copiedOnly)
                self.lastTranscript = final
                self.lastLatency = Date().timeIntervalSince(released)
                HistoryStore.shared.add(
                    text: final,
                    duration: Double(samples.count) / AudioRecorder.targetSampleRate,
                    language: stt.language
                )
                self.log.info("End-to-end (release → inject): \(self.lastLatency ?? 0, format: .fixed(precision: 2))s")
                self.state = .idle
                if !pasteFailed { self.flashDone() }
            } catch {
                self.lastError = error.localizedDescription
                self.log.error("Pipeline failed: \(error.localizedDescription, privacy: .public)")
                self.progressPhase = nil
                self.progressFraction = nil
                self.state = .idle
            }
        }
    }

    /// F11: pop the green "Done" bubble where the recording pill was, then fade out.
    private func flashDone() {
        doneFlashTask?.cancel()
        showingDone = true
        hud.show()
        doneFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, let self else { return }
            self.showingDone = false
            if self.state != .recording {
                self.hud.hide(fade: true)
            }
        }
    }

    func unloadModels() async {
        await transcriber.unload()
    }
}
