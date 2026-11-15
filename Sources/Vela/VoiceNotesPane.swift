import SwiftUI
import UniformTypeIdentifiers

/// Voice Notes tab: drop WhatsApp audio files (or browse), get English
/// transcripts to paste into Claude. Uses the palette and PaneToolbar from
/// DashboardView.swift.
struct VoiceNotesPane: View {
    @ObservedObject private var store = VoiceNotesStore.shared
    @State private var dropTargeted = false
    @State private var expandedID: UUID?
    /// Row whose Copy button just fired — flashes a checkmark.
    @State private var copiedID: UUID?
    @State private var copiedAll = false
    /// Conversation (who-said-what) vs. one plain block; copy follows
    /// whichever view is showing.
    /// Every note opens in Conversation view; Plain text is a per-viewing switch.
    @State private var conversationView = true
    @State private var query = ""
    /// Turn (or plain block) just scrolled to — briefly tinted so the eye lands on it.
    @State private var flashAnchor: String?

    private var isSearching: Bool { !SearchMatch.terms(query).isEmpty }

    private var visibleNotes: [VoiceNoteRecord] {
        guard isSearching else { return store.notes }
        return store.notes.filter {
            SearchMatch.matches($0.title + " " + $0.exportText(asConversation: true) + " " + $0.fileName, query: query)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(
                title: "Voice Notes",
                subtitle: "Drop WhatsApp audio — transcribed on-device, exactly as spoken"
            ) {
                if !store.notes.isEmpty {
                    SearchField(placeholder: "Search voice notes", text: $query)
                    copyAllButton
                }
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // While searching, show just the results.
                    if !isSearching {
                        VocabularyCard()
                            .padding(EdgeInsets(top: 16, leading: 20, bottom: 0, trailing: 20))
                        dropZone
                            .padding(EdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20))
                        ForEach(store.pending) { item in
                            PendingRow(item: item) { store.dismiss(item) }
                        }
                    } else if visibleNotes.isEmpty {
                        Text("No voice notes match your search.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.velaFaint)
                            .padding(48)
                    }
                    ForEach(visibleNotes) { note in
                        NoteRow(
                            note: note,
                            dateLabel: Self.dateFormatter.string(from: note.date),
                            query: query,
                            flashAnchor: flashAnchor,
                            isExpanded: expandedID == note.id,
                            justCopied: copiedID == note.id,
                            conversationView: $conversationView,
                            toggle: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if expandedID == note.id {
                                        expandedID = nil
                                    } else {
                                        expandedID = note.id
                                        conversationView = true
                                    }
                                }
                            },
                            copy: { copy(note) },
                            delete: { store.delete(note) },
                            rename: { speaker, name in store.renameSpeaker(speaker, in: note, to: name) }
                        )
                    }
                }
                .padding(.bottom, 16)
            }
            .onChange(of: query) { _, _ in scrollToFirstMatch(proxy) }
            .onChange(of: expandedID) { _, _ in scrollToFirstMatch(proxy) }
            .onChange(of: conversationView) { _, _ in scrollToFirstMatch(proxy) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importFiles(urls)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
    }

    // MARK: Search

    /// With a note open and a search active, bring the first hit into view —
    /// in a long conversation it's usually far below the fold.
    private func scrollToFirstMatch(_ proxy: ScrollViewProxy) {
        guard isSearching, let id = expandedID,
              let note = visibleNotes.first(where: { $0.id == id }),
              let target = firstMatchAnchor(in: note)
        else { return }
        // Let the expand / view switch lay out before scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .center)
            }
            withAnimation(.easeIn(duration: 0.15)) { flashAnchor = target }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                guard flashAnchor == target else { return }
                withAnimation(.easeOut(duration: 0.6)) { flashAnchor = nil }
            }
        }
    }

    private func firstMatchAnchor(in note: VoiceNoteRecord) -> String? {
        let terms = SearchMatch.terms(query)
        let hits: (String) -> Bool = { text in terms.contains { SearchMatch.matches(text, query: $0) } }
        if note.isConversation, conversationView, let turns = note.turns {
            guard let index = turns.firstIndex(where: { hits($0.text) }) else { return nil }
            return ConversationBody.anchor(note: note, turn: index)
        }
        return hits(note.text) ? "\(note.id)-plain" : nil
    }

    // MARK: Actions

    private func copy(_ note: VoiceNoteRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.exportText(asConversation: conversationView), forType: .string)
        copiedID = note.id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == note.id { copiedID = nil }
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.combinedTranscripts(asConversation: conversationView), forType: .string)
        copiedAll = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copiedAll = false
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AudioFileImporter.supportedExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose audio files to transcribe"
        panel.prompt = "Transcribe"
        if panel.runModal() == .OK {
            store.importFiles(panel.urls)
        }
    }

    // MARK: Pieces

    private var copyAllButton: some View {
        Button(action: copyAll) {
            Label(copiedAll ? "Copied" : "Copy All for Claude",
                  systemImage: copiedAll ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.velaAccent)
                .padding(EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11))
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.velaAccent.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(conversationView
              ? "Copy every transcript, oldest first, with speaker names"
              : "Copy every transcript, oldest first, as plain text")
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(dropTargeted ? Color.velaAccent : Color.velaFaint)
            Text(dropTargeted ? "Release to transcribe" : "Drop WhatsApp voice notes here")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(dropTargeted ? Color.velaAccentDeep : Color.velaInk)
            Text(".ogg, .opus, .m4a, .mp3, .wav — or click to browse")
                .font(.system(size: 12))
                .foregroundStyle(Color.velaMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(dropTargeted ? Color.velaSelection : Color.velaHeaderBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    dropTargeted ? Color.velaAccent : Color.velaFaint.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: browse)
    }
}

// MARK: - Rows

/// A queued / in-flight / failed import.
private struct PendingRow: View {
    let item: VoiceNotesStore.PendingVoiceNote
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if item.failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.velaInk)
                    .lineLimit(1)
                Text(progressLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.failed ? Color.orange : Color.velaMuted)
                    .lineLimit(1)
            }
            Spacer()
            if let fraction = item.fraction, !item.failed {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            }
            if item.failed {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.velaBody)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.velaRowBorder).frame(height: 1)
        }
    }

    private var progressLabel: String {
        if item.failed { return item.phase }
        if let fraction = item.fraction, fraction > 0 {
            return "\(item.phase) \(Int(fraction * 100))%"
        }
        return item.phase
    }
}

/// A finished transcript. Click to expand the full text; Copy is always visible.
private struct NoteRow: View {
    let note: VoiceNoteRecord
    let dateLabel: String
    let query: String
    let flashAnchor: String?
    let isExpanded: Bool
    let justCopied: Bool
    @Binding var conversationView: Bool
    let toggle: () -> Void
    let copy: () -> Void
    let delete: () -> Void
    let rename: (Int, String) -> Void
    @State private var hovering = false

    private var durationLabel: String {
        let total = Int(note.duration.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if note.isConversation {
                        Picker("View", selection: $conversationView) {
                            Text("Conversation").tag(true)
                            Text("Plain text").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("Conversation splits the note by speaker; Plain text is one block to copy anywhere")
                    }
                    if note.isConversation, conversationView, let turns = note.turns {
                        ConversationBody(note: note, turns: turns, query: query, flashAnchor: flashAnchor, rename: rename)
                    } else {
                        Text(SearchMatch.highlighted(note.text, query: query))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.velaBody)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.velaHighlight.opacity(flashAnchor == "\(note.id)-plain" ? 0.25 : 0))
                            )
                            .padding(-6)
                            .id("\(note.id)-plain")
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 20, bottom: 14, trailing: 20))
            }
        }
        .background(
            isExpanded ? Color.velaSelection.opacity(0.5)
                : hovering ? Color.black.opacity(0.03) : .clear
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.velaRowBorder).frame(height: 1)
        }
        .contextMenu {
            Button("Copy transcript", action: copy)
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.velaFaint)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(SearchMatch.highlighted(note.title, query: query))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isExpanded ? Color.velaAccentDeep : Color.velaInk)
                    .lineLimit(1)
                // Collapsed rows preview the transcript so you can tell voice
                // notes apart at a glance; click for the full text.
                if !isExpanded {
                    Text(SearchMatch.highlighted(SearchMatch.snippet(note.text, query: query), query: query))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.velaMuted)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(note.fileName)
                        .lineLimit(1)
                    Text("·")
                    Text(dateLabel)
                    Text("·")
                    Text(durationLabel).monospacedDigit()
                    Text("·")
                    Text("\(note.words) words")
                    if note.isConversation, let turns = note.turns {
                        Text("·")
                        Label("\(Set(turns.map(\.speaker)).count) speakers", systemImage: "person.2")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.velaMuted)
            }
            Spacer()
            Button(action: copy) {
                Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(justCopied ? Color.green : Color.velaAccent)
                    .padding(EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9))
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.velaAccent.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Copy this transcript")
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .help(isExpanded ? "Hide the full transcript" : "Show the full transcript")
    }
}

// MARK: - Conversation view

/// Speaker colors, by order of first appearance.
private let speakerColors: [Color] = [
    .velaAccent,
    Color(hex: 0xC2570C),
    Color(hex: 0x1F8A4C),
    Color(hex: 0x7C4DDB),
    Color(hex: 0xB0306A),
]

private func speakerColor(_ speaker: Int) -> Color {
    speakerColors[speaker % speakerColors.count]
}

/// Who-said-what transcript: one block per turn with the speaker's name
/// (click to rename) and where in the recording it starts.
private struct ConversationBody: View {
    let note: VoiceNoteRecord
    let turns: [ConversationTurn]
    let query: String
    let flashAnchor: String?
    let rename: (Int, String) -> Void

    static func anchor(note: VoiceNoteRecord, turn: Int) -> String { "\(note.id)-turn-\(turn)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(speakerColor(turn.speaker).opacity(0.55))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            SpeakerLabel(
                                name: note.speakerName(turn.speaker),
                                color: speakerColor(turn.speaker),
                                rename: { rename(turn.speaker, $0) }
                            )
                            Text(Self.timestamp(turn.start))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(Color.velaFaint)
                        }
                        Text(SearchMatch.highlighted(turn.text, query: query))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.velaBody)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.velaHighlight.opacity(flashAnchor == Self.anchor(note: note, turn: index) ? 0.25 : 0))
                )
                .padding(-6)
                .id(Self.anchor(note: note, turn: index))
            }
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// Speaker name; click to rename this speaker throughout the note.
private struct SpeakerLabel: View {
    let name: String
    let color: Color
    let rename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = name.hasPrefix("Speaker ") ? "" : name
            editing = true
        } label: {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help("Rename this speaker")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rename speaker")
                    .font(.system(size: 12, weight: .semibold))
                TextField(name, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(commit)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save", action: commit)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    private func commit() {
        rename(draft)
        editing = false
    }
}

// MARK: - Vocabulary

/// "Words to get right" — add names/terms before dropping audio. Writes to the
/// shared vocabulary (Settings → Vocabulary), so dictation benefits too.
private struct VocabularyCard: View {
    @AppStorage(AppSettings.Keys.glossary) private var glossary = ""
    @ObservedObject private var store = VoiceNotesStore.shared
    /// Result of the last "Fix existing notes" press, flashed on the button.
    @State private var fixResult: String?
    @State private var term = ""
    @State private var misheard = ""
    @State private var expanded = false
    @FocusState private var termFocused: Bool

    private var entries: [AppSettings.GlossaryEntry] {
        glossary.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(AppSettings.parseGlossaryLine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Words to get right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.velaInk)
                    Text("Names and terms in your recordings. Saved to your vocabulary for every transcription.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.velaMuted)
                }
                Spacer()
                if !store.notes.isEmpty, entries.contains(where: { !$0.misheard.isEmpty }) {
                    Button(action: fixExisting) {
                        Label(fixResult ?? "Fix words in existing notes",
                              systemImage: fixResult == nil ? "wand.and.stars" : "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.velaAccent)
                            .padding(EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9))
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.velaAccent.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Apply your “usually written as” fixes to voice notes you already imported")
                }
            }
            HStack(spacing: 8) {
                TextField("Correct spelling — e.g. Alfavet", text: $term)
                    .focused($termFocused)
                    .onSubmit(add)
                Image(systemName: "arrow.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.velaFaint)
                    .help("Vela will replace what it usually writes with the correct spelling")
                TextField("Usually written as (optional) — e.g. Alphabet", text: $misheard)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5))

            if !entries.isEmpty {
                let shown = expanded ? entries : Array(entries.suffix(12).reversed())
                FlowLayout(spacing: 6) {
                    ForEach(shown, id: \.line) { entry in
                        chip(entry)
                    }
                    if entries.count > 12 {
                        Button(expanded ? "Show fewer" : "Show all \(entries.count)") {
                            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.velaAccent)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.velaHeaderBg))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.velaBorder))
    }

    private func chip(_ entry: AppSettings.GlossaryEntry) -> some View {
        HStack(spacing: 5) {
            if !entry.misheard.isEmpty {
                Text(entry.misheard.joined(separator: ", "))
                    .strikethrough()
                    .foregroundStyle(Color.velaMuted)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.velaFaint)
            }
            Text(entry.term)
                .foregroundStyle(Color.velaInk)
            Button {
                AppSettings.removeGlossaryLine(entry.line)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.velaFaint)
            }
            .buttonStyle(.plain)
            .help("Remove from vocabulary")
        }
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 7))
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().strokeBorder(Color.velaBorder))
        .help(entry.misheard.isEmpty
              ? "Vela listens for this spelling"
              : "Vela always replaces \(entry.misheard.joined(separator: " / ")) with \(entry.term)")
    }

    private func fixExisting() {
        let changed = store.applyVocabularyToExistingNotes()
        fixResult = changed == 0 ? "Nothing to fix"
            : changed == 1 ? "Fixed 1 note" : "Fixed \(changed) notes"
        Task {
            try? await Task.sleep(for: .seconds(2))
            fixResult = nil
        }
    }

    private func add() {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        AppSettings.addGlossaryEntry(term: term, misheard: misheard)
        term = ""
        misheard = ""
        termFocused = true
    }
}

/// Wrapping row layout for chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
