import AppKit
import SwiftUI

/// Floating Wispr-style waveform pill shown while recording. Borderless,
/// non-activating, click-through, above all windows, on every Space.
@MainActor
final class RecordingHUD {
    private var panel: NSPanel?

    /// Bumped by every show() so a fade-out started earlier can tell it's stale.
    private var showGeneration = 0

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        showGeneration += 1
        // A fade from the previous take may be mid-flight — snap back to opaque.
        panel.alphaValue = 1
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide(fade: Bool = false) {
        guard let panel else { return }
        guard fade else {
            panel.orderOut(nil)
            return
        }
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // A new take started during the fade (show() ran) — leave it visible.
            guard let self, self.showGeneration == generation else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
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
        // No window shadow: macOS computes it from the content's opaque shape and
        // leaves a stale fuzzy ring around the animating Done bubble.
        panel.hasShadow = false
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
    @ObservedObject private var modeStore = ModeStore.shared
    @AppStorage(AppSettings.Keys.dictationStyle) private var styleRaw = "flow"

    private var mode: DictationMode {
        modeStore.modes.first { $0.id == styleRaw } ?? modeStore.selected
    }

    @State private var hovering = false
    @State private var funWord = WaveformHUD.randomFunWord()

    var body: some View {
        Group {
            if controller.showingDone {
                doneBubble
            } else if controller.state == .recording {
                // Only rendered while actually recording — otherwise the panel
                // re-appears for the Done flash with a stale pill frame (F11).
                recordingPill
                    .onHover { hovering = $0 }
                    .animation(.easeInOut(duration: 0.15), value: hovering)
            } else if controller.state == .transcribing || controller.state == .cleaning {
                transcribingPill
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .onChange(of: controller.state) { old, new in
            hovering = false
            // A fresh pipeline run (not the transcribing→cleaning handoff) gets its
            // own whimsical word; the same word carries through both phases.
            if new == .transcribing, old != .cleaning {
                funWord = Self.randomFunWord()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: controller.showingDone)
        .animation(.easeInOut(duration: 0.2), value: controller.state)
    }

    /// Hover state for the right side of the pill: ✕ cancel — elapsed timer —
    /// ✓ finish (F13). The style chip stays visible on the left so it remains
    /// clickable while hovering.
    private var hoverControls: some View {
        HStack(spacing: 8) {
            controlButton("xmark", help: "Cancel dictation (Esc)") {
                controller.cancelRecording()
            }
            DottedSeparator()
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(elapsedLabel(at: context.date))
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            DottedSeparator()
            controlButton(
                controller.isPaused ? "play.fill" : "pause.fill",
                help: controller.isPaused ? "Resume (Control)" : "Pause (Control)"
            ) {
                controller.togglePause()
            }
            controlButton("checkmark", help: "Finish dictation") {
                controller.stopAndProcess()
            }
        }
    }

    private func controlButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func elapsedLabel(at now: Date) -> String {
        // While paused the clock freezes at the moment the pause began.
        let reference = controller.pausedAt ?? now
        let seconds = max(0, Int(reference.timeIntervalSince(controller.recordingStarted ?? reference)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// Orange sibling of the green Done bubble, shown in place of the waveform
    /// while recording is paused.
    private var pausedIndicator: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Self.pausedOrange)
                .frame(width: 7, height: 7)
            Text("Paused")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("⌃ to resume")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    static let pausedOrange = Color(red: 0.98, green: 0.62, blue: 0.18)

    private var recordingPill: some View {
        HStack(spacing: 10) {
            styleChip
            if hovering {
                hoverControls
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else if controller.isPaused {
                pausedIndicator
                    .transition(.opacity)
            } else {
                waveform
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, hovering ? 8 : 16)
        .frame(width: 284, height: 44)
        .background(
            Capsule()
                .fill(Color(red: 0.05, green: 0.05, blue: 0.06).opacity(0.92))
        )
        .overlay(
            Capsule().strokeBorder(
                controller.isPaused ? Self.pausedOrange.opacity(0.65) : .white.opacity(0.14),
                lineWidth: 1
            )
        )
        .animation(.easeInOut(duration: 0.15), value: controller.isPaused)
        .animation(.linear(duration: 0.08), value: controller.micLevels)
        .transition(.opacity)
    }

    /// Shown while the pipeline is working after recording stops — Whisper
    /// transcription, then (for styles that use it) LLM cleanup.
    private var transcribingPill: some View {
        Text(transcribingPhaseText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(width: 284, height: 44)
            .background(
                Capsule()
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.06).opacity(0.92))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }

    private var transcribingPhaseText: String {
        switch controller.state {
        case .transcribing:
            // "Downloading model" is real, actionable info — never swap that one
            // out for the whimsical word. Plain "Transcribing" is the generic
            // fallback, so that's the one that gets the fun treatment.
            let phase = controller.progressPhase == "Downloading model"
                ? "Downloading model"
                : funWord
            if let fraction = controller.progressFraction, fraction > 0 {
                return "\(phase)… \(Int(fraction * 100))%"
            }
            return "\(phase)…"
        case .cleaning:
            return "\(funWord)…"
        default:
            return ""
        }
    }

    /// Claude-Code-style whimsical status phrases shown while the pipeline works.
    private static let funWords = [
        "Untangling your train of thought", "Bribing the vowels into place",
        "Coaxing sense out of the mumbling", "Herding words into formation",
        "Negotiating with stray syllables", "Reassembling scattered thoughts",
        "Straightening out crooked sentences", "Rounding up runaway words",
        "Sweet-talking the transcript into shape", "Distilling rambling into sense",
        "Untying a few verbal knots", "Polishing rough-cut phrases",
        "Chasing down wayward thoughts", "Making peace with your run-ons",
        "Sorting signal from the static", "Convincing consonants to cooperate",
        "Smoothing the wrinkles out of your speech", "Divining meaning from the noise",
    ]

    private static func randomFunWord() -> String {
        funWords.randomElement() ?? "Transcribing"
    }

    /// Green confirmation bubble flashed after the transcript lands (F11).
    private var doneBubble: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(red: 0.30, green: 0.78, blue: 0.42))
                .frame(width: 7, height: 7)
            Text(controller.lastInsertWasCopyOnly ? "Copied" : "Done")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(red: 0.05, green: 0.05, blue: 0.06).opacity(0.92)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private var styleChip: some View {
        Menu {
            ForEach(modeStore.modes) { candidate in
                Button {
                    styleRaw = candidate.id
                } label: {
                    if candidate.id == mode.id {
                        Image(systemName: "checkmark")
                    }
                    Text("\(candidate.name) — \(candidate.detail)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(mode.name)
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

    private struct DottedSeparator: View {
        var body: some View {
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.5, 5]))
                .foregroundStyle(.white.opacity(0.35))
            }
            .frame(height: 2)
        }
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
