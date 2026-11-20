import SwiftData
import SwiftUI

/// Searchable recording history with a detail pane. Used by Voice (all kinds) and Meetings (meetings only).
struct RecordingsBrowser: View {
    var kinds: Set<RecordingKind>
    var emptyMessage: String

    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
    @State private var selectedID: UUID?
    @State private var search = ""

    private var visible: [Recording] {
        recordings.filter { recording in
            guard kinds.contains(recording.kind) else { return false }
            guard !search.isEmpty else { return true }
            return recording.title.localizedCaseInsensitiveContains(search)
                || recording.summary.localizedCaseInsensitiveContains(search)
                || recording.attendees.localizedCaseInsensitiveContains(search)
                || recording.segments.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    private var selected: Recording? {
        guard let selectedID else { return nil }
        return recordings.first { $0.uid == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search titles, transcripts, summaries", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                List(visible, id: \.uid, selection: $selectedID) { recording in
                    RecordingRow(recording: recording)
                        .tag(recording.uid)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(recording) }
                        }
                }
                .overlay {
                    if visible.isEmpty {
                        Text(search.isEmpty ? emptyMessage : "No matches.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            .frame(width: 280)

            Divider()

            if let selected {
                RecordingDetailView(recording: selected, onDelete: { delete(selected) })
                    .id(selected.uid)
            } else {
                EmptyStateView(systemImage: "waveform", title: visible.isEmpty ? "No recordings yet" : "Select a recording",
                               message: visible.isEmpty ? "Record a meeting or voice note, or import an audio file." : "Its summary, action items and transcript appear here.")
            }
        }
        .onAppear {
            handlePendingAction()
            if selectedID == nil { selectedID = visible.first?.uid }
        }
        .onChange(of: appState.pendingAction) { _, _ in handlePendingAction() }
        .onChange(of: RecordingManager.shared.current?.uid) { _, newValue in
            if let newValue { selectedID = newValue }
        }
    }

    private func handlePendingAction() {
        guard case .openRecording(let uid)? = appState.pendingAction,
              let recording = recordings.first(where: { $0.uid == uid }),
              kinds.contains(recording.kind) else { return }
        appState.pendingAction = nil
        search = ""
        selectedID = uid
    }

    private func delete(_ recording: Recording) {
        guard recording.status != .recording else { return }
        if selectedID == recording.uid { selectedID = nil }
        RecordingActions.delete(recording, context: context)
    }
}

private struct RecordingRow: View {
    let recording: Recording

    private var tint: Color {
        switch recording.kind {
        case .meeting: return AppSection.calendar.tint
        case .voiceNote: return AppSection.voice.tint
        case .imported: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DS.Space.xs) {
                IconTile(systemImage: recording.kind.systemImage, color: tint, size: 20)
                Text(recording.title).font(.body.weight(.medium)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(TranscriptSegment.format(recording.duration))
                Spacer()
                StatusBadge(status: recording.status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: RecordingStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .recording, .failed: return .red
        case .transcribing, .analyzing: return .orange
        case .ready: return .green
        case .recorded, .transcribed: return .secondary
        }
    }
}
