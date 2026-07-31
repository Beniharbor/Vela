import Foundation

/// One completed dictation, as shown in the Dashboard history table.
struct TranscriptionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    /// Recording length in seconds.
    let duration: TimeInterval
    let words: Int
    /// Uppercased ISO code for the badge, e.g. "EN", "ES".
    let language: String
    let text: String

    /// First few words of the transcript, used as the row title.
    var title: String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(5)
        var title = words.joined(separator: " ")
        while title.hasSuffix(".") || title.hasSuffix(",") || title.hasSuffix(":") {
            title.removeLast()
        }
        return title.isEmpty ? "Untitled" : title
    }
}

/// Persists dictation history as JSON in ~/Library/Application Support/Vela/.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var records: [TranscriptionRecord] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vela", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }()

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? decoder.decode([TranscriptionRecord].self, from: data) {
            records = loaded
        }
    }

    func add(text: String, duration: TimeInterval, language: String) {
        let record = TranscriptionRecord(
            id: UUID(),
            date: Date(),
            duration: duration,
            words: text.split(whereSeparator: \.isWhitespace).count,
            language: language.uppercased(),
            text: text
        )
        records.append(record)
        save()
    }

    func delete(_ record: TranscriptionRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    var totalWords: Int { records.reduce(0) { $0 + $1.words } }

    /// (sessions, minutes) over the trailing 7 days — the sidebar footer.
    var thisWeek: (sessions: Int, minutes: Int) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let recent = records.filter { $0.date > cutoff }
        let minutes = Int((recent.reduce(0) { $0 + $1.duration } / 60).rounded())
        return (recent.count, minutes)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Decoding must match; set it once here so init and save can't drift.
        if let data = try? encoder.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
