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
                VStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Select a recording").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: handlePendingAction)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: recording.kind.systemImage).foregroundStyle(.secondary)
                Text(recording.title).lineLimit(1)
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
