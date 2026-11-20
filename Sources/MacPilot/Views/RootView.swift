import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            Sidebar(selection: $appState.selectedSection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail(for: appState.selectedSection ?? .dashboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(DS.accent)
        .frame(minWidth: 940, minHeight: 600)
    }

    @ViewBuilder
    private func detail(for section: AppSection) -> some View {
        switch section {
        case .dashboard: DashboardView()
        case .assistant: AssistantView()
        case .notes: NotesView()
        case .tasks: TasksView()
        case .settings: SettingsView()
        case .voice: VoiceView()
        case .calendar: CalendarMeetingsView()
        case .clipboard: ClipboardView()
        case .tools: FileToolsView()
        case .developer: DeveloperView()
        case .automations: AutomationsView()
        }
    }
}

/// Grouped sidebar with colored icon tiles and live badges.
private struct Sidebar: View {
    @Binding var selection: AppSection?
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }) private var openTasks: [TaskItem]
    private let recorder = RecordingManager.shared
    private let clipboard = ClipboardMonitor.shared

    private let groups = ["Workspace", "Organize", "Build"]

    var body: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(AppSection.allCases.filter { $0.group == group }) { section in
                        row(section)
                    }
                }
            }
            Section {
                row(.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RecordingStatusFooter()
        }
    }

    private func row(_ section: AppSection) -> some View {
        HStack(spacing: DS.Space.xs) {
            IconTile(systemImage: section.systemImage, color: section.tint)
            Text(section.title)
            Spacer(minLength: 0)
            badge(for: section)
        }
        .tag(section)
        .accessibilityLabel(section.title)
    }

    @ViewBuilder
    private func badge(for section: AppSection) -> some View {
        switch section {
        case .tasks:
            let overdue = openTasks.filter(\.isOverdue).count
            if !openTasks.isEmpty {
                Pill(text: "\(openTasks.count)", color: overdue > 0 ? .red : .secondary)
                    .help(overdue > 0 ? "\(overdue) overdue" : "\(openTasks.count) open")
            }
        case .voice, .calendar:
            if recorder.isActive && (recorder.current?.kind == .meeting) == (section == .calendar) {
                Circle().fill(recorder.isPaused ? Color.orange : Color.red).frame(width: 8, height: 8)
                    .accessibilityLabel("Recording")
            }
        case .clipboard:
            if clipboard.isPaused {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.caption)
                    .accessibilityLabel("Capture paused")
            }
        default:
            EmptyView()
        }
    }
}

private struct RecordingStatusFooter: View {
    @Environment(AppState.self) private var appState
    private let recorder = RecordingManager.shared

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Circle()
                .fill(appState.isRecording ? (recorder.isPaused ? Color.orange : Color.red) : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            if recorder.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(recorder.isPaused ? "Paused" : "Recording") · \(TranscriptSegment.format(recorder.elapsed(at: context.date)))")
                        .font(.caption.monospacedDigit())
                }
            } else {
                Text("Not recording").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if recorder.isActive {
                Button {
                    Task { await recorder.stop() }
                } label: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Stop recording")
                .accessibilityLabel("Stop recording")
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(.bar)
    }
}
