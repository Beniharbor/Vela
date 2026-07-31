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
                    copyAllButton
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    dropZone
                        .padding(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                    ForEach(store.pending) { item in
                        PendingRow(item: item) { store.dismiss(item) }
                    }
                    ForEach(store.notes) { note in
                        NoteRow(
                            note: note,
                            dateLabel: Self.dateFormatter.string(from: note.date),
                            isExpanded: expandedID == note.id,
                            justCopied: copiedID == note.id,
                            toggle: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedID = expandedID == note.id ? nil : note.id
                                }
                            },
                            copy: { copy(note) },
                            delete: { store.delete(note) }
                        )
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importFiles(urls)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
    }

    // MARK: Actions

    private func copy(_ note: VoiceNoteRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        copiedID = note.id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == note.id { copiedID = nil }
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.combinedTranscripts, forType: .string)
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
        .help("Copy every transcript, oldest first, ready to paste into Claude")
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
    let isExpanded: Bool
    let justCopied: Bool
    let toggle: () -> Void
    let copy: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    private var durationLabel: String {
        let total = Int(note.duration.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Text(note.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.velaBody)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(note.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isExpanded ? Color.velaAccentDeep : Color.velaInk)
                    .lineLimit(1)
                // Collapsed rows preview the transcript so you can tell voice
                // notes apart at a glance; click for the full text.
                if !isExpanded {
                    Text(note.text)
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
