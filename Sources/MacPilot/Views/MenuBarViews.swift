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

    var body: some View {
        if appState.isRecording {
            Text("● Recording in progress")
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
        Button("Quick Recording (Phase 3)") {}
            .disabled(true)

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
