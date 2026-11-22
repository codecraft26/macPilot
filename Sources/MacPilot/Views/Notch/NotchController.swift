import AppKit
import SwiftData
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

/// What the notch is showing right now (highest priority first).
enum NotchActivity: Equatable {
    case idle
    case recording(paused: Bool)
    case dictating
    case timer
    case meetingSoon(title: String, start: Date)
    case nowPlaying
    /// Live ↓/↑ throughput (optional, Settings → Notch).
    case network
}

/// A short message that drops out of the notch for a few seconds.
struct NotchPeek: Equatable, Identifiable {
    var id = UUID()
    var systemImage: String
    var tint: NotchTint = .accent
    var title: String
    var subtitle: String = ""
    var duration: Double = 4.5
    var action: NotchPeekAction?
    /// An extra button on the right of the banner (e.g. "Stop" for an automatic recording).
    var buttonTitle: String?
    var buttonAction: NotchPeekAction?

    static func == (lhs: NotchPeek, rhs: NotchPeek) -> Bool { lhs.id == rhs.id }
}

enum NotchTint: Equatable { case accent, red, orange, green, blue }

enum NotchPeekAction: Equatable {
    case openRecording(UUID, kind: RecordingKind)
    case joinMeeting(URL)
    case openTasks
    case stopRecording
    case reminderDone(UUID)
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
    private(set) var peekMessage: NotchPeek?
    private var peekTask: Task<Void, Never>?
    private var announced: Set<String> = []
    private var lastAnnouncementCheck = Date.distantPast

    /// Size of the panel window; the visible black shape is drawn inside it.
    static let panelSize = CGSize(width: 620, height: 440)
    static let expandedSize = CGSize(width: 560, height: 196)
    static let compactSideWidth: CGFloat = 78

    private var panel: NSPanel?
    private var timer: Timer?
    private var hoverStartedAt: Date?
    private var leftAt: Date?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var fileDragActive = false

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
        if isExpanded { return CGSize(width: Self.expandedSize.width, height: Self.expandedSize.height + 62 * CGFloat(extraCards)) }
        if peekMessage != nil { return CGSize(width: max(geometry.notch.width + 160, 380), height: geometry.notch.height + 54) }
        let notch = geometry.notch.size
        switch activity {
        case .idle: return geometry.hasHardwareNotch ? notch : .zero
        default: return CGSize(width: notch.width + Self.compactSideWidth * 2, height: notch.height)
        }
    }

    /// Timer and music cards shown below the main card when expanded.
    var extraCards: Int {
        var count = 0
        if NotchTimers.shared.current != nil { count += 1 }
        if NowPlaying.shared.track != nil { count += 1 }
        if !NotchShelf.shared.items.isEmpty || NotchShelf.shared.isDropTargeted { count += 1 }
        if UserDefaults.standard.bool(forKey: PrefKey.notchNetworkCard) { count += 1 }
        return count
    }

    /// Shows a message for a few seconds (only when the notch is enabled).
    func peek(_ message: NotchPeek) {
        guard Self.isEnabled, panel != nil else { return }
        peekTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { peekMessage = message }
        peekTask = Task {
            try? await Task.sleep(for: .seconds(message.duration))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { peekMessage = nil }
        }
    }

    func dismissPeek() {
        peekTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { peekMessage = nil }
    }

    func perform(_ action: NotchPeekAction) {
        dismissPeek()
        switch action {
        case let .openRecording(id, kind):
            WindowManager.shared.open(kind == .meeting ? .calendar : .voice, action: .openRecording(id))
        case .joinMeeting(let url):
            NSWorkspace.shared.open(url)
        case .openTasks:
            WindowManager.shared.showDashboard(section: .tasks)
        case .stopRecording:
            Task { await RecordingManager.shared.stop() }
        case .reminderDone(let id):
            if let reminder = ReminderEngine.shared.reminders.first(where: { $0.uid == id }) { ReminderEngine.shared.done(reminder) }
        }
    }

    /// Meetings starting now and tasks falling due, announced once each.
    private func checkAnnouncements(now: Date) {
        guard now.timeIntervalSince(lastAnnouncementCheck) > 15 else { return }
        lastAnnouncementCheck = now
        if let event = CalendarService.shared.upcoming(limit: 3, withinDays: 1).first(where: { abs($0.start.timeIntervalSince(now)) < 60 }),
           announced.insert("event:\(event.id):\(event.start.timeIntervalSince1970)").inserted {
            let link = MeetingLink.find(in: [event.location, event.notes])
            peek(NotchPeek(systemImage: "video.fill", tint: .green, title: "Starting now: \(event.title)",
                           subtitle: link == nil ? event.location : "Click to join", duration: 10, action: link.map { .joinMeeting($0) }))
        }
        let context = Persistence.container.mainContext
        let soon = now.addingTimeInterval(30)
        let recent = now.addingTimeInterval(-60)
        if let tasks = try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isCompleted })),
           let due = tasks.first(where: { ($0.dueDate ?? .distantPast) <= soon && ($0.dueDate ?? .distantPast) > recent }),
           announced.insert("task:\(due.uid)").inserted {
            peek(NotchPeek(systemImage: "checklist", tint: .blue, title: "Due now: \(due.title)", duration: 8, action: .openTasks))
        }
    }

    private func tick() {
        updateActivity()
        checkAnnouncements(now: Date())
        guard let panel else { return }
        // Hit-test the visible shape (plus the notch itself so hovering the notch opens it).
        let mouse = NSEvent.mouseLocation
        let size = shapeSize
        let shapeRect = CGRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        // On screens without a notch, the empty top centre only reacts while something is showing.
        let idleWithoutNotch = !geometry.hasHardwareNotch && activity == .idle && !isExpanded && peekMessage == nil
        let hotRect = idleWithoutNotch ? .zero : shapeRect.union(geometry.notch).insetBy(dx: -4, dy: -2)
        var inside = hotRect.contains(mouse)

        // File shelf: while files are dragged near the notch, open it as a drop zone.
        let buttonDown = NSEvent.pressedMouseButtons & 1 == 1
        if buttonDown {
            let changeCount = NSPasteboard(name: .drag).changeCount
            if changeCount != dragChangeCount {
                dragChangeCount = changeCount
                fileDragActive = !NotchShelf.draggedFileURLs().isEmpty
            }
        } else {
            fileDragActive = false
        }
        let dropZone = geometry.notch.insetBy(dx: -170, dy: -90)
        let dragNear = fileDragActive && UserDefaults.standard.bool(forKey: PrefKey.notchShelfEnabled)
            && (dropZone.contains(mouse) || (isExpanded && shapeRect.contains(mouse)))
        if dragNear != NotchShelf.shared.isDropTargeted {
            NotchShelf.shared.isDropTargeted = dragNear
            if dragNear { withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) { isExpanded = true } }
        }
        if dragNear { inside = true }
        panel.ignoresMouseEvents = !inside

        let now = Date()
        if inside, peekMessage != nil {
            // Hovering a peek keeps it open; clicking it runs its action (handled by the view).
            hoverStartedAt = nil
        } else if inside {
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
        } else if NotchTimers.shared.current != nil {
            next = .timer
        } else if UserDefaults.standard.bool(forKey: PrefKey.notchMeetingCountdown),
                  let event = CalendarService.shared.upcoming(limit: 1, withinDays: 1).first,
                  event.start.timeIntervalSinceNow < 15 * 60, event.end > Date() {
            next = .meetingSoon(title: event.title, start: event.start)
        } else if NowPlaying.shared.isPlaying {
            next = .nowPlaying
        } else if UserDefaults.standard.bool(forKey: PrefKey.notchNetworkReadout) {
            next = .network
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
