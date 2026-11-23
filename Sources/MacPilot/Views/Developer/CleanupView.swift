import AppKit
import SwiftUI

/// Developer → Cleanup: reclaimable developer files grouped by category, confirm-first, Trash by default.
struct CleanupView: View {
    private let cleanup = DevCleanup.shared
    @State private var selection: Set<String> = []
    @State private var sort: Sort = .size
    @State private var ageFilter = 0
    @State private var confirm: Pending?
    @State private var secondConfirm: [CleanupItem]?
    @State private var message: String?
    @State private var showSettings = false

    enum Sort: String, CaseIterable, Identifiable { case size = "Size", age = "Age"; var id: String { rawValue } }
    struct Pending { var items: [CleanupItem]; var permanent: Bool }

    private var visible: [CleanupItem] { CleanupRules.untouched(cleanup.items, days: ageFilter) }
    private var selected: [CleanupItem] { cleanup.items.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar.padding(12)
            if let message { Text(message).font(.caption).padding(.horizontal, 12).padding(.bottom, 6) }
            Divider()
            if cleanup.items.isEmpty {
                ContentUnavailableView(cleanup.scanning ? cleanup.status : (cleanup.lastScan == nil ? "Scan to find reclaimable files" : "Nothing to clean up"),
                                       systemImage: "externaldrive.badge.minus",
                                       description: Text("node_modules, Xcode DerivedData and Archives, Docker, and package-manager caches."))
            } else {
                list
            }
            Divider()
            footer.padding(12)
        }
        .sheet(isPresented: $showSettings) { CleanupSettingsSheet() }
        .confirmationDialog(confirm.map { $0.permanent ? "Delete permanently?" : "Clean up \($0.items.count) item\($0.items.count == 1 ? "" : "s")?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if let pending = confirm {
                Button(pending.permanent ? "Continue…" : "Move to Trash", role: .destructive) {
                    if pending.permanent { secondConfirm = pending.items } else { run(pending.items, permanent: false) }
                }
            }
        } message: { Text(confirm.map { CleanupRules.confirmation($0.items, permanent: $0.permanent) } ?? "") }
        .confirmationDialog("This can't be undone.", isPresented: Binding(get: { secondConfirm != nil }, set: { if !$0 { secondConfirm = nil } })) {
            Button("Delete permanently", role: .destructive) { if let items = secondConfirm { run(items, permanent: true) } }
        } message: { Text("These caches are deleted, not moved to the Trash. Tools re-download them when needed.") }
    }

    private var toolbar: some View {
        HStack {
            if cleanup.scanning {
                ProgressView().controlSize(.small)
                Text(cleanup.status).font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { cleanup.cancel() }
            } else {
                Button { Task { await cleanup.scan(); selection = [] } } label: { Label(cleanup.lastScan == nil ? "Scan" : "Rescan", systemImage: "magnifyingglass") }
                if cleanup.lastScan != nil { Text(cleanup.status).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            Picker("Not touched in", selection: $ageFilter) {
                Text("Any age").tag(0); Text("30+ days").tag(30); Text("90+ days").tag(90)
            }.frame(width: 190)
            Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 120)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("Folders and options")
        }
    }

    private var list: some View {
        List {
            ForEach(CleanupRules.byCategory(visible), id: \.0) { category, bytes, items in
                Section {
                    ForEach(sorted(items)) { row($0) }
                } header: {
                    HStack {
                        Label(category.title, systemImage: category.systemImage)
                        Spacer()
                        Text(CleanupFormat.bytes(bytes)).monospacedDigit()
                        Button("Select") { selection.formUnion(CleanupRules.selectAll(items)) }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    private func sorted(_ items: [CleanupItem]) -> [CleanupItem] {
        switch sort {
        case .size: return items.sorted { $0.bytes > $1.bytes }
        case .age: return items.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        }
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { selection.contains(item.id) }, set: { on in if on { selection.insert(item.id) } else { selection.remove(item.id) } }))
                .labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.medium)
                    if item.isRecent { Text("active project").font(.caption2).padding(.horizontal, 5).background(.orange.opacity(0.2), in: Capsule()) }
                }
                if item.category.isCommand {
                    Text(item.commandLine).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let modified = item.modified {
                Text(modified, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.bytes > 0 ? CleanupFormat.bytes(item.bytes) : "—").monospacedDigit().frame(width: 80, alignment: .trailing)
            if let url = item.url {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Select all") { selection = CleanupRules.selectAll(visible) }.disabled(visible.isEmpty)
            Button("Select none") { selection = [] }.disabled(selection.isEmpty)
            Text(selected.isEmpty ? "Active projects (changed in the last 7 days) are skipped unless you tick them."
                 : "\(selected.count) selected · \(CleanupFormat.bytes(CleanupRules.total(selected)))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if CleanupRules.canDeletePermanently(selected) {
                Button("Delete permanently…") { confirm = Pending(items: selected, permanent: true) }
            }
            Button("Clean up…") { confirm = Pending(items: selected, permanent: false) }
                .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
        }
    }

    private func run(_ items: [CleanupItem], permanent: Bool) {
        Task {
            let outcome = await cleanup.clean(items, permanent: permanent)
            selection.subtract(items.map(\.id))
            var text = "Freed about \(CleanupFormat.bytes(outcome.freed)) (\(outcome.done.count) item\(outcome.done.count == 1 ? "" : "s"))."
            if !outcome.refused.isEmpty { text += " Refused \(outcome.refused.count): outside the scanned folders or a link." }
            if !outcome.failed.isEmpty { text += " Failed: " + outcome.failed.joined(separator: "; ") }
            message = text
        }
    }
}

/// Scanned folders and optional categories.
struct CleanupSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var roots = DevCleanup.shared.roots
    @AppStorage(DevCleanup.swiftKey) private var swiftBuild = false
    @AppStorage(DevCleanup.venvKey) private var venvs = false
    @AppStorage(DevCleanup.monthlyKey) private var monthly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup settings").font(.headline)
            Text("Folders scanned for node_modules (and optional .build / venvs)").font(.callout)
            List {
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Text(root.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Spacer()
                        Button { roots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }.frame(height: 140)
            Button("Add folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url, !roots.contains(url.path) { roots.append(url.path) }
            }
            Toggle("Include Swift .build folders", isOn: $swiftBuild)
            Toggle("Include Python virtualenvs", isOn: $venvs)
            Toggle("Monthly reminder when developer files use over 5 GB", isOn: $monthly)
            HStack {
                Spacer()
                Button("Done") { DevCleanup.shared.roots = roots; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Dashboard: "12.4 GB reclaimable", with a link to Developer → Cleanup.
struct CleanupDashboardCard: View {
    private let cleanup = DevCleanup.shared

    var body: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: "externaldrive.badge.minus", color: .teal, size: 20)
            Text("Developer files").font(.headline)
            if cleanup.scanning {
                ProgressView().controlSize(.small)
            } else if cleanup.lastKnownTotal > 0 {
                Text("\(CleanupFormat.bytes(cleanup.lastKnownTotal)) reclaimable").font(.callout).fontWeight(.semibold)
            } else {
                Text("Not scanned yet").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") {
                DeveloperView.openCleanupNext = true
                AppState.shared.selectedSection = .developer
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .card(padding: DS.Space.s)
    }
}
