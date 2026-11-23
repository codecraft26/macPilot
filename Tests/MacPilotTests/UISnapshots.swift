import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import MacPilot

/// Renders key screens to PNGs for visual review. Skipped unless SNAPSHOT_DIR is set:
///   SNAPSHOT_DIR=/tmp/shots swift test --filter UISnapshots
@MainActor
final class UISnapshots: XCTestCase {
    private var directory: URL!
    private var appearance = NSAppearance(named: .aqua)
    private var container: ModelContainer!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else {
            throw XCTSkip("Set SNAPSHOT_DIR to render UI snapshots.")
        }
        directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        container = try ModelContainer(for: Persistence.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        seed(container.mainContext)
    }

    private func seed(_ context: ModelContext) {
        let tasks = [("Send Q4 roadmap to the team", 2, 3), ("Review PR #214", 0, 2), ("Book flights for offsite", -1, 1), ("Renew domain", 5, 0)]
        for (title, days, priority) in tasks {
            let task = TaskItem(title: title, dueDate: Calendar.current.date(byAdding: .day, value: days, to: Date()), priority: TaskPriority(rawValue: priority) ?? .none)
            context.insert(task)
        }
        let n1 = Note(title: "Product ideas", body: "- Smart clipboard\n- Meeting recap emails", folder: "Ideas")
        n1.isPinned = true
        context.insert(n1)
        context.insert(Note(title: "1:1 with Sam", body: "Career goals, feedback", folder: "Meetings"))
        context.insert(Note(body: "Buy milk", folder: "Quick notes"))
        let conversation = Conversation(provider: .anthropic, model: "claude-opus-5-5")
        conversation.title = "Explain Swift concurrency"
        context.insert(conversation)
        let question = ChatMessage(role: .user, content: "How do I run two network calls in parallel in Swift?")
        let answer = ChatMessage(role: .assistant, content: "Use `async let` so both requests start immediately, then await them together:\n\n```swift\nasync let user = api.user(id)\nasync let posts = api.posts(for: id)\nlet (u, p) = try await (user, posts)\n```\n\nBoth calls run **concurrently**; the total time is the slower of the two.")
        answer.createdAt = Date().addingTimeInterval(1)
        context.insert(question)
        context.insert(answer)
        question.conversation = conversation
        answer.conversation = conversation
        let recording = Recording(kind: .meeting, title: "Weekly product sync", attendees: "Sam, Priya, Alex")
        recording.duration = 1834
        recording.status = .ready
        recording.summary = "The team agreed to ship clipboard history in 0.6 and move calendar sync to the next sprint. Priya will own the release notes; Alex will finish the onboarding flow."
        recording.decisions = ["Ship clipboard history in 0.6", "Move Google Calendar sync to next sprint"]
        recording.actionItems = [ActionItem(task: "Write release notes", owner: "Priya", due: "Friday"), ActionItem(task: "Finish onboarding flow", owner: "Alex")]
        recording.segments = [TranscriptSegment(start: 3, end: 9, speaker: "Me", text: "Let's start with the release."),
                              TranscriptSegment(start: 10, end: 18, speaker: "Others", text: "Clipboard history is ready for 0.6.")]
        context.insert(recording)
        for (text, app) in [("https://developer.apple.com/documentation/swiftui", "Safari"), ("let total = items.reduce(0) { $0 + $1.price }", "Xcode"),
                            ("#5B5BF7", "Figma"), ("Thanks for the update — see you tomorrow!", "Slack")] {
            let clip = ClipboardItem(kind: ClipboardMonitor.classify(text), text: text, contentHash: UUID().uuidString)
            clip.sourceAppName = app
            context.insert(clip)
        }
        try? context.save()
    }

    private func snapshot<V: View>(_ name: String, size: CGSize, _ view: V) {
        let root = view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(AppState.shared)
            .modelContainer(container)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = appearance
        hosting.appearance = appearance
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = rep.representation(using: .png, properties: [:])
        try? data?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func sampleGrid(week: Bool) -> some View {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        let days = week ? (0..<7).map { cal.date(byAdding: .day, value: $0, to: weekStart)! } : [Date()]
        func at(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date { cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)! }
        let work = CalendarInfo(rawID: "w", source: .apple, title: "Work", color: RGBColor(red: 0.2, green: 0.5, blue: 1), isWritable: true)
        let personal = CalendarInfo(rawID: "p", source: .google, title: "Personal", color: RGBColor(red: 0.95, green: 0.4, blue: 0.3), isWritable: true)
        var events: [CalendarEvent] = []
        for (index, day) in days.enumerated() {
            events.append(CalendarEvent(id: "s\(index)", title: "Standup", start: at(day, 9, 30), end: at(day, 9, 45), isAllDay: false, location: "Zoom", notes: "", attendees: [], calendar: work))
            if index % 2 == 0 {
                events.append(CalendarEvent(id: "r\(index)", title: "Design review", start: at(day, 11), end: at(day, 12), isAllDay: false, location: "Room 4", notes: "", attendees: ["Sam"], calendar: work))
                events.append(CalendarEvent(id: "c\(index)", title: "Customer call", start: at(day, 11, 30), end: at(day, 12, 30), isAllDay: false, location: "", notes: "", attendees: [], calendar: personal))
            }
            events.append(CalendarEvent(id: "l\(index)", title: "Lunch", start: at(day, 13), end: at(day, 14), isAllDay: false, location: "", notes: "", attendees: [], calendar: personal))
        }
        events.append(CalendarEvent(id: "a", title: "Offsite", start: cal.startOfDay(for: days[0]), end: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: days[0]))!, isAllDay: true, location: "", notes: "", attendees: [], calendar: personal))
        let spans = events.filter { !$0.isAllDay }.map { EventSpan(id: $0.id, start: $0.start, end: $0.end) }
        let actions = EventActions(edit: { _ in }, record: { _ in }, prep: { _ in }, delete: { _ in })
        return TimeGrid(days: days, events: events, conflicts: EventSpan.conflictingIDs(spans), actions: actions)
    }

    func testRenderScreens() {
        let big = CGSize(width: 1180, height: 760)
        AppState.shared.selectedSection = .dashboard
        snapshot("1-root-dashboard", size: big, RootView())
        snapshot("2-tasks", size: big, TasksView())
        snapshot("3-notes", size: big, NotesView())
        snapshot("4-voice", size: big, VoiceView())
        snapshot("5-clipboard", size: big, ClipboardView())
        snapshot("6-developer", size: big, DeveloperView())
        snapshot("7-calendar", size: big, CalendarMeetingsView())
        snapshot("8-clip-panel", size: CGSize(width: 780, height: 480), ClipboardPanelView())
        snapshot("9-launcher", size: CGSize(width: 680, height: 440), LauncherView())
        snapshot("10-settings", size: big, SettingsView())
        snapshot("17-file-tools", size: big, FileToolsView())
        let notchGeometry = NotchGeometry(notch: CGRect(x: 0, y: 0, width: 200, height: 32), hasHardwareNotch: true)
        let wallpaper = LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.55), Color(red: 0.55, green: 0.35, blue: 0.6)], startPoint: .top, endPoint: .bottom)
        for (name, activity, expanded) in [("notch-recording", NotchActivity.recording(paused: false), false),
                                           ("notch-meeting", NotchActivity.meetingSoon(title: "Design review", start: Date().addingTimeInterval(480)), false),
                                           ("notch-expanded", NotchActivity.idle, true)] {
            NotchController.shared.setPreview(geometry: notchGeometry, activity: activity, expanded: expanded)
            snapshot(name, size: NotchController.panelSize, ZStack(alignment: .top) { wallpaper; NotchView() })
        }
        snapshot("15-week-grid", size: big, sampleGrid(week: true))
        snapshot("16-day-grid", size: CGSize(width: 800, height: 900), sampleGrid(week: false))
        snapshot("11-assistant", size: big, AssistantView())
        snapshot("12-quick-assistant", size: CGSize(width: 680, height: 460), QuickAssistantView())
        appearance = NSAppearance(named: .darkAqua)
        snapshot("13-dashboard-dark", size: big, RootView())
        snapshot("14-assistant-dark", size: big, AssistantView())
        appearance = NSAppearance(named: .aqua)
    }

    func testRenderAutomations() throws {
        let context = container.mainContext
        let workflow = AutomationWorkflow(name: "Weekly sync transcript")
        workflow.action = .copyTranscript
        context.insert(workflow)
        let event = AutomationEvent(trigger: .transcriptReady, id: "weekly-sync", date: Date(),
                                    title: "Weekly product sync", body: "The team agreed to update the release notes.")
        AutomationEngine.handle(event, workflows: [workflow], context: context)
        try context.save()
        snapshot("automations", size: CGSize(width: 900, height: 640), AutomationsView())
    }

    // MARK: Features added in 0.15–0.17

    /// A small multi-page PDF that looks like a real document.
    private func samplePDF() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Quarterly report.pdf")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        let titles = ["Quarterly report", "Highlights", "Revenue", "Customers", "Roadmap", "Appendix"]
        for (index, title) in titles.enumerated() {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor(calibratedRed: 0.33, green: 0.36, blue: 0.98, alpha: 1).setFill()
            NSRect(x: 0, y: 720, width: 612, height: 72).fill()
            NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.white])
                .draw(at: NSPoint(x: 48, y: 740))
            for line in 0..<14 {
                NSColor(white: 0.85, alpha: 1).setFill()
                let width = CGFloat(300 + (line * 37 + index * 53) % 216)
                let y = CGFloat(660 - line * 34)
                NSRect(x: 48, y: y, width: width, height: 12).fill()
            }
            if index == 2 {
                for bar in 0..<6 {
                    NSColor(calibratedRed: 0.6, green: 0.3, blue: 0.95, alpha: 1).setFill()
                    let x = CGFloat(80 + bar * 80), height = CGFloat(40 + bar * 30)
                    NSRect(x: x, y: 90, width: 50, height: height).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        try? (data as Data).write(to: url)
        return url
    }

    /// Something that looks like a captured Xcode error, for the screenshot panel.
    private func sampleCapture() -> NSImage {
        NSImage(size: NSSize(width: 520, height: 300), flipped: true) { rect in
            NSColor(white: 0.12, alpha: 1).setFill()
            rect.fill()
            let mono = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
            let lines: [(String, NSColor)] = [
                ("func loadUser() async throws -> User {", .white),
                ("    let data = try await api.get(\"/me\")", .white),
                ("    return try decoder.decode(User.self, from: data)", .white),
                ("}", .white),
                ("", .white),
                ("error: keyNotFound(\"createdAt\")", NSColor.systemRed),
                ("  No value associated with key \"createdAt\"", NSColor.systemOrange)
            ]
            for (index, line) in lines.enumerated() {
                NSAttributedString(string: line.0, attributes: [.font: mono, .foregroundColor: line.1])
                    .draw(at: NSPoint(x: 24, y: CGFloat(30 + index * 30)))
            }
            return true
        }
    }

    func testRenderNewFeatures() {
        let big = CGSize(width: 1180, height: 760)
        DailyBriefing.shared.setPreview("""
        A focused day: two meetings before lunch and one overdue task to clear first.

        **Meetings**
        - 10:00 Design review with Sam and Priya
        - 11:30 Customer call — Acme renewal

        **Due & overdue**
        - Send Q4 roadmap to the team *(overdue)*
        - Review PR #214 (today)

        **Open from recent meetings**
        - Write release notes — Priya, due Friday

        **Suggested focus**
        - Send the roadmap before the design review so it can be discussed there.
        """)
        AppState.shared.selectedSection = .dashboard
        snapshot("briefing-dashboard", size: CGSize(width: 1000, height: 820), DashboardView())

        TextActionsController.shared.setPreview(
            selection: "hey team, i think we shoud move the launch to next week becuase the onboarding isnt ready and we dont want users to get confused",
            action: .professional,
            result: "Hi team, I suggest we move the launch to next week. The onboarding flow isn't ready yet, and we want to avoid confusing new users.")
        snapshot("text-actions", size: CGSize(width: 520, height: 470), TextActionsView())
        TextActionsController.shared.reset()
        snapshot("text-actions-menu", size: CGSize(width: 520, height: 560), TextActionsView())

        let now = Date()
        AskMyMacController.shared.setPreview(
            question: "What did we decide about the launch date?",
            answer: "You agreed to **ship clipboard history in 0.6** and move Google Calendar sync to the next sprint [1]. Priya owns the release notes, due Friday [1][2], and the launch email is drafted in your notes [3].",
            sources: [
                KnowledgeSource(id: "1", kind: .meeting, title: "Weekly product sync", date: now.addingTimeInterval(-86_400), text: "", itemID: UUID()),
                KnowledgeSource(id: "2", kind: .task, title: "Write release notes (Priya)", date: now, text: "", itemID: UUID()),
                KnowledgeSource(id: "3", kind: .note, title: "Launch email draft", date: now.addingTimeInterval(-3 * 86_400), text: "", itemID: UUID())
            ])
        snapshot("ask-my-mac", size: CGSize(width: 640, height: 480), AskMyMacView())

        ScreenCaptureTool.shared.setPreview(image: sampleCapture(), text: """
        func loadUser() async throws -> User {
            let data = try await api.get("/me")
            return try decoder.decode(User.self, from: data)
        }
        error: keyNotFound("createdAt")
          No value associated with key "createdAt"
        """)
        snapshot("screenshot-tool", size: CGSize(width: 640, height: 440), ScreenshotView())

        snapshot("pdf-page-editor", size: big, PDFPageEditorView(onBack: {}, initialURL: samplePDF()))
        snapshot("settings-snippets", size: CGSize(width: 900, height: 900), SnippetsSettingsView())
        snapshot("settings-sync", size: CGSize(width: 760, height: 640), SyncSettingsView())

        let context = container.mainContext
        if let meeting = try? context.fetch(FetchDescriptor<Recording>()).first {
            meeting.followUpEmail = "Subject: Weekly product sync — next steps\n\nHi all,\n\nThanks for today. We'll ship clipboard history in 0.6; Priya is writing the release notes (Friday) and Alex is finishing onboarding.\n\nBest,\nMe"
            meeting.attendees = "Sam <sam@acme.com>, Priya <priya@acme.com>, Alex <alex@acme.com>"
            snapshot("meeting-follow-up", size: CGSize(width: 900, height: 860), RecordingDetailView(recording: meeting, onDelete: {}))
        }
    }

    // MARK: Mac-style shots (real window frame, desktop background, shadow)

    /// A soft desktop background (generated, so it can ship in the repo).
    private func drawDesktop(in rect: NSRect) {
        NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.85, alpha: 1),
                            NSColor(calibratedRed: 0.62, green: 0.36, blue: 0.86, alpha: 1),
                            NSColor(calibratedRed: 0.98, green: 0.60, blue: 0.55, alpha: 1)])!
            .draw(in: rect, angle: -35)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.width * 0.55, y: -rect.height * 0.3, width: rect.width * 0.8, height: rect.height * 1.1)).fill()
    }

    /// Draws macOS's menu bar across the top of `rect` (flipped = false coordinates).
    private func drawMenuBar(in rect: NSRect, height: CGFloat = 28) {
        let bar = NSRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
        NSColor.white.withAlphaComponent(0.28).setFill()
        bar.fill()
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        var x: CGFloat = 18
        let apple = NSAttributedString(string: "\u{F8FF}", attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black])
        apple.draw(at: NSPoint(x: x, y: bar.minY + 5))
        x += 30
        for (index, item) in ["MacPilot", "File", "Edit", "View", "Window", "Help"].enumerated() {
            let text = NSAttributedString(string: item, attributes: [.font: index == 0 ? NSFont.boldSystemFont(ofSize: 13) : font, .foregroundColor: NSColor.black])
            text.draw(at: NSPoint(x: x, y: bar.minY + 6))
            x += text.size().width + 20
        }
        let clock = NSAttributedString(string: "Fri 20 Nov  9:41 AM", attributes: [.font: font, .foregroundColor: NSColor.black])
        clock.draw(at: NSPoint(x: rect.maxX - clock.size().width - 18, y: bar.minY + 6))
        if let icon = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil) {
            icon.draw(in: NSRect(x: rect.maxX - clock.size().width - 46, y: bar.minY + 7, width: 15, height: 15))
        }
    }

    /// Renders `view` in a real titled NSWindow (title bar + traffic lights), or as a rounded floating panel,
    /// then places it on the desktop with a menu bar and a window shadow.
    private func macShot<V: View>(_ name: String, size: CGSize, title: String? = nil, panel: Bool = false, _ view: V) {
        let root = view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(AppState.shared)
            .modelContainer(container)
        let hosting = NSHostingView(rootView: root)
        let style: NSWindow.StyleMask = panel ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title ?? ""
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        // Sidebar selection uses vibrancy, which renders black offscreen: draw it as a solid accent row instead.
        func solidSelection(_ view: NSView) {
            if let table = view as? NSTableView {
                if table.style != .sourceList {
                    // Content lists: paint the selected row as a soft accent highlight instead of the black vibrancy block.
                    for row in table.selectedRowIndexes {
                        guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { continue }
                        rowView.isSelected = false
                        rowView.wantsLayer = true
                        rowView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
                        rowView.layer?.cornerRadius = 6
                    }
                    return
                }
                table.style = .sourceList
                table.selectionHighlightStyle = .regular
            }
            if let effect = view as? NSVisualEffectView { effect.blendingMode = .withinWindow; effect.state = .inactive }
            view.subviews.forEach(solidSelection)
        }
        solidSelection(window.contentView?.superview ?? hosting)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let frameView = panel ? hosting : (hosting.superview ?? hosting)
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let windowImage = NSImage(size: frameView.bounds.size)
        windowImage.addRepresentation(rep)

        let margin: CGFloat = 70, menuBar: CGFloat = 28
        let canvas = NSSize(width: frameView.bounds.width + margin * 2, height: frameView.bounds.height + margin * 2 + menuBar)
        let output = NSImage(size: canvas, flipped: false) { rect in
            self.drawDesktop(in: rect)
            self.drawMenuBar(in: rect, height: menuBar)
            let frame = NSRect(x: margin, y: margin, width: frameView.bounds.width, height: frameView.bounds.height)
            let radius: CGFloat = panel ? 14 : 10
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 36
            shadow.shadowOffset = NSSize(width: 0, height: -14)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
            windowImage.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            border.lineWidth = 1
            border.stroke()
            return true
        }
        guard let tiff = output.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// The notch as it looks on a MacBook: desktop, menu bar split by the camera housing, MacPilot's notch on top.
    private func notchShot(_ name: String, activity: NotchActivity, expanded: Bool) {
        let size = NotchController.panelSize
        let geometry = NotchGeometry(notch: CGRect(x: size.width / 2 - 100, y: 0, width: 200, height: 32), hasHardwareNotch: true)
        NotchController.shared.setPreview(geometry: geometry, activity: activity, expanded: expanded)
        let hosting = NSHostingView(rootView: NotchView().environment(AppState.shared).modelContainer(container))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let notchImage = NSImage(size: size)
        notchImage.addRepresentation(rep)

        let canvas = NSSize(width: 1100, height: expanded ? 330 : 150)
        let output = NSImage(size: canvas, flipped: false) { rect in
            self.drawDesktop(in: rect)
            self.drawMenuBar(in: rect, height: 32)
            // Camera housing.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 100, y: rect.maxY - 32, width: 200, height: 40), xRadius: 10, yRadius: 10).fill()
            notchImage.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.maxY - size.height, width: size.width, height: size.height))
            return true
        }
        guard let tiff = output.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    func testRenderSetupWizard() {
        let setup = SetupController.shared
        let saved = setup.progress
        defer { setup.progress = saved }
        setup.progress = SetupProgress()
        setup.progress.completed = [.welcome, .provider]
        setup.progress.skipped = []
        setup.progress.current = .permissions
        macShot("setup-permissions", size: CGSize(width: 760, height: 560), title: "Set up MacPilot", SetupWizardView())
        setup.progress.current = .welcome
        macShot("setup-welcome", size: CGSize(width: 760, height: 560), title: "Set up MacPilot", SetupWizardView())
    }

    func testRenderCleanup() {
        let now = Date()
        let home = NSHomeDirectory()
        func days(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
        let items = [
            CleanupItem(category: .nodeModules, title: "storefront", detail: "~/Developer/storefront", url: URL(fileURLWithPath: home + "/Developer/storefront/node_modules"), bytes: 1_480_000_000, modified: days(140)),
            CleanupItem(category: .nodeModules, title: "landing-page", detail: "~/Projects/landing-page", url: URL(fileURLWithPath: home + "/Projects/landing-page/node_modules"), bytes: 612_000_000, modified: days(64)),
            CleanupItem(category: .nodeModules, title: "macpilot-site", detail: "~/Code/macpilot-site", url: URL(fileURLWithPath: home + "/Code/macpilot-site/node_modules"), bytes: 455_000_000, modified: days(2), isRecent: true),
            CleanupItem(category: .derivedData, title: "MacPilot", url: URL(fileURLWithPath: home + "/Library/Developer/Xcode/DerivedData/MacPilot-a"), bytes: 3_900_000_000, modified: days(1)),
            CleanupItem(category: .derivedData, title: "Notes", url: URL(fileURLWithPath: home + "/Library/Developer/Xcode/DerivedData/Notes-b"), bytes: 1_200_000_000, modified: days(95)),
            CleanupItem(category: .deviceSupport, title: "17.4 (21E219)", url: URL(fileURLWithPath: home + "/Library/Developer/Xcode/iOS DeviceSupport/17.4"), bytes: 2_700_000_000, modified: days(210)),
            CleanupItem(category: .unavailableSimulators, title: "3 unavailable simulators", bytes: 0, command: CleanupCommands.simctlDeleteUnavailable),
            CleanupItem(category: .dockerBuildCache, title: "Docker build cache", bytes: 1_900_000_000, command: CleanupCommands.dockerBuilderPrune),
            CleanupItem(category: .npmCache, title: "npm cache", detail: "~/.npm/_cacache", url: URL(fileURLWithPath: home + "/.npm/_cacache"), bytes: 194_000_000, modified: days(3)),
            CleanupItem(category: .homebrew, title: "Old Homebrew downloads and versions", bytes: 78_000_000, command: CleanupCommands.brewCleanup)
        ]
        let cleanup = DevCleanup.shared
        cleanup.showForPreview(items)
        defer { cleanup.showForPreview([]) }
        macShot("dev-cleanup", size: CGSize(width: 1000, height: 860), title: "Developer Workspace — Cleanup", CleanupView())
        macShot("dev-cleanup-card", size: CGSize(width: 640, height: 70), title: nil, panel: true, CleanupDashboardCard().padding(10))
    }

    func testRenderMacScreens() {
        VisualEffectBackground.hiddenForSnapshots = true
        defer { VisualEffectBackground.hiddenForSnapshots = false }
        let window = CGSize(width: 1180, height: 740)
        AppState.shared.selectedSection = .dashboard
        DailyBriefing.shared.setPreview("""
        A focused day: two meetings before lunch and one overdue task to clear first.

        **Meetings**
        - 10:00 Design review with Sam and Priya
        - 11:30 Customer call — Acme renewal

        **Suggested focus**
        - Send the Q4 roadmap before the design review so it can be discussed there.
        """)
        macShot("dashboard", size: CGSize(width: 1180, height: 820), title: "MacPilot", RootView())
        macShot("assistant", size: window, title: "AI Assistant", AssistantView())
        macShot("quick-assistant", size: CGSize(width: 680, height: 460), panel: true, QuickAssistantView())
        macShot("recordings", size: window, title: "Voice & Transcription", VoiceView())
        macShot("calendar", size: window, title: "Calendar & Meetings", sampleGrid(week: true))
        if let note = try? container.mainContext.fetch(FetchDescriptor<Note>()).first(where: { $0.title == "Product ideas" }) {
            note.body = """
            # Product ideas

            ## Next release
            - **Smart clipboard** — group copies by project
            - Meeting recap emails sent automatically
            - [ ] Prototype the notch timer presets

            ## Research
            > Users want one shortcut for everything.

            Links: [Design doc](https://example.com) · #roadmap #ideas
            """
            note.tagsRaw = "roadmap, ideas"
            AppState.shared.pendingAction = .openNote(note.uid)
        }
        macShot("notes", size: window, title: "Notes & Knowledge", NotesView())
        macShot("tasks", size: window, title: "Tasks & Reminders", TasksView())
        macShot("clipboard", size: window, title: "Clipboard", ClipboardView())
        macShot("clipboard-panel", size: CGSize(width: 780, height: 480), panel: true, ClipboardPanelView())
        macShot("launcher", size: CGSize(width: 680, height: 440), panel: true, LauncherView())
        macShot("file-tools", size: window, title: "File Tools", FileToolsView())
        macShot("pdf-page-editor", size: window, title: "File Tools", PDFPageEditorView(onBack: {}, initialURL: samplePDF()))
        macShot("developer", size: window, title: "Developer Workspace", DeveloperView())
        macShot("settings", size: CGSize(width: 980, height: 700), title: "Settings", SettingsView())

        TextActionsController.shared.setPreview(
            selection: "hey team, i think we shoud move the launch to next week becuase the onboarding isnt ready",
            action: .professional,
            result: "Hi team, I suggest we move the launch to next week. The onboarding flow isn't ready yet, and we want new users to have a smooth first experience.")
        macShot("text-actions", size: CGSize(width: 520, height: 470), panel: true, TextActionsView())
        AskMyMacController.shared.setPreview(
            question: "What did we decide about the launch date?",
            answer: "You agreed to **ship clipboard history in 0.6** and move Google Calendar sync to the next sprint [1]. Priya owns the release notes, due Friday [1][2].",
            sources: [KnowledgeSource(id: "1", kind: .meeting, title: "Weekly product sync", date: Date().addingTimeInterval(-86_400), text: "", itemID: UUID()),
                      KnowledgeSource(id: "2", kind: .task, title: "Write release notes (Priya)", date: Date(), text: "", itemID: UUID())])
        macShot("ask-my-mac", size: CGSize(width: 640, height: 420), panel: true, AskMyMacView())
        ScreenCaptureTool.shared.setPreview(image: sampleCapture(), text: "func loadUser() async throws -> User {\nerror: keyNotFound(\"createdAt\")")
        macShot("screenshot-tool", size: CGSize(width: 640, height: 440), panel: true, ScreenshotView())
        appearance = NSAppearance(named: .darkAqua)
        macShot("dashboard-dark", size: CGSize(width: 1180, height: 820), title: "MacPilot", RootView())
        appearance = NSAppearance(named: .aqua)

        buddyShot()
        func cal(_ id: String, _ title: String, _ account: String, _ hex: String, writable: Bool = true) -> CalendarInfo {
            GoogleMapping.calendar(["id": id, "summary": title, "backgroundColor": hex, "accessRole": writable ? "owner" : "reader"], account: account)!
        }
        GoogleCalendarService.shared.setPreview(accounts: ["you@gmail.com", "you@company.com"], calendars: [
            cal("you@gmail.com", "Personal", "you@gmail.com", "#7986cb"),
            cal("family@group.calendar.google.com", "Family", "you@gmail.com", "#33b679"),
            cal("en.indian#holiday@group.v.calendar.google.com", "Holidays in India", "you@gmail.com", "#f6bf26", writable: false),
            cal("you@company.com", "Work", "you@company.com", "#039be5"),
            cal("team@group.calendar.google.com", "Team standups", "you@company.com", "#e67c73"),
            cal("oncall@group.calendar.google.com", "On-call rota", "you@company.com", "#8e24aa", writable: false)
        ])
        macShot("settings-google-accounts", size: CGSize(width: 860, height: 560), title: "Settings",
                Form { GoogleCalendarSettingsSection() }.formStyle(.grouped))
        GoogleCalendarService.shared.setPreview(accounts: [], calendars: [])

        // Notch
        NowPlaying.shared.setPreview(NowPlaying.Track(title: "Weightless", artist: "Marconi Union", album: "Ambient", player: .music),
                                     playing: true, artwork: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil))
        notchShot("notch-recording", activity: .recording(paused: false), expanded: false)
        notchShot("notch-meeting", activity: .meetingSoon(title: "Design review", start: Date().addingTimeInterval(480)), expanded: false)
        notchShot("notch-dictating", activity: .dictating, expanded: false)
        notchShot("notch-music", activity: .nowPlaying, expanded: false)
        notchShot("notch-expanded", activity: .idle, expanded: true)
        let shelfDir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: shelfDir, withIntermediateDirectories: true)
        let shelfFiles = ["Q4 roadmap.pdf", "Hero banner.png", "Contract draft.docx", "Budget.xlsx", "Demo.mov"].map { shelfDir.appendingPathComponent($0) }
        shelfFiles.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data("demo".utf8)) }
        NowPlaying.shared.setPreview(nil, playing: false, artwork: nil)
        NotchShelf.shared.setPreview(shelfFiles)
        notchShot("notch-shelf", activity: .idle, expanded: true)
        NotchShelf.shared.setPreview([])
        NowPlaying.shared.setPreview(nil, playing: false, artwork: nil)
    }

    /// The floating buddy in its four states, on the desktop.
    private func buddyShot() {
        let states: [(String, BuddyMood, Bool)] = [("Idle", .idle, false), ("Hover", .idle, true),
                                                   ("Dictating", .listening, false), ("Recording", .recording, false)]
        talkingBuddyShot()
        var images: [NSImage] = []
        for (_, mood, hover) in states {
            let hosting = NSHostingView(rootView: BuddyView(previewMood: mood, previewHover: hover).environment(AppState.shared))
            hosting.frame = CGRect(origin: .zero, size: FloatingBuddy.size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let image = NSImage(size: hosting.bounds.size)
            image.addRepresentation(rep)
            images.append(image)
        }
        let cell = FloatingBuddy.size
        let canvas = NSSize(width: cell.width * 4 + 60 * 5, height: cell.height + 90)
        let output = NSImage(size: canvas, flipped: false) { rect in
            self.drawDesktop(in: rect)
            for (index, image) in images.enumerated() {
                let x = 60 + CGFloat(index) * (cell.width + 60)
                image.draw(in: NSRect(x: x, y: 50, width: cell.width, height: cell.height))
                let label = NSAttributedString(string: states[index].0, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white])
                label.draw(at: NSPoint(x: x + (cell.width - label.size().width) / 2, y: 18))
            }
            return true
        }
        guard let tiff = output.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent("buddy.png"))
    }

    /// Pilot answering a spoken question, on the desktop.
    private func talkingBuddyShot() {
        let size = FloatingBuddy.talkingSize
        let hosting = NSHostingView(rootView: BuddyView(previewMood: .speaking,
                                                        previewBubble: (heard: "Hey Pilot, what's next today?",
                                                                        reply: "Next up is Design review at 10:00. You have 3 meetings left today, and 2 tasks due, starting with Send Q4 roadmap."))
            .environment(AppState.shared))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        let canvas = NSSize(width: 560, height: size.height + 70)
        let output = NSImage(size: canvas, flipped: false) { rect in
            self.drawDesktop(in: rect)
            self.drawMenuBar(in: rect, height: 28)
            image.draw(in: NSRect(x: (rect.width - size.width) / 2, y: 20, width: size.width, height: size.height))
            return true
        }
        guard let tiff = output.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent("buddy-talking.png"))
    }
}
