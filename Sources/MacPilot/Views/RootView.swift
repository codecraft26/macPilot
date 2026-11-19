import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            List(AppSection.allCases, selection: $appState.selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                RecordingStatusFooter()
            }
        } detail: {
            detail(for: appState.selectedSection ?? .dashboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        case .clipboard, .developer, .automations:
            ComingSoonView(section: section)
        }
    }
}

private struct RecordingStatusFooter: View {
    @Environment(AppState.self) private var appState
    private let recorder = RecordingManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appState.isRecording ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(appState.isRecording ? (recorder.isPaused ? "Recording paused" : "Recording") : "Not recording")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if recorder.isActive {
                Button {
                    Task { await recorder.stop() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop recording")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Planned modules from the PRD, shown with what is coming and in which phase.
struct ComingSoonView: View {
    let section: AppSection

    private var plan: (phase: String, features: [String]) {
        switch section {
        case .clipboard:
            return ("Phase 6", ["Clipboard history with search, favorites, pins and folders",
                                "Sensitive-content exclusions and configurable retention",
                                "Optional image history"])
        case .developer:
            return ("Phase 6", ["Git status, branches, recent commits and AI commit messages",
                                "AI error explanations, code review and test generation",
                                "API request builder, JSON formatter and response viewer",
                                "Terminal shortcuts; every command needs your approval, destructive ones a second confirmation"])
        case .automations:
            return ("Phase 7", ["Triggers: recording finished, meeting ended, transcript ready, daily summary",
                                "Conditional workflows with run history",
                                "Manual approval for sensitive actions"])
        default:
            return ("", [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(section.title, systemImage: section.systemImage)
                .font(.largeTitle.bold())
            Text("Coming in \(plan.phase)")
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.features, id: \.self) { feature in
                    Label(feature, systemImage: "circle.dashed")
                }
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle(section.title)
    }
}
