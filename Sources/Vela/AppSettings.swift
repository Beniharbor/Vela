import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Custom toggle shortcut (used when trigger mode is .customShortcut).
    /// Default ⌥Space — changeable in Settings.
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.option]))
}

/// How dictation is triggered. Both modes are press-to-toggle:
/// press once to start recording, press again to stop and insert.
enum TriggerMode: String {
    case fnKey       // bare Fn key (default)
    case customShortcut
}

/// UserDefaults-backed settings. All keys are also readable via @AppStorage in SwiftUI.
enum AppSettings {
    enum Keys {
        static let triggerMode = "triggerMode"
        static let dictationStyle = "dictationStyle"
        static let dictationLanguage = "dictationLanguage"
        static let ollamaModel = "ollamaModel"
        static let whisperModel = "whisperModel"
        static let glossary = "glossary"
        static let modelIdleUnloadSeconds = "modelIdleUnloadSeconds"
        static let userName = "userName"
        static let sidebarWidth = "sidebarWidth"
        /// Comma-joined DashboardPane raw values, in the user's chosen order.
        /// Empty until the user first drags a tab — DashboardView fills in any
        /// pane missing from a stored order (new tabs added later, etc.).
        static let sidebarOrder = "sidebarOrder"
    }

    static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        // Migrate legacy style names (Structured → Polished, Clean → Prompt).
        if let raw = defaults.string(forKey: Keys.dictationStyle),
           let migrated = ["structured": "polished", "clean": "prompt"][raw] {
            defaults.set(migrated, forKey: Keys.dictationStyle)
        }
        defaults.register(defaults: [
            Keys.triggerMode: TriggerMode.fnKey.rawValue,
            // G3: ship in Flow (no LLM — lightest). Whisper already punctuates.
            Keys.dictationStyle: "flow",
            // "auto" = per-dictation language detection (English, Spanish, …).
            Keys.dictationLanguage: "auto",
            Keys.ollamaModel: "qwen2.5:3b",
            // Argmax-compressed large-v3 turbo (~0.6 GB). See PRD §7.
            Keys.whisperModel: "large-v3-v20240930_626MB",
            Keys.glossary: "",
            // Unload Whisper from RAM after this many seconds idle (G3).
            Keys.modelIdleUnloadSeconds: 120.0,
            // Sign-off name for Compose ("Best,\n<name>") — macOS first name by default.
            Keys.userName: NSFullUserName().split(separator: " ").first.map(String.init) ?? "",
            Keys.sidebarWidth: 210.0,
        ])
    }

    static var triggerMode: TriggerMode {
        TriggerMode(rawValue: defaults.string(forKey: Keys.triggerMode) ?? "") ?? .fnKey
    }
    /// The selected mode's id — resolve to a DictationMode via ModeStore.shared.selected.
    static var dictationStyleID: String {
        defaults.string(forKey: Keys.dictationStyle) ?? "flow"
    }
    /// Whisper language code ("en", "es", …) or "auto" to detect per dictation.
    static var dictationLanguage: String { defaults.string(forKey: Keys.dictationLanguage) ?? "auto" }
    static var ollamaModel: String { defaults.string(forKey: Keys.ollamaModel) ?? "qwen2.5:3b" }
    static var whisperModel: String { defaults.string(forKey: Keys.whisperModel) ?? "large-v3-v20240930_626MB" }
    static var modelIdleUnloadSeconds: Double { defaults.double(forKey: Keys.modelIdleUnloadSeconds) }
    /// Name used in Compose's default email sign-off.
    static var userName: String {
        (defaults.string(forKey: Keys.userName) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// One term per line. Used for Whisper prompt biasing + LLM canonicalization (F4).
    static var glossaryTerms: [String] {
        (defaults.string(forKey: Keys.glossary) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
