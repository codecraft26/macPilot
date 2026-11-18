import SwiftData
import SwiftUI

struct PromptLibraryView: View {
    var onInsert: (PromptTemplate) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PromptTemplate.title) private var prompts: [PromptTemplate]
    @State private var search = ""
    @State private var editing: PromptTemplate?

    private var grouped: [(String, [PromptTemplate])] {
        let visible = prompts.filter {
            search.isEmpty
                || $0.title.localizedCaseInsensitiveContains(search)
                || $0.body.localizedCaseInsensitiveContains(search)
        }
        let groups = Dictionary(grouping: visible) { $0.category.isEmpty ? "General" : $0.category }
        return groups.keys.sorted().map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Prompt library").font(.headline)
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button {
                    let prompt = PromptTemplate(title: "New prompt", body: "")
                    context.insert(prompt)
                    editing = prompt
                } label: {
                    Image(systemName: "plus")
                }
            }
            .padding(14)
            Divider()
            List {
                ForEach(grouped, id: \.0) { category, items in
                    Section(category) {
                        ForEach(items) { prompt in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(prompt.title)
                                    Text(prompt.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Edit") { editing = prompt }.buttonStyle(.borderless)
                                Button("Insert") { onInsert(prompt) }.buttonStyle(.bordered)
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    context.delete(prompt)
                                    try? context.save()
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 480)
        .sheet(item: $editing) { prompt in
            PromptEditor(prompt: prompt)
        }
    }
}

private struct PromptEditor: View {
    @Bindable var prompt: PromptTemplate
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Title", text: $prompt.title)
            TextField("Category", text: $prompt.category)
            Section("Prompt") {
                TextEditor(text: $prompt.body)
                    .font(.body)
                    .frame(minHeight: 160)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 380)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    try? context.save()
                    dismiss()
                }
            }
        }
    }
}
