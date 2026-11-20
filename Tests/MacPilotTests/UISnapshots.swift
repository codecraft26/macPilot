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
}
