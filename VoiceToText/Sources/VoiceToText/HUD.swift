import AppKit
import SwiftUI
import VoiceToTextKit

/// A small glass capsule at the bottom of the screen while dictating:
/// "Opening the mic…", then a red mic with a level meter and the time, then
/// "Transcribing…", then the result for a moment. It never takes focus or
/// clicks, so your typing and the paste go to the app you are in.
final class RecordingHUD {
    static let size = NSSize(width: 480, height: 120)

    private let dictation: Dictation
    private var panel: NSPanel?

    init(dictation: Dictation) {
        self.dictation = dictation
    }

    var window: NSWindow? { panel }
    var isVisible: Bool { panel?.isVisible == true }

    func refresh() {
        guard dictation.state != .idle || dictation.notice != nil else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? make()
        if !panel.isVisible { position(panel) }
        panel.orderFrontRegardless()
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the glass draws its own
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(dictation: dictation))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Bottom center of the screen with the mouse, above the Dock.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: (area.midX - Self.size.width / 2).rounded(), y: area.minY + Space.lg))
    }
}

struct HUDView: View {
    let dictation: Dictation
    /// How long the HUD says "Speak now" once the mic is live.
    static let speakNow: TimeInterval = 1.5

    var body: some View {
        content
            .font(.callout.weight(.medium))
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .frame(minHeight: 40)
            .gridArea("hud", inset: Space.sm)
            // Small glass flips dark over a dark app; the tint under the text keeps it readable.
            .background(Palette.glassTint, in: .rect(cornerRadius: 20))
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        if let notice = dictation.notice {
            NoticeLabel(notice: notice)
        } else {
            switch dictation.state {
            case .idle:
                EmptyView()
            case .starting:
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Opening the mic… wait").foregroundStyle(.secondary)
                }
            case .recording(let since):
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    HStack(spacing: Space.md) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(Palette.recording)
                            .symbolEffect(.pulse)
                            .gridProbe("mic", area: "hud")
                        LevelMeter(level: dictation.recorder.level())
                        Text(Elapsed.text(context.date.timeIntervalSince(since)))
                            .monospacedDigit()
                        // The moment to talk: the mic is live (the Tink plays now too).
                        if context.date.timeIntervalSince(since) < Self.speakNow {
                            Text("Speak now").foregroundStyle(Palette.recording)
                        } else {
                            Text("\(HotkeyCenter.shared.combo.symbols) to stop")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .transcribing:
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                }
            }
        }
    }
}

/// Five bars that grow with the input level; the middle ones the most.
private struct LevelMeter: View {
    var level: Float
    private static let weights: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Palette.recording)
                    .frame(width: 4, height: max(4, (CGFloat(level) * 20 * Self.weights[index]).rounded()))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityLabel("Input level")
    }
}

private struct NoticeLabel: View {
    let notice: Notice

    var body: some View {
        switch notice {
        case .pasted:
            Label("Pasted", systemImage: "checkmark.circle.fill").foregroundStyle(.primary, .green)
        case .copied:
            Label("Copied. Press ⌘V to paste", systemImage: "doc.on.clipboard")
        case .nothingHeard:
            Label("Nothing heard", systemImage: "ear")
        case .canceled:
            Label("Canceled", systemImage: "xmark.circle")
        case .error(let message):
            Label {
                Text(message).lineLimit(2).frame(maxWidth: 360, alignment: .leading)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}
