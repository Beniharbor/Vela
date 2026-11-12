import Foundation
import os

/// Loading for the JSON-backed stores (history, voice notes, modes) that can
/// never silently erase data. A plain `try? decode` returns nothing on any
/// error — one bad record or a future schema change — and the store's next
/// save then overwrites the file with only the new item.
///
/// Here, records are decoded one by one (unreadable ones are skipped, not
/// fatal), and whenever anything couldn't be read the original bytes are
/// copied to `<name>.corrupt-<timestamp>.json` first. If even that backup
/// fails, `canSave` is false and the store must not write.
enum SafeStorage {
    private static let log = Logger(subsystem: "com.vela.app", category: "storage")

    struct Loaded<T> {
        var items: [T]
        /// False only when unreadable data exists and couldn't be backed up.
        var canSave: Bool
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vela", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func loadArray<T: Decodable>(_: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> Loaded<T> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Loaded(items: [], canSave: true)
        }
        guard let data = try? Data(contentsOf: url) else {
            // Exists but unreadable (permissions, I/O): never overwrite it.
            log.error("Couldn't read \(url.lastPathComponent, privacy: .public) — saving disabled to protect it")
            return Loaded(items: [], canSave: false)
        }
        let label = url.deletingPathExtension().lastPathComponent
        return loadArray(T.self, from: data, label: label, decoder: decoder)
    }

    /// Same, for data held elsewhere (e.g. UserDefaults). `label` names the backup file.
    static func loadArray<T: Decodable>(_: T.Type, from data: Data, label: String, decoder: JSONDecoder = JSONDecoder()) -> Loaded<T> {
        do {
            let decoded = try decoder.decode([Lossy<T>].self, from: data)
            let items = decoded.compactMap(\.value)
            if items.count < decoded.count {
                log.error("\(label, privacy: .public): \(decoded.count - items.count) of \(decoded.count) record(s) unreadable — skipped")
                return Loaded(items: items, canSave: backup(data, label: label))
            }
            return Loaded(items: items, canSave: true)
        } catch {
            log.error("\(label, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return Loaded(items: [], canSave: backup(data, label: label))
        }
    }

    /// Writes the original bytes next to the store. Returns true on success.
    private static func backup(_ data: Data, label: String) -> Bool {
        let formatter = DateFormatter()
        // POSIX locale: otherwise a 12-hour system clock yields "…-24958 PM".
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("\(label).corrupt-\(formatter.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
            log.notice("Backed up unreadable data to \(url.path, privacy: .public)")
            return true
        } catch {
            log.error("Backup of \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — saving disabled")
            return false
        }
    }
}

/// Decodes one array element, yielding nil instead of failing the whole array.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
