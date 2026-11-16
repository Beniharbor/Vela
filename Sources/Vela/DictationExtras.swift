import AppKit
import ApplicationServices
import os

// MARK: - Reading the focused field

/// Accessibility reads of whatever text field has focus in the front app.
/// Everything here returns nil when the app doesn't expose it (Electron apps,
/// terminals, password fields) — callers treat that as "can't tell".
enum FocusContext {
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    static func characterCount(_ element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref)
        return (ref as? NSNumber)?.intValue
    }

    static func caret(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref)
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(ref as! AXValue, .cfRange, &range) ? range : nil
    }

    /// The field's full text, skipped when it is too long to be worth copying.
    static func value(_ element: AXUIElement, maxCharacters: Int = 20_000) -> String? {
        if let count = characterCount(element), count > maxCharacters { return nil }
        guard let value = string(element, kAXValueAttribute), value.count <= maxCharacters else { return nil }
        return value
    }

    /// The selection in the focused field, straight from Accessibility.
    static func selectedText() -> String? {
        guard let element = focusedElement(),
              let text = string(element, kAXSelectedTextAttribute),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Up to `limit` characters of what is already written before the cursor.
    static func textBeforeCaret(limit: Int = 1200) -> String? {
        guard let element = focusedElement(), let value = value(element), !value.isEmpty else { return nil }
        let utf16 = Array(value.utf16)
        let end = min(caret(element)?.location ?? utf16.count, utf16.count)
        guard end > 0 else { return nil }
        let text = String(decoding: utf16[max(0, end - limit)..<end], as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Per-app style

/// "In this app, always dictate in this style" — looked up when a recording
/// starts. The globally selected style is untouched.
struct AppStyleRule: Codable, Identifiable, Equatable {
    var bundleID: String
    var appName: String
    var modeID: String
    var id: String { bundleID }
}

enum AppStyleRules {
    static func load() -> [AppStyleRule] {
        guard let data = AppSettings.defaults.data(forKey: AppSettings.Keys.appStyleRules),
              let rules = try? JSONDecoder().decode([AppStyleRule].self, from: data)
        else { return [] }
        return rules
    }

    static func save(_ rules: [AppStyleRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        AppSettings.defaults.set(data, forKey: AppSettings.Keys.appStyleRules)
    }

    /// The mode pinned to the frontmost app, if any (and still usable).
    @MainActor
    static func modeForFrontmostApp() -> DictationMode? {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let rule = load().first(where: { $0.bundleID == bundleID }),
              let mode = ModeStore.shared.modes.first(where: { $0.id == rule.modeID }),
              !mode.needsOllama
        else { return nil }
        return mode
    }
}

// MARK: - Learning vocabulary from corrections

/// After a dictation is pasted into a readable text field, watches for the
/// user fixing a word in it ("Versel" → "Vercel") and offers that fix as a
/// vocabulary rule. Suggestions wait in Settings → Vocabulary for a yes/no;
/// nothing is added on its own. Reads happen locally and nothing is stored
/// beyond the suggested word pair.
@MainActor
final class VocabularyLearner {
    static let shared = VocabularyLearner()

    private struct Tracked {
        let element: AXUIElement
        let pasted: String
        var value: String
    }

    private var tracked: Tracked?
    private var checks: [Task<Void, Never>] = []
    private let log = Logger(subsystem: "com.vela.app", category: "vocab-learn")

    /// Called once a paste is confirmed to have landed in a readable field.
    func track(element: AXUIElement, pasted: String, value: String) {
        guard AppSettings.learnVocabulary, value.contains(pasted) else { return }
        checks.forEach { $0.cancel() }
        tracked = Tracked(element: element, pasted: pasted, value: value)
        checks = [15, 45, 120].map { delay in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.check()
            }
        }
    }

    /// Looks at the field again; also called when the next dictation starts.
    func check() {
        guard var current = tracked, let now = FocusContext.value(current.element) else { return }
        guard now != current.value else { return }
        if let suggestion = Self.correction(before: current.value, after: now, within: current.pasted) {
            AppSettings.addVocabularySuggestion(misheard: suggestion.misheard, term: suggestion.term)
            log.info("Suggested vocabulary rule: \(suggestion.misheard, privacy: .public) -> \(suggestion.term, privacy: .public)")
        }
        current.value = now
        tracked = current
    }

    /// A single small substitution inside the pasted text, or nil when the
    /// edit is anything else (rewording, deleting, typing more).
    nonisolated static func correction(before: String, after: String, within pasted: String) -> (misheard: String, term: String)? {
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        let removed = old[prefix..<(old.count - suffix)].map(strip).filter { !$0.isEmpty }
        let inserted = new[prefix..<(new.count - suffix)].map(strip).filter { !$0.isEmpty }
        guard (1...3).contains(removed.count), (1...3).contains(inserted.count) else { return nil }

        let misheard = removed.joined(separator: " ")
        let term = inserted.joined(separator: " ")
        guard misheard.count >= 3, term.count >= 2,
              misheard.caseInsensitiveCompare(term) != .orderedSame,
              pasted.range(of: misheard, options: .caseInsensitive) != nil
        else { return nil }
        // A fix sounds like the original; a rewording doesn't.
        let distance = levenshtein(Array(misheard.lowercased()), Array(term.lowercased()))
        guard Double(distance) / Double(max(misheard.count, term.count)) <= 0.6 else { return nil }
        return (misheard, term)
    }

    private nonisolated static func strip(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    private nonisolated static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
