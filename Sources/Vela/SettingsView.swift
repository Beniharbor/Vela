import SwiftUI
import AVFoundation
import KeyboardShortcuts
import Speech

struct SettingsView: View {
    /// True when hosted inside the Dashboard window (fills the pane instead of a fixed sheet size).
    var embedded = false
    @State private var tab: SettingsTab = .general

    private enum SettingsTab: String, CaseIterable {
        case general = "General", vocabulary = "Vocabulary"
    }

    var body: some View {
        VStack(spacing: 0) {
            // A plain in-content segmented control, not a native TabView: TabView's
            // tab picker gets hoisted into the window's toolbar on macOS, which
            // would grow the shared Dashboard title bar only while Settings is open.
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.top, 14)
            .padding(.bottom, 6)

            Group {
                switch tab {
                case .general: GeneralSettings()
                case .vocabulary: VocabularySettings()
                }
            }
        }
        .frame(
            width: embedded ? nil : 480,
            height: embedded ? nil : 420
        )
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.Keys.triggerMode) private var triggerMode = TriggerMode.fnKey.rawValue
    @AppStorage(AppSettings.Keys.dictationStyle) private var styleRaw = "flow"
    @ObservedObject private var modeStore = ModeStore.shared
    @AppStorage(AppSettings.Keys.dictationLanguage) private var language = "auto"
    @AppStorage(AppSettings.Keys.ollamaModel) private var ollamaModel = "qwen2.5:3b"
    @AppStorage(AppSettings.Keys.whisperModel) private var whisperModel = "large-v3-v20240930_626MB"
    @AppStorage(AppSettings.Keys.modelIdleUnloadSeconds) private var idleUnload = 120.0
    @AppStorage(AppSettings.Keys.userName) private var userName = ""
    @AppStorage(AppSettings.Keys.pauseMediaWhileDictating) private var pauseMedia = true
    @AppStorage(AppSettings.Keys.soundCues) private var soundCues = true
    @AppStorage(AppSettings.Keys.spokenPunctuation) private var spokenPunctuation = true
    @AppStorage(AppSettings.Keys.voiceSendCommand) private var voiceSendCommand = false
    @AppStorage(AppSettings.Keys.screenContext) private var screenContext = false
    @AppStorage(AppSettings.Keys.learnVocabulary) private var learnVocabulary = true
    @State private var appRules = AppStyleRules.load()
    @ObservedObject private var llmDownloader = LocalLLMDownloader.shared

    private var selectedMode: DictationMode {
        modeStore.modes.first { $0.id == styleRaw } ?? modeStore.selected
    }

    private func addAppRule() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              !appRules.contains(where: { $0.bundleID == bundleID })
        else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        appRules.append(AppStyleRule(bundleID: bundleID, appName: name, modeID: selectedMode.id))
    }

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Trigger:", selection: $triggerMode) {
                    Text("Fn key — press to start, press again to insert")
                        .tag(TriggerMode.fnKey.rawValue)
                    Text("Custom shortcut (toggle)").tag(TriggerMode.customShortcut.rawValue)
                }
                if triggerMode == TriggerMode.customShortcut.rawValue {
                    KeyboardShortcuts.Recorder("Shortcut:", name: .pushToTalk)
                } else {
                    Text("Tip: set System Settings → Keyboard → “Press 🌐 key to” to **Do Nothing**, so Fn doesn't also open the emoji picker or macOS Dictation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Picker("Language:", selection: $language) {
                    Text("Auto-detect — English, Spanish, …").tag("auto")
                    Text("English").tag("en")
                    Text("Spanish (Español)").tag("es")
                }
                Picker("Speech model:", selection: $whisperModel) {
                    Text("Parakeet v3 ~0.5 GB (fastest; 25 European languages)")
                        .tag(ParakeetTranscriber.modelID)
                    Text("large-v3 turbo, compressed ~0.6 GB (recommended)")
                        .tag("large-v3-v20240930_626MB")
                    Text("large-v3 turbo, full ~1.6 GB").tag("large-v3-v20240930")
                    Text("distil-large-v3 ~0.6 GB (faster)").tag("distil-large-v3")
                    Text("base.en ~150 MB (lightest, English only)").tag("base.en")
                }
                if whisperModel == "base.en" && language != "en" {
                    Label {
                        Text("base.en only understands English — pick another model to dictate in Spanish.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Picker("Unload model after idle:", selection: $idleUnload) {
                    Text("30 seconds").tag(30.0)
                    Text("2 minutes").tag(120.0)
                    Text("10 minutes").tag(600.0)
                }
                Toggle("Pause music and videos while dictating", isOn: $pauseMedia)
                Toggle("Play a sound when recording starts and stops", isOn: $soundCues)
                Toggle("Spoken punctuation (“new line”, “new paragraph”, “comma”, “question mark”)", isOn: $spokenPunctuation)
                Toggle("Press Return when a dictation ends with “send it”", isOn: $voiceSendCommand)
                Toggle("Suggest vocabulary rules from words I correct", isOn: $learnVocabulary)
                KeyboardShortcuts.Recorder("Rewrite selection by voice:", name: .rewriteSelection)
                Text("Select text, press the shortcut, then say how to change it (“make this shorter”). Needs the AI model below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Per-app style") {
                ForEach($appRules) { $rule in
                    HStack {
                        Text(rule.appName)
                        Spacer()
                        Picker("", selection: $rule.modeID) {
                            ForEach(modeStore.modes) { mode in
                                Text(mode.name).tag(mode.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                        Button {
                            appRules.removeAll { $0.bundleID == rule.bundleID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                Button("Add app…") { addAppRule() }
                Text("Dictating in a listed app uses its style instead of the selected one — for example Polished in Mail and Flow in Slack.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: appRules) { _, rules in AppStyleRules.save(rules) }

            Section("Style") {
                Picker("Style:", selection: $styleRaw) {
                    ForEach(modeStore.modes) { mode in
                        Text(mode.needsOllama
                             ? "\(mode.name) — Needs AI model"
                             : "\(mode.name) — \(mode.detail)")
                            .tag(mode.id)
                            .selectionDisabled(mode.needsOllama)
                    }
                }
                Text("Modes with a system prompt rewrite with a local LLM; a mode without one (Flow) inserts your words as spoken. Rename modes, edit their prompts, or create new ones in the Dashboard → Modes. You can also switch modes from the dropdown in the recording pill.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if selectedMode.systemPrompt.contains("{name}") {
                    TextField("Sign-off name:", text: $userName, prompt: Text("Mateo"))
                    Text("Replaces {name} in the mode's prompt — e.g. to close emails with “Best, \(userName.isEmpty ? "…" : userName)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Built-in AI model:") {
                    if llmDownloader.isDownloaded {
                        HStack {
                            Label("\(LocalLLM.modelName) installed", systemImage: "checkmark.circle.fill")
                            Button("Remove") { llmDownloader.remove() }
                        }
                    } else if let progress = llmDownloader.progress {
                        HStack {
                            ProgressView(value: progress).frame(width: 140)
                            Text("\(Int(progress * 100))%").monospacedDigit()
                            Button("Cancel") { llmDownloader.cancel() }
                        }
                    } else {
                        Button("Download \(LocalLLM.modelName) (2.1 GB)") { llmDownloader.start() }
                    }
                }
                if let error = llmDownloader.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Text("Runs the LLM styles and voice rewrite entirely inside Vela — nothing else to install. Loaded only while it's working.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Let the cleanup model read the text before the cursor", isOn: $screenContext)
                Text("Helps LLM styles spell names and match the tone of what you've already written. The text goes only to the local model on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if selectedMode.usesLLM, !llmDownloader.isDownloaded {
                    Picker("Ollama model:", selection: $ollamaModel) {
                        Text("qwen2.5:3b (balanced)").tag("qwen2.5:3b")
                        Text("gemma2:2b (lighter)").tag("gemma2:2b")
                    }
                    if !OllamaCleanup.isInstalled {
                        Label {
                            Text("Download the built-in AI model above to use this style. Until then, raw transcripts are inserted.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            PermissionsSection()
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsSection: View {
    @State private var axGranted = false
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Permissions") {
            LabeledContent("Microphone (to hear you)") {
                statusBadge(granted: micStatus == .authorized, notDetermined: micStatus == .notDetermined)
            }
            LabeledContent("Accessibility (to insert text & catch Fn)") {
                badge(granted: axGranted)
            }
            LabeledContent("Speech Recognition (for the \"watermelon\" stop-word)") {
                statusBadge(granted: speechStatus == .authorized, notDetermined: speechStatus == .notDetermined)
            }
            Button("Open Privacy & Security settings…") {
                let pane: String
                if micStatus != .authorized {
                    pane = "Privacy_Microphone"
                } else if !axGranted {
                    pane = "Privacy_Accessibility"
                } else if speechStatus != .authorized {
                    pane = "Privacy_SpeechRecognition"
                } else {
                    pane = "Privacy_Accessibility"
                }
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
            Text("Everything runs 100% on-device. If a permission shows as missing after you granted it there, relaunch Vela once.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear { update() }
        .onReceive(refresh) { _ in update() }
    }

    private func update() {
        axGranted = TextInjector.ensureAccessibility(prompt: false)
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
    }

    @ViewBuilder
    private func statusBadge(granted: Bool, notDetermined: Bool) -> some View {
        if notDetermined {
            // macOS simply hasn't asked yet — the first recording will.
            Label("Will ask on first use", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        } else {
            badge(granted: granted)
        }
    }

    private func badge(granted: Bool) -> Label<Text, Image> {
        granted
            ? Label("Granted", systemImage: "checkmark.circle.fill")
            : Label("Not granted", systemImage: "xmark.circle.fill")
    }
}

private struct VocabularySettings: View {
    @AppStorage(AppSettings.Keys.glossary) private var glossary = ""
    @AppStorage(AppSettings.Keys.vocabularySuggestions) private var suggestionsRaw = ""

    private var suggestions: [String] {
        suggestionsRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            if !suggestions.isEmpty {
                Section("Suggested from your corrections") {
                    ForEach(suggestions, id: \.self) { line in
                        HStack {
                            Text(line).font(.body.monospaced())
                            Spacer()
                            Button("Add") {
                                let entry = AppSettings.parseGlossaryLine(line)
                                if let misheard = entry.misheard.first {
                                    AppSettings.addGlossaryEntry(term: entry.term, misheard: misheard)
                                }
                                AppSettings.removeVocabularySuggestion(line)
                            }
                            Button("Dismiss") { AppSettings.removeVocabularySuggestion(line) }
                        }
                    }
                }
            }
            Section("Custom vocabulary") {
                Text("One term per line — names, jargon, acronyms (e.g. Vercel, Supabase, Moonbase). Used to bias recognition and correct near-misses. To always fix a word Whisper gets wrong, write it as a rule: Alphabet -> Alfavet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $glossary)
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
            }
        }
        .formStyle(.grouped)
    }
}
