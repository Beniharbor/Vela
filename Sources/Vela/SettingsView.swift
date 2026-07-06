import SwiftUI
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
    @AppStorage(AppSettings.Keys.cleanupEnabled) private var cleanupEnabled = false
    @AppStorage(AppSettings.Keys.ollamaModel) private var ollamaModel = "qwen2.5:3b"
    @AppStorage(AppSettings.Keys.whisperModel) private var whisperModel = "large-v3-v20240930_626MB"
    @AppStorage(AppSettings.Keys.modelIdleUnloadSeconds) private var idleUnload = 120.0

    var body: some View {
        Form {
            Section("Dictation") {
                KeyboardShortcuts.Recorder("Push-to-talk (hold):", name: .pushToTalk)
                Picker("Whisper model:", selection: $whisperModel) {
                    Text("large-v3 turbo, compressed ~0.6 GB (recommended)")
                        .tag("large-v3-v20240930_626MB")
                    Text("large-v3 turbo, full ~1.6 GB").tag("large-v3-v20240930")
                    Text("distil-large-v3 ~0.6 GB (faster)").tag("distil-large-v3")
                    Text("base.en ~150 MB (lightest)").tag("base.en")
                }
                Picker("Unload model after idle:", selection: $idleUnload) {
                    Text("30 seconds").tag(30.0)
                    Text("2 minutes").tag(120.0)
                    Text("10 minutes").tag(600.0)
                }
            }

            Section("AI cleanup (optional)") {
                Toggle("Clean up transcripts with a local LLM", isOn: $cleanupEnabled)
                if cleanupEnabled {
                    Picker("Cleanup model:", selection: $ollamaModel) {
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

            Section("Permissions") {
                Button("Check Accessibility permission…") {
                    TextInjector.ensureAccessibility(prompt: true)
                }
                Text("Vela needs Microphone (to hear you) and Accessibility (to paste into other apps). Models run 100% on-device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
