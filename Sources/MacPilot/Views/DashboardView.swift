import AppKit
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }, sort: \TaskItem.createdAt)
    private var openTasks: [TaskItem]
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]

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

    private let columns = [GridItem(.flexible(), spacing: DS.Space.m, alignment: .top),
                           GridItem(.flexible(), spacing: DS.Space.m, alignment: .top)]
    private let cardHeight: CGFloat = 236

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                header
                NextMeetingHero()
                BriefingCard()
                QuickActionsRow()
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                    tasksCard
                    notesCard
                    recordingsCard
                    recentChatsCard
                }
                NetworkDashboardCard()
                ProviderStatusCard()
            }
            .padding(DS.Space.l)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dashboard")
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(greeting).font(.largeTitle.weight(.bold))
                Text(summaryLine).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Date().formatted(date: .complete, time: .omitted))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var summaryLine: String {
        let overdue = openTasks.filter(\.isOverdue).count
        let today = openTasks.filter { $0.dueDate.map(Calendar.current.isDateInToday) ?? false }.count
        var parts: [String] = []
        if today > 0 { parts.append("\(today) task\(today == 1 ? "" : "s") due today") }
        if overdue > 0 { parts.append("\(overdue) overdue") }
        return parts.isEmpty ? "You're all caught up." : parts.joined(separator: " · ")
    }

    // MARK: Cards

    private var tasksCard: some View {
        DashboardCard(title: "Tasks", systemImage: AppSection.tasks.systemImage, color: AppSection.tasks.tint, section: .tasks, height: cardHeight) {
            if sortedTasks.isEmpty {
                EmptyStateView(systemImage: "checkmark.circle", title: "Nothing pending", message: "New tasks appear here.",
                               actionTitle: "New task", action: { WindowManager.shared.open(.tasks, action: .newTask) }, compact: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(sortedTasks.prefix(6)) { task in
                        HStack(spacing: DS.Space.xs) {
                            Button {
                                TaskActions.toggle(task, context: context)
                            } label: {
                                Image(systemName: "circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Complete \(task.title)")
                            Text(task.title).lineLimit(1)
                            Spacer()
                            if task.priority == .high { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.red) }
                            if let due = task.dueDate {
                                Text(due.shortRelative)
                                    .font(.caption)
                                    .foregroundStyle(task.isOverdue ? .red : .secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, DS.Space.xxs)
                        .hoverHighlight()
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        DashboardCard(title: "Notes", systemImage: AppSection.notes.systemImage, color: AppSection.notes.tint, section: .notes, height: cardHeight) {
            HStack(spacing: DS.Space.xs) {
                TextField("Jot something down…", text: $quickNote)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addQuickNote)
                Button(action: addQuickNote) { Image(systemName: "plus") }
                    .disabled(quickNote.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add quick note")
            }
            VStack(spacing: 2) {
                ForEach(notes.prefix(4)) { note in
                    Button {
                        appState.pendingAction = .openNote(note.uid)
                        appState.selectedSection = .notes
                    } label: {
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: note.isPinned ? "pin.fill" : "doc.text")
                                .font(.caption)
                                .foregroundStyle(note.isPinned ? .orange : .secondary)
                                .frame(width: 14)
                            Text(note.displayTitle).lineLimit(1)
                            Spacer()
                            Text(note.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, DS.Space.xxs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                }
            }
        }
    }

    private var recordingsCard: some View {
        DashboardCard(title: "Recordings", systemImage: AppSection.voice.systemImage, color: AppSection.voice.tint, section: .voice, height: cardHeight) {
            if recordings.isEmpty {
                EmptyStateView(systemImage: "waveform", title: "No recordings yet", message: "Record a meeting or voice note to get a transcript and summary.",
                               actionTitle: "Record meeting", action: { RecordingManager.shared.toggleMeeting() }, compact: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(recordings.prefix(4)) { recording in
                        Button {
                            appState.pendingAction = .openRecording(recording.uid)
                            appState.selectedSection = recording.kind == .meeting ? .calendar : .voice
                        } label: {
                            HStack(spacing: DS.Space.xs) {
                                Image(systemName: recording.kind.systemImage).foregroundStyle(.secondary).frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recording.title).lineLimit(1)
                                    Text("\(recording.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(TranscriptSegment.format(recording.duration))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                StatusBadge(status: recording.status)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, DS.Space.xxs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                    }
                }
            }
        }
    }

    private var recentChatsCard: some View {
        DashboardCard(title: "AI chats", systemImage: AppSection.assistant.systemImage, color: AppSection.assistant.tint, section: .assistant, height: cardHeight) {
            if conversations.isEmpty {
                EmptyStateView(systemImage: "sparkles", title: "No conversations yet", message: "Ask anything with ⌥Space from any app.",
                               actionTitle: "Ask AI", action: { WindowManager.shared.toggleQuickAssistant() }, compact: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(conversations.prefix(5)) { conversation in
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: "bubble.left").font(.caption).foregroundStyle(.secondary).frame(width: 14)
                            Text(conversation.title).lineLimit(1)
                            Spacer()
                            Pill(text: conversation.provider.shortName)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, DS.Space.xxs)
                        .hoverHighlight()
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

// MARK: - Next meeting hero

/// The most prominent card: the next meeting with a live countdown and a Record button.
private struct NextMeetingHero: View {
    private let calendar = CalendarService.shared
    private let recorder = RecordingManager.shared

    var body: some View {
        let _ = calendar.revision
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let upcoming = calendar.upcoming(limit: 3, withinDays: 7)
            HStack(alignment: .center, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(heroLabel(upcoming.first, now: context.date))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.8))
                    if let next = upcoming.first {
                        HStack(spacing: DS.Space.xs) {
                            Text(next.title).font(.title2.weight(.bold)).lineLimit(1)
                            if next.source == .google { GoogleBadge() }
                        }
                        Text(detail(for: next)).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        if upcoming.count > 1 {
                            Text("Then: " + upcoming.dropFirst().map { "\($0.title) \($0.start.formatted(date: .omitted, time: .shortened))" }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    } else if calendar.isConnected {
                        Text("No meetings in the next 7 days").font(.title2.weight(.bold))
                        Text("Enjoy the focus time.").font(.callout).foregroundStyle(.white.opacity(0.85))
                    } else {
                        Text("Connect your calendar").font(.title2.weight(.bold))
                        Text("See what's next, get conflict warnings and record meetings with one click.")
                            .font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .foregroundStyle(.white)
                Spacer()
                if let next = upcoming.first {
                    Text(Countdown.text(to: next.start, end: next.end, now: context.date))
                        .font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Button {
                        Task {
                            await recorder.start(kind: .meeting, title: next.title, eventID: next.id, attendees: next.attendeeNames)
                        }
                    } label: {
                        Label("Record", systemImage: "record.circle")
                            .font(.headline)
                            .padding(.horizontal, DS.Space.xs)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.25))
                    .controlSize(.large)
                    .disabled(recorder.isActive)
                } else if !calendar.isConnected {
                    Button("Connect Apple Calendar") {
                        if calendar.isDenied { calendar.openPrivacySettings() } else { Task { await calendar.requestAccess() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.25))
                    .controlSize(.large)
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(RoundedRectangle(cornerRadius: DS.Radius.large + 4, style: .continuous).fill(DS.brandGradient))
            .shadow(color: DS.indigo.opacity(0.25), radius: 10, y: 4)
        }
        .task {
            await calendar.refresh(from: Date(), to: Date().addingTimeInterval(7 * 86_400))
        }
    }

    private func heroLabel(_ event: CalendarEvent?, now: Date) -> String {
        guard let event else { return "Next meeting" }
        return event.start <= now ? "Happening now" : "Next meeting"
    }

    private func detail(for event: CalendarEvent) -> String {
        var parts = ["\(event.start.shortRelative) – \(event.end.formatted(date: .omitted, time: .shortened))"]
        if !event.location.isEmpty { parts.append(event.location) }
        if !event.attendees.isEmpty { parts.append("\(event.attendees.count) attendee\(event.attendees.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Quick actions

private struct QuickActionsRow: View {
    private let shortcuts = ShortcutManager.shared
    private let recorder = RecordingManager.shared

    var body: some View {
        HStack(spacing: DS.Space.s) {
            QuickActionTile(title: "Ask AI", systemImage: "sparkles", color: AppSection.assistant.tint, shortcut: label(.assistant)) {
                WindowManager.shared.toggleQuickAssistant()
            }
            QuickActionTile(title: "New note", systemImage: "square.and.pencil", color: AppSection.notes.tint, shortcut: label(.newNote)) {
                WindowManager.shared.open(.notes, action: .newNote)
            }
            QuickActionTile(title: "New task", systemImage: "plus", color: AppSection.tasks.tint, shortcut: label(.newTask)) {
                WindowManager.shared.open(.tasks, action: .newTask)
            }
            QuickActionTile(title: recorder.isActive ? "Stop" : "Record", systemImage: recorder.isActive ? "stop.fill" : "record.circle",
                            color: .red, shortcut: label(.recording)) {
                recorder.toggleMeeting()
            }
            QuickActionTile(title: "Clipboard", systemImage: "doc.on.clipboard", color: AppSection.clipboard.tint, shortcut: label(.clipboard)) {
                WindowManager.shared.toggleClipboardPanel()
            }
            QuickActionTile(title: "Launcher", systemImage: "command", color: DS.indigo, shortcut: label(.launcher)) {
                WindowManager.shared.toggleLauncher()
            }
        }
    }

    private func label(_ action: ShortcutAction) -> String {
        shortcuts.hotKey(for: action)?.displayString ?? ""
    }
}

private struct QuickActionTile: View {
    let title: String
    let systemImage: String
    let color: Color
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                IconTile(systemImage: systemImage, color: color, size: 28)
                Spacer(minLength: 0)
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                Text(shortcut.isEmpty ? " " : shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).fill(DS.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(hovering ? color.opacity(0.5) : DS.hairline, lineWidth: hovering ? 1.5 : 1))
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shortcut.isEmpty ? title : "\(title) (\(shortcut))")
    }
}

// MARK: - Briefing

private struct BriefingCard: View {
    @AppStorage(PrefKey.autoBriefing) private var auto = true
    @State private var expanded = true
    private let briefing = DailyBriefing.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "Today's briefing", systemImage: "sun.max", color: .orange) {
                if briefing.phase == .writing { ProgressView().controlSize(.small) }
                if let date = briefing.generatedAt, briefing.phase != .writing {
                    Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
                Menu {
                    Toggle("Write automatically each morning", isOn: $auto)
                    Button(expanded ? "Collapse" : "Expand") { expanded.toggle() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 28)
                Button(briefing.text.isEmpty ? "Write it" : "Refresh") { briefing.generate() }
                    .controlSize(.small).disabled(briefing.phase == .writing)
            }
            if expanded {
                if briefing.text.isEmpty && briefing.phase != .writing {
                    Text("A short AI summary of today's meetings, due and overdue tasks, and open action items from recent meetings.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if briefing.text.isEmpty {
                    TypingIndicator()
                } else {
                    Text(LocalizedStringKey(briefing.text)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if case .failed(let message) = briefing.phase {
                    Label("AI unavailable (\(message)) — showing the plain list.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .card()
        .onAppear { briefing.generateIfNeeded() }
    }
}

// MARK: - Card container

struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    var color: Color = DS.accent
    let section: AppSection
    var height: CGFloat?
    @ViewBuilder var content: Content
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: title, systemImage: systemImage, color: color) {
                Button {
                    appState.selectedSection = section
                } label: {
                    HStack(spacing: 2) {
                        Text("See all")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open \(title)")
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .card()
    }
}

private struct ProviderStatusCard: View {
    @State private var configured: [AIProviderID: Bool] = [:]
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: "key.fill", color: .gray, size: 20)
            Text("AI providers").font(.headline)
            ForEach(AIProviderID.allCases) { provider in
                HStack(spacing: DS.Space.xxs) {
                    Circle()
                        .fill(configured[provider] == true ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(provider.shortName).font(.callout)
                    Text(statusText(provider)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Button("Manage") { appState.selectedSection = .settings }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .card(padding: DS.Space.s)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        for provider in AIProviderID.allCases {
            configured[provider] = Prefs.isEnabled(provider) && provider.hasCredentials
        }
    }

    private func statusText(_ provider: AIProviderID) -> String {
        if !Prefs.isEnabled(provider) { return "off" }
        if provider.requiresAPIKey && configured[provider] != true { return "no key" }
        return Prefs.model(for: provider)
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
