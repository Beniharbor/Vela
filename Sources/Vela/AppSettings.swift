import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk: hold to record, release to transcribe.
    /// Default ⌥Space — changeable in Settings.
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.option]))
}

/// UserDefaults-backed settings. All keys are also readable via @AppStorage in SwiftUI.
enum AppSettings {
    enum Keys {
        static let cleanupEnabled = "cleanupEnabled"
        static let ollamaModel = "ollamaModel"
        static let whisperModel = "whisperModel"
        static let glossary = "glossary"
        static let modelIdleUnloadSeconds = "modelIdleUnloadSeconds"
    }

    static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            // G3: ship with cleanup OFF (lightest). Whisper already punctuates.
            Keys.cleanupEnabled: false,
            Keys.ollamaModel: "qwen2.5:3b",
            // Argmax-compressed large-v3 turbo (~0.6 GB). See PRD §7.
            Keys.whisperModel: "large-v3-v20240930_626MB",
            Keys.glossary: "",
            // Unload Whisper from RAM after this many seconds idle (G3).
            Keys.modelIdleUnloadSeconds: 120.0,
        ])
    }

    static var cleanupEnabled: Bool { defaults.bool(forKey: Keys.cleanupEnabled) }
    static var ollamaModel: String { defaults.string(forKey: Keys.ollamaModel) ?? "qwen2.5:3b" }
    static var whisperModel: String { defaults.string(forKey: Keys.whisperModel) ?? "large-v3-v20240930_626MB" }
    static var modelIdleUnloadSeconds: Double { defaults.double(forKey: Keys.modelIdleUnloadSeconds) }

    /// One term per line. Used for Whisper prompt biasing + LLM canonicalization (F4).
    static var glossaryTerms: [String] {
        (defaults.string(forKey: Keys.glossary) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
