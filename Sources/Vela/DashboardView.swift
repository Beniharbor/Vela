import AppKit
import SwiftUI

// MARK: - Design palette (from Vela Dashboard.dc.html)
// Internal (not private): VoiceNotesPane.swift shares the palette and chrome.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    static let velaInk = Color(hex: 0x1D1D1F)          // primary text
    static let velaBody = Color(hex: 0x3C4149)          // nav / strong secondary
    static let velaMuted = Color(hex: 0x8B9097)         // previews, subtitles
    static let velaFaint = Color(hex: 0x9098A1)         // placeholders, captions
    static let velaCell = Color(hex: 0x6B7076)          // date/length cells
    static let velaAccent = Color(hex: 0x2F6FE8)        // active sort, links
    static let velaAccentDeep = Color(hex: 0x1A49B0)    // active nav / selected title
    static let velaSelection = Color(hex: 0xE8F0FE)     // selected row
    static let velaBadgeText = Color(hex: 0x5A728F)
    static let velaSidebar = Color(hex: 0xF4F6F9, opacity: 0.7)
    static let velaHeaderBg = Color(hex: 0xFAFBFC)
    static let velaBorder = Color.black.opacity(0.06)
    static let velaRowBorder = Color.black.opacity(0.045)
}

// MARK: - Dashboard window

enum DashboardPane: String, CaseIterable {
    case history, voiceNotes, languages, modes, features, settings

    var label: String {
        switch self {
        case .history: return "History"
        case .voiceNotes: return "Voice Notes"
        case .languages: return "Languages"
        case .modes: return "Modes"
        case .features: return "Features"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .voiceNotes: return "waveform.badge.plus"
        case .languages: return "globe"
        case .modes: return "slider.vertical.3"
        case .features: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}

struct DashboardView: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var pane: DashboardPane = .history
    @AppStorage(AppSettings.Keys.sidebarWidth) private var sidebarWidth: Double = 210
    @AppStorage(AppSettings.Keys.sidebarOrder) private var sidebarOrderRaw: String = ""
    @State private var dropTargetPane: DashboardPane?

    /// The user's saved tab order, with any pane missing from it (a tab added
    /// after they last reordered, or on first launch) appended at the end.
    private var orderedPanes: [DashboardPane] {
        let stored = sidebarOrderRaw.split(separator: ",").compactMap { DashboardPane(rawValue: String($0)) }
        let missing = DashboardPane.allCases.filter { !stored.contains($0) }
        return stored + missing
    }

    private func movePane(_ draggedRawValue: String, to target: DashboardPane) {
        guard let dragged = DashboardPane(rawValue: draggedRawValue), dragged != target else { return }
        var order = orderedPanes
        guard let fromIndex = order.firstIndex(of: dragged) else { return }
        order.remove(at: fromIndex)
        let insertIndex = order.firstIndex(of: target) ?? order.count
        order.insert(dragged, at: insertIndex)
        sidebarOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            SidebarResizeHandle(width: $sidebarWidth)
            content
        }
        .frame(minWidth: 880, minHeight: 560)
        .background(Color.white)
        // The design is light-only; fixed hex colors would clash with dark mode.
        .preferredColorScheme(.light)
    }

    private var content: some View {
        Group {
            switch pane {
            case .history: HistoryPane(history: history)
            case .voiceNotes: VoiceNotesPane()
            case .languages: LanguagesPane()
            case .modes: ModesPane()
            case .features: FeaturesPane()
            case .settings: SettingsPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 11) {
                VelaLogoMark()
                    .frame(width: 40, height: 40)
                Text("Vela")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.velaInk)
            }
            .padding(EdgeInsets(top: 2, leading: 8, bottom: 14, trailing: 8))

            ForEach(orderedPanes, id: \.self) { item in
                SidebarButton(pane: item, isActive: pane == item, isDropTarget: dropTargetPane == item) {
                    pane = item
                }
                .draggable(item.rawValue)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first else { return false }
                    movePane(dragged, to: item)
                    return true
                } isTargeted: { targeting in
                    dropTargetPane = targeting ? item : nil
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("THIS WEEK")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.44)
                    .foregroundStyle(Color.velaFaint)
                let week = history.thisWeek
                Text("\(week.sessions) sessions · \(week.minutes) min")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.velaBody)
            }
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 4, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.velaBorder).frame(height: 1)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 12, bottom: 16, trailing: 12))
        .frame(width: CGFloat(sidebarWidth))
        .frame(maxHeight: .infinity)
        .background(Color.velaSidebar)
    }
}

/// Drag-to-resize divider between the sidebar and the main content. A wider
/// clear hit area sits over the thin visible border line so it's easy to grab.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    private static let range: ClosedRange<Double> = 170...320

    @State private var dragStartWidth: Double?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.velaBorder).frame(width: 1)
            Color.clear
        }
        .frame(width: 7)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            // Global coordinate space: the handle's local frame shifts as
            // `width` changes mid-drag, which would corrupt a local translation.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? width
                    dragStartWidth = start
                    width = min(max(start + value.translation.width, Self.range.lowerBound), Self.range.upperBound)
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }
}

private struct SidebarButton: View {
    let pane: DashboardPane
    let isActive: Bool
    let isDropTarget: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                Text(pane.label)
                    .font(.system(size: 13.5, weight: isActive ? .semibold : .medium))
            }
            .foregroundStyle(isActive ? Color.velaAccentDeep : Color.velaBody)
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive
                        ? Color.velaAccent.opacity(0.12)
                        : (hovering || isDropTarget) ? Color.black.opacity(0.04) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The sail-over-waveform mark from Resources/Icon.svg, drawn in a 512-unit
/// viewbox and scaled to fill the view — matches the app icon (Vela.icns).
private struct VelaLogoMark: View {
    var body: some View {
        Canvas { context, size in
            // Full-bleed 512 viewbox scaled uniformly into the frame.
            let s = min(size.width, size.height) / 512
            context.scaleBy(x: s, y: s)

            // Rounded tile background (gradient), also clips the artwork.
            let tile = Path(roundedRect: CGRect(x: 0, y: 0, width: 512, height: 512), cornerRadius: 113)
            context.fill(tile, with: .linearGradient(
                Gradient(colors: [Color(hex: 0xC4DAF6), Color(hex: 0xA1C2F1)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 512, y: 512)
            ))
            context.clip(to: tile)

            // Two sails.
            var sails = Path()
            sails.move(to: CGPoint(x: 253.37, y: 52.6))
            sails.addCurve(
                to: CGPoint(x: 416.44, y: 344.99),
                control1: CGPoint(x: 345.1, y: 133),
                control2: CGPoint(x: 436.3, y: 225.6)
            )
            sails.addLine(to: CGPoint(x: 252.93, y: 344.99))
            sails.closeSubpath()
            sails.move(to: CGPoint(x: 234.1, y: 117.04))
            sails.addLine(to: CGPoint(x: 117.04, y: 344.99))
            sails.addLine(to: CGPoint(x: 234.1, y: 344.99))
            sails.closeSubpath()
            context.fill(sails, with: .color(Color(hex: 0x0D1B2A)))

            // Multi-colored waveform bars.
            let bars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: UInt32)] = [
                (116.2, 387.5, 37.3, 0x678FE8), (150.4, 370.0, 72.3, 0x4E79E4),
                (184.6, 352.5, 107.4, 0x5A83E6), (218.3, 365.6, 81.1, 0x3B69E2),
                (252.9, 378.7, 54.7, 0x537EE5), (286.7, 352.0, 90.3, 0x2F5FE0),
                (320.9, 352.0, 63.6, 0x537EE5), (355.1, 352.0, 41.6, 0x416EE3),
                (389.3, 352.0, 28.5, 0x4D79E4),
            ]
            for bar in bars {
                let rect = CGRect(x: bar.x, y: bar.y, width: 16.66, height: bar.h)
                context.fill(Path(roundedRect: rect, cornerRadius: 8.33), with: .color(Color(hex: bar.color)))
            }
        }
    }
}

// MARK: - Shared pane chrome

struct PaneToolbar<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.38)
                    .foregroundStyle(Color.velaInk)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.velaMuted)
            }
            Spacer()
            trailing
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.velaBorder).frame(height: 1)
        }
    }
}

// MARK: - History

private enum SortKey {
    case title, date, duration, words

    /// Fresh-key direction: alphabetical starts ascending, everything else newest/biggest first.
    var initialAscending: Bool { self == .title }
}

private struct HistoryPane: View {
    @ObservedObject var history: HistoryStore
    @State private var query = ""
    @State private var sortKey: SortKey = .date
    @State private var ascending = false
    @State private var selectedID: TranscriptionRecord.ID?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private var rows: [TranscriptionRecord] {
        var rows = history.records
        if !SearchMatch.terms(query).isEmpty {
            rows = rows.filter { SearchMatch.matches($0.title + " " + $0.text, query: query) }
        }
        rows.sort { a, b in
            let comparison: Bool
            switch sortKey {
            case .title: comparison = a.title.lowercased() < b.title.lowercased()
            case .date: comparison = a.date < b.date
            case .duration: comparison = a.duration < b.duration
            case .words: comparison = a.words < b.words
            }
            return ascending ? comparison : !comparison
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(
                title: "History",
                subtitle: "\(history.totalWords.formatted()) words dictated all-time"
            ) {
                searchField
            }
            tableHeader
            table
        }
    }

    private var searchField: some View {
        SearchField(placeholder: "Search transcriptions", text: $query)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            headerButton("Transcription", key: .title, width: nil, alignment: .leading)
            headerButton("Date", key: .date, width: 104, alignment: .leading)
            headerButton("Length", key: .duration, width: 62, alignment: .trailing)
            headerButton("Words", key: .words, width: 52, alignment: .trailing)
        }
        .padding(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
        .background(Color.velaHeaderBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.velaBorder).frame(height: 1)
        }
    }

    private func headerButton(_ label: String, key: SortKey, width: CGFloat?, alignment: Alignment) -> some View {
        Button {
            if sortKey == key {
                ascending.toggle()
            } else {
                sortKey = key
                ascending = key.initialAscending
            }
        } label: {
            Text(label.uppercased() + (sortKey == key ? (ascending ? " ↑" : " ↓") : ""))
                .font(.system(size: 11, weight: .bold))
                .tracking(0.55)
                .foregroundStyle(sortKey == key ? Color.velaAccent : Color.velaMuted)
                .lineLimit(1)
                .modifier(ColumnWidth(width: width, alignment: alignment))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var table: some View {
        let rows = rows
        if rows.isEmpty {
            Text(history.records.isEmpty
                ? "No transcriptions yet — press Fn and speak."
                : "No transcriptions match your search.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.velaFaint)
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { record in
                        HistoryRow(
                            record: record,
                            dateLabel: Self.dateFormatter.string(from: record.date),
                            query: query,
                            isSelected: record.id == selectedID
                        ) {
                            selectedID = record.id
                        }
                        .contextMenu {
                            Button("Copy transcript") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(record.text, forType: .string)
                            }
                            Button("Delete", role: .destructive) {
                                history.delete(record)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ColumnWidth: ViewModifier {
    let width: CGFloat?
    let alignment: Alignment

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, alignment: alignment)
        } else {
            content.frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}

private struct HistoryRow: View {
    let record: TranscriptionRecord
    let dateLabel: String
    let query: String
    let isSelected: Bool
    let select: () -> Void

    private var durationLabel: String {
        let total = Int(record.duration.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(record.language)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.36)
                        .foregroundStyle(Color.velaBadgeText)
                        .padding(EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5))
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.velaAccent.opacity(0.1)))
                    Text(SearchMatch.highlighted(record.title, query: query))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.velaAccentDeep : Color.velaInk)
                        .lineLimit(1)
                }
                Text(SearchMatch.highlighted(SearchMatch.snippet(record.text, query: query), query: query))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.velaMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 14)

            Text(dateLabel)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.velaCell)
                .lineLimit(1)
                .frame(width: 104, alignment: .leading)
            Text(durationLabel)
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Color.velaCell)
                .frame(width: 62, alignment: .trailing)
            Text("\(record.words)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.velaBody)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
        .background(isSelected ? Color.velaSelection : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.velaRowBorder).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

// MARK: - Languages

private struct LanguagesPane: View {
    @AppStorage(AppSettings.Keys.dictationLanguage) private var language = "auto"

    private static let options: [(code: String, name: String, detail: String)] = [
        ("auto", "Auto-detect", "Whisper picks the language per dictation"),
        ("en", "English", "Force English recognition"),
        ("es", "Spanish (Español)", "Force Spanish recognition"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: "Languages", subtitle: "Which language Whisper listens for") {}
            OptionList(
                options: Self.options.map { ($0.code, $0.name, $0.detail) },
                selection: $language
            )
        }
    }
}

// MARK: - Modes

private struct ModesPane: View {
    @ObservedObject private var store = ModeStore.shared
    @AppStorage(AppSettings.Keys.dictationStyle) private var styleRaw = "flow"
    @State private var expandedID: String?

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: "Modes", subtitle: "How your words are formatted before insertion") {
                Button {
                    let id = store.addMode()
                    expandedID = id
                } label: {
                    Label("New Mode", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.velaAccent)
                        .padding(EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11))
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.velaAccent.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.modes) { mode in
                        ModeRow(
                            mode: binding(for: mode),
                            isSelected: styleRaw == mode.id,
                            isExpanded: expandedID == mode.id,
                            select: { styleRaw = mode.id },
                            toggleExpanded: {
                                expandedID = expandedID == mode.id ? nil : mode.id
                            },
                            delete: mode.isFlow ? nil : { store.delete(mode) }
                        )
                    }
                }
            }
        }
    }

    /// Live binding into the store so edits persist as you type.
    private func binding(for mode: DictationMode) -> Binding<DictationMode> {
        Binding(
            get: { store.modes.first { $0.id == mode.id } ?? mode },
            set: { updated in
                guard let index = store.modes.firstIndex(where: { $0.id == mode.id }) else { return }
                store.modes[index] = updated
            }
        )
    }
}

private struct ModeRow: View {
    @Binding var mode: DictationMode
    let isSelected: Bool
    let isExpanded: Bool
    let select: () -> Void
    let toggleExpanded: () -> Void
    let delete: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                editor
            }
        }
        .background(isSelected ? Color.velaSelection : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.velaRowBorder).frame(height: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Color.velaAccent : Color.velaFaint)
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.velaAccentDeep : Color.velaInk)
                Text(mode.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.velaMuted)
            }
            Spacer()
            if !mode.usesLLM {
                Text("NO AI")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.36)
                    .foregroundStyle(Color.velaBadgeText)
                    .padding(EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5))
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.velaAccent.opacity(0.1)))
            }
            Button(action: toggleExpanded) {
                Image(systemName: isExpanded ? "chevron.up" : "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.velaBody)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse" : "Edit this mode")
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("NAME") {
                TextField("Mode name", text: $mode.name)
            }
            field("DESCRIPTION") {
                TextField("Short description shown in menus", text: $mode.detail)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("ENGINE")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.44)
                    .foregroundStyle(Color.velaFaint)
                Picker("", selection: $mode.engine) {
                    Text("WhisperKit").tag(TranscriptionEngineKind.whisperKit)
                    if #available(macOS 26, *) {
                        Text("Apple (on-device)").tag(TranscriptionEngineKind.appleSpeech)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("SYSTEM PROMPT")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.44)
                    .foregroundStyle(Color.velaFaint)
                if mode.isFlow {
                    Text("Flow has no AI pass — your words are inserted as spoken (filler words are always stripped).")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.velaMuted)
                } else {
                    TextEditor(text: $mode.systemPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.velaInk)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 150)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.velaBorder))
                        )
                    Text("Leave empty for no AI pass. {name} is replaced with your sign-off name from Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.velaFaint)
                }
            }
            if let delete {
                Button(role: .destructive, action: delete) {
                    Label("Delete mode", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(EdgeInsets(top: 2, leading: 48, bottom: 16, trailing: 20))
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.44)
                .foregroundStyle(Color.velaFaint)
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.velaInk)
                .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.velaBorder))
                )
        }
    }
}

/// Radio-style list matching the history table's row treatment.
private struct OptionList: View {
    let options: [(tag: String, name: String, detail: String)]
    @Binding var selection: String

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(options, id: \.tag) { option in
                    let isSelected = selection == option.tag
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(isSelected ? Color.velaAccent : Color.velaFaint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.velaAccentDeep : Color.velaInk)
                            Text(option.detail)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.velaMuted)
                        }
                        Spacer()
                    }
                    .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .background(isSelected ? Color.velaSelection : .clear)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.velaRowBorder).frame(height: 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option.tag }
                }
            }
        }
    }
}

// MARK: - Features

private struct FeatureItem {
    let symbol: String
    let name: String
    let detail: String
}

private struct FeaturesPane: View {
    /// Manually maintained — append a line here whenever a capability ships,
    /// same as you'd add a changelog entry.
    private static let items: [FeatureItem] = [
        FeatureItem(symbol: "keyboard", name: "Fn key or custom shortcut", detail: "Press to start dictating, press again to stop and paste. Switch triggers in Settings."),
        FeatureItem(symbol: "escape", name: "Esc to cancel", detail: "Discards the current take — nothing gets pasted."),
        FeatureItem(symbol: "pause.circle", name: "Control to pause / resume", detail: "Freezes the recording and the elapsed timer until you tap Control again."),
        FeatureItem(symbol: "leaf", name: "\"Watermelon\" voice stop-word 🍉", detail: "Say it mid-dictation to stop and paste what came before it — on-device, nothing leaves the Mac."),
        FeatureItem(symbol: "waveform.slash", name: "Silence guard", detail: "Recordings with no real speech are discarded instead of handed to Whisper, which hallucinates text on silence."),
        FeatureItem(symbol: "timer", name: "10-minute auto-stop", detail: "A take that runs long stops and transcribes on its own instead of recording forever."),
        FeatureItem(symbol: "waveform", name: "Floating waveform HUD", detail: "Live mic level and elapsed time while you're recording."),
        FeatureItem(symbol: "globe", name: "Bilingual auto-detect", detail: "Recognizes English and Spanish per dictation, or force one in Languages."),
        FeatureItem(symbol: "wand.and.stars", name: "Dictation styles", detail: "Flow, Polished, Prompt, Compose, or your own custom modes — each with its own LLM cleanup prompt."),
        FeatureItem(symbol: "hourglass", name: "Live progress in the menu bar", detail: "Shows model download/load/transcribe percent while a take is processing."),
        FeatureItem(symbol: "doc.on.clipboard", name: "Copy last transcript", detail: "From the menu bar or dashboard — in case paste had nowhere to land."),
        FeatureItem(symbol: "waveform.badge.plus", name: "Voice Notes import", detail: "Transcribes WhatsApp-style audio files (.ogg/.opus, .m4a, .mp3, .wav) dropped in."),
        FeatureItem(symbol: "clock.arrow.circlepath", name: "Searchable history", detail: "Every dictation, sortable by date, length, or word count."),
        FeatureItem(symbol: "checkmark.shield", name: "Permission status badges", detail: "Settings shows live Mic/Accessibility/Speech status with a deep link to fix them."),
        FeatureItem(symbol: "internaldrive", name: "Offline-safe models", detail: "Loads Whisper from disk when present, only downloads if missing."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: "Features", subtitle: "\(Self.items.count) things Vela can do") {}
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Self.items, id: \.name) { item in
                        FeatureRow(item: item)
                    }
                }
            }
        }
    }
}

private struct FeatureRow: View {
    let item: FeatureItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.velaAccent)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.velaInk)
                Text(item.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.velaMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.velaRowBorder).frame(height: 1)
        }
    }
}

// MARK: - Settings

private struct SettingsPane: View {
    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: "Settings", subtitle: "Trigger, models, permissions, and vocabulary") {}
            SettingsView(embedded: true)
        }
    }
}
