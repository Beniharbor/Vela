import Foundation

/// F12: deterministic filler cleanup applied to EVERY transcript, right after
/// Whisper — Flow has no LLM pass, and the LLM styles benefit from pre-cleaned
/// input. Deliberately conservative: only hesitation sounds that are never real
/// words ("like" / "you know" need context, which the LLM styles provide).
enum TranscriptFilter {
    /// Standalone hesitation sounds. Absorbs a preceding and/or trailing comma so
    /// "and, uh, bought" collapses to "and bought" rather than "and, bought".
    private static let fillers = #"(?i)(?:,\s*)?\b(?:u+m+|u+h+|e+r[rm]*m*|ehm|hm+)\b,?"#

    static func clean(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: fillers, with: "", options: .regularExpression)
        // Standalone dash tokens are Whisper artifacts, never dictated words:
        // silence and pause-seam hallucinations ("video. - - - - Okay") and
        // dialogue markers ("- It works"). Only bare "-" between spaces is
        // touched — hyphenated words and attached dashes ("5-10") survive.
        s = s.replacingOccurrences(of: #"(?:^|(?<=\s))-(?:\s+-)*(?=\s|$)"#, with: "", options: .regularExpression)
        // Whitespace the removals (or Whisper) left behind: space before
        // punctuation, orphaned ", ." pairs, double spaces.
        s = s.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,;:]\s*([,.!?;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        // A removed sentence-initial filler can orphan its punctuation ("Um. So" → ". So").
        s = s.replacingOccurrences(of: #"^\s*[,.!?;:]+\s*"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return applyingReplacements(capitalizeSentenceStarts(s))
    }

    /// F4: vocabulary rules ("Alphabet -> Alfavet"). Whole words only, any
    /// capitalization, flexible spacing for multi-word forms; possessives and
    /// plurals survive ("Alphabet's" → "Alfavet's").
    static func applyingReplacements(_ text: String, rules: [(from: String, to: String)] = AppSettings.replacementRules) -> String {
        var s = text
        for rule in rules {
            let words = rule.from.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = #"(?i)(?<![\p{L}\p{N}])"# + words.joined(separator: #"[\s-]+"#) + #"(?![\p{L}\p{N}])"#
            s = s.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: rule.to), options: .regularExpression)
        }
        return s
    }

    /// Dictation-only: turns spoken layout and punctuation commands into the
    /// real thing ("new line", "new paragraph", "comma", "question mark",
    /// "exclamation mark"; Spanish "nueva línea", "nuevo párrafo", "punto y
    /// aparte"). Deliberately leaves out words that are common in ordinary
    /// speech ("period", "colon", Spanish "coma") — Whisper already ends
    /// sentences on its own. Never applied to video / voice-note transcripts,
    /// where these are just words someone said.
    static func applyingSpokenCommands(_ text: String) -> String {
        var s = text
        // Commas Whisper put around the command go with it; a sentence end
        // before it ("item. New line.") is kept.
        let rules: [(pattern: String, replacement: String)] = [
            (#"(?i)[ \t,;]*\b(?:new|next) paragraph\b[ \t,.;:!?]*"#, "\n\n"),
            (#"(?i)[ \t,;]*\b(?:nuevo párrafo|nuevo parrafo|punto y aparte)\b[ \t,.;:!?]*"#, "\n\n"),
            (#"(?i)[ \t,;]*\b(?:new line|newline|next line|nueva línea|nueva linea)\b[ \t,.;:!?]*"#, "\n"),
            (#"(?i)[ \t,.?!]*\bquestion mark\b[ \t,.?!]*"#, "? "),
            (#"(?i)[ \t,.?!]*\bexclamation (?:mark|point)\b[ \t,.?!]*"#, "! "),
            (#"(?i)[ \t,]*\bcomma\b[ \t,]*"#, ", "),
        ]
        for rule in rules {
            s = s.replacingOccurrences(
                of: rule.pattern,
                with: NSRegularExpression.escapedTemplate(for: rule.replacement),
                options: .regularExpression
            )
        }
        guard s != text else { return text }
        // Tidy what the substitutions left: spaces hugging line breaks, a
        // dangling ", " or "? " at the very end, a comma opening the text.
        s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #",$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[ \t]*,[ \t]*"#, with: "", options: .regularExpression)
        // A new line or a "? " starts a new sentence.
        if let regex = try? NSRegularExpression(pattern: #"(?:^|\n|[?!] )(\p{Ll})"#) {
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: s) else { continue }
                s.replaceSubrange(range, with: s[range].uppercased())
            }
        }
        return s
    }

    /// "Send it" spoken as its own closing sentence means: paste, then press
    /// Return. Only matches at the very end and only after a sentence break,
    /// so "tell me when you send it" is left alone.
    static func extractingSendCommand(_ text: String) -> (text: String, send: Bool) {
        let pattern = #"(?i)(^|[.!?\n])\s*(?:send it|send message|envíalo|envialo|enviar mensaje)\s*[.!]*\s*$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return (text, false) }
        let stripped = text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        return (stripped.trimmingCharacters(in: .whitespaces), true)
    }

    /// Strips a voice stop-word (e.g. "watermelon") said to end dictation early,
    /// along with any trailing punctuation it picked up in the transcript. Only
    /// call this for takes actually ended by the stop-word — applying it to every
    /// transcript would mangle a real dictation that happens to end on that word.
    static func strippingTrailingStopWord(_ text: String, word: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = #"(?i)\s*\b"# + escaped + #"\b[.,!?;:]*\s*$"#
        let stripped = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removing a sentence-initial "Um, " exposes a lowercase word — fix those.
    private static func capitalizeSentenceStarts(_ text: String) -> String {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"(?:^|[.!?]\s+)(\p{Ll})"#)
        else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(range, with: result[range].uppercased())
        }
        return result
    }
}
