import AppKit
import SwiftUI

/// Shared search for dashboard panes: a toolbar search field that ⌘F focuses
/// and Esc clears, plus matching / highlighting helpers.
enum SearchMatch {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Query split into words; every word must appear (in any order).
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ text: String, query: String) -> Bool {
        let terms = terms(query)
        return terms.allSatisfy { text.range(of: $0, options: options) != nil }
    }

    /// If the first match sits deep in the text, start the preview a little
    /// before it so a one/two-line preview actually shows the hit.
    static func snippet(_ text: String, query: String, lead: Int = 40) -> String {
        let ranges = terms(query).compactMap { text.range(of: $0, options: options) }
        guard let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }) else { return text }
        let offset = text.distance(from: text.startIndex, to: first.lowerBound)
        guard offset > lead else { return text }
        var start = text.index(first.lowerBound, offsetBy: -lead)
        // Don't cut a word in half.
        while start > text.startIndex, !text[text.index(before: start)].isWhitespace {
            start = text.index(before: start)
        }
        return "…" + text[start...]
    }

    /// Text with every occurrence of each query word highlighted.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        for term in terms(query) {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: options, range: searchStart..<text.endIndex) {
                if let attrRange = Range(range, in: result) {
                    result[attrRange].backgroundColor = Color.velaHighlight
                    result[attrRange].foregroundColor = Color.velaInk
                }
                searchStart = range.upperBound
            }
        }
        return result
    }
}

extension Color {
    static let velaHighlight = Color(hex: 0xFFE58A)
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(focused ? Color.velaAccent : Color.velaFaint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.velaInk)
                .focused($focused)
                .onExitCommand {
                    text = ""
                    focused = false
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.velaFaint)
                }
                .buttonStyle(.plain)
                .help("Clear search (Esc)")
            } else {
                Text("⌘F")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.velaFaint)
            }
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.black.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(focused ? Color.velaAccent.opacity(0.5) : Color.velaBorder)
                )
        )
        .onAppear(perform: installShortcut)
        .onDisappear(perform: removeShortcut)
    }

    /// ⌘F via a local key monitor rather than `.keyboardShortcut`: the app is
    /// a menu-bar agent, so there's no Find menu item to hang it on, and the
    /// monitor works no matter which control has focus. Only the visible
    /// pane's field is on screen, so only one monitor is ever live.
    private func installShortcut() {
        removeShortcut()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "f"
            else { return event }
            focused = true
            return nil
        }
    }

    private func removeShortcut() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
