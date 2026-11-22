import Foundation
import Observation

/// The ten top-level areas from the PRD navigation (section 7).
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, assistant, agent, voice, calendar, notes, tasks, clipboard, tools, developer, automations, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .assistant: return "AI Assistant"
        case .agent: return "Agent"
        case .voice: return "Voice & Transcription"
        case .calendar: return "Calendar & Meetings"
        case .notes: return "Notes & Knowledge"
        case .tasks: return "Tasks & Reminders"
        case .clipboard: return "Clipboard"
        case .tools: return "File Tools"
        case .developer: return "Developer Workspace"
        case .automations: return "Automations"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .assistant: return "sparkles"
        case .agent: return "cpu"
        case .voice: return "waveform"
        case .calendar: return "calendar"
        case .notes: return "note.text"
        case .tasks: return "checklist"
        case .clipboard: return "doc.on.clipboard"
        case .tools: return "arrow.triangle.2.circlepath.doc.on.clipboard"
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
    case openNote(UUID)
    case openRecording(UUID)
    case quickAddEvent(String)
    case openTool(String)
    case askAgent(String)
}

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    var selectedSection: AppSection? = .dashboard
    var pendingAction: PendingAction?
    /// Tab to show when a recording opens from a calendar event ("Summary", "Transcript").
    var pendingRecordingTab: String?
    /// Seconds to jump to in a transcript opened from search.
    var pendingTranscriptSeek: Double?
    /// Drives the menu bar recording indicator. Set by `RecordingManager`.
    var isRecording = false
    /// Text for the quick assistant to ask as soon as it opens (from the launcher).
    var pendingQuickPrompt: String?
    /// Incremented each time a clipboard/launcher panel opens so it can reset its search.
    var panelSession = 0

    private init() {}
}
