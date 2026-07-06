import AppKit
import SwiftUI

/// Floating Wispr-style waveform pill shown while recording. Borderless,
/// non-activating, click-through, above all windows, on every Space.
@MainActor
final class RecordingHUD {
    private var panel: NSPanel?

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 300, height: 56)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Clickable for the style dropdown; .nonactivatingPanel keeps focus (and the
        // insertion point) in the app being dictated into.
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: WaveformHUD(controller: .shared))
        return panel
    }

    private func position(_ panel: NSPanel) {
        // Bottom-center of the screen the user is working on (where the key window is).
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 48
        ))
    }
}

struct WaveformHUD: View {
    @ObservedObject var controller: DictationController
    @AppStorage(AppSettings.Keys.dictationStyle) private var styleRaw = DictationStyle.flow.rawValue

    private var style: DictationStyle { DictationStyle(rawValue: styleRaw) ?? .flow }

    var body: some View {
        HStack(spacing: 10) {
            styleChip
            waveform
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(width: 284, height: 44)
        .background(
            Capsule()
                .fill(Color(red: 0.05, green: 0.05, blue: 0.06).opacity(0.92))
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .animation(.linear(duration: 0.08), value: controller.micLevels)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var styleChip: some View {
        Menu {
            ForEach(DictationStyle.allCases) { candidate in
                Button {
                    styleRaw = candidate.rawValue
                } label: {
                    if candidate == style {
                        Image(systemName: "checkmark")
                    }
                    Text("\(candidate.displayName) — \(candidate.menuDescription)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(style.displayName)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var waveform: some View {
        HStack(spacing: 3.5) {
            ForEach(Array(controller.micLevels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(level < 0.06 ? 0.45 : 0.95))
                    .frame(width: 3, height: max(3.5, CGFloat(level) * 30))
            }
        }
        .frame(maxWidth: .infinity)
    }
}
