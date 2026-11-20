import Foundation
import SwiftData

enum AutomationTrigger: String, CaseIterable, Identifiable {
    case recordingFinished, meetingEnded, transcriptReady, dailySummary

    var id: Self { self }
    var label: String {
        switch self {
        case .recordingFinished: return "Recording finished"
        case .meetingEnded: return "Meeting ended"
        case .transcriptReady: return "Transcript ready"
        case .dailySummary: return "Daily summary"
        }
    }
}

enum AutomationAction: String, CaseIterable, Identifiable {
    case createNote, createTask, copyTranscript

    var id: Self { self }
    var label: String {
        switch self {
        case .createNote: return "Create note"
        case .createTask: return "Create task"
        case .copyTranscript: return "Copy transcript"
        }
    }

    var requiresApproval: Bool { self == .copyTranscript }

    func supports(_ trigger: AutomationTrigger) -> Bool {
        self != .copyTranscript || trigger == .transcriptReady
    }
}

enum AutomationRunStatus: String {
    case pending, completed, declined, failed

    var label: String {
        switch self {
        case .pending: return "Needs approval"
        case .completed: return "Completed"
        case .declined: return "Declined"
        case .failed: return "Failed"
        }
    }
}

@Model
final class AutomationWorkflow {
    var uid = UUID()
    var name = ""
    var triggerRaw = "transcriptReady"
    var actionRaw = "createNote"
    var enabledSince: Date? = Date()
    var titleContains = ""
    var minimumMinutes = 0
    var dailyHour = 17
    var dailyMinute = 0
    var requiresApproval = false

    init(name: String) { self.name = name }

    var trigger: AutomationTrigger {
        get { AutomationTrigger(rawValue: triggerRaw) ?? .transcriptReady }
        set { triggerRaw = newValue.rawValue }
    }

    var action: AutomationAction {
        get { AutomationAction(rawValue: actionRaw) ?? .createNote }
        set { actionRaw = newValue.rawValue }
    }
}

@Model
final class AutomationRun {
    var uid = UUID()
    var occurrenceKey = ""
    var workflowName = ""
    var actionRaw = ""
    var statusRaw = "pending"
    var title = ""
    var payload = ""
    var detail = ""
    var date = Date()
    var recordingID: UUID?
    var calendarEventID: String?

    init(workflow: AutomationWorkflow, occurrenceKey: String, event: AutomationEvent) {
        self.occurrenceKey = occurrenceKey
        self.workflowName = workflow.name
        self.actionRaw = workflow.actionRaw
        self.title = event.title
        self.payload = event.body
        self.recordingID = event.recordingID
        self.calendarEventID = event.calendarEventID
    }

    var action: AutomationAction? { AutomationAction(rawValue: actionRaw) }

    var status: AutomationRunStatus {
        get { AutomationRunStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
}

struct AutomationEvent {
    let trigger: AutomationTrigger
    let id: String
    let date: Date
    let title: String
    let body: String
    var minutes: Double = 0
    var recordingID: UUID?
    var calendarEventID: String?

    func matches(_ workflow: AutomationWorkflow) -> Bool {
        guard workflow.trigger == trigger, let enabledSince = workflow.enabledSince, enabledSince <= date,
              workflow.action.supports(trigger), minutes >= Double(workflow.minimumMinutes) else { return false }
        let query = workflow.titleContains.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedStandardContains(query)
    }
}
