import SwiftUI

// MARK: - Store

/// One video an agent (OpenBot, …) asked Vela to transcribe through the local API.
struct AgentTranscript: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case working, done, failed }

    let id: UUID
    let date: Date
    /// The link (or file path) the agent sent.
    let source: String
    var title: String?
    var language: String?
    var duration: TimeInterval?
    var text: String
    var status: Status
    /// Live phase while working ("Downloading…"), error message when failed.
    var detail: String?
    var fraction: Double?

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return sourceLabel
    }

    /// "YouTube", "Instagram", "tiktok.com", or the file name.
    var sourceLabel: String {
        guard let url = URL(string: source), let host = url.host?.lowercased() else {
            return (source as NSString).lastPathComponent
        }
        if host.contains("youtube.") || host == "youtu.be" { return "YouTube" }
        if host.contains("instagram.") { return "Instagram" }
        if host.contains("tiktok.") { return "TikTok" }
        if host == "x.com" || host.contains("twitter.") { return "X" }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    var isLink: Bool { source.hasPrefix("http://") || source.hasPrefix("https://") }
}

/// Persists agent transcripts to ~/Library/Application Support/Vela/agent-transcripts.json.
@MainActor
final class AgentTranscriptsStore: ObservableObject {
    static let shared = AgentTranscriptsStore()

    /// Newest first.
    @Published private(set) var items: [AgentTranscript] = []
    private var canSave = true
    private let fileURL = SafeStorage.directory.appendingPathComponent("agent-transcripts.json")

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = SafeStorage.loadArray(AgentTranscript.self, from: fileURL, decoder: decoder)
        canSave = loaded.canSave
        // A job still "working" on disk means Vela quit mid-transcription.
        items = loaded.items.map { item in
            guard item.status == .working else { return item }
            var item = item
            item.status = .failed
            item.detail = "Interrupted (Vela quit before it finished)"
            item.fraction = nil
            return item
        }
    }

    func begin(source: String) -> UUID {
        let item = AgentTranscript(
            id: UUID(), date: Date(), source: source,
            text: "", status: .working, detail: "Waiting in line…"
        )
        items.insert(item, at: 0)
        save()
        return item.id
    }

    /// Live progress — not saved to disk on every tick.
    func progress(_ id: UUID, detail: String, fraction: Double? = nil, title: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].detail = detail
        items[index].fraction = fraction
        if let title { items[index].title = title }
    }

    func finish(_ id: UUID, title: String?, language: String, duration: TimeInterval, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].title = title ?? items[index].title
        items[index].language = language
        items[index].duration = duration
        items[index].text = text
        items[index].status = .done
        items[index].detail = text.isEmpty ? "No speech detected" : nil
        items[index].fraction = nil
        save()
    }

    func fail(_ id: UUID, error: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .failed
        items[index].detail = error
        items[index].fraction = nil
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard canSave else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Pane

struct AgentTranscriptsPane: View {
    @ObservedObject private var store = AgentTranscriptsStore.shared
    @State private var expandedID: UUID?
    @State private var copiedID: UUID?
    @State private var query = ""

    private var isSearching: Bool { !SearchMatch.terms(query).isEmpty }

    private var visible: [AgentTranscript] {
        guard isSearching else { return store.items }
        return store.items.filter {
            SearchMatch.matches($0.displayTitle + " " + $0.source + " " + $0.text, query: query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(
                title: "Agent Transcripts",
                subtitle: "Videos and reels OpenBot sent Vela to transcribe"
            ) {
                if !store.items.isEmpty {
                    SearchField(placeholder: "Search transcripts", text: $query)
                }
            }
            if store.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if visible.isEmpty {
                            Text("No transcripts match “\(query)”")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.velaMuted)
                                .padding(.top, 40)
                        }
                        ForEach(visible) { item in
                            AgentTranscriptRow(
                                item: item,
                                query: query,
                                isExpanded: expandedID == item.id || (isSearching && item.status == .done),
                                justCopied: copiedID == item.id,
                                toggle: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        expandedID = expandedID == item.id ? nil : item.id
                                    }
                                },
                                copy: { copy(item) },
                                delete: { store.delete(item.id) }
                            )
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.velaFaint)
            Text("Nothing yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.velaInk)
            Text("When OpenBot sends a YouTube video or reel to Vela,\nit shows up here as it's transcribed.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.velaMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func copy(_ item: AgentTranscript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        copiedID = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == item.id { copiedID = nil }
        }
    }
}

private struct AgentTranscriptRow: View {
    let item: AgentTranscript
    let query: String
    let isExpanded: Bool
    let justCopied: Bool
    let toggle: () -> Void
    let copy: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private var metaLine: String {
        var parts = [item.sourceLabel, Self.dateFormatter.string(from: item.date)]
        if let duration = item.duration {
            let total = Int(duration.rounded())
            parts.append("\(total / 60):" + String(format: "%02d", total % 60))
        }
        if item.status == .done {
            parts.append("\(item.text.split(whereSeparator: \.isWhitespace).count) words")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded, item.status == .done {
                VStack(alignment: .leading, spacing: 10) {
                    if item.isLink, let url = URL(string: item.source) {
                        Link(destination: url) {
                            Label(item.source, systemImage: "arrow.up.right.square")
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(Color.velaAccent)
                    }
                    Text(item.text.isEmpty ? "No speech detected (music-only or silent video)." : SearchMatch.highlighted(item.text, query: query))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.velaBody)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(EdgeInsets(top: 0, leading: 20, bottom: 14, trailing: 20))
            }
        }
        .background(isExpanded ? Color.velaHeaderBg : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.velaRowBorder).frame(height: 1)
        }
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.velaInk)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.status == .failed ? Color.orange : Color.velaMuted)
                    .lineLimit(1)
            }
            Spacer()
            if item.status == .working, let fraction = item.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            }
            if let language = item.language, item.status == .done {
                Text(language.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.velaBadgeText)
                    .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.velaSelection))
            }
            if item.status != .working {
                if hovering {
                    iconButton("trash", help: "Delete", action: delete)
                }
                if item.status == .done, !item.text.isEmpty {
                    iconButton(justCopied ? "checkmark" : "doc.on.doc", help: "Copy transcript", action: copy)
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
        .contentShape(Rectangle())
        .onTapGesture { if item.status == .done { toggle() } }
    }

    private var subtitle: String {
        switch item.status {
        case .done: return item.detail.map { metaLine + " · " + $0 } ?? metaLine
        case .failed: return "Failed: " + (item.detail ?? "unknown error")
        case .working:
            let phase = item.detail ?? "Working…"
            if let fraction = item.fraction, fraction > 0 { return "\(phase) \(Int(fraction * 100))%" }
            return phase
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .working: ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14)).foregroundStyle(.orange)
        case .done:
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 14)).foregroundStyle(Color.velaAccent.opacity(0.8))
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.velaBody)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
