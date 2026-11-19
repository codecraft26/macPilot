import SwiftData
import SwiftUI

struct AutomationsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AutomationWorkflow.name) private var workflows: [AutomationWorkflow]
    @Query(sort: \AutomationRun.date, order: .reverse) private var runs: [AutomationRun]
    @State private var editing: WorkflowDraft?
    @State private var reviewing: AutomationRun?
    @State private var deleting: AutomationWorkflow?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                SectionHeader(title: "Workflows", systemImage: "gearshape.2", color: .green) {
                    Button {
                        editing = WorkflowDraft()
                    } label: {
                        Label("New Workflow", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if workflows.isEmpty {
                    Text("Create a workflow to run an action when a recording, transcript, calendar event, or daily schedule is ready.")
                        .foregroundStyle(.secondary)
                }
                ForEach(workflows) { workflow in workflowRow(workflow) }

                let pending = runs.filter { $0.status == .pending }
                if !pending.isEmpty {
                    SectionHeader(title: "Needs Approval", systemImage: "hand.raised", color: .orange)
                    ForEach(pending) { run in runRow(run) }
                }
                SectionHeader(title: "Run History", systemImage: "clock.arrow.circlepath")
                let history = runs.filter { $0.status != .pending }
                if history.isEmpty { Text("Completed and declined runs appear here.").foregroundStyle(.secondary) }
                LazyVStack(spacing: DS.Space.xs) {
                    ForEach(history) { run in runRow(run) }
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Automations")
        .sheet(item: $editing) { draft in
            WorkflowEditor(draft: draft, onSave: save)
        }
        .sheet(item: $reviewing) { run in
            ApprovalSheet(run: run) { approved in
                AutomationEngine.resolve(run, approved: approved, context: context)
                reviewing = nil
            }
        }
        .alert("Delete this workflow?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Workflow", role: .destructive) {
                if let deleting {
                    context.delete(deleting)
                    persist()
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Run history and runs already awaiting approval will remain available.")
        }
    }

    private func workflowRow(_ workflow: AutomationWorkflow) -> some View {
        HStack(spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(workflow.name).font(.headline)
                Text("\(workflow.trigger.label) → \(workflow.action.label)")
                    .foregroundStyle(.secondary)
                if workflow.requiresApproval || workflow.action.requiresApproval {
                    Label("Requires approval", systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Enable \(workflow.name)", isOn: Binding(
                get: { workflow.enabledSince != nil },
                set: { enabled in
                    workflow.enabledSince = enabled ? Date() : nil
                    persist()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            Button("Edit") { editing = WorkflowDraft(workflow) }
            Button(role: .destructive) {
                deleting = workflow
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete \(workflow.name)")
        }
        .card()
    }

    private func runRow(_ run: AutomationRun) -> some View {
        HStack(spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(run.title).font(.headline)
                Text("\(run.workflowName) · \(run.action?.label ?? "Action") · \(run.status.label)")
                    .foregroundStyle(.secondary)
                if run.status != .pending {
                    Text(run.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(run.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            if run.status == .pending { Button("Review") { reviewing = run } }
        }
        .card()
    }

    private func save(_ draft: WorkflowDraft) {
        let workflow = draft.existing ?? AutomationWorkflow(name: draft.name)
        if draft.existing == nil { context.insert(workflow) }
        workflow.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        workflow.trigger = draft.trigger
        workflow.action = draft.action
        workflow.titleContains = draft.trigger == .dailySummary ? "" : draft.titleContains
        workflow.minimumMinutes = draft.trigger == .dailySummary ? 0 : draft.minimumMinutes
        let time = Calendar.current.dateComponents([.hour, .minute], from: draft.dailyTime)
        workflow.dailyHour = time.hour ?? 17
        workflow.dailyMinute = time.minute ?? 0
        workflow.requiresApproval = draft.requiresApproval
        persist()
    }

    private func persist() {
        do {
            try context.save()
            error = nil
        } catch {
            context.rollback()
            self.error = error.localizedDescription
        }
    }
}

private struct WorkflowDraft: Identifiable {
    let id = UUID()
    var existing: AutomationWorkflow?
    var name = ""
    var trigger: AutomationTrigger = .transcriptReady
    var action: AutomationAction = .createNote
    var titleContains = ""
    var minimumMinutes = 0
    var dailyTime = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    var requiresApproval = false

    init(_ workflow: AutomationWorkflow? = nil) {
        guard let workflow else { return }
        existing = workflow
        name = workflow.name
        trigger = workflow.trigger
        action = workflow.action
        titleContains = workflow.titleContains
        minimumMinutes = workflow.minimumMinutes
        dailyTime = Calendar.current.date(bySettingHour: workflow.dailyHour, minute: workflow.dailyMinute, second: 0, of: Date()) ?? dailyTime
        requiresApproval = workflow.requiresApproval
    }
}

private struct WorkflowEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: WorkflowDraft
    let onSave: (WorkflowDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(draft.existing == nil ? "New Workflow" : "Edit Workflow").font(.title2.bold())
            Form {
                TextField("Name", text: $draft.name)
                Picker("When", selection: $draft.trigger) {
                    ForEach(AutomationTrigger.allCases) { Text($0.label).tag($0) }
                }
                if draft.trigger == .dailySummary {
                    DatePicker("Run at", selection: $draft.dailyTime, displayedComponents: .hourAndMinute)
                    Text("Uses the Mac’s local time and runs while MacPilot is open.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Title contains (optional)", text: $draft.titleContains)
                    Stepper("Minimum duration: \(draft.minimumMinutes) min", value: $draft.minimumMinutes, in: 0...480)
                }
                Picker("Action", selection: $draft.action) {
                    ForEach(AutomationAction.allCases.filter { $0.supports(draft.trigger) }) { Text($0.label).tag($0) }
                }
                if draft.action.requiresApproval {
                    Label("Copying a transcript always requires approval.", systemImage: "hand.raised")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Toggle("Ask before running the action", isOn: $draft.requiresApproval)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Workflow") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 480)
        .onChange(of: draft.trigger) { _, trigger in
            if !draft.action.supports(trigger) { draft.action = .createNote }
        }
    }
}

private struct ApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let run: AutomationRun
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(run.action?.label ?? "Review Run").font(.title2.bold())
            Text(run.title).font(.headline)
            ScrollView {
                Text(run.payload).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140, maxHeight: 280)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Decline") { onDecision(false) }
                Button("Approve") { onDecision(true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 520)
    }
}
