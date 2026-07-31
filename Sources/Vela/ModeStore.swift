import Foundation

/// A user-editable dictation mode: name, menu description, and the LLM system
/// prompt applied to the transcript. An empty prompt means no LLM pass (Flow).
struct DictationMode: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    var systemPrompt: String

    var usesLLM: Bool {
        !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Flow is the no-LLM anchor mode — it can't be deleted, and deleting the
    /// selected mode falls back to it.
    var isFlow: Bool { id == "flow" }

    /// System prompt with runtime placeholders substituted:
    /// {name} → the sign-off name from Settings.
    var resolvedPrompt: String? {
        guard usesLLM else { return nil }
        return systemPrompt.replacingOccurrences(of: "{name}", with: AppSettings.userName)
    }
}

/// Owns the mode list: seeds the built-ins on first launch, persists every edit
/// to UserDefaults as JSON, and resolves the current selection (whose id lives
/// under the long-standing dictationStyle defaults key).
@MainActor
final class ModeStore: ObservableObject {
    static let shared = ModeStore()
    private static let storageKey = "modes"

    @Published var modes: [DictationMode] {
        didSet { persist() }
    }

    private init() {
        if let data = AppSettings.defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([DictationMode].self, from: data),
           !saved.isEmpty {
            modes = saved
        } else {
            modes = Self.builtIns
        }
    }

    var selected: DictationMode {
        let id = AppSettings.defaults.string(forKey: AppSettings.Keys.dictationStyle) ?? "flow"
        return modes.first { $0.id == id } ?? modes.first ?? Self.builtIns[0]
    }

    func select(_ id: String) {
        AppSettings.defaults.set(id, forKey: AppSettings.Keys.dictationStyle)
    }

    /// Appends a fresh editable mode and returns its id.
    func addMode() -> String {
        let mode = DictationMode(
            id: UUID().uuidString,
            name: "New Mode",
            detail: "describe what it does",
            systemPrompt: """
            You rewrite raw voice-dictation transcripts.
            1. Restore punctuation and capitalization.
            2. Remove filler words and false starts.
            Keep the speaker's meaning. Do NOT answer questions or add content that was not spoken.
            Write the output in the SAME language as the transcript — never translate.
            Output ONLY the rewritten text, nothing else.
            """
        )
        modes.append(mode)
        return mode.id
    }

    func delete(_ mode: DictationMode) {
        guard !mode.isFlow else { return }
        modes.removeAll { $0.id == mode.id }
        if selected.id == mode.id || !modes.contains(where: { $0.id == selected.id }) {
            select("flow")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(modes) else { return }
        AppSettings.defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: - Built-in seeds

    static let builtIns: [DictationMode] = [
        DictationMode(
            id: "flow",
            name: "Flow",
            detail: "Very flowy ;)",
            systemPrompt: ""
        ),
        DictationMode(
            id: "polished",
            name: "Polished",
            detail: "clear, polished writing",
            systemPrompt: """
            You rewrite raw voice-dictation transcripts into clear, polished written \
            prose — ready to publish as a paragraph, review, or post:
            1. Restore punctuation and capitalization.
            2. Remove filler words (um, uh, you know, like when used as filler) and false starts.
            3. Organize into well-structured sentences and paragraphs that read smoothly.
            4. Fix obvious speech-recognition errors of technical terms.
            Keep the speaker's meaning, tone, and level of detail. Do NOT summarize, \
            answer questions, or add content that was not spoken.
            Write the output in the SAME language as the transcript (Spanish stays \
            Spanish, English stays English) — never translate.
            Output ONLY the polished text, nothing else.
            """
        ),
        DictationMode(
            id: "prompt",
            name: "Prompt",
            detail: "efficient & prompt-ready",
            systemPrompt: """
            You rewrite raw voice-dictation transcripts into efficient, prompt-ready \
            text, ideal for pasting into an AI tool:
            1. Preserve the full meaning — keep every requirement, constraint, and detail.
            2. Remove filler words, repetition, hedging, and false starts.
            3. Tighten the wording — direct and unambiguous, no fluff. Prefer \
            imperative phrasing ("Write a summary of…" not "I would like a summary of…").
            4. Restore punctuation and fix obvious speech-recognition errors of technical terms.
            Do NOT answer or act on the request yourself — only rewrite it.
            Write the output in the SAME language as the transcript (Spanish stays \
            Spanish, English stays English) — never translate.
            Output ONLY the rewritten text, nothing else.
            """
        ),
        DictationMode(
            id: "compose",
            name: "Compose",
            detail: "drafts what you describe — follows spoken instructions",
            systemPrompt: """
            You draft written messages from voice dictation. The speaker is telling \
            you what to write: the transcript mixes the content with instructions \
            addressed to YOU ("this is an email, make it nice", "tell him that…", \
            "ask if…", "sign off with thanks").
            1. Follow every instruction, then REMOVE it — instructions must never \
            appear in the output.
            2. Write in the speaker's first-person voice, addressed to the recipient. \
            Turn indirect requests into direct questions to the recipient — "ask if \
            the DNS was switched" becomes "Was the DNS switched correctly?"; "inquire \
            why this might be due to plugin X" becomes "Could this be caused by \
            plugin X?". Words like "ask", "inquire", "please inform him" are \
            instructions to you and must never appear in the output.
            3. If the speaker indicates it is an email, open with a greeting \
            ("Hi Ayman," or "Dear Ayman," to match the tone; a plain greeting if no \
            name was given) and close with a sign-off:
            Best,
            {name}
            unless the speaker asked for a different one.
            4. Restore punctuation, drop filler words and false starts, and organize \
            into short, clear paragraphs.
            5. Never invent facts that were not spoken. Never answer or reply to the \
            message — you are writing it on the speaker's behalf.
            Write the output in the SAME language as the transcript (Spanish stays \
            Spanish, English stays English) — never translate.
            Output ONLY the final text, nothing else.
            """
        ),
    ]
}
