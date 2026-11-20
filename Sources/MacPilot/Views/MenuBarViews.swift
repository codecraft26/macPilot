import AppKit
import SwiftData
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState
    private let recorder = RecordingManager.shared

    var body: some View {
        // While audio is captured the icon is a red (orange when paused) record symbol, never hidden.
        if appState.isRecording {
            Image(nsImage: MenuBarIcon.recording(paused: recorder.isPaused))
        } else {
            Image(nsImage: MenuBarIcon.idle)
        }
    }
}

/// Menu bar images. The idle icon is a template (adapts to light/dark menu bars and highlights);
/// the recording icon is deliberately non-template so it stays red.
enum MenuBarIcon {
    /// Standard menu bar glyph size.
    private static let pointSize: CGFloat = 15

    static let idle: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "MacPilot")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    static func recording(paused: Bool) -> NSImage {
        let color: NSColor = paused ? .systemOrange : .systemRed
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let name = paused ? "pause.circle.fill" : "record.circle.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: paused ? "Recording paused" : "Recording")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }
}

struct MenuBarContent: View {
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }) private var openTasks: [TaskItem]
    @Environment(AppState.self) private var appState
    private let shortcuts = ShortcutManager.shared
    private let recorder = RecordingManager.shared
    private let clipboard = ClipboardMonitor.shared

    var body: some View {
        if recorder.isActive {
            Text(recorder.isPaused ? "⏸ Recording paused" : "● Recording: \(recorder.current?.title ?? "")")
            Button(recorder.isPaused ? "Resume Recording" : "Pause Recording") { recorder.togglePause() }
            Button("Stop Recording  \(shortcutLabel(.recording))") { Task { await recorder.stop() } }
            Divider()
        } else if let next = CalendarService.shared.upcoming(limit: 1, withinDays: 1).first {
            Text("Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))")
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

        Button("Clipboard History…  \(shortcutLabel(.clipboard))") {
            WindowManager.shared.toggleClipboardPanel()
        }
        Button(clipboard.isPaused ? "Resume Clipboard Capture" : "Pause Clipboard Capture") {
            clipboard.isPaused.toggle()
        }
        Button("Command Launcher…  \(shortcutLabel(.launcher))") {
            WindowManager.shared.toggleLauncher()
        }
        Button(FloatingBuddy.shared.isVisible ? "Hide Floating Buddy" : "Show Floating Buddy") {
            FloatingBuddy.shared.toggle()
        }
        Button("Developer Workspace") {
            WindowManager.shared.showDashboard(section: .developer)
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
