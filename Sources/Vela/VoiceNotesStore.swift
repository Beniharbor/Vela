import Foundation
import os

/// One transcribed voice note, as shown in the Voice Notes tab.
struct VoiceNoteRecord: Codable, Identifiable, Equatable {
    let id: UUID
    /// Original file name, e.g. "WhatsApp Audio 2026-07-17 at 09.12.44.ogg".
    let fileName: String
    /// When the file was imported (not when the voice note was recorded).
    let date: Date
    /// Audio length in seconds.
    let duration: TimeInterval
    var words: Int
    /// The plain transcript — always present, the "one block" view.
    var text: String
    /// Who-said-what, when two or more voices were detected. nil for
    /// single-speaker files and notes imported before speaker detection.
    var turns: [ConversationTurn]? = nil
    /// User-given names, indexed by speaker number; missing/empty → "Speaker N".
    var speakerNames: [String]? = nil

    var isConversation: Bool { (turns?.count ?? 0) > 1 }

    func speakerName(_ speaker: Int) -> String {
        if let names = speakerNames, speaker < names.count {
            let name = names[speaker].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return "Speaker \(speaker + 1)"
    }

    /// "Name: …" lines, one per turn, for pasting elsewhere.
    var conversationText: String {
        guard let turns, isConversation else { return text }
        return turns.map { "\(speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n\n")
    }

    func exportText(asConversation: Bool) -> String {
        asConversation ? conversationText : text
    }

    /// First few words of the transcript, used as the row title.
    var title: String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6)
        var title = words.joined(separator: " ")
        while title.hasSuffix(".") || title.hasSuffix(",") || title.hasSuffix(":") {
            title.removeLast()
        }
        return title.isEmpty ? "Untitled" : title
    }
}

/// Imports audio files (WhatsApp voice notes), transcribes them sequentially,
/// and persists the results as JSON in ~/Library/Application Support/Vela/.
@MainActor
final class VoiceNotesStore: ObservableObject {
    static let shared = VoiceNotesStore()

    /// Finished transcriptions, newest first.
    @Published private(set) var notes: [VoiceNoteRecord] = []
    /// Files queued or in flight, in import order.
    @Published private(set) var pending: [PendingVoiceNote] = []
    /// False when voice-notes.json is unreadable and couldn't be backed up — see SafeStorage.
    private var canSave = true

    struct PendingVoiceNote: Identifiable, Equatable {
        let id: UUID
        let fileName: String
        var phase: String
        /// 0–1 while transcribing; nil when indeterminate.
        var fraction: Double?
        var failed = false
    }

    private var queue: [(id: UUID, url: URL)] = []
    private var working = false
    private let log = Logger(subsystem: "com.vela.app", category: "voicenotes")

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vela", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("voice-notes.json")
    }()

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = SafeStorage.loadArray(VoiceNoteRecord.self, from: fileURL, decoder: decoder)
        notes = loaded.items
        canSave = loaded.canSave
    }

    // MARK: Import pipeline

    func importFiles(_ urls: [URL]) {
        for url in urls {
            guard AudioFileImporter.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                let id = UUID()
                pending.append(PendingVoiceNote(
                    id: id,
                    fileName: url.lastPathComponent,
                    phase: "Unsupported file type",
                    fraction: nil,
                    failed: true
                ))
                continue
            }
            let id = UUID()
            pending.append(PendingVoiceNote(id: id, fileName: url.lastPathComponent, phase: "Waiting…", fraction: nil))
            queue.append((id, url))
        }
        processNext()
    }

    private func processNext() {
        guard !working, let job = queue.first else { return }
        queue.removeFirst()
        working = true
        update(job.id, phase: "Reading file…", fraction: nil)

        Task {
            do {
                // Decode off the main thread — multi-minute files take a moment.
                let url = job.url
                let didScope = url.startAccessingSecurityScopedResource()
                let samples = try await Task.detached(priority: .userInitiated) {
                    try AudioFileImporter.load(url: url)
                }.value
                if didScope { url.stopAccessingSecurityScopedResource() }

                let duration = Double(samples.count) / AudioRecorder.targetSampleRate
                guard duration > 0.3 else {
                    throw VelaError.audio("File is too short to transcribe")
                }

                // Always auto-detect, ignoring the Languages setting: voice
                // notes are often Spanglish, and forcing one language turns the
                // other into gibberish. Detection is per ~30 s window, so mixed
                // notes come out in whichever language each stretch was spoken.
                let stt = try await Transcriber.shared.transcribe(
                    samples: samples,
                    // No glossary prompt: on long audio it blanks out whole
                    // windows. Vocabulary replacement rules still apply below.
                    glossaryTerms: [],
                    languageOverride: "auto",
                    wordTimestamps: true
                ) { phase, fraction in
                    Task { @MainActor in
                        self.update(job.id, phase: "\(phase)…", fraction: fraction)
                    }
                }
                let text = TranscriptFilter.clean(stt.text)
                guard !text.isEmpty else {
                    throw VelaError.transcription("No speech recognized in this file")
                }

                // Best-effort: if speaker detection fails (e.g. first-run model
                // download offline), keep the plain transcript rather than lose it.
                self.update(job.id, phase: "Identifying speakers…", fraction: nil)
                var turns: [ConversationTurn]?
                do {
                    turns = try await SpeakerDiarizer.shared.turns(
                        samples: samples,
                        transcription: stt.results
                    ) { fraction in
                        Task { @MainActor in
                            self.update(job.id, phase: "Identifying speakers…", fraction: fraction)
                        }
                    }
                } catch {
                    self.log.error("Speaker detection failed for \(job.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }

                // Fresh UUID, never job.id: the pending row (keyed by job.id)
                // leaves one ForEach as this record enters another in the same
                // update — a shared id corrupts LazyVStack's diff and the list
                // silently stops re-rendering (rows freeze at their last state).
                let record = VoiceNoteRecord(
                    id: UUID(),
                    fileName: job.url.lastPathComponent,
                    date: Date(),
                    duration: duration,
                    words: text.split(whereSeparator: \.isWhitespace).count,
                    text: text,
                    turns: turns
                )
                self.pending.removeAll { $0.id == job.id }
                self.notes.insert(record, at: 0)
                self.save()
                self.log.info("Transcribed \(job.url.lastPathComponent, privacy: .public): \(record.words) words from \(duration, format: .fixed(precision: 1))s")
            } catch {
                self.log.error("Import failed for \(job.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if let index = self.pending.firstIndex(where: { $0.id == job.id }) {
                    self.pending[index].phase = error.localizedDescription
                    self.pending[index].fraction = nil
                    self.pending[index].failed = true
                }
            }
            self.working = false
            self.processNext()
        }
    }

    private func update(_ id: UUID, phase: String, fraction: Double?) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].phase = phase
        pending[index].fraction = fraction
    }

    /// Removes a failed row from the pending list.
    func dismiss(_ item: PendingVoiceNote) {
        pending.removeAll { $0.id == item.id }
    }

    func delete(_ record: VoiceNoteRecord) {
        notes.removeAll { $0.id == record.id }
        save()
    }

    /// Applies the vocabulary's replacement rules ("Alphabet -> Alfavet") to
    /// notes already transcribed. Returns how many notes changed.
    @discardableResult
    func applyVocabularyToExistingNotes() -> Int {
        let rules = AppSettings.replacementRules
        guard !rules.isEmpty else { return 0 }
        var changed = 0
        for index in notes.indices {
            var note = notes[index]
            note.text = TranscriptFilter.applyingReplacements(note.text, rules: rules)
            note.turns = note.turns?.map {
                ConversationTurn(speaker: $0.speaker, start: $0.start,
                                 text: TranscriptFilter.applyingReplacements($0.text, rules: rules))
            }
            note.words = note.text.split(whereSeparator: \.isWhitespace).count
            if note != notes[index] {
                notes[index] = note
                changed += 1
            }
        }
        if changed > 0 { save() }
        log.info("Vocabulary re-applied: \(changed) note(s) updated")
        return changed
    }

    func renameSpeaker(_ speaker: Int, in note: VoiceNoteRecord, to name: String) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var names = notes[index].speakerNames ?? []
        while names.count <= speaker { names.append("") }
        names[speaker] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[index].speakerNames = names
        save()
    }

    /// All transcripts, oldest first, formatted for pasting into Claude.
    func combinedTranscripts(asConversation: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return notes.reversed().enumerated().map { index, note in
            let total = Int(note.duration.rounded())
            let length = "\(total / 60):" + String(format: "%02d", total % 60)
            return "Voice note \(index + 1) — \(formatter.string(from: note.date)) (\(length)):\n\(note.exportText(asConversation: asConversation))"
        }
        .joined(separator: "\n\n")
    }

    private func save() {
        guard canSave else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(notes) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
