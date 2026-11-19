import Foundation
import NaturalLanguage

/// Breaks a long monologue into readable paragraphs at display/copy time.
/// Stored transcripts stay untouched, so this applies to old notes too.
enum Paragraphs {
    /// Paragraph can close at a topic-shift word once it has this many words…
    private static let softLimit = 40
    /// …and closes at the next sentence end regardless once it has this many.
    private static let hardLimit = 80
    /// A last paragraph shorter than this is folded into the one before it.
    private static let minTail = 12

    /// Openers that usually start a new thought when someone talks.
    private static let markers: [String] = [
        "so", "but", "however", "also", "anyway", "anyways", "now", "okay", "ok",
        "and then", "then", "the difference", "the other thing", "another thing",
        "one thing", "first", "second", "third", "finally", "look", "listen",
        "basically", "in the end", "on the other hand", "although", "plus",
        "entonces", "pero", "bueno", "además", "también", "otra cosa", "mira",
        "oye", "por otro lado", "y luego", "al final", "o sea", "la diferencia",
    ]

    private static let cache = NSCache<NSString, NSString>()

    /// The text with blank lines between paragraphs.
    static func format(_ text: String) -> String {
        if let hit = cache.object(forKey: text as NSString) { return hit as String }
        let result = split(text).joined(separator: "\n\n")
        cache.setObject(result as NSString, forKey: text as NSString)
        return result
    }

    static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .flatMap { splitBlock($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
    }

    private static func splitBlock(_ block: String) -> [String] {
        guard wordCount(block) > hardLimit else { return [block] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = block
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: block.startIndex..<block.endIndex) { range, _ in
            let s = block[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }

        var paragraphs: [[String]] = [[]]
        var words = 0
        for sentence in sentences {
            let breakHere = words >= hardLimit || (words >= softLimit && startsWithMarker(sentence))
            if breakHere {
                paragraphs.append([])
                words = 0
            }
            paragraphs[paragraphs.count - 1].append(sentence)
            words += wordCount(sentence)
        }
        if paragraphs.count > 1, words < minTail {
            let tail = paragraphs.removeLast()
            paragraphs[paragraphs.count - 1] += tail
        }
        return paragraphs.map { $0.joined(separator: " ") }
    }

    private static func startsWithMarker(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        return markers.contains { marker in
            guard lower.hasPrefix(marker) else { return false }
            let next = lower.dropFirst(marker.count).first
            return next == nil || !(next!.isLetter || next!.isNumber)
        }
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: \.isWhitespace).count
    }
}

extension SpeakerDiarizer {
    /// Diarization sometimes splits one person into two — a change of tone or
    /// distance from the mic near the end of a voice note reads as a "new
    /// voice". A speaker who appears in just one turn and says under a quarter
    /// of the words is folded into the speaker next to them. Returns nil when
    /// only one voice is left (shown as plain text).
    static func collapsingFalseSpeakers(_ input: [ConversationTurn]) -> [ConversationTurn]? {
        var turns = input
        while true {
            var words: [Int: Int] = [:]
            var turnCount: [Int: Int] = [:]
            for t in turns {
                words[t.speaker, default: 0] += t.text.split(whereSeparator: \.isWhitespace).count
                turnCount[t.speaker, default: 0] += 1
            }
            guard words.count >= 2 else { break }
            let total = words.values.reduce(0, +)
            let dominant = words.max { $0.value < $1.value }!.key
            guard let stray = words
                .filter({ $0.key != dominant && turnCount[$0.key] == 1 && Double($0.value) < Double(total) * 0.25 })
                .min(by: { $0.value < $1.value })?.key,
                  let index = turns.firstIndex(where: { $0.speaker == stray })
            else { break }

            let neighbour = index > 0 ? turns[index - 1].speaker : turns[index + 1].speaker
            turns[index] = ConversationTurn(speaker: neighbour, start: turns[index].start, text: turns[index].text)

            var merged: [ConversationTurn] = []
            for t in turns {
                if let last = merged.last, last.speaker == t.speaker {
                    merged[merged.count - 1] = ConversationTurn(speaker: last.speaker, start: last.start, text: last.text + " " + t.text)
                } else {
                    merged.append(t)
                }
            }
            turns = merged
        }

        // Renumber by first appearance so "Speaker 1" still talks first.
        var order: [Int: Int] = [:]
        turns = turns.map { t in
            let n = order[t.speaker] ?? { let n = order.count; order[t.speaker] = n; return n }()
            return ConversationTurn(speaker: n, start: t.start, text: t.text)
        }
        return order.count >= 2 && turns.count > 1 ? turns : nil
    }
}
