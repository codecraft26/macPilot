import AppKit
import SwiftUI

/// The small floating pill shown while dictating. It never takes focus from the app you're typing in.
@MainActor
final class DictationHUD {
    static let shared = DictationHUD()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64))
            let hosting = NSHostingView(rootView: DictationHUDView().environment(AppState.shared))
            hosting.frame = panel.contentRect(forFrameRect: panel.frame)
            panel.contentView = hosting
            self.panel = panel
        }
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 48))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }
}

private final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct DictationHUDView: View {
    private let controller = DictationController.shared

    var body: some View {
        HStack(spacing: DS.Space.s) {
            indicator
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if controller.phase == .listening || controller.phase == .starting {
                Menu {
                    ForEach(DictationMode.allCases) { mode in
                        Button { controller.mode = mode } label: { Label(mode.label, systemImage: mode.systemImage) }
                    }
                } label: {
                    Label(controller.mode.label, systemImage: controller.mode.systemImage).font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Cleanup style")
                Button { controller.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Cancel (Esc)")
                    .accessibilityLabel("Cancel dictation")
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(width: 420, height: 64)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .tint(DS.accent)
    }

    @ViewBuilder
    private var indicator: some View {
        switch controller.phase {
        case .listening, .starting:
            WaveformBars(level: controller.level).frame(width: 44, height: 28)
        case .transcribing, .cleaning:
            ProgressView().controlSize(.small).frame(width: 44)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green).frame(width: 44)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange).frame(width: 44)
        case .idle:
            Color.clear.frame(width: 44)
        }
    }

    private var title: String {
        switch controller.phase {
        case .starting: return "Starting microphone…"
        case .listening:
            return controller.handsFree ? "Listening — tap ⌥D to finish" : "Listening — release to finish"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up (\(controller.mode.label))…"
        case .done: return "Done"
        case .failed: return "Dictation failed"
        case .idle: return ""
        }
    }

    private var subtitle: String {
        switch controller.phase {
        case .listening:
            let partial = controller.partialText
            return partial.isEmpty ? elapsed : partial
        case .done(let message), .failed(let message): return message
        default: return Prefs.transcriptionProvider.displayName
        }
    }

    private var elapsed: String {
        guard let start = controller.startedAt else { return "Speak now" }
        return "Speak now · " + TranscriptSegment.format(Date().timeIntervalSince(start))
    }
}

/// Animated bars driven by the microphone level.
struct WaveformBars: View {
    var level: Float
    private let weights: [Float] = [0.5, 0.8, 1.0, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.red)
                    .frame(width: 4, height: max(4, CGFloat(min(1, level * weights[index] * 1.4)) * 28))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .accessibilityLabel("Microphone level")
    }
}
