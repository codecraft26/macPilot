import AppKit
import SwiftData
import SwiftUI

/// Clipboard section in the dashboard: full history, filters, folders, AI actions.
struct ClipboardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]
    @State private var query = ""
    @State private var filter: ClipFilter = .all
    @State private var folder: String?
    @State private var selectedID: UUID?
    @State private var confirmClear = false
    private let monitor = ClipboardMonitor.shared

    private var folders: [String] {
        Array(Set(items.map(\.folder).filter { !$0.isEmpty })).sorted()
    }

    private var visible: [ClipboardItem] {
        let filtered = items.filter { filter.matches($0) && (folder == nil || $0.folder == folder) }
        let ordered = filtered.filter(\.isPinned) + filtered.filter { !$0.isPinned }
        return FuzzyMatcher.rank(ordered, query: query) { "\($0.title) \($0.text.prefix(2000)) \($0.sourceAppName)" }
    }

    private var selected: ClipboardItem? {
        guard let selectedID else { return nil }
        return items.first { $0.uid == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(12)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 150)
                Divider()
                List(visible.prefix(1000), id: \.uid, selection: $selectedID) { item in
                    ClipRow(item: item)
                        .tag(item.uid)
                        .contextMenu { contextMenu(for: item) }
                }
                .frame(width: 330)
                .overlay {
                    if visible.isEmpty {
                        Text(items.isEmpty ? "Copy something in any app and it appears here." : "No matches.")
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                if let selected {
                    ClipDetail(item: selected, folders: folders, onDelete: {
                        selectedID = nil
                        monitor.delete(selected)
                    })
                    .id(selected.uid)
                } else {
                    Text("Select an item").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Clipboard")
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear history (keep pinned & favorites)", role: .destructive) { monitor.clearHistory(includeKept: false) }
            Button("Clear everything", role: .destructive) { monitor.clearHistory(includeKept: true) }
        } message: {
            Text("\(items.count) items. This cannot be undone.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search clipboard history", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Picker("Filter", selection: $filter) {
                ForEach(ClipFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 150)
            Spacer()
            if let reason = monitor.lastSkipReason {
                Label(reason, systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Toggle(isOn: Binding(get: { !monitor.isPaused }, set: { monitor.isPaused = !$0 })) {
                Text(monitor.isPaused ? "Paused" : "Capturing")
            }
            .toggleStyle(.switch)
            .help("Pause or resume clipboard capture")
            Button("Open panel (\(ShortcutManager.shared.hotKey(for: .clipboard)?.displayString ?? "⌥C"))") {
                WindowManager.shared.toggleClipboardPanel()
            }
            Button("Clear…", role: .destructive) { confirmClear = true }
                .disabled(items.isEmpty)
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { folder ?? "" }, set: { folder = $0.isEmpty ? nil : $0 })) {
            Label("All items", systemImage: "tray.full").tag("")
            if !folders.isEmpty {
                Section("Folders") {
                    ForEach(folders, id: \.self) { name in
                        Label(name, systemImage: "folder").tag(name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func contextMenu(for item: ClipboardItem) -> some View {
        Button("Copy") { PasteService.write(item) }
        Button(item.isPinned ? "Unpin" : "Pin") { item.isPinned.toggle(); try? context.save() }
        Button(item.isFavorite ? "Remove from favorites" : "Add to favorites") { item.isFavorite.toggle(); try? context.save() }
        Divider()
        Button("Delete", role: .destructive) {
            if selectedID == item.uid { selectedID = nil }
            monitor.delete(item)
        }
    }
}

private struct ClipDetail: View {
    @Bindable var item: ClipboardItem
    let folders: [String]
    var onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @State private var aiResult: String?
    @State private var aiError: String?
    @State private var runningAction: ClipAIAction?
    @State private var language = "English"
    @State private var newFolder = ""
    @State private var flash: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(item.kind.label, systemImage: item.kind.systemImage).font(.headline)
                if !item.sourceAppName.isEmpty {
                    Text("from \(item.sourceAppName)").foregroundStyle(.secondary)
                }
                Spacer()
                Button { item.isPinned.toggle(); try? context.save() } label: { Image(systemName: item.isPinned ? "pin.fill" : "pin") }
                    .help(item.isPinned ? "Unpin" : "Pin (never expires)")
                Button { item.isFavorite.toggle(); try? context.save() } label: { Image(systemName: item.isFavorite ? "star.fill" : "star") }
                    .help("Favorite (never expires)")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            }
            ClipPreview(item: item)
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 280)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Button("Copy") {
                    PasteService.write(item)
                    flash = "Copied."
                }
                if item.kind == .richText {
                    Button("Copy as plain text") {
                        PasteService.write(item, plainText: true)
                        flash = "Copied as plain text."
                    }
                }
                Menu(item.folder.isEmpty ? "Add to folder" : "Folder: \(item.folder)") {
                    ForEach(folders, id: \.self) { name in
                        Button(name) { item.folder = name; try? context.save() }
                    }
                    if !item.folder.isEmpty {
                        Divider()
                        Button("Remove from folder") { item.folder = ""; try? context.save() }
                    }
                }
                .fixedSize()
                TextField("New folder", text: $newFolder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit {
                        let name = newFolder.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        item.folder = name
                        newFolder = ""
                        try? context.save()
                    }
                if let flash { Text(flash).font(.caption).foregroundStyle(.green) }
            }
            .controlSize(.small)

            if item.kind != .image && item.kind != .file {
                Divider()
                HStack {
                    Text("AI").font(.headline)
                    ForEach(ClipAIAction.allCases) { action in
                        Button {
                            run(action)
                        } label: {
                            Label(action.rawValue, systemImage: action.systemImage)
                        }
                        .disabled(runningAction != nil)
                    }
                    TextField("Language", text: $language)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .help("Target language for Translate")
                }
                .controlSize(.small)
                if let runningAction {
                    HStack { ProgressView().controlSize(.small); Text("\(runningAction.rawValue)…").font(.caption) }
                }
                if let aiError {
                    Text(aiError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let aiResult {
                    ScrollView {
                        Text(MarkdownText.attributed(aiResult))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    HStack {
                        Button("Copy result") {
                            PasteService.write(text: aiResult)
                            flash = "Result copied."
                        }
                        Button("Paste into previous app") {
                            PasteService.paste(text: aiResult, into: WindowManager.shared.previousApp)
                        }
                        .disabled(WindowManager.shared.previousApp == nil)
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func run(_ action: ClipAIAction) {
        runningAction = action
        aiError = nil
        aiResult = nil
        let text = item.text
        let language = language
        Task {
            do {
                aiResult = try await action.run(on: text, language: language)
            } catch {
                aiError = AIError.describe(error)
            }
            runningAction = nil
        }
    }
}
