import SwiftData
import SwiftUI

private enum CalendarTab: String, CaseIterable, Identifiable {
    case calendar = "Calendar", meetings = "Meetings"
    var id: String { rawValue }
}

enum CalendarMode: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month"
    var id: String { rawValue }
}

/// Calendar & Meetings: Apple Calendar views plus meeting recordings.
struct CalendarMeetingsView: View {
    @Environment(AppState.self) private var appState
    @State private var tab: CalendarTab = .calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Section", selection: $tab) {
                    ForEach(CalendarTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
            }
            .padding([.horizontal, .top], 16)
            RecordingControlBar(allowVoiceNote: false)
                .padding(16)
            Divider()
            switch tab {
            case .calendar:
                CalendarPane()
            case .meetings:
                RecordingsBrowser(kinds: [.meeting], emptyMessage: "No meetings recorded yet.\nPress Record meeting, or Record on a calendar event.")
            }
        }
        .navigationTitle("Calendar & Meetings")
        .onAppear(perform: handlePendingAction)
        .onChange(of: appState.pendingAction) { _, _ in handlePendingAction() }
        .onChange(of: RecordingManager.shared.current?.uid) { _, newValue in
            if newValue != nil, RecordingManager.shared.current?.kind == .meeting { tab = .meetings }
        }
    }

    private func handlePendingAction() {
        switch appState.pendingAction {
        case .openRecording?: tab = .meetings
        case .quickAddEvent?: tab = .calendar
        default: break
        }
    }
}

// MARK: - Calendar

struct CalendarPane: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }) private var openTasks: [TaskItem]
    @Query private var notes: [Note]

    @State private var mode: CalendarMode = .week
    @State private var anchor = Date()
    @State private var editor: EventEditorRequest?
    @State private var quickAdd = ""
    @State private var isParsing = false
    @State private var quickAddError: String?
    @State private var deleting: CalendarEvent?

    private let calendar = CalendarService.shared
    private var cal: Calendar { Calendar.current }

    var body: some View {
        Group {
            if calendar.isConnected {
                VStack(spacing: 0) {
                    toolbar.padding(16)
                    if let quickAddError {
                        Label(quickAddError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                    Divider()
                    content
                }
            } else {
                accessPrompt
            }
        }
        .sheet(item: $editor) { request in
            EventEditorSheet(draft: request.draft, notice: request.notice)
        }
        .onAppear(perform: takeQuickAdd)
        .onChange(of: appState.pendingAction) { _, _ in takeQuickAdd() }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Event", role: .destructive) {
                if let event = deleting {
                    Task {
                        do { try await calendar.delete(event) } catch { quickAddError = AIError.describe(error) }
                    }
                }
                deleting = nil
            }
        } message: {
            Text("It is removed from your calendar on every device that syncs it.")
        }
    }

    private var accessPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Connect Apple Calendar").font(.title2.bold())
            Text("MacPilot reads your calendars to show upcoming meetings, link recordings and prep notes, and warn about conflicts. Events are only created or changed after you confirm them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                if calendar.isDenied {
                    Button("Open Privacy Settings") { calendar.openPrivacySettings() }
                } else {
                    Button("Allow Apple Calendar Access") { Task { await calendar.requestAccess() } }
                        .buttonStyle(.borderedProminent)
                }
                Button("Set up Google Calendar…") { appState.selectedSection = .settings }
            }
            if calendar.isDenied {
                Text("Apple Calendar access was denied. Allow MacPilot under Privacy & Security → Calendars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Google Calendar: connect it in Settings → Recording & Calendar, or add your Google account under System Settings → Internet Accounts so it appears through Apple Calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let error = calendar.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                Button("Today") { anchor = Date() }
                Button { move(1) } label: { Image(systemName: "chevron.right") }
            }
            Text(periodTitle).font(.title3.bold()).frame(minWidth: 180, alignment: .leading)
            Picker("Mode", selection: $mode) {
                ForEach(CalendarMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            calendarsMenu
            autoRecordMenu
            Spacer()
            TextField("Quick add: “Lunch with Sam Friday 1pm”", text: $quickAdd)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200, maxWidth: 300)
                .onSubmit(runQuickAdd)
            if isParsing {
                ProgressView().controlSize(.small)
            }
            Button {
                editor = EventEditorRequest(draft: .new(at: nextHalfHour(on: anchor)))
            } label: {
                Label("New event", systemImage: "plus")
            }
        }
    }

    private var calendarsMenu: some View {
        Menu {
            let apple = calendar.calendars.filter { $0.source == .apple }
            let google = calendar.calendars.filter { $0.source == .google }
            if !apple.isEmpty {
                Section("Apple Calendar") {
                    ForEach(apple) { item in
                        Toggle(item.title, isOn: Binding(get: { calendar.isVisible(item) }, set: { calendar.setVisible($0, item) }))
                    }
                }
            }
            // One section per Google account.
            ForEach(Array(Set(google.map(\.account))).sorted(), id: \.self) { account in
                Section(account.isEmpty ? "Google Calendar" : "Google · \(account)") {
                    ForEach(google.filter { $0.account == account }) { item in
                        Toggle(item.title, isOn: Binding(get: { calendar.isVisible(item) }, set: { calendar.setVisible($0, item) }))
                    }
                }
            }
        } label: {
            Label("Calendars", systemImage: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
    }

    /// Which meetings MacPilot records by itself.
    private var autoRecordMenu: some View {
        let auto = MeetingAutoRecord.shared
        return Menu {
            Toggle("Record all meetings automatically", isOn: Binding(get: { auto.rules.recordAll }, set: { auto.setRecordAll($0) }))
            Toggle("Only events with attendees or a video link", isOn: Binding(get: { auto.rules.onlyRealMeetings }, set: { auto.setOnlyRealMeetings($0) }))
            Toggle("Stop recording when the meeting ends", isOn: Binding(get: { auto.stopAtEnd }, set: { auto.stopAtEnd = $0 }))
            Section("Always record meetings in") {
                ForEach(calendar.calendars) { item in
                    Toggle(item.source == .google && !item.account.isEmpty ? "\(item.title) (\(item.account))" : item.title,
                           isOn: Binding(get: { auto.records(calendarID: item.id) }, set: { auto.setCalendar(item.id, record: $0) }))
                }
            }
            Section {
                Text("Or right-click any meeting → “Record automatically when it starts”.")
            }
        } label: {
            let active = auto.rules.recordAll || !auto.rules.calendars.isEmpty || !auto.rules.marked.isEmpty
            Label(active ? "Auto-record on" : "Auto-record", systemImage: active ? "record.circle.fill" : "record.circle")
        }
        .fixedSize()
        .help("Choose which meetings MacPilot records automatically")
    }

    private var periodTitle: String {
        switch mode {
        case .day: return anchor.formatted(.dateTime.weekday(.wide).month().day())
        case .week:
            let days = weekDays
            guard let first = days.first, let last = days.last else { return "" }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
        case .month: return anchor.formatted(.dateTime.month(.wide).year())
        }
    }

    private func move(_ direction: Int) {
        let component: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : .month
        anchor = cal.date(byAdding: component, value: direction, to: anchor) ?? anchor
    }

    /// Quick add requested from the command launcher.
    private func takeQuickAdd() {
        guard case .quickAddEvent(let text)? = appState.pendingAction else { return }
        appState.pendingAction = nil
        quickAdd = text
        runQuickAdd()
    }

    private func runQuickAdd() {
        let text = quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isParsing else { return }
        isParsing = true
        quickAddError = nil
        Task {
            let (draft, message) = await EventQuickAdd.draft(from: text)
            isParsing = false
            if let draft {
                editor = EventEditorRequest(draft: draft, notice: message ?? "Review the event, then press Add to Calendar.")
                quickAdd = ""
            } else {
                quickAddError = message
            }
        }
    }

    private func nextHalfHour(on day: Date) -> Date {
        let now = Date()
        let base = cal.isDate(day, inSameDayAs: now) ? now : cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        let minute = cal.component(.minute, from: base)
        let rounded = cal.date(byAdding: .minute, value: minute < 30 ? 30 - minute : 60 - minute, to: base) ?? base
        return cal.date(bySetting: .second, value: 0, of: rounded) ?? rounded
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        // Reading `revision` makes the view reload when the calendar database changes.
        let _ = calendar.revision
        Group {
            switch mode {
            case .day: dayView
            case .week: weekView
            case .month: monthView
            }
        }
        .task(id: loadKey) {
            // Google events are fetched for the visible range now and every 5 minutes while open.
            while !Task.isCancelled {
                await calendar.refresh(from: loadRange.start, to: loadRange.end)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private var loadRange: DateInterval {
        let component: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : .month
        let interval = cal.dateInterval(of: component, for: anchor) ?? DateInterval(start: anchor, duration: 86_400)
        // Month view shows up to 6 weeks; pad by a week on each side.
        return DateInterval(start: interval.start.addingTimeInterval(-7 * 86_400), end: interval.end.addingTimeInterval(7 * 86_400))
    }

    private var loadKey: String {
        "\(mode.rawValue)-\(Int(loadRange.start.timeIntervalSince1970))-\(calendar.google.isConnected)"
    }

    private var weekDays: [Date] {
        let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? cal.startOfDay(for: anchor)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    // Day

    private var eventActions: EventActions {
        EventActions(
            edit: { editor = EventEditorRequest(draft: EventDraft($0)) },
            record: { record($0) },
            prep: { openPrepNote(for: $0) },
            delete: { deleting = $0 }
        )
    }

    private var dayView: some View {
        let events = calendar.events(on: anchor)
        let conflicts = calendar.conflictingIDs(in: events)
        let tasks = tasksDue(on: anchor)
        return HStack(spacing: 0) {
            TimeGrid(days: [anchor], events: events, conflicts: conflicts, actions: eventActions, onDayTap: nil)
            Divider()
            List {
                Section("Agenda") {
                    if events.isEmpty {
                        Text("No events.").foregroundStyle(.secondary)
                    }
                    ForEach(events, id: \.id) { event in
                        DayEventRow(
                            event: event,
                            isConflict: conflicts.contains(event.id),
                            hasPrepNote: prepNote(for: event) != nil,
                            onRecord: { record(event) },
                            onPrep: { openPrepNote(for: event) },
                            onEdit: { editor = EventEditorRequest(draft: EventDraft(event)) }
                        )
                        .contextMenu { eventActions.menu(for: event) }
                    }
                }
                Section("Tasks due") {
                    if tasks.isEmpty {
                        Text("No tasks due.").foregroundStyle(.secondary)
                    }
                    ForEach(tasks) { task in
                        HStack {
                            Button { TaskActions.toggle(task, context: context) } label: { Image(systemName: "circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Complete \(task.title)")
                            Text(task.title)
                            Spacer()
                            if let due = task.dueDate {
                                Text(due.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(task.isOverdue ? .red : .secondary)
                            }
                        }
                    }
                }
            }
            .frame(width: 340)
        }
    }

    // Week

    private var weekView: some View {
        let days = weekDays
        let all = calendar.events(from: days.first ?? anchor, to: cal.date(byAdding: .day, value: 1, to: days.last ?? anchor) ?? anchor)
        return TimeGrid(days: days, events: all, conflicts: calendar.conflictingIDs(in: all), actions: eventActions) { day in
            anchor = day
            mode = .day
        }
    }

    // Month

    private var monthView: some View {
        let interval = cal.dateInterval(of: .month, for: anchor) ?? DateInterval(start: anchor, duration: 86_400 * 30)
        let gridStart = cal.dateInterval(of: .weekOfYear, for: interval.start)?.start ?? interval.start
        let days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
        let events = calendar.events(from: days.first ?? gridStart, to: cal.date(byAdding: .day, value: 1, to: days.last ?? gridStart) ?? gridStart)
        let symbols = cal.shortWeekdaySymbols
        let first = cal.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return VStack(spacing: 4) {
            HStack {
                ForEach(ordered, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    let dayEvents = events.filter { cal.isDate($0.start, inSameDayAs: day) }
                    MonthCell(
                        day: day,
                        inMonth: cal.isDate(day, equalTo: anchor, toGranularity: .month),
                        events: dayEvents,
                        taskCount: tasksDue(on: day).count
                    )
                    .onTapGesture {
                        anchor = day
                        mode = .day
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    // MARK: Helpers

    private func tasksDue(on day: Date) -> [TaskItem] {
        openTasks.filter { task in task.dueDate.map { cal.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private func prepNote(for event: CalendarEvent) -> Note? {
        notes.first { $0.eventID == event.id }
    }

    private func openPrepNote(for event: CalendarEvent) {
        let note = prepNote(for: event) ?? {
            let note = Note(
                title: "Prep: \(event.title)",
                body: "**When:** \(event.start.formatted(date: .abbreviated, time: .shortened))\n\n## Agenda\n\n- \n\n## Questions\n\n- \n",
                folder: "Meeting prep"
            )
            note.eventID = event.id
            note.tagsRaw = "meeting, prep"
            context.insert(note)
            try? context.save()
            return note
        }()
        appState.pendingAction = .openNote(note.uid)
        appState.selectedSection = .notes
    }

    private func record(_ event: CalendarEvent) {
        let prep = prepNote(for: event)?.body ?? ""
        Task {
            await RecordingManager.shared.start(
                kind: .meeting,
                title: event.title,
                eventID: event.id,
                attendees: event.attendeeNames,
                prepNotes: prep
            )
        }
    }
}

// MARK: - Rows and cells

private struct DayEventRow: View {
    let event: CalendarEvent
    let isConflict: Bool
    let hasPrepNote: Bool
    var onRecord: () -> Void
    var onPrep: () -> Void
    var onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendar.color.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.title).font(.headline)
                    if event.source == .google { GoogleBadge() }
                    AutoRecordBadge(event: event)
                    if isConflict {
                        Label("Conflict", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text(timeRange).font(.caption).foregroundStyle(.secondary)
                if !event.location.isEmpty {
                    Label(event.location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
                }
                let attendees = event.attendeeNames
                if !attendees.isEmpty {
                    Label(attendees, systemImage: "person.2").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(action: onPrep) {
                Label(hasPrepNote ? "Prep notes" : "Add prep notes", systemImage: hasPrepNote ? "note.text" : "square.and.pencil")
            }
            Button(action: onRecord) {
                Label("Record", systemImage: "record.circle")
            }
            .disabled(RecordingManager.shared.isActive)
            Button(action: onEdit) { Image(systemName: "pencil") }
                .help("Edit event")
        }
        .controlSize(.small)
        .padding(.vertical, 4)
    }

    private var timeRange: String {
        if event.isAllDay { return "All day" }
        return "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
    }
}

private struct EventChip: View {
    let event: CalendarEvent
    let isConflict: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if event.source == .google { GoogleBadge() }
                Text(event.title).font(.caption.weight(.medium)).lineLimit(2)
            }
            Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(event.calendar.color.color.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isConflict ? Color.orange : Color.clear, lineWidth: 1.5))
        .help(isConflict ? "Overlaps another event" : (event.title))
    }
}

private struct MonthCell: View {
    let day: Date
    let inMonth: Bool
    let events: [CalendarEvent]
    let taskCount: Int
    @State private var hovering = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.weight(isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.5)))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isToday ? Color.red : .clear))
                Spacer()
                if taskCount > 0 {
                    Label("\(taskCount)", systemImage: "checklist").font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
            ForEach(events.prefix(3), id: \.id) { event in
                Text(event.isAllDay ? event.title : "\(event.start.formatted(.dateTime.hour().minute())) \(event.title)")
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(event.calendar.color.color.opacity(0.22)))
                    .foregroundStyle(.primary)
            }
            if events.count > 3 {
                Text("+\(events.count - 3) more").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(hovering ? DS.subtleFill : (inMonth ? DS.cardBackground : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).strokeBorder(DS.hairline))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(events.count) events")
    }
}
