import Foundation

/// How the transcript is treated before insertion — selectable from the dropdown in
/// the recording HUD, the menu bar, or Settings.
enum DictationStyle: String, CaseIterable, Identifiable {
    /// Verbatim: exactly what was said. No LLM pass — lightest (G3 default).
    case flow
    /// Written prose ready for an email/message: punctuation, fillers out, paragraphs.
    case structured
    /// Tightest form: rewritten as simply and efficiently as possible, same meaning.
    case clean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flow: return "Flow"
        case .structured: return "Structured"
        case .clean: return "Clean"
        }
    }

    var menuDescription: String {
        switch self {
        case .flow: return "exactly as you say it"
        case .structured: return "formatted like an email"
        case .clean: return "as simple & efficient as possible"
        }
    }

    /// Flow skips the LLM stage entirely.
    var usesLLM: Bool { self != .flow }

    /// System prompt for the Ollama pass (nil for .flow).
    var systemPrompt: String? {
        switch self {
        case .flow:
            return nil
        case .structured:
            return """
            You format raw voice-dictation transcripts into polished written text, \
            ready to paste into an email or message:
            1. Restore punctuation and capitalization.
            2. Remove filler words (um, uh, you know, like when used as filler) and false starts.
            3. Organize into clear sentences and paragraphs.
            4. Fix obvious speech-recognition errors of technical terms.
            Keep the speaker's meaning, tone, and level of detail. Do NOT summarize, \
            answer questions, or add content that was not spoken.
            Write the output in the SAME language as the transcript (Spanish stays \
            Spanish, English stays English) — never translate.
            Output ONLY the formatted text, nothing else.
            """
        case .clean:
            return """
            You rewrite raw voice-dictation transcripts to be as simple and efficient \
            as possible:
            1. Preserve the full meaning and intent.
            2. Remove filler words, repetition, hedging, and false starts.
            3. Tighten the wording — shorter and clearer is better.
            4. Restore punctuation and fix obvious speech-recognition errors of technical terms.
            Do NOT answer questions or add content that was not spoken.
            Write the output in the SAME language as the transcript (Spanish stays \
            Spanish, English stays English) — never translate.
            Output ONLY the rewritten text, nothing else.
            """
        }
    }
}
