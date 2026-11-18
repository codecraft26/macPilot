import SwiftData
import SwiftUI

@MainActor
enum TaskActions {
    static func toggle(_ task: TaskItem, context: ModelContext) {
        task.isCompleted.toggle()
        task.completedAt = task.isCompleted ? Date() : nil
        if task.isCompleted {
            NotificationService.cancel(id: task.notificationID)
            // Recurring tasks roll forward to the next occurrence.
            if task.recurrence != .none, let next = task.recurrence.next(after: task.dueDate ?? Date()) {
                let copy = TaskItem(title: task.title, dueDate: next, priority: task.priority, category: task.category)
                copy.notes = task.notes
                copy.recurrence = task.recurrence
                context.insert(copy)
                NotificationService.schedule(id: copy.notificationID, title: copy.title, at: copy.dueDate)
            }
        } else {
            NotificationService.schedule(id: task.notificationID, title: task.title, at: task.dueDate)
        }
        try? context.save()
    }

    static func delete(_ task: TaskItem, context: ModelContext) {
        NotificationService.cancel(id: task.notificationID)
        context.delete(task)
        try? context.save()
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case today = "Today", upcoming = "Upcoming", all = "All", completed = "Completed"
    var id: String { rawValue }
}

struct TasksView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var tasks: [TaskItem]

    @State private var filter: TaskFilter = .all
    @State private var newTitle = ""
    @State private var newHasDue = false
    @State private var newDue = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var newPriority: TaskPriority = .none
    @State private var editing: TaskItem?
    @FocusState private var titleFocused: Bool

    private var filtered: [TaskItem] {
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let list: [TaskItem]
        switch filter {
        case .today:
            list = tasks.filter { !$0.isCompleted && ($0.dueDate.map { $0 < endOfToday } ?? false) }
        case .upcoming:
            list = tasks.filter { !$0.isCompleted && ($0.dueDate.map { $0 >= endOfToday } ?? false) }
        case .all:
            list = tasks.filter { !$0.isCompleted }
        case .completed:
            return tasks.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        }
        return list.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.priorityRaw > rhs.priorityRaw
            }
        }
    }

    private var completionSummary: String {
        let done = tasks.filter(\.isCompleted).count
        return "\(done) of \(tasks.count) completed"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Filter", selection: $filter) {
                    ForEach(TaskFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                Spacer()
                Text(completionSummary).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)

            addRow
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider()

            if filtered.isEmpty {
                Text(filter == .completed ? "No completed tasks yet." : "Nothing here. Add a task above.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { task in
                        TaskRow(task: task, onToggle: { TaskActions.toggle(task, context: context) })
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { editing = task }
                            .contextMenu {
                                Button("Edit…") { editing = task }
                                Button("Delete", role: .destructive) { TaskActions.delete(task, context: context) }
                            }
                    }
                }
            }
        }
        .navigationTitle("Tasks & Reminders")
        .sheet(item: $editing) { task in
            TaskEditor(task: task)
        }
        .onAppear(perform: handlePendingAction)
        .onChange(of: appState.pendingAction) { _, _ in handlePendingAction() }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("New task", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(addTask)
            Toggle("Due", isOn: $newHasDue)
            if newHasDue {
                DatePicker("", selection: $newDue)
                    .labelsHidden()
                    .frame(width: 190)
            }
            Picker("Priority", selection: $newPriority) {
                ForEach(TaskPriority.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 140)
            Button("Add", action: addTask)
                .buttonStyle(.borderedProminent)
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func handlePendingAction() {
        guard appState.pendingAction == .newTask else { return }
        appState.pendingAction = nil
        filter = .all
        titleFocused = true
    }

    private func addTask() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = TaskItem(title: title, dueDate: newHasDue ? newDue : nil, priority: newPriority)
        context.insert(task)
        try? context.save()
        NotificationService.schedule(id: task.notificationID, title: task.title, at: task.dueDate)
        newTitle = ""
        newPriority = .none
    }
}

private struct TaskRow: View {
    let task: TaskItem
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                HStack(spacing: 8) {
                    if let due = task.dueDate {
                        Label(due.shortRelative, systemImage: "clock")
                            .foregroundStyle(task.isOverdue ? .red : .secondary)
                    }
                    if task.recurrence != .none {
                        Label(task.recurrence.label, systemImage: "repeat")
                    }
                    if !task.category.isEmpty {
                        Label(task.category, systemImage: "tag")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if task.priority != .none {
                Image(systemName: "flag.fill")
                    .foregroundStyle(task.priority == .high ? .red : task.priority == .medium ? .orange : .blue)
                    .help("\(task.priority.label) priority")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct TaskEditor: View {
    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var hasDue = false
    @State private var due = Date()

    var body: some View {
        Form {
            TextField("Title", text: $task.title)
            TextField("Category", text: $task.category)
            Picker("Priority", selection: Binding(get: { task.priority }, set: { task.priority = $0 })) {
                ForEach(TaskPriority.allCases) { Text($0.label).tag($0) }
            }
            Picker("Repeat", selection: Binding(get: { task.recurrence }, set: { task.recurrence = $0 })) {
                ForEach(TaskRecurrence.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Due date", isOn: $hasDue)
            if hasDue {
                DatePicker("Due", selection: $due)
            }
            Section("Notes") {
                TextEditor(text: $task.notes).frame(minHeight: 80)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
        .onAppear {
            hasDue = task.dueDate != nil
            due = task.dueDate ?? Date()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    task.dueDate = hasDue ? due : nil
                    try? context.save()
                    NotificationService.schedule(id: task.notificationID, title: task.title, at: task.isCompleted ? nil : task.dueDate)
                    dismiss()
                }
            }
        }
    }
}
