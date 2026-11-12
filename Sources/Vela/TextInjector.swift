import AppKit
import ApplicationServices
import os

/// Inserts text into the frontmost app (F3): clipboard + synthetic ⌘V primary,
/// CGEvent Unicode typing as fallback.
enum TextInjector {
    private static let log = Logger(subsystem: "com.vela.app", category: "inject")

    /// Prompts for Accessibility permission if not yet granted. Returns current status.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    enum Outcome {
        /// Synthetic ⌘V sent to a focused editable element (clipboard restored after).
        case pasted
        /// No editable element focused — transcript left on the clipboard instead.
        case copiedOnly
        case failed
    }

    @discardableResult
    static func inject(_ text: String) -> Outcome {
        guard !text.isEmpty else { return .failed }
        guard ensureAccessibility(prompt: true) else {
            log.error("Accessibility not granted; cannot inject")
            return .failed
        }
        guard isLikelyEditableContext() else {
            // Nothing to paste into (user clicked away, desktop focused, …):
            // keep the transcript on the clipboard so it isn't lost.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            log.info("No editable element focused — transcript left on clipboard")
            return .copiedOnly
        }
        pasteViaClipboard(text)
        return .pasted
    }

    /// True when the system-wide focused UI element can take text. Errs toward
    /// pasting: any settable value, text-like role, or selection range counts —
    /// only a clearly non-editable focus (desktop, button, none at all) fails.
    private static func hasEditableFocus() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return false }
        let element = focusedRef as! AXUIElement

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String,
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
            return true
        }

        // Terminals and custom editors often expose only a selection range.
        var names: CFArray?
        if AXUIElementCopyAttributeNames(element, &names) == .success,
           let attributes = names as? [String],
           attributes.contains(kAXSelectedTextRangeAttribute) {
            return true
        }
        return false
    }

    /// Contexts with no dictation target at all — the only cases worth refusing
    /// to paste into. Everything else defaults to pasting: many canvas-rendered
    /// editors and Electron apps (VS Code, Cursor, Slack, terminals, …) don't
    /// report AX focus/value/selection attributes, so `hasEditableFocus()`
    /// false-negatives constantly. A blind ⌘V is harmless in a real app; it's
    /// only actively bad on the Finder desktop (drops a clipping file) or
    /// system chrome (Dock, menu bar, notifications) that can't take text.
    private static let noPasteTargetBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.loginwindow",
    ]

    private static func isLikelyEditableContext() -> Bool {
        if hasEditableFocus() { return true }
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        return !noPasteTargetBundleIDs.contains(app.bundleIdentifier ?? "")
    }

    /// Marks the clipboard write we made, so the delayed restore below can tell
    /// whether the user copied something else in the meantime.
    private static let sessionType = NSPasteboard.PasteboardType("com.vela.app.paste-session")

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        } ?? []

        let sessionID = UUID().uuidString
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(sessionID, forType: sessionType)
        let changeCount = pasteboard.changeCount

        postPaste()

        // Restore the user's previous clipboard after the paste lands — but only
        // if nothing else has touched the clipboard since (e.g. the user copied
        // something new during the restore delay); clobbering that would be worse
        // than leaving our own text on the clipboard a little longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == changeCount,
                  pasteboard.string(forType: sessionType) == sessionID
            else { return }
            pasteboard.clearContents()
            for (type, data) in saved {
                pasteboard.setData(data, forType: type)
            }
        }
    }

    /// Tries the System Events route first — more reliable than a synthetic key
    /// event in some Electron/web-based apps — falling back to CGEvent if
    /// Automation permission hasn't been granted (or the app rejects it).
    private static func postPaste() {
        if pasteViaAppleScript() { return }
        log.info("AppleScript paste unavailable — falling back to synthetic key events")
        postCmdV()
    }

    private static func pasteViaAppleScript() -> Bool {
        let source = "tell application \"System Events\" to keystroke \"v\" using command down"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            log.info("AppleScript paste failed: \(error)")
            return false
        }
        return true
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        log.info("Posted synthetic ⌘V")
    }

    /// Fallback for apps that ignore paste: type the string as Unicode key events.
    static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Chunk: keyboardSetUnicodeString has a limited internal buffer.
        for chunk in text.chunked(into: 20) {
            let utf16 = Array(chunk.utf16)
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(5_000)
        }
        log.info("Typed \(text.count) chars via Unicode fallback")
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}
