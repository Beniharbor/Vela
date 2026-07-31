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
        return capitalizeSentenceStarts(s)
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
