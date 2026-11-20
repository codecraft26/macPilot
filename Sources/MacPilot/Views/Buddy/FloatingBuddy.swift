import AppKit
import Observation
import SwiftUI

/// "Pilot", MacPilot's desktop buddy: a small always-on-top character with quick actions
/// (voice note, dictation, Ask AI, new note). Drag it anywhere; it remembers its spot.
@Observable
@MainActor
final class FloatingBuddy {
    static let shared = FloatingBuddy()

    static let size = NSSize(width: 150, height: 196)
    /// Room for the speech bubble above the buddy while it talks.
    static let talkingSize = NSSize(width: 300, height: 330)
    private var panel: NSPanel?
    private var dragStart: (origin: NSPoint, mouse: NSPoint)?
    private let originKey = "buddy.origin"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.buddyEnabled) }
    /// Observable, so the menu bar ("Show/Hide Floating Buddy") and Settings update immediately.
    private(set) var isVisible = false

    func start() {
        if Self.isEnabled { show() }
        WakeWordListener.shared.start()
    }

    /// Grows the window upward for the speech bubble (keeping the buddy where it is), and back.
    func updateSize() {
        guard let panel else { return }
        let target = PilotVoice.shared.showsBubble ? Self.talkingSize : Self.size
        guard panel.frame.size != target else { return }
        let frame = panel.frame
        let origin = NSPoint(x: frame.midX - target.width / 2, y: frame.minY)
        panel.setFrame(NSRect(origin: origin, size: target), display: true, animate: false)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PrefKey.buddyEnabled)
        if enabled { show() } else { panel?.orderOut(nil); isVisible = false; PilotVoice.shared.stopAll() }
        WakeWordListener.shared.start()
    }

    func toggle() { setEnabled(!isVisible) }

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: savedOrigin(), size: Self.size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let hosting = NSHostingView(rootView: BuddyView().environment(AppState.shared))
            hosting.frame = NSRect(origin: .zero, size: Self.size)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            self.panel = panel
        }
        panel?.orderFrontRegardless()
        isVisible = true
        ScreenPrivacy.applyAll()
    }

    // MARK: Position

    private func savedOrigin() -> NSPoint {
        if let values = UserDefaults.standard.array(forKey: originKey) as? [Double], values.count == 2 {
            let point = NSPoint(x: values[0], y: values[1])
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) }) { return point }
        }
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.maxX - Self.size.width - 24, y: frame.minY + 24)
    }

    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (panel.frame.origin, mouse) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    func dragEnded() {
        dragStart = nil
        guard let frame = panel?.frame else { return }
        // Save the compact position (bottom-centre stays put when the bubble opens).
        let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY)
        UserDefaults.standard.set([origin.x, origin.y], forKey: originKey)
    }

    // MARK: Actions

    func toggleVoiceNote() {
        let recorder = RecordingManager.shared
        if recorder.isActive {
            Task { await recorder.stop() }
        } else {
            Task { await recorder.start(kind: .voiceNote, title: "Voice note \(Date().formatted(date: .abbreviated, time: .shortened))") }
        }
    }

    /// Tap = hands-free dictation into the app you're using; tap again to stop and paste.
    func toggleDictation() {
        DictationController.shared.hotKeyDown(mode: Prefs.dictationDefaultMode)
        DictationController.shared.hotKeyUp()
    }
}

/// What the buddy's face shows.
enum BuddyMood: Equatable {
    case idle, listening, recording, thinking, speaking

    @MainActor
    static var current: BuddyMood {
        switch PilotVoice.shared.phase {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .idle: break
        }
        if RecordingManager.shared.isActive { return .recording }
        if DictationController.shared.phase.isActive {
            if case .listening = DictationController.shared.phase { return .listening }
            return .thinking
        }
        return .idle
    }
}

struct BuddyView: View {
    /// For screenshots: show this state instead of the live one.
    var previewMood: BuddyMood?
    var previewHover = false
    var previewBubble: (heard: String, reply: String)?
    @State private var hovering = false
    @State private var showMore = false
    private let buddy = FloatingBuddy.shared

    var body: some View {
        let mood = previewMood ?? BuddyMood.current
        let voice = PilotVoice.shared
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if previewBubble != nil || voice.showsBubble {
                SpeechBubble(heard: previewBubble?.heard ?? voice.heard, reply: previewBubble?.reply ?? voice.reply,
                             phase: previewMood.map { $0 == .listening ? .listening : $0 == .thinking ? .thinking : .speaking } ?? voice.phase)
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
            if showMore { morePill.transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)) }
            PilotMascot(mood: mood, excited: hovering || previewHover,
                        level: CGFloat(max(RecordingManager.shared.level, DictationController.shared.level, voice.level)))
                .frame(width: 104, height: 104)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { _ in buddy.dragChanged() }
                    .onEnded { _ in buddy.dragEnded() })
                .onTapGesture { PilotVoice.shared.toggle() }
                .help("Click and speak: “add a task…”, “what's next today?”, “start recording”, or any question · drag to move · right-click for more")
                .contextMenu { menu }
                .overlay(alignment: .topTrailing) {
                    if hovering || previewHover {
                        Button { buddy.setEnabled(false) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(.black.opacity(0.75)))
                                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Hide the buddy (bring it back from the menu bar, ⌥K or Settings)")
                        .accessibilityLabel("Hide buddy")
                        .transition(.scale.combined(with: .opacity))
                        .offset(x: 2, y: 4)
                    }
                }
            actionPill(mood: mood)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: voice.showsBubble)
        .onHover { inside in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = inside }
            if !inside { withAnimation(.easeOut(duration: 0.2)) { showMore = false } }
        }
    }

    private func actionPill(mood: BuddyMood) -> some View {
        HStack(spacing: 2) {
            pillButton(mood == .recording ? "stop.fill" : "mic.fill", tint: mood == .recording ? .red : nil,
                       help: mood == .recording ? "Stop recording" : "Record a voice note") { buddy.toggleVoiceNote() }
            pillButton(mood == .listening ? "waveform.circle.fill" : "waveform", tint: mood == .listening ? DS.accent : nil,
                       help: "Dictate into the app you're using (tap again to finish)") { buddy.toggleDictation() }
            pillButton("square.and.pencil", help: "New note") { WindowManager.shared.open(.notes, action: .newNote) }
            pillButton("ellipsis", help: "More") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showMore.toggle() }
            }
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private var morePill: some View {
        HStack(spacing: 2) {
            pillButton("sparkle.magnifyingglass", help: "Ask my Mac") { WindowManager.shared.toggleAskMac() }
            pillButton("camera.viewfinder", help: "Screenshot & read text") { ScreenCaptureTool.shared.captureArea() }
            pillButton("doc.on.clipboard", help: "Clipboard history") { WindowManager.shared.toggleClipboardPanel() }
            pillButton("command", help: "Launcher") { WindowManager.shared.toggleLauncher() }
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private func pillButton(_ symbol: String, tint: Color? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? .white)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Talk to Pilot") { PilotVoice.shared.toggle() }
        Button("Type to AI instead (⌥Space)") { WindowManager.shared.toggleQuickAssistant() }
        Button("Ask my Mac") { WindowManager.shared.toggleAskMac() }
        Button("Record a voice note") { buddy.toggleVoiceNote() }
        Button("Record a meeting") { RecordingManager.shared.toggleMeeting() }
        Button("New task") { WindowManager.shared.open(.tasks, action: .newTask) }
        Button("Open dashboard") { WindowManager.shared.showDashboard(section: .dashboard) }
        Divider()
        Button("Hide buddy") { buddy.setEnabled(false) }
    }
}

/// What Pilot heard and what it answers, above its head.
struct SpeechBubble: View {
    var heard: String
    var reply: String
    var phase: PilotVoice.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !heard.isEmpty {
                Text("“\(heard)”").font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
            }
            switch phase {
            case .listening where heard.isEmpty:
                Label("Listening…", systemImage: "waveform").font(.callout.weight(.medium))
            case .thinking:
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Thinking…").font(.callout) }
            default:
                if !reply.isEmpty { Text(reply).font(.callout).lineLimit(6).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 270, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.12, green: 0.11, blue: 0.24).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.accent.opacity(0.6)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .onTapGesture { PilotVoice.shared.stopAll() }
    }
}

/// The character: a rounded robot head with a visor, glowing eyes and a paper-plane antenna.
/// Bobs gently, blinks, looks happy on hover, shows a waveform while listening and a red light while recording.
struct PilotMascot: View {
    var mood: BuddyMood
    var excited = false
    var level: CGFloat = 0

    var body: some View {
        // Idle: a slow 12 fps bob and blink keeps it alive without costing battery; faster while listening/recording.
        TimelineView(.animation(minimumInterval: mood == .idle && !excited ? 1 / 12 : 1 / 30, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let bob = sin(t * 2.2) * (mood == .idle ? 2.5 : 1.2)
            let blinking = mood == .idle && !excited && t.truncatingRemainder(dividingBy: 4.2) < 0.14
            GeometryReader { proxy in
                let s = min(proxy.size.width, proxy.size.height)
                ZStack {
                    // Floor shadow
                    Ellipse().fill(.black.opacity(0.22))
                        .frame(width: s * 0.5, height: s * 0.08)
                        .blur(radius: 2)
                        .offset(y: s * 0.46)
                    ZStack {
                        antenna(s, t: t)
                        // Ears
                        HStack(spacing: s * 0.66) {
                            Capsule().fill(DS.indigo).frame(width: s * 0.08, height: s * 0.22)
                            Capsule().fill(DS.indigo).frame(width: s * 0.08, height: s * 0.22)
                        }
                        .offset(y: s * 0.02)
                        // Head
                        RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.55, blue: 1.0), DS.violet],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: s * 0.7, height: s * 0.6)
                            .overlay(
                                RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                            )
                            .shadow(color: DS.violet.opacity(0.45), radius: 6, y: 3)
                        // Visor
                        RoundedRectangle(cornerRadius: s * 0.15, style: .continuous)
                            .fill(Color(red: 0.08, green: 0.07, blue: 0.2))
                            .frame(width: s * 0.54, height: s * 0.36)
                            .overlay(face(s, t: t, blinking: blinking))
                            .offset(y: s * 0.01)
                        // Cheeks
                        HStack(spacing: s * 0.4) {
                            Circle().fill(.pink.opacity(excited ? 0.55 : 0.3))
                            Circle().fill(.pink.opacity(excited ? 0.55 : 0.3))
                        }
                        .frame(width: s * 0.5, height: s * 0.06)
                        .offset(y: s * 0.24)
                    }
                    .offset(y: bob - s * 0.04)
                    .scaleEffect(excited ? 1.06 : 1)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .accessibilityLabel("MacPilot buddy")
    }

    private func antenna(_ s: CGFloat, t: Double) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: s * 0.15, weight: .bold))
                .foregroundStyle(mood == .recording ? .red : .white)
                .rotationEffect(.degrees(-20 + sin(t * 3) * 6))
                .shadow(color: mood == .recording ? .red : DS.accent, radius: mood == .idle ? 2 : 5)
            Rectangle().fill(DS.indigo).frame(width: 2.5, height: s * 0.08)
        }
        .offset(y: -s * 0.38)
    }

    @ViewBuilder
    private func face(_ s: CGFloat, t: Double, blinking: Bool) -> some View {
        let glow = Color(red: 0.55, green: 0.95, blue: 1.0)
        switch mood {
        case .speaking:
            VStack(spacing: s * 0.035) {
                HStack(spacing: s * 0.13) {
                    eye(s, blinking: false, glow: glow)
                    eye(s, blinking: false, glow: glow)
                }
                // Talking mouth.
                Capsule().fill(glow)
                    .frame(width: s * 0.1, height: s * (0.025 + 0.05 * abs(sin(t * 11))))
            }
            .shadow(color: glow.opacity(0.8), radius: 3)
        case .listening, .thinking:
            // Voice bars that follow the microphone level.
            HStack(spacing: s * 0.03) {
                ForEach(0..<5) { index in
                    let wave = (sin(t * 9 + Double(index) * 1.3) + 1) / 2
                    let height = mood == .thinking ? 0.06 + wave * 0.05 : 0.05 + (0.08 + level * 1.4) * wave
                    Capsule().fill(glow).frame(width: s * 0.04, height: s * min(height, 0.26))
                }
            }
            .shadow(color: glow, radius: 4)
        default:
            VStack(spacing: s * 0.035) {
                HStack(spacing: s * 0.13) {
                    eye(s, blinking: blinking, glow: glow)
                    eye(s, blinking: blinking, glow: glow)
                }
                if mood == .recording {
                    HStack(spacing: 3) {
                        Circle().fill(.red).frame(width: s * 0.05).opacity(sin(t * 5) > 0 ? 1 : 0.35)
                        Text("REC").font(.system(size: s * 0.07, weight: .heavy, design: .rounded)).foregroundStyle(.red)
                    }
                } else {
                    // Smile
                    Capsule().fill(glow).frame(width: excited ? s * 0.14 : s * 0.1, height: s * 0.03)
                }
            }
            .shadow(color: glow.opacity(0.8), radius: 3)
        }
    }

    @ViewBuilder
    private func eye(_ s: CGFloat, blinking: Bool, glow: Color) -> some View {
        if excited {
            // Happy ^ ^ eyes on hover.
            Image(systemName: "chevron.up").font(.system(size: s * 0.1, weight: .black)).foregroundStyle(glow)
                .frame(width: s * 0.08, height: s * 0.1)
        } else {
            Capsule().fill(glow).frame(width: s * 0.07, height: blinking ? s * 0.015 : s * 0.11)
        }
    }
}
