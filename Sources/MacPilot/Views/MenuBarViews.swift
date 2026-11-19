import AppKit
import SwiftData
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // A filled red record icon whenever audio is being captured (no hidden recording).
        Image(systemName: appState.isRecording ? "record.circle.fill" : "sparkles")
    }
}

struct MenuBarContent: View {
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }) private var openTasks: [TaskItem]
    @Environment(AppState.self) private var appState
    private let shortcuts = ShortcutManager.shared
    private let recorder = RecordingManager.shared

    var body: some View {
        if recorder.isActive {
            Text(recorder.isPaused ? "⏸ Recording paused" : "● Recording: \(recorder.current?.title ?? "")")
            Button(recorder.isPaused ? "Resume Recording" : "Pause Recording") { recorder.togglePause() }
            Button("Stop Recording  \(shortcutLabel(.recording))") { Task { await recorder.stop() } }
            Divider()
        } else if let next = CalendarService.shared.upcoming(limit: 1, withinDays: 1).first {
            Text("Next: \(next.title ?? "Event") at \(next.startDate.formatted(date: .omitted, time: .shortened))")
            Divider()
        }

        Button("Ask AI…  \(shortcutLabel(.assistant))") {
            WindowManager.shared.toggleQuickAssistant()
        }
        Button("Open Dashboard") {
            WindowManager.shared.showDashboard(section: .dashboard)
        }
        Button("AI Assistant") {
            WindowManager.shared.showDashboard(section: .assistant)
        }

        Divider()

        Button("New Note  \(shortcutLabel(.newNote))") {
            WindowManager.shared.open(.notes, action: .newNote)
        }
        Button("New Task  \(shortcutLabel(.newTask))") {
            WindowManager.shared.open(.tasks, action: .newTask)
        }
        Button("Tasks (\(openTasks.count) open)") {
            WindowManager.shared.showDashboard(section: .tasks)
        }
        if !recorder.isActive {
            Button("Record Meeting  \(shortcutLabel(.recording))") { recorder.toggleMeeting() }
            Button("Record Voice Note") {
                Task { await recorder.start(kind: .voiceNote, title: "Voice note \(Date().formatted(date: .abbreviated, time: .shortened))") }
                WindowManager.shared.showDashboard(section: .voice)
            }
        }
        Button("Calendar & Meetings") {
            WindowManager.shared.showDashboard(section: .calendar)
        }

        Divider()

        Button("Settings…") {
            WindowManager.shared.showDashboard(section: .settings)
        }
        .keyboardShortcut(",")
        Button("Quit MacPilot") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func shortcutLabel(_ action: ShortcutAction) -> String {
        shortcuts.hotKey(for: action)?.displayString ?? ""
    }
}
