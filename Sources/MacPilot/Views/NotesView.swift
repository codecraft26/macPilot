import SwiftData
import SwiftUI

struct NotesView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @State private var selection: Note?
    @State private var search = ""

    private var visibleNotes: [Note] {
        let matching = notes.filter { note in
            search.isEmpty
                || note.title.localizedCaseInsensitiveContains(search)
                || note.body.localizedCaseInsensitiveContains(search)
                || note.tagsRaw.localizedCaseInsensitiveContains(search)
                || note.folder.localizedCaseInsensitiveContains(search)
        }
        return matching.filter(\.isPinned) + matching.filter { !$0.isPinned }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search notes", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Button(action: createNote) { Image(systemName: "square.and.pencil") }
                        .help("New note (⌥N)")
                }
                .padding(10)
                List(visibleNotes, selection: $selection) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if note.isPinned { Image(systemName: "pin.fill").font(.caption2) }
                            Text(note.displayTitle).lineLimit(1)
                        }
                        HStack {
                            if !note.folder.isEmpty { Text(note.folder) }
                            Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(note)
                    .contextMenu {
                        Button(note.isPinned ? "Unpin" : "Pin") { note.isPinned.toggle() }
                        Button("Delete", role: .destructive) { delete(note) }
                    }
                }
            }
            .frame(width: 260)

            Divider()

            if let selection {
                NoteEditor(note: selection, onDelete: { delete(selection) })
                    .id(selection.persistentModelID)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "note.text").font(.system(size: 40)).foregroundStyle(.secondary)
                    Button("New note", action: createNote).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Notes & Knowledge")
        .onAppear(perform: handlePendingAction)
        .onChange(of: appState.pendingAction) { _, _ in handlePendingAction() }
    }

    private func handlePendingAction() {
        switch appState.pendingAction {
        case .newNote?:
            appState.pendingAction = nil
            createNote()
        case .openNote(let uid)?:
            appState.pendingAction = nil
            search = ""
            selection = notes.first { $0.uid == uid }
        default:
            break
        }
    }

    private func createNote() {
        let note = Note()
        context.insert(note)
        try? context.save()
        selection = note
    }

    private func delete(_ note: Note) {
        if selection == note { selection = nil }
        context.delete(note)
        try? context.save()
    }
}

private struct NoteEditor: View {
    @Bindable var note: Note
    var onDelete: () -> Void
    @State private var showPreview = false
    @State private var summary: String?
    @State private var isSummarizing = false
    @State private var summaryError: String?
    @Environment(AppState.self) private var appState
    @Query private var recordings: [Recording]

    private var linkedRecording: Recording? {
        guard let id = note.recordingID else { return nil }
        return recordings.first { $0.uid == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Title", text: $note.title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                Spacer()
                Button {
                    summarize()
                } label: {
                    if isSummarizing { ProgressView().controlSize(.small) } else { Label("AI summary", systemImage: "sparkles") }
                }
                .disabled(isSummarizing || note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Summarize this note with \(Prefs.analysisProvider.displayName)")
                Toggle(isOn: $showPreview) { Image(systemName: "eye") }
                    .toggleStyle(.button)
                    .help("Preview Markdown")
                Button { note.isPinned.toggle() } label: {
                    Image(systemName: note.isPinned ? "pin.fill" : "pin")
                }
                .help(note.isPinned ? "Unpin" : "Pin")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Delete note")
            }
            HStack {
                Label {
                    TextField("Folder", text: $note.folder).textFieldStyle(.roundedBorder).frame(width: 160)
                } icon: { Image(systemName: "folder") }
                Label {
                    TextField("Tags, comma separated", text: $note.tagsRaw).textFieldStyle(.roundedBorder)
                } icon: { Image(systemName: "tag") }
            }
            if let recording = linkedRecording {
                Button {
                    appState.pendingAction = .openRecording(recording.uid)
                    appState.selectedSection = recording.kind == .meeting ? .calendar : .voice
                } label: {
                    Label("Linked recording: \(recording.title)", systemImage: recording.kind.systemImage)
                }
                .buttonStyle(.link)
            }
            if let eventID = note.eventID, let event = CalendarService.shared.event(withID: eventID) {
                Label("Prep for \(event.title ?? "event") · \(event.startDate.shortRelative)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let summaryError {
                Label(summaryError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if showPreview {
                ScrollView {
                    Text(MarkdownText.attributed(note.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                TextEditor(text: $note.body)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
            }
            Text("Edited \(note.updatedAt.formatted(.relative(presentation: .named))) · Markdown supported")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .sheet(isPresented: Binding(get: { summary != nil }, set: { if !$0 { summary = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI summary").font(.title3.bold())
                ScrollView {
                    Text(MarkdownText.attributed(summary ?? ""))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Copy") { Clipboard.copy(summary ?? "") }
                    Spacer()
                    Button("Close", role: .cancel) { summary = nil }
                    Button("Insert at top of note") {
                        note.body = "## Summary\n\n\(summary ?? "")\n\n---\n\n" + note.body
                        summary = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 520, height: 420)
        }
        .onChange(of: note.body) { _, _ in note.updatedAt = Date() }
        .onChange(of: note.title) { _, _ in note.updatedAt = Date() }
    }

    private func summarize() {
        isSummarizing = true
        summaryError = nil
        let text = (note.title.isEmpty ? "" : "# \(note.title)\n\n") + note.body
        Task {
            do {
                summary = try await MeetingIntelligence.summarize(note: text)
            } catch {
                summaryError = AIError.describe(error)
            }
            isSummarizing = false
        }
    }
}
