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

    private var selectedMode: DictationMode {
        modeStore.modes.first { $0.id == styleRaw } ?? modeStore.selected
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
                Picker("Whisper model:", selection: $whisperModel) {
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
            }

            Section("Style") {
                Picker("Style:", selection: $styleRaw) {
                    ForEach(modeStore.modes) { mode in
                        Text("\(mode.name) — \(mode.detail)")
                            .tag(mode.id)
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
                if selectedMode.usesLLM {
                    Picker("LLM model:", selection: $ollamaModel) {
                        Text("qwen2.5:3b (balanced)").tag("qwen2.5:3b")
                        Text("gemma2:2b (lighter)").tag("gemma2:2b")
                    }
                    if !OllamaCleanup.isInstalled {
                        Label {
                            Text("Ollama is not installed. Run `brew install ollama`, then `ollama pull \(ollamaModel)`. Until then, raw transcripts are inserted.")
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

    var body: some View {
        Form {
            Section("Custom vocabulary") {
                Text("One term per line — names, jargon, acronyms (e.g. Vercel, Supabase, Moonbase). Used to bias recognition and correct near-misses.")
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
