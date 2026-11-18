import Foundation
import Observation

/// The ten top-level areas from the PRD navigation (section 7).
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, assistant, voice, calendar, notes, tasks, clipboard, developer, automations, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .assistant: return "AI Assistant"
        case .voice: return "Voice & Transcription"
        case .calendar: return "Calendar & Meetings"
        case .notes: return "Notes & Knowledge"
        case .tasks: return "Tasks & Reminders"
        case .clipboard: return "Clipboard"
        case .developer: return "Developer Workspace"
        case .automations: return "Automations"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .assistant: return "sparkles"
        case .voice: return "waveform"
        case .calendar: return "calendar"
        case .notes: return "note.text"
        case .tasks: return "checklist"
        case .clipboard: return "doc.on.clipboard"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .automations: return "gearshape.2"
        case .settings: return "gear"
        }
    }
}

/// One-shot requests delivered to a section when it opens (e.g. from a global shortcut).
enum PendingAction: Equatable {
    case newNote
    case newTask
}

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    var selectedSection: AppSection? = .dashboard
    var pendingAction: PendingAction?
    /// Drives the menu bar recording indicator. Set by the recorder (Phase 3).
    var isRecording = false

    private init() {}
}
