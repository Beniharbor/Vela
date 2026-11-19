import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Custom toggle shortcut (used when trigger mode is .customShortcut).
    /// Default ⌥Space — changeable in Settings.
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.option]))
    /// Select text, press this, say how to change it ("make this shorter").
    static let rewriteSelection = Self("rewriteSelection", default: .init(.r, modifiers: [.control, .option]))
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
        static let pauseMediaWhileDictating = "pauseMediaWhileDictating"
        static let soundCues = "soundCues"
        static let spokenPunctuation = "spokenPunctuation"
        static let voiceSendCommand = "voiceSendCommand"
        static let screenContext = "screenContext"
        static let learnVocabulary = "learnVocabulary"
        /// "misheard -> term" lines waiting for a yes/no in Settings → Vocabulary.
        static let vocabularySuggestions = "vocabularySuggestions"
        /// JSON [AppStyleRule].
        static let appStyleRules = "appStyleRules"
        /// "parakeet" or "whisper" — engine used for imported voice notes.
        static let voiceNotesEngine = "voiceNotesEngine"
    }

    /// Voice notes default to Parakeet: more accurate on everyday English and
    /// Spanish speech, and no Whisper-style looping on long files.
    static var voiceNotesUseParakeet: Bool {
        (defaults.string(forKey: Keys.voiceNotesEngine) ?? "parakeet") == "parakeet"
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
            Keys.pauseMediaWhileDictating: true,
            Keys.soundCues: true,
            Keys.spokenPunctuation: true,
            // Off until switched on: it presses Return in the focused app.
            Keys.voiceSendCommand: false,
            // Off until switched on: it hands on-screen text to the cleanup LLM.
            Keys.screenContext: false,
            Keys.learnVocabulary: true,
            Keys.vocabularySuggestions: "",
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
    /// The selected speech model: a WhisperKit variant, or ParakeetTranscriber.modelID.
    static var whisperModel: String { defaults.string(forKey: Keys.whisperModel) ?? "large-v3-v20240930_626MB" }
    static var usesParakeet: Bool { whisperModel == ParakeetTranscriber.modelID }
    /// The Whisper variant to load when Whisper itself is needed — the selected
    /// one, or the default when Parakeet is selected (word-timed voice notes).
    static var whisperKitModel: String { usesParakeet ? "large-v3-v20240930_626MB" : whisperModel }
    static var pauseMediaWhileDictating: Bool { defaults.bool(forKey: Keys.pauseMediaWhileDictating) }
    static var soundCues: Bool { defaults.bool(forKey: Keys.soundCues) }
    static var spokenPunctuation: Bool { defaults.bool(forKey: Keys.spokenPunctuation) }
    static var voiceSendCommand: Bool { defaults.bool(forKey: Keys.voiceSendCommand) }
    static var screenContext: Bool { defaults.bool(forKey: Keys.screenContext) }
    static var learnVocabulary: Bool { defaults.bool(forKey: Keys.learnVocabulary) }

    static var vocabularySuggestionLines: [String] {
        (defaults.string(forKey: Keys.vocabularySuggestions) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Queues "misheard -> term" for review unless it's already a rule or queued.
    static func addVocabularySuggestion(misheard: String, term: String) {
        let known = replacementRules.contains {
            $0.from.caseInsensitiveCompare(misheard) == .orderedSame
        }
        let line = "\(misheard) -> \(term)"
        var lines = vocabularySuggestionLines
        guard !known, !lines.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) else { return }
        lines.append(line)
        defaults.set(lines.suffix(20).joined(separator: "\n"), forKey: Keys.vocabularySuggestions)
    }

    static func removeVocabularySuggestion(_ line: String) {
        defaults.set(vocabularySuggestionLines.filter { $0 != line }.joined(separator: "\n"),
                     forKey: Keys.vocabularySuggestions)
    }
    static var modelIdleUnloadSeconds: Double { defaults.double(forKey: Keys.modelIdleUnloadSeconds) }
    /// Name used in Compose's default email sign-off.
    static var userName: String {
        (defaults.string(forKey: Keys.userName) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// One vocabulary entry per line (F4). Either a plain term ("Alfavet") or a
    /// replacement rule: "Alphabet -> Alfavet" (also "→" / "=>"; several
    /// misheard forms may be comma-separated on the left).
    struct GlossaryEntry: Hashable {
        let line: String
        let term: String
        let misheard: [String]
    }

    static var glossaryLines: [String] {
        (defaults.string(forKey: Keys.glossary) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func parseGlossaryLine(_ line: String) -> GlossaryEntry {
        for arrow in ["->", "→", "=>"] {
            if let range = line.range(of: arrow) {
                let term = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let misheard = line[..<range.lowerBound]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.caseInsensitiveCompare(term) != .orderedSame }
                if !term.isEmpty { return GlossaryEntry(line: line, term: term, misheard: misheard) }
            }
        }
        return GlossaryEntry(line: line, term: line, misheard: [])
    }

    static var glossaryEntries: [GlossaryEntry] { glossaryLines.map(parseGlossaryLine) }

    /// Correct spellings only — fed to Whisper's prompt and the LLM styles.
    static var glossaryTerms: [String] { glossaryEntries.map(\.term) }

    /// (misheard, correct) pairs applied to every transcript.
    static var replacementRules: [(from: String, to: String)] {
        glossaryEntries.flatMap { entry in entry.misheard.map { ($0, entry.term) } }
    }

    /// Adds a term (and optional misheard form) to the vocabulary. If the term
    /// is already listed, the misheard form is merged into its line.
    static func addGlossaryEntry(term rawTerm: String, misheard rawMisheard: String) {
        let term = rawTerm.trimmingCharacters(in: .whitespaces)
        let misheard = rawMisheard.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        var lines = glossaryLines
        if let index = lines.firstIndex(where: { parseGlossaryLine($0).term.caseInsensitiveCompare(term) == .orderedSame }) {
            let existing = parseGlossaryLine(lines[index])
            guard !misheard.isEmpty,
                  !existing.misheard.contains(where: { $0.caseInsensitiveCompare(misheard) == .orderedSame })
            else { return }
            lines[index] = (existing.misheard + [misheard]).joined(separator: ", ") + " -> " + existing.term
        } else {
            lines.append(misheard.isEmpty ? term : "\(misheard) -> \(term)")
        }
        defaults.set(lines.joined(separator: "\n"), forKey: Keys.glossary)
    }

    static func removeGlossaryLine(_ line: String) {
        let lines = glossaryLines.filter { $0 != line }
        defaults.set(lines.joined(separator: "\n"), forKey: Keys.glossary)
    }
}
