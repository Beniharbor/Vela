import SwiftUI
import KeyboardShortcuts

@main
struct VelaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = DictationController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            MenuBarLabel(controller: controller)
        }

        // Dashboard: history, languages, modes, settings. Opens on launch and
        // reopen (see AppDelegate); MenuBarExtra stays the primary scene.
        // Empty title: the sidebar already brands the window, so a title-bar
        // "Vela" would be redundant.
        Window("", id: "dashboard") {
            DashboardView()
        }
        .defaultSize(width: 960, height: 640)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent app: no dock icon (also set via LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)
        AppSettings.registerDefaults()
        DictationController.shared.registerHotkey()
        // Local transcription API for agents (OpenBot etc.) — see LocalAPIServer.
        LocalAPIServer.shared.start()
        // Launching the app (Finder, Spotlight, login item) shows the dashboard
        // right away — otherwise the only feedback is the menu-bar icon.
        DashboardOpener.shared.openDashboard()
    }

    // Double-clicking Vela.app while it's already running lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DashboardOpener.shared.openDashboard()
        return false
    }
}

/// Bridges AppKit launch/reopen events to SwiftUI's `openWindow`, which is only
/// reachable from a view's environment. The MenuBarExtra label (always alive)
/// donates the action; requests that arrive before then are held and replayed.
@MainActor
final class DashboardOpener {
    static let shared = DashboardOpener()

    var open: (() -> Void)? {
        didSet {
            if pending, open != nil {
                pending = false
                openDashboard()
            }
        }
    }
    private var pending = false

    func openDashboard() {
        guard let open else {
            pending = true
            return
        }
        open()
        // Agent app (LSUIElement): windows open behind the frontmost app unless activated.
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let percent = controller.menuBarPercent {
                // Live progress in the menu bar while downloading/transcribing.
                Text(percent)
            } else if controller.state == .idle {
                // Vela sails, template-rendered so macOS tints it like system icons.
                Image(nsImage: MenuBarIcon.sails)
            } else if controller.isPaused {
                Image(systemName: "pause.circle")
            } else {
                Image(systemName: controller.state.symbolName)
            }
        }
        .onAppear {
            DashboardOpener.shared.open = { openWindow(id: "dashboard") }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var controller: DictationController
    @AppStorage(AppSettings.Keys.dictationStyle) private var styleRaw = "flow"
    @ObservedObject private var modeStore = ModeStore.shared

    var body: some View {
        Text(controller.statusLine)
        // The last transcript lives at the top so a dictation that had nowhere to
        // paste (focus was lost, wrong click, …) is never lost.
        if let transcript = controller.lastTranscript {
            Text("“\(Self.snippet(transcript))”")
            Button(controller.lastInsertWasCopyOnly ? "Copy to clipboard (wasn't pasted)" : "Copy last transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript, forType: .string)
            }
        }
        Divider()
        Picker("Style", selection: $styleRaw) {
            ForEach(modeStore.modes) { mode in
                Text("\(mode.name) — \(mode.detail)")
                    .tag(mode.id)
            }
        }
        if let latency = controller.lastLatencyDescription {
            Text(latency)
        }
        Divider()
        Button("Open Dashboard") {
            DashboardOpener.shared.openDashboard()
        }
        .keyboardShortcut("d")
        Button("Unload models now") {
            Task { await controller.unloadModels() }
        }
        Divider()
        Button("Quit Vela") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private static func snippet(_ text: String, limit: Int = 48) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : trimmed.prefix(limit) + "…"
    }
}
