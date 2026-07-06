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
            if let percent = controller.menuBarPercent {
                // Live progress in the menu bar while downloading/transcribing.
                Text(percent)
            } else {
                Image(systemName: controller.state.symbolName)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent app: no dock icon (also set via LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)
        AppSettings.registerDefaults()
        DictationController.shared.registerHotkey()
    }
}

struct MenuContent: View {
    @ObservedObject var controller: DictationController
    @AppStorage(AppSettings.Keys.dictationStyle) private var styleRaw = DictationStyle.flow.rawValue

    var body: some View {
        Text(controller.statusLine)
        Picker("Style", selection: $styleRaw) {
            ForEach(DictationStyle.allCases) { style in
                Text("\(style.displayName) — \(style.menuDescription)")
                    .tag(style.rawValue)
            }
        }
        if let latency = controller.lastLatencyDescription {
            Text(latency)
        }
        if let transcript = controller.lastTranscript {
            Button("Copy last transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript, forType: .string)
            }
        }
        Divider()
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Button("Unload models now") {
            Task { await controller.unloadModels() }
        }
        Divider()
        Button("Quit Vela") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
