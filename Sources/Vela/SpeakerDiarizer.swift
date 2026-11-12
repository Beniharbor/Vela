import Foundation
import SpeakerKit
import WhisperKit
import os

/// One stretch of a conversation spoken by a single person.
struct ConversationTurn: Codable, Equatable, Hashable {
    /// 0-based, numbered by who speaks first (0 = first voice heard).
    let speaker: Int
    /// Seconds from the start of the recording.
    let start: TimeInterval
    let text: String
}

/// Voice Notes: splits a recording into "who said what" with on-device speaker
/// diarization (SpeakerKit / pyannote), then lines Whisper's word timings up
/// with the speaker timeline. Models download once (~tens of MB) and are
/// dropped from RAM straight after each file (G3).
actor SpeakerDiarizer {
    static let shared = SpeakerDiarizer()
    private let log = Logger(subsystem: "com.vela.app", category: "diarize")

    /// Returns conversation turns, or nil when only one voice was found (the
    /// note is then shown as plain text, exactly as before).
    func turns(
        samples: [Float],
        transcription: [TranscriptionResult],
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> [ConversationTurn]? {
        let kit = try await SpeakerKit(PyannoteConfig(verbose: false))
        defer { Task { await kit.unloadModels() } }

        let start = Date()
        let diarization = try await kit.diarize(audioArray: samples) { progress in
            onProgress(progress.fractionCompleted)
        }
        log.info("Diarized \(diarization.speakerCount) speaker(s) in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
        guard diarization.speakerCount >= 2 else { return nil }

        let words: [Word] = diarization.addSpeakerInfo(to: transcription, strategy: .subsegment)
            .flatMap { $0 }
            .flatMap(\.speakerWords)
            .map { Word(text: $0.wordTiming.word, start: $0.wordTiming.start, speaker: $0.speaker.speakerId) }
        return Self.buildTurns(from: words)
    }

    struct Word {
        let text: String
        let start: Float
        var speaker: Int?
    }

    private struct Run {
        var speaker: Int
        var start: Float
        var words: [String]
        var raw: String { words.joined() }
    }

    /// Groups speaker-tagged words into turns. Pure — kept static for testing.
    static func buildTurns(from input: [Word]) -> [ConversationTurn]? {
        // Words the diarizer couldn't place inherit the nearest known speaker.
        var words = input
        var last: Int? = words.first(where: { $0.speaker != nil })?.speaker
        guard last != nil else { return nil }
        for i in words.indices {
            if let s = words[i].speaker { last = s } else { words[i].speaker = last }
        }

        var runs: [Run] = []
        for w in words {
            let speaker = w.speaker!
            if var tail = runs.last, tail.speaker == speaker {
                tail.words.append(w.text)
                runs[runs.count - 1] = tail
            } else {
                runs.append(Run(speaker: speaker, start: w.start, words: [w.text]))
            }
        }

        // Smooth out blips: a 1–2 word run wedged mid-sentence between two runs
        // of the same other speaker is almost always a diarization flicker (or
        // an overlapping "mm-hm"), not a real turn. A short reply after a
        // finished sentence ("Yeah.") is kept.
        var changed = true
        while changed {
            changed = false
            var i = 1
            while i < runs.count - 1 {
                let prev = runs[i - 1], cur = runs[i], next = runs[i + 1]
                let midSentence = !prev.raw.trimmingCharacters(in: .whitespaces)
                    .hasSuffix(where: { ".?!".contains($0) })
                if cur.words.count <= 2, prev.speaker == next.speaker, midSentence {
                    runs[i - 1].words += cur.words + next.words
                    runs.removeSubrange(i...(i + 1))
                    changed = true
                } else {
                    i += 1
                }
            }
        }

        // Number speakers by first appearance so "Speaker 1" talks first.
        var order: [Int: Int] = [:]
        var turns: [ConversationTurn] = []
        for run in runs {
            let text = TranscriptFilter.clean(
                run.raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            )
            guard !text.isEmpty else { continue }
            let speaker = order[run.speaker] ?? {
                let n = order.count
                order[run.speaker] = n
                return n
            }()
            if let tail = turns.last, tail.speaker == speaker {
                // Merging can re-join a speaker split by a now-empty run.
                turns[turns.count - 1] = ConversationTurn(speaker: speaker, start: tail.start, text: tail.text + " " + text)
            } else {
                turns.append(ConversationTurn(speaker: speaker, start: TimeInterval(run.start), text: text))
            }
        }
        return order.count >= 2 ? turns : nil
    }
}

private extension String {
    func hasSuffix(where predicate: (Character) -> Bool) -> Bool {
        guard let c = last else { return false }
        return predicate(c)
    }
}
