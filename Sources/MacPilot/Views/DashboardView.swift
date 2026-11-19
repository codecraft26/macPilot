import AppKit
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }, sort: \TaskItem.createdAt)
    private var openTasks: [TaskItem]
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var quickNote = ""

    private var sortedTasks: [TaskItem] {
        openTasks.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.priorityRaw > rhs.priorityRaw
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                QuickActionsRow()
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    tasksCard
                    notesCard
                    meetingsCard
                    recentChatsCard
                    ProviderStatusCard()
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting).font(.largeTitle.bold())
            Text(Date().formatted(date: .complete, time: .omitted))
                .foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var tasksCard: some View {
        DashboardCard(title: "Pending tasks", systemImage: "checklist", section: .tasks) {
            if sortedTasks.isEmpty {
                Text("Nothing pending.").foregroundStyle(.secondary)
            } else {
                ForEach(sortedTasks.prefix(6)) { task in
                    HStack {
                        Button {
                            TaskActions.toggle(task, context: context)
                        } label: {
                            Image(systemName: "circle")
                        }
                        .buttonStyle(.borderless)
                        Text(task.title).lineLimit(1)
                        Spacer()
                        if let due = task.dueDate {
                            Text(due.shortRelative)
                                .font(.caption)
                                .foregroundStyle(task.isOverdue ? .red : .secondary)
                        }
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        DashboardCard(title: "Quick notes", systemImage: "note.text", section: .notes) {
            HStack {
                TextField("Jot something down…", text: $quickNote)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addQuickNote)
                Button("Add", action: addQuickNote)
                    .disabled(quickNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(notes.prefix(5)) { note in
                HStack {
                    if note.isPinned { Image(systemName: "pin.fill").font(.caption) }
                    Text(note.displayTitle).lineLimit(1)
                    Spacer()
                    Text(note.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var meetingsCard: some View {
        DashboardCard(title: "Upcoming meetings", systemImage: "calendar", section: .calendar) {
            UpcomingMeetingsList()
        }
    }

    private var recentChatsCard: some View {
        DashboardCard(title: "Recent AI chats", systemImage: "sparkles", section: .assistant) {
            if conversations.isEmpty {
                Text("No conversations yet.").foregroundStyle(.secondary)
            } else {
                ForEach(conversations.prefix(5)) { conversation in
                    HStack {
                        Text(conversation.title).lineLimit(1)
                        Spacer()
                        Text(conversation.provider.shortName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func addQuickNote() {
        let text = quickNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        context.insert(Note(body: text, folder: "Quick notes"))
        try? context.save()
        quickNote = ""
    }
}

private struct QuickActionsRow: View {
    private let shortcuts = ShortcutManager.shared

    var body: some View {
        HStack(spacing: 12) {
            action("Ask AI", "sparkles", .assistant) { WindowManager.shared.toggleQuickAssistant() }
            action("New note", "square.and.pencil", .newNote) { WindowManager.shared.open(.notes, action: .newNote) }
            action("New task", "plus.circle", .newTask) { WindowManager.shared.open(.tasks, action: .newTask) }
            action(RecordingManager.shared.isActive ? "Stop" : "Record", RecordingManager.shared.isActive ? "stop.circle" : "record.circle", .recording) {
                RecordingManager.shared.toggleMeeting()
            }
        }
    }

    private func action(_ title: String, _ image: String, _ shortcut: ShortcutAction, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 6) {
                Image(systemName: image).font(.title2)
                Text(title).font(.callout.weight(.medium))
                Text(shortcuts.hotKey(for: shortcut)?.displayString ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, height: 78)
        }
        .buttonStyle(.bordered)
    }
}

struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    let section: AppSection
    @ViewBuilder var content: Content
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                Spacer()
                Button("Open") { appState.selectedSection = section }
                    .buttonStyle(.link)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
    }
}

private struct ProviderStatusCard: View {
    @State private var configured: [AIProviderID: Bool] = [:]

    var body: some View {
        DashboardCard(title: "AI providers", systemImage: "key", section: .settings) {
            ForEach(AIProviderID.allCases) { provider in
                HStack {
                    Image(systemName: statusIcon(provider))
                        .foregroundStyle(configured[provider] == true ? .green : .secondary)
                    Text(provider.displayName)
                    Spacer()
                    Text(statusText(provider)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        for provider in AIProviderID.allCases {
            let hasKey = provider.requiresAPIKey ? KeychainStore.exists(account: provider.rawValue) : true
            configured[provider] = Prefs.isEnabled(provider) && hasKey
        }
    }

    private func statusIcon(_ provider: AIProviderID) -> String {
        configured[provider] == true ? "checkmark.circle.fill" : "circle"
    }

    private func statusText(_ provider: AIProviderID) -> String {
        if !Prefs.isEnabled(provider) { return "Off" }
        if provider.requiresAPIKey && configured[provider] != true { return "No key" }
        return Prefs.model(for: provider)
    }
}

/// Next meetings from Apple Calendar with a live countdown.
private struct UpcomingMeetingsList: View {
    private let calendar = CalendarService.shared
    private let recorder = RecordingManager.shared

    var body: some View {
        let _ = calendar.revision
        if !calendar.isAuthorized {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect Apple Calendar to see what's next.").foregroundStyle(.secondary)
                Button(calendar.isDenied ? "Open Privacy Settings" : "Connect Calendar") {
                    if calendar.isDenied { calendar.openPrivacySettings() } else { Task { await calendar.requestAccess() } }
                }
            }
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let events = calendar.upcoming(limit: 4, withinDays: 7)
                if events.isEmpty {
                    Text("No meetings in the next 7 days.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(events, id: \.calendarItemIdentifier) { event in
                            HStack {
                                Circle()
                                    .fill(Color(cgColor: event.calendar?.cgColor ?? CGColor(gray: 0.5, alpha: 1)))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.title ?? "Event").lineLimit(1)
                                    Text(event.startDate.shortRelative).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Countdown.text(to: event.startDate, end: event.endDate, now: context.date))
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .foregroundStyle(event.startDate <= context.date ? .green : .secondary)
                                Button {
                                    Task {
                                        await recorder.start(
                                            kind: .meeting,
                                            title: event.title ?? "Meeting",
                                            eventID: event.calendarItemIdentifier,
                                            attendees: CalendarService.attendeeNames(event)
                                        )
                                    }
                                } label: {
                                    Image(systemName: "record.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(recorder.isActive)
                                .help("Record this meeting")
                            }
                        }
                    }
                }
            }
        }
    }
}

enum Countdown {
    static func text(to start: Date, end: Date, now: Date) -> String {
        if start <= now { return end > now ? "Now" : "Ended" }
        let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "in \(hours) h" : "in \(hours) h \(minutes % 60) min" }
        let days = hours / 24
        return "in \(days) day\(days == 1 ? "" : "s")"
    }
}
