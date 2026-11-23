import AppKit
import SwiftUI

/// Agent → Loops: open loops found in memory, with Done, Snooze, Dismiss and Remind me; plus memory search.
struct OpenLoopsView: View {
    private let loops = OpenLoops.shared
    @State private var query = ""
    @State private var results: [MemorySnippet] = []
    @State private var showingSnippet: MemorySnippet?
    @State private var processing = false

    var body: some View {
        let _ = loops.revision
        VStack(spacing: 0) {
            header.padding(DS.Space.m)
            Divider()
            if !MemorySettings.load().enabled && loops.store.count == 0 {
                EmptyStateView(systemImage: "brain", title: "Memory is off",
                               message: "Turn it on in Settings → Memory and choose which apps MacPilot may remember. It reads visible text locally, finds what you promised or were asked, and keeps everything on this Mac.",
                               actionTitle: "Open Settings", action: { AppState.shared.selectedSection = .settings })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !results.isEmpty {
                        Section("Memory search") {
                            ForEach(results) { snippet in
                                Button { showingSnippet = snippet } label: { snippetRow(snippet) }.buttonStyle(.plain)
                            }
                        }
                    }
                    let current = loops.current()
                    let probable = current.filter { $0.status == .probablyDone }
                    if !probable.isEmpty {
                        Section("Probably done — confirm") { ForEach(probable) { loopRow($0) } }
                    }
                    Section("Open loops") {
                        let open = current.filter { $0.status != .probablyDone }
                        if open.isEmpty { Text("Nothing open.").foregroundStyle(.secondary) }
                        ForEach(open) { loopRow($0) }
                    }
                }
            }
        }
        .popover(item: $showingSnippet) { snippet in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(snippet.app) · \(snippet.window)").font(.headline)
                    Text(snippet.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Text(snippet.text).font(.callout).textSelection(.enabled)
                }
                .padding()
            }
            .frame(width: 460, height: 360)
        }
    }

    private var header: some View {
        HStack {
            TextField("Search memory…", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { results = query.isEmpty ? [] : loops.store.semanticSearch(query, limit: 20) }
            Button {
                processing = true
                Task { _ = await loops.process(); processing = false }
            } label: { if processing { ProgressView().controlSize(.small) } else { Label("Find loops now", systemImage: "sparkles") } }
            .disabled(processing)
            Text(loops.lastMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func snippetRow(_ snippet: MemorySnippet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(snippet.app) · \(snippet.window.prefix(60))").font(.caption.weight(.semibold))
            Text(snippet.text.prefix(200)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func loopRow(_ loop: OpenLoop) -> some View {
        HStack(alignment: .top) {
            Image(systemName: loop.status == .probablyDone ? "checkmark.circle.badge.questionmark" : loop.status == .snoozed ? "moon.zzz" : "circle")
                .foregroundStyle(loop.status == .probablyDone ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(loop.what)
                HStack(spacing: 6) {
                    if !loop.who.isEmpty { Text(loop.who) }
                    if let due = loop.due { Text("due \(due.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(due < Date() ? .red : .secondary) }
                    Text(appName(loop.app))
                    Text(String(format: "%.0f%%", loop.confidence * 100))
                    if loop.status == .probablyDone, !loop.closeEvidence.isEmpty { Text("· \(loop.closeEvidence)").lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let snippet = loops.store.snippet(loop.snippetID) {
                Button { showingSnippet = snippet } label: { Image(systemName: "text.quote") }.buttonStyle(.borderless).help("Show the source snippet")
            }
            Button(loop.status == .probablyDone ? "Confirm done" : "Done") { loops.set(loop.id, status: .done) }
            Menu {
                Button("Snooze 1 day") { loops.snooze(loop.id, days: 1) }
                Button("Snooze 1 week") { loops.snooze(loop.id, days: 7) }
                Button("Remind me") { loops.remind(loop.id) }
                if loop.status == .probablyDone { Button("Not done yet") { loops.set(loop.id, status: .open) } }
                Divider()
                Button("Dismiss", role: .destructive) { loops.set(loop.id, status: .dismissed) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func appName(_ bundleID: String) -> String {
        MemorySettings.suggestions.first { $0.bundleID == bundleID }?.name
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? bundleID
    }
}

/// Settings → Memory.
struct MemorySettingsView: View {
    @State private var settings = MemorySettings.load()
    @State private var confirmDelete = false
    @State private var forgetting: String?
    @State private var token = ""
    @State private var revealToken = false
    @State private var copied: String?
    private let server = MemoryMCPServer.shared
    private let store = MemoryStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Remember text from apps I choose", isOn: $settings.enabled)
                Toggle("Pause capture", isOn: $settings.paused).disabled(!settings.enabled)
                Text("""
                Off by default. When on, MacPilot reads the visible text of the focused window — only in the apps below — using macOS Accessibility (not screenshots), \
                at most every 30 seconds per window and only when it changed. Password fields, password managers, private browsing windows and the apps the agent may never touch are skipped. \
                Secrets are removed before anything is stored. Everything stays in a database on this Mac.
                """).font(.caption).foregroundStyle(.secondary)
                if !ComputerPermissions.accessibility {
                    HStack {
                        Label("Needs \(ComputerPermissions.accessibilityPaneName()) permission", systemImage: "exclamationmark.circle").help(ComputerPermissions.accessibilityHelp).foregroundStyle(.orange)
                        Button("Request") { ComputerPermissions.requestAccessibility() }
                    }
                }
            } header: { Text("Memory") }

            Section("Apps MacPilot may remember") {
                ForEach(Array(Set(MemorySettings.suggestions.map(\.bundleID) + settings.allowlist)).sorted(), id: \.self) { bundleID in
                    let name = MemorySettings.suggestions.first { $0.bundleID == bundleID }?.name ?? bundleID
                    HStack {
                        Toggle(name, isOn: Binding(get: { settings.allowlist.contains(bundleID) },
                                                   set: { on in if on { settings.allowlist.append(bundleID) } else { settings.allowlist.removeAll { $0 == bundleID } } }))
                        Spacer()
                        Button("Forget…") { forgetting = bundleID }.buttonStyle(.borderless).font(.caption)
                    }
                }
                Menu("Add a running app…") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app -> (String, String)? in
                        guard let id = app.bundleIdentifier, !GUIPolicy.isForbidden(GUIApp(name: app.localizedName ?? "", bundleID: id, pid: 0)) else { return nil }
                        return (app.localizedName ?? id, id)
                    }, id: \.1) { item in
                        Button(item.0) { if !settings.allowlist.contains(item.1) { settings.allowlist.append(item.1) } }
                    }
                }
                .fixedSize()
            }

            Section("Keep") {
                Picker("Keep snippets for", selection: $settings.retentionDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("\(store.count) snippet\(store.count == 1 ? "" : "s") stored in \(store.url.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Delete everything…", role: .destructive) { confirmDelete = true }
            }

            Section("Open loops") {
                Toggle("Add a smart reminder for loops with a due date", isOn: $settings.feedReminders)
                Toggle("Close loops automatically when it's very clear they're done", isOn: $settings.autoClose)
                if settings.autoClose {
                    Slider(value: $settings.autoCloseThreshold, in: 0.7...0.99) { Text(String(format: "Confidence ≥ %.0f%%", settings.autoCloseThreshold * 100)) }
                }
                Text("New snippets are read in batches by Ollama when it's set up (always, in local-only mode) or otherwise by a small cloud model under your agent cost caps. Only the snippets themselves are sent. Below the threshold a loop is marked “probably done” for you to confirm.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Local MCP server (127.0.0.1 only)", isOn: Binding(get: { server.isEnabled }, set: { server.isEnabled = $0 }))
                if server.isEnabled {
                    Text(server.isRunning ? "Listening on http://127.0.0.1:\(server.boundPort ?? server.port)/mcp" : (server.lastError ?? "Starting…"))
                        .font(.caption).foregroundStyle(server.isRunning ? .green : .orange)
                    HStack {
                        Text(revealToken ? token : String(repeating: "•", count: 24)).font(.caption.monospaced()).textSelection(.enabled)
                        Button(revealToken ? "Hide" : "Show") { token = MemoryMCPServer.token(); revealToken.toggle() }
                        Button("Rotate token") {
                            token = MemoryMCPServer.rotateToken()
                            server.start()
                        }
                    }
                    configBox("Claude Desktop and other clients (stdio)", MemoryMCPServer.stdioConfig(executable: Bundle.main.executablePath ?? "/Applications/MacPilot.app/Contents/MacOS/MacPilot"))
                    configBox("Clients that use HTTP", MemoryMCPServer.httpConfig(port: server.port, token: MemoryMCPServer.token()))
                    configBox("Claude Code", MemoryMCPServer.claudeCodeCommand(port: server.port, token: MemoryMCPServer.token()))
                }
                Text("Offers search_memory, get_open_loops and mark_loop_done to MCP clients you connect. Off by default; HTTP needs the bearer token; every query is written to the audit log. Whatever a client does with results is up to that client.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Memory MCP server") }
        }
        .formStyle(.grouped)
        .onChange(of: settings) { old, new in
            new.save()
            if new.retentionDays < old.retentionDays { store.purge(olderThan: new.retentionDays) }
        }
        .confirmationDialog("Delete all memory?", isPresented: $confirmDelete) {
            Button("Delete all snippets and open loops", role: .destructive) { store.deleteEverything() }
        } message: { Text("This can't be undone.") }
        .confirmationDialog("Forget everything from this app?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget app", role: .destructive) {
                if let id = forgetting { store.forget(bundleID: id); settings.allowlist.removeAll { $0 == id } }
                forgetting = nil
            }
        } message: { Text("Deletes its snippets and loops, and stops remembering it.") }
    }

    private func configBox(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Button(copied == title ? "Copied" : "Copy") { PasteService.write(text: text); copied = title }.buttonStyle(.borderless).font(.caption)
            }
            Text(revealToken ? text : text.replacingOccurrences(of: MemoryMCPServer.token(), with: "•••"))
                .font(.caption2.monospaced()).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
