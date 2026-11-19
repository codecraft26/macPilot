import AppKit
import SwiftData
import SwiftUI

/// One row in the command launcher.
struct LauncherItem: Identifiable {
    enum Icon {
        case system(String)
        case file(String)
    }

    let id: String
    let title: String
    var subtitle: String = ""
    let icon: Icon
    let section: String
    let primary: @MainActor () -> Void
    var secondaryLabel: String?
    var secondary: (@MainActor () -> Void)?
}

/// Applications in the standard folders, scanned once per launch.
@MainActor
enum AppCatalog {
    struct App: Hashable {
        let name: String
        let path: String
    }

    private static var cached: [App]?

    static var apps: [App] {
        if let cached { return cached }
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var result: [App] = []
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".app") {
                let display = String(name.dropLast(4))
                guard seen.insert(display).inserted else { continue }
                result.append(App(name: display, path: folder + "/" + name))
            }
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cached = result
        return result
    }
}

/// Builds launcher results from commands, notes, tasks, clipboard items and apps.
@MainActor
enum LauncherCatalog {
    static func items(query: String) -> [LauncherItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let windows = WindowManager.shared
        let recorder = RecordingManager.shared
        let context = Persistence.container.mainContext
        var results: [LauncherItem] = []

        // Instant answers (calculator, conversions, URLs) go above everything else.
        var instant: [LauncherItem] = []
        if let value = Calculator.evaluate(trimmed) {
            let text = Calculator.format(value)
            instant.append(LauncherItem(id: "calc:\(text)", title: "= \(text)", subtitle: "Copy result · ⌘↩ paste into your app", icon: .system("plus.forwardslash.minus"), section: "Calculator",
                                        primary: { PasteService.write(text: text) },
                                        secondaryLabel: "Paste", secondary: { PasteService.paste(text: text, into: windows.previousApp) }))
        }
        if let conversion = UnitConversion.convert(trimmed) {
            instant.append(LauncherItem(id: "calc:\(conversion.text)", title: "= \(conversion.text)", subtitle: "Copy result · ⌘↩ paste into your app", icon: .system("arrow.left.arrow.right"), section: "Convert",
                                        primary: { PasteService.write(text: conversion.text) },
                                        secondaryLabel: "Paste", secondary: { PasteService.paste(text: conversion.text, into: windows.previousApp) }))
        }
        if let timer = TimerParser.parse(trimmed) {
            let what = TimerParser.describe(timer.seconds) + (timer.label.isEmpty ? "" : " · \(timer.label)")
            instant.append(LauncherItem(id: "timer.start", title: "Start timer: \(what)", subtitle: "Shows in the notch and chimes when done",
                                        icon: .system("timer"), section: "Timer",
                                        primary: { NotchTimers.shared.start(seconds: timer.seconds, label: timer.label) }))
        }
        if let url = WebLinks.url(from: trimmed) {
            instant.append(LauncherItem(id: "url:\(url.absoluteString)", title: "Open \(url.absoluteString)", icon: .system("safari"), section: "Web",
                                        primary: { NSWorkspace.shared.open(url) }))
        }

        // Typed-text actions first.
        if !trimmed.isEmpty {
            results.append(LauncherItem(id: "ask", title: "Ask AI: \(trimmed)", icon: .system("sparkles"), section: "AI",
                                        primary: { windows.askQuickAssistant(trimmed) }))
        }

        var commands: [LauncherItem] = [
            LauncherItem(id: "cmd.note", title: trimmed.isEmpty ? "New note" : "New note: \(trimmed)", icon: .system("square.and.pencil"), section: "Commands",
                         primary: {
                             if trimmed.isEmpty {
                                 windows.open(.notes, action: .newNote)
                             } else {
                                 let note = Note(title: trimmed)
                                 context.insert(note)
                                 try? context.save()
                                 windows.open(.notes, action: .openNote(note.uid))
                             }
                         }),
            LauncherItem(id: "cmd.task", title: trimmed.isEmpty ? "New task" : "Add task: \(trimmed)", icon: .system("plus.circle"), section: "Commands",
                         primary: {
                             if trimmed.isEmpty {
                                 windows.open(.tasks, action: .newTask)
                             } else {
                                 let task = TaskItem(title: trimmed, dueDate: DateParsing.firstDate(in: trimmed))
                                 context.insert(task)
                                 try? context.save()
                                 NotificationService.schedule(id: task.notificationID, title: task.title, at: task.dueDate)
                             }
                         }),
            LauncherItem(id: "cmd.event", title: trimmed.isEmpty ? "Add calendar event" : "Add event: \(trimmed)", icon: .system("calendar.badge.plus"), section: "Commands",
                         primary: { windows.open(.calendar, action: trimmed.isEmpty ? nil : .quickAddEvent(trimmed)) }),
            LauncherItem(id: "cmd.record", title: recorder.isActive ? "Stop recording" : "Start meeting recording", icon: .system(recorder.isActive ? "stop.circle" : "record.circle"), section: "Commands",
                         primary: { recorder.toggleMeeting() }),
            LauncherItem(id: "cmd.voice", title: "Record voice note", icon: .system("mic"), section: "Commands",
                         primary: {
                             Task { await recorder.start(kind: .voiceNote, title: "Voice note \(Date().formatted(date: .abbreviated, time: .shortened))") }
                             windows.showDashboard(section: .voice)
                         }),
            LauncherItem(id: "cmd.clipboard", title: "Clipboard history", icon: .system("doc.on.clipboard"), section: "Commands",
                         primary: { windows.toggleClipboardPanel() }),
            LauncherItem(id: "cmd.pauseclip", title: ClipboardMonitor.shared.isPaused ? "Resume clipboard capture" : "Pause clipboard capture", icon: .system("pause.circle"), section: "Commands",
                         primary: { ClipboardMonitor.shared.isPaused.toggle() })
        ]
        commands += WindowLayout.allCases.map { layout in
            LauncherItem(id: "win.\(layout.rawValue)", title: "Window: \(layout.rawValue)", subtitle: windows.previousApp?.localizedName ?? "",
                         icon: .system(layout.systemImage), section: "Window",
                         primary: {
                             if let problem = layout.apply(to: windows.previousApp) { LauncherAlert.show(problem) }
                         })
        }
        commands += [
            LauncherItem(id: "timer.cancel", title: NotchTimers.shared.current == nil ? "Timer: type “timer 25m”" : "Cancel timer",
                         icon: .system("timer"), section: "Timer",
                         primary: { if NotchTimers.shared.current != nil { NotchTimers.shared.cancel() } else { WindowManager.shared.toggleLauncher() } }),
            LauncherItem(id: "sys.lock", title: "Lock Screen", icon: .system("lock"), section: "System", primary: { SystemCommands.lockScreen() }),
            LauncherItem(id: "sys.sleepdisplay", title: "Sleep Display", icon: .system("display"), section: "System", primary: { SystemCommands.sleepDisplay() }),
            LauncherItem(id: "sys.screensaver", title: "Start Screen Saver", icon: .system("sparkles.tv"), section: "System", primary: { SystemCommands.startScreenSaver() }),
            LauncherItem(id: "sys.darkmode", title: "Toggle Dark Mode", icon: .system("circle.lefthalf.filled"), section: "System", primary: { SystemCommands.toggleDarkMode() }),
            LauncherItem(id: "sys.emptytrash", title: "Empty Trash…", subtitle: "Asks first", icon: .system("trash"), section: "System", primary: { SystemCommands.emptyTrash() })
        ]
        commands += ConversionTool.allCases.map { tool in
            LauncherItem(id: "tool.\(tool.rawValue)", title: tool.title, subtitle: tool.subtitle, icon: .system(tool.systemImage), section: "File Tools",
                         primary: { windows.open(.tools, action: .openTool(tool.rawValue)) })
        }
        commands += AppSection.allCases.map { section in
            LauncherItem(id: "open.\(section.rawValue)", title: "Open \(section.title)", icon: .system(section.systemImage), section: "MacPilot",
                         primary: { windows.showDashboard(section: section) })
        }
        results += FuzzyMatcher.rank(commands, query: trimmed) { $0.title }

        // With no query, the things you use most come first.
        guard !trimmed.isEmpty else { return LauncherUsage.rerank(results) }

        let notes = (try? context.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        results += FuzzyMatcher.rank(Array(notes.prefix(300)), query: trimmed) { "\($0.displayTitle) \($0.tagsRaw)" }.prefix(5).map { note in
            LauncherItem(id: "note.\(note.uid)", title: note.displayTitle, subtitle: note.folder, icon: .system("note.text"), section: "Notes",
                         primary: { windows.open(.notes, action: .openNote(note.uid)) })
        }

        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isCompleted }))) ?? []
        results += FuzzyMatcher.rank(tasks, query: trimmed) { $0.title }.prefix(5).map { task in
            LauncherItem(id: "task.\(task.uid)", title: task.title, subtitle: task.dueDate?.shortRelative ?? "", icon: .system("circle"), section: "Tasks",
                         primary: { windows.showDashboard(section: .tasks) },
                         secondaryLabel: "Complete",
                         secondary: { TaskActions.toggle(task, context: context) })
        }

        let clips = (try? context.fetch(FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        results += FuzzyMatcher.rank(Array(clips.prefix(500)), query: trimmed) { "\($0.title) \($0.text.prefix(500))" }.prefix(5).map { clip in
            LauncherItem(id: "clip.\(clip.uid)", title: clip.title, subtitle: clip.sourceAppName, icon: .system(clip.kind.systemImage), section: "Clipboard",
                         primary: { PasteService.paste(clip, into: windows.previousApp) },
                         secondaryLabel: "Copy",
                         secondary: { PasteService.write(clip) })
        }

        let running = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in app.bundleURL.map { ($0.path, app) } },
                                 uniquingKeysWith: { first, _ in first })
        results += FuzzyMatcher.rank(AppCatalog.apps, query: trimmed) { $0.name }.prefix(8).map { app in
            if let process = running[app.path] {
                return LauncherItem(id: "app.\(app.path)", title: app.name, subtitle: "Running", icon: .file(app.path), section: "Applications",
                                    primary: { process.activate() },
                                    secondaryLabel: "Quit", secondary: { process.terminate() })
            }
            return LauncherItem(id: "app.\(app.path)", title: app.name, icon: .file(app.path), section: "Applications",
                                primary: { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration()) },
                                secondaryLabel: "Show in Finder",
                                secondary: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) })
        }

        // Files from Spotlight (they arrive a moment after typing).
        if FileSearch.shared.query == trimmed {
            results += FileSearch.shared.results.map { file in
                LauncherItem(id: "file.\(file.path)", title: file.name, subtitle: (file.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                             icon: .file(file.path), section: "Files",
                             primary: { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) },
                             secondaryLabel: "Show in Finder",
                             secondary: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) })
            }
        }

        // Prefer the strongest matches across sections (nudged by what you use), keeping "Ask AI" second.
        let ask = results.filter { $0.id == "ask" }
        let rest = LauncherUsage.rerank(FuzzyMatcher.rank(results.filter { $0.id != "ask" }, query: trimmed) { "\($0.title) \($0.subtitle)" })
        let web = ["Google", "YouTube", "GitHub"].compactMap { engine -> LauncherItem? in
            guard let url = WebLinks.search(engine, trimmed) else { return nil }
            return LauncherItem(id: "web.\(engine):\(trimmed)", title: "Search \(engine) for “\(trimmed)”", icon: .system("magnifyingglass"), section: "Web",
                                primary: { NSWorkspace.shared.open(url) })
        }
        let ranked = rest.isEmpty ? ask : Array(rest.prefix(1)) + ask + Array(rest.dropFirst())
        return instant + ranked + web
    }
}

/// ⌥K command launcher.
struct LauncherView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var selectedID: String?
    @State private var keyMonitor = PanelKeyMonitor()
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = LauncherCatalog.items(query: query)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Search commands, notes, tasks, clipboard and apps…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selectedID) {
                    ForEach(results) { item in
                        LauncherRow(item: item, isSelected: item.id == (selectedID ?? results.first?.id))
                            .tag(item.id)
                            .id(item.id)
                            .onTapGesture(count: 2) { run(item, secondary: false) }
                            .onTapGesture { selectedID = item.id }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                // Each time the launcher opens or the search changes, start again at the top.
                .onChange(of: appState.panelSession) { _, _ in
                    if let first = LauncherCatalog.items(query: "").first?.id { proxy.scrollTo(first, anchor: .top) }
                }
                .onChange(of: query) { _, _ in
                    if let first = results.first?.id { proxy.scrollTo(first, anchor: .top) }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Spacer()
                KeyHint("↩", "Run")
                KeyHint("⌘↩", (results.first { $0.id == (selectedID ?? results.first?.id) }?.secondaryLabel) ?? "More")
                KeyHint("esc", "Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(VisualEffectBackground(material: .hudWindow))
        .tint(DS.accent)
        .onAppear {
            searchFocused = true
            keyMonitor.install(window: { WindowManager.shared.launcherPanel }, handler: handle)
        }
        .onChange(of: appState.panelSession) { _, _ in
            query = ""
            selectedID = nil
            searchFocused = true
        }
        .onChange(of: query) { _, newValue in
            selectedID = nil
            FileSearch.shared.search(newValue)
        }
    }

    private func handle(_ event: PanelKey.Event) -> Bool {
        let results = LauncherCatalog.items(query: query)
        let index = results.firstIndex { $0.id == selectedID } ?? 0
        switch event.key {
        case .down:
            if !results.isEmpty { selectedID = results[min(index + 1, results.count - 1)].id }
        case .up:
            if !results.isEmpty { selectedID = results[max(index - 1, 0)].id }
        case .enter:
            if results.indices.contains(index) { run(results[index], secondary: event.command) }
        case .escape:
            WindowManager.shared.hidePanels()
        default:
            return false
        }
        return true
    }

    private func run(_ item: LauncherItem, secondary: Bool) {
        LauncherUsage.record(item.id)
        WindowManager.shared.hidePanels()
        if secondary, let action = item.secondary {
            action()
        } else {
            item.primary()
        }
    }
}

private struct LauncherRow: View {
    let item: LauncherItem
    let isSelected: Bool

    private var tint: Color {
        switch item.section {
        case "AI": return DS.violet
        case "Notes": return AppSection.notes.tint
        case "Tasks": return AppSection.tasks.tint
        case "Clipboard": return AppSection.clipboard.tint
        case "MacPilot": return DS.indigo
        case "Calculator", "Convert", "Timer": return .orange
        case "File Tools": return .indigo
        case "Web": return .blue
        case "Window": return .teal
        case "System": return .gray
        case "Commands": return DS.accent
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(item.section).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .listRowBackground(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(isSelected ? DS.accent.opacity(0.22) : Color.clear)
                .padding(.horizontal, 6)
        )
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .system(let name):
            IconTile(systemImage: name, color: tint, size: 22)
        case .file(let path):
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        }
    }
}

@MainActor
enum LauncherAlert {
    static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
