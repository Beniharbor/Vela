import SwiftUI
import AVFoundation
import KeyboardShortcuts

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            VocabularySettings()
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
        }
        .frame(width: 480, height: 360)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.Keys.triggerMode) private var triggerMode = TriggerMode.fnKey.rawValue
    @AppStorage(AppSettings.Keys.dictationStyle) private var styleRaw = DictationStyle.flow.rawValue
    @AppStorage(AppSettings.Keys.dictationLanguage) private var language = "auto"
    @AppStorage(AppSettings.Keys.ollamaModel) private var ollamaModel = "qwen2.5:3b"
    @AppStorage(AppSettings.Keys.whisperModel) private var whisperModel = "large-v3-v20240930_626MB"
    @AppStorage(AppSettings.Keys.modelIdleUnloadSeconds) private var idleUnload = 120.0

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
                    ForEach(DictationStyle.allCases) { style in
                        Text("\(style.displayName) — \(style.menuDescription)")
                            .tag(style.rawValue)
                    }
                }
                Text("Flow inserts your words verbatim with no LLM (lightest). Structured and Clean rewrite with a local LLM. You can also switch styles from the dropdown in the recording pill.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let style = DictationStyle(rawValue: styleRaw), style.usesLLM {
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
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Permissions") {
            LabeledContent("Microphone (to hear you)") {
                statusBadge(micGranted: micStatus)
            }
            LabeledContent("Accessibility (to insert text & catch Fn)") {
                badge(granted: axGranted)
            }
            Button("Open Privacy & Security settings…") {
                let pane = axGranted && micStatus != .authorized
                    ? "Privacy_Microphone" : "Privacy_Accessibility"
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
    }

    @ViewBuilder
    private func statusBadge(micGranted status: AVAuthorizationStatus) -> some View {
        if status == .notDetermined {
            // macOS simply hasn't asked yet — the first recording will.
            Label("Will ask on first use", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        } else {
            badge(granted: status == .authorized)
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
