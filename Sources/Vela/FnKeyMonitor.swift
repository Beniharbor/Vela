import AppKit
import os

/// Watches for a bare Fn key press-and-release (no other key in between) and fires a
/// toggle callback. Carbon hotkeys can't bind a lone modifier, so this uses NSEvent
/// global monitors — which work under the Accessibility permission Vela already needs
/// for text injection (no Input Monitoring prompt).
@MainActor
final class FnKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnDown = false
    private var sawOtherKey = false
    private let log = Logger(subsystem: "com.vela.app", category: "hotkey")

    private static let fnKeyCode: UInt16 = 63 // kVK_Function
    private static let escKeyCode: UInt16 = 53 // kVK_Escape

    var onToggle: (() -> Void)?
    /// Fired on any Esc key-down (global monitors can't consume the event, so the
    /// focused app still receives the Esc — acceptable for a cancel gesture).
    var onEscape: (() -> Void)?

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
        log.info("Fn key monitor started")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard event.keyCode == Self.fnKeyCode else { return }
            if event.modifierFlags.contains(.function) {
                fnDown = true
                sawOtherKey = false
            } else if fnDown {
                fnDown = false
                // Only a *bare* Fn tap toggles — Fn+arrow (Home/PgUp…) etc. pass through.
                if !sawOtherKey { onToggle?() }
            }
        case .keyDown:
            if fnDown { sawOtherKey = true }
            if event.keyCode == Self.escKeyCode { onEscape?() }
        default:
            break
        }
    }
}
