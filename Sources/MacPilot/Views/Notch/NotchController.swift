import AppKit
import Observation
import SwiftUI

/// Geometry of the camera notch (or a stand-in on screens without one).
struct NotchGeometry: Equatable {
    /// Notch frame in screen coordinates (Cocoa: origin bottom-left).
    var notch: CGRect
    var hasHardwareNotch: Bool

    /// The built-in display with a notch if there is one, otherwise the main display with a menu-bar-sized stand-in.
    @MainActor
    static func current() -> (screen: NSScreen, geometry: NotchGeometry)? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let height = screen.safeAreaInsets.top
            let x = screen.frame.minX + left.width
            let width = screen.frame.width - left.width - right.width
            return (screen, NotchGeometry(notch: CGRect(x: x, y: screen.frame.maxY - height, width: width, height: height), hasHardwareNotch: true))
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let width: CGFloat = 190
        return (screen, NotchGeometry(notch: CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height),
                                      hasHardwareNotch: false))
    }
}

/// What the notch is showing right now.
enum NotchActivity: Equatable {
    case idle
    case recording(paused: Bool)
    case dictating
    case meetingSoon(title: String, start: Date)
}

/// A Dynamic Island–style area around the MacBook notch: live status when something is happening,
/// expands on hover with controls, the next meeting and quick actions.
@Observable
@MainActor
final class NotchController {
    static let shared = NotchController()

    private(set) var geometry = NotchGeometry(notch: .zero, hasHardwareNotch: false)
    private(set) var isExpanded = false
    private(set) var activity: NotchActivity = .idle

    /// Size of the panel window; the visible black shape is drawn inside it.
    static let panelSize = CGSize(width: 620, height: 300)
    static let expandedSize = CGSize(width: 560, height: 196)
    static let compactSideWidth: CGFloat = 78

    private var panel: NSPanel?
    private var timer: Timer?
    private var hoverStartedAt: Date?
    private var leftAt: Date?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.notchEnabled) }

    private init() {}

    func start() {
        guard Self.isEnabled else { stop(); return }
        if panel == nil { makePanel() }
        layout()
        panel?.orderFrontRegardless()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { NotchController.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.layout() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    /// For previews and snapshots only.
    func setPreview(geometry: NotchGeometry, activity: NotchActivity, expanded: Bool) {
        self.geometry = geometry
        self.activity = activity
        self.isExpanded = expanded
    }

    func collapse() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { isExpanded = false }
    }

    // MARK: Window

    private func makePanel() {
        let panel = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.panelSize))
        let hosting = NSHostingView(rootView: NotchView().environment(AppState.shared).modelContainer(Persistence.container))
        hosting.frame = CGRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hosting
        self.panel = panel
    }

    private func layout() {
        guard let panel, let (screen, geometry) = NotchGeometry.current() else { return }
        self.geometry = geometry
        let origin = CGPoint(x: geometry.notch.midX - Self.panelSize.width / 2, y: screen.frame.maxY - Self.panelSize.height)
        panel.setFrame(CGRect(origin: origin, size: Self.panelSize), display: true)
    }

    // MARK: State

    /// Visible shape in panel coordinates (top-left origin, like SwiftUI).
    var shapeSize: CGSize {
        if isExpanded { return Self.expandedSize }
        let notch = geometry.notch.size
        switch activity {
        case .idle: return geometry.hasHardwareNotch ? notch : .zero
        default: return CGSize(width: notch.width + Self.compactSideWidth * 2, height: notch.height)
        }
    }

    private func tick() {
        updateActivity()
        guard let panel else { return }
        // Hit-test the visible shape (plus the notch itself so hovering the notch opens it).
        let mouse = NSEvent.mouseLocation
        let size = shapeSize
        let shapeRect = CGRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        // On screens without a notch, the empty top centre only reacts while something is showing.
        let idleWithoutNotch = !geometry.hasHardwareNotch && activity == .idle && !isExpanded
        let hotRect = idleWithoutNotch ? .zero : shapeRect.union(geometry.notch).insetBy(dx: -4, dy: -2)
        let inside = hotRect.contains(mouse)
        panel.ignoresMouseEvents = !inside

        let now = Date()
        if inside {
            leftAt = nil
            if hoverStartedAt == nil { hoverStartedAt = now }
            if !isExpanded, let started = hoverStartedAt, now.timeIntervalSince(started) > 0.18,
               UserDefaults.standard.bool(forKey: PrefKey.notchExpandOnHover) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { isExpanded = true }
            }
        } else {
            hoverStartedAt = nil
            if isExpanded {
                if leftAt == nil { leftAt = now }
                if let left = leftAt, now.timeIntervalSince(left) > 0.35 { collapse() }
            }
        }
    }

    private func updateActivity() {
        let recorder = RecordingManager.shared
        let dictation = DictationController.shared
        var next: NotchActivity = .idle
        if recorder.isActive {
            next = .recording(paused: recorder.isPaused)
        } else if dictation.phase.isActive {
            next = .dictating
        } else if UserDefaults.standard.bool(forKey: PrefKey.notchMeetingCountdown),
                  let event = CalendarService.shared.upcoming(limit: 1, withinDays: 1).first,
                  event.start.timeIntervalSinceNow < 15 * 60, event.end > Date() {
            next = .meetingSoon(title: event.title, start: event.start)
        }
        if next != activity {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { activity = next }
        }
    }
}

private final class NotchPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar so it can sit on the notch.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Finds a video-call link in an event's location or notes.
enum MeetingLink {
    static func find(in texts: [String]) -> URL? {
        let pattern = #"https://[^\s<>"]*(zoom\.us/(j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|webex\.com/|whereby\.com/|around\.co/)[^\s<>"]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) {
                let link = String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;>"))
                if let url = URL(string: link) { return url }
            }
        }
        return nil
    }
}
