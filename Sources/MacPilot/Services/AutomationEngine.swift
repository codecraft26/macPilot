import Foundation
import SwiftData

@MainActor
final class AutomationEngine {
    static let shared = AutomationEngine()
    private var timer: Task<Void, Never>?
    private var lastMeetingCheck = Date()

    private var context: ModelContext { Persistence.container.mainContext }

    func start() {
        guard timer == nil else { return }
        lastMeetingCheck = Date()
        timer = Task {
            while !Task.isCancelled {
                await runScheduledWork(at: Date())
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
            }
        }
    }

    func recordingFinished(_ recording: Recording) {
        runRecordingTrigger(.recordingFinished, recording: recording)
    }

    func transcriptReady(_ recording: Recording) {
        runRecordingTrigger(.transcriptReady, recording: recording)
    }

    private func runRecordingTrigger(_ trigger: AutomationTrigger, recording: Recording) {
        let now = Date()
        let body = trigger == .transcriptReady ? recording.transcriptText :
            "Recorded \(recording.startedAt.formatted()). Duration: \(TranscriptSegment.format(recording.duration))."
        let event = AutomationEvent(trigger: trigger, id: recording.uid.uuidString, date: now, title: recording.title,
                                    body: body, minutes: recording.duration / 60, recordingID: recording.uid,
                                    calendarEventID: recording.calendarEventID)
        Self.handle(event, workflows: workflows(for: trigger), context: context)
    }

    private func workflows(for trigger: AutomationTrigger) -> [AutomationWorkflow] {
        let raw = trigger.rawValue
        let descriptor = FetchDescriptor<AutomationWorkflow>(predicate: #Predicate { $0.triggerRaw == raw && $0.enabledSince != nil })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func runScheduledWork(at now: Date) async {
        let meetings = workflows(for: .meetingEnded)
        let daily = workflows(for: .dailySummary)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: day) else { return }

        let due = daily.compactMap { workflow -> (AutomationWorkflow, Date)? in
            guard let scheduled = Self.dailyOccurrence(for: workflow, on: day, calendar: calendar),
                  scheduled <= now, workflow.enabledSince.map({ $0 <= scheduled }) == true,
                  !Self.hasRun(key: Self.key(workflow, trigger: .dailySummary, id: day.formatted(.iso8601)), context: context) else { return nil }
            return (workflow, scheduled)
        }

        guard !meetings.isEmpty || !due.isEmpty else {
            lastMeetingCheck = now
            return
        }
        let meetingWindowStart = max(lastMeetingCheck, now.addingTimeInterval(-86_400))
        let start = due.isEmpty ? meetingWindowStart.addingTimeInterval(-1) : min(day, meetingWindowStart.addingTimeInterval(-1))
        let end = due.isEmpty ? now : endOfDay
        let calendars = CalendarService.shared
        await calendars.refresh(from: start, to: end)
        let events = calendars.events(from: start, to: end)

        for meeting in events where !meeting.isAllDay && meeting.end > meetingWindowStart && meeting.end <= now {
            let event = AutomationEvent(trigger: .meetingEnded, id: "\(meeting.id)|\(meeting.start.timeIntervalSinceReferenceDate)",
                                        date: meeting.end, title: meeting.title,
                                        body: "\(meeting.start.formatted()) – \(meeting.end.formatted(date: .omitted, time: .shortened))",
                                        minutes: meeting.end.timeIntervalSince(meeting.start) / 60, calendarEventID: meeting.id)
            Self.handle(event, workflows: workflows(for: .meetingEnded), context: context)
        }
        if !calendars.google.isConnected || calendars.google.lastError == nil { lastMeetingCheck = now }

        if !due.isEmpty {
            let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isCompleted },
                                                                     sortBy: [SortDescriptor(\.dueDate)]))) ?? []
            let body = Self.dailySummary(events: events.filter { $0.start < endOfDay && $0.end > day },
                                         tasks: tasks.filter { $0.dueDate.map { $0 < endOfDay } == true })
            for (workflow, scheduled) in due where !workflow.isDeleted {
                let event = AutomationEvent(trigger: .dailySummary, id: day.formatted(.iso8601), date: scheduled,
                                            title: "Daily summary · \(day.formatted(date: .abbreviated, time: .omitted))", body: body)
                Self.handle(event, workflows: [workflow], context: context)
            }
        }
    }

    static func dailyOccurrence(for workflow: AutomationWorkflow, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: workflow.dailyHour, minute: workflow.dailyMinute, second: 0,
                      of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }

    static func dailySummary(events: [CalendarEvent], tasks: [TaskItem]) -> String {
        let calendar = events.map { event in
            let time = event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)
            return "- \(time) · \(event.title)"
        }
        let due = tasks.map { task in
            "- \(task.title)\(task.dueDate.map { " · \($0.shortRelative)" } ?? "")"
        }
        let appointments = calendar.isEmpty ? "No events." : calendar.joined(separator: "\n")
        let taskList = due.isEmpty ? "No tasks due." : due.joined(separator: "\n")
        return "## Calendar\n\(appointments)\n\n## Due and overdue tasks\n\(taskList)"
    }

    static func handle(_ event: AutomationEvent, workflows: [AutomationWorkflow], context: ModelContext) {
        for workflow in workflows where event.matches(workflow) {
            let occurrenceKey = key(workflow, trigger: event.trigger, id: event.id)
            guard !hasRun(key: occurrenceKey, context: context) else { continue }
            let run = AutomationRun(workflow: workflow, occurrenceKey: occurrenceKey, event: event)
            context.insert(run)
            if workflow.requiresApproval || workflow.action.requiresApproval {
                run.detail = "Waiting for your approval."
                try? context.save()
            } else {
                resolve(run, approved: true, context: context)
            }
        }
    }

    private static func key(_ workflow: AutomationWorkflow, trigger: AutomationTrigger, id: String) -> String {
        "\(workflow.uid.uuidString)|\(trigger.rawValue)|\(id)"
    }

    private static func hasRun(key: String, context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<AutomationRun>(predicate: #Predicate { $0.occurrenceKey == key })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).isEmpty == false
    }

    static func resolve(_ run: AutomationRun, approved: Bool, context: ModelContext) {
        guard run.status == .pending, let action = run.action else { return }
        let payload = run.payload
        run.payload = ""
        guard approved else {
            run.status = .declined
            run.detail = "Declined."
            try? context.save()
            return
        }

        var note: Note?
        var task: TaskItem?
        run.status = .completed
        switch action {
        case .createNote:
            let item = Note(title: run.title, body: payload, folder: "Automations")
            item.recordingID = run.recordingID
            item.eventID = run.calendarEventID
            context.insert(item)
            note = item
            run.detail = "Created a note in Automations."
        case .createTask:
            let item = TaskItem(title: run.title, category: "Automation")
            item.notes = payload
            context.insert(item)
            task = item
            run.detail = "Created a task."
        case .copyTranscript:
            run.detail = "Copied the transcript to the clipboard."
        }
        do {
            try context.save()
            if action == .copyTranscript { Clipboard.copy(payload) }
        } catch {
            if let note { context.delete(note) }
            if let task { context.delete(task) }
            run.status = .failed
            run.detail = "Could not save the automation run. \(error.localizedDescription)"
            try? context.save()
        }
    }

    static func discardPending(for recordingID: UUID, context: ModelContext) {
        let pending = AutomationRunStatus.pending.rawValue
        let descriptor = FetchDescriptor<AutomationRun>(predicate: #Predicate {
            $0.recordingID == recordingID && $0.statusRaw == pending
        })
        for run in (try? context.fetch(descriptor)) ?? [] {
            run.payload = ""
            run.status = .declined
            run.detail = "The source recording was deleted."
        }
    }
}
