import SwiftData
import SwiftUI

/// Agent tab: ask, watch each tool call in a timeline, approve exactly what runs, stop or retry.
struct AgentView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \AgentTask.createdAt, order: .reverse) private var tasks: [AgentTask]
    @State private var selectedID: UUID?
    @State private var prompt = ""
    /// Bumped to re-read settings after a one-click provider change.
    @State private var providerRefresh = 0
    private let engine = AgentEngine.shared

    private var selected: AgentTask? {
        if let selectedID { return tasks.first { $0.uid == selectedID } }
        return nil
    }

    @Bindable private var tabState = AgentTabState.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tabState.tab) {
                Text("Tasks").tag("Tasks")
                Text("Jobs").tag("Jobs")
                Text("Reminders").tag("Reminders")
                Text("Loops").tag("Loops")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 400)
            .padding(.vertical, 8)
            switch tabState.tab {
            case "Jobs": JobsView()
            case "Reminders": SmartRemindersView()
            case "Loops": OpenLoopsView()
            default: tasksBody
            }
        }
        .navigationTitle("Agent")
        .onChange(of: tabState.focusTaskID) { _, id in if let id { selectedID = id; tabState.focusTaskID = nil } }
        .onAppear { if let id = tabState.focusTaskID { selectedID = id; tabState.focusTaskID = nil } }
    }

    private var tasksBody: some View {
        HSplitView {
            taskList.frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            VStack(spacing: 0) {
                statusBanner
                if let task = selected {
                    AgentTaskDetail(task: task)
                } else {
                    intro
                }
                Divider()
                composer
            }
            .frame(minWidth: 520)
        }
        .onAppear(perform: takePending)
        .onChange(of: appState.pendingAction) { _, _ in takePending() }
        .onChange(of: engine.activeTaskID) { _, id in if let id { selectedID = id } }
    }

    private var taskList: some View {
        List(selection: $selectedID) {
            Section("Tasks") {
                if tasks.isEmpty { Text("No tasks yet.").foregroundStyle(.secondary) }
                ForEach(tasks) { task in
                    HStack(spacing: 8) {
                        AgentStateIcon(state: task.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title.isEmpty ? "Task" : task.title).lineLimit(2)
                            Text("\(task.state.label) · \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(task.uid)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            Button { selectedID = nil } label: { Label("New task", systemImage: "plus") }
                .buttonStyle(.borderless)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        let _ = providerRefresh
        let settings = AgentSettings.load()
        if engine.isHalted {
            banner("Kill switch is on: no model or tool calls will run.", systemImage: "hand.raised.fill", color: .red) {
                Button("Resume agent") { engine.resume() }
            }
        } else if settings.workspaceRoots.isEmpty {
            banner("Add a workspace folder so the agent can work with files.", systemImage: "folder.badge.plus", color: .orange) {
                Button("Settings…") { appState.selectedSection = .settings }
            }
        } else if let alternative = settings.providerOffer {
            banner(ProviderResolver.offerText(chosen: settings.provider, alternative: alternative), systemImage: "exclamationmark.triangle.fill", color: .orange) {
                Button("Use \(alternative.displayName)") {
                    var updated = settings
                    updated.provider = alternative
                    updated.model = Prefs.model(for: alternative)
                    updated.providerExplicit = true
                    updated.providerOffer = nil
                    updated.save()
                    providerRefresh += 1
                }
            }
        } else if !settings.provider.hasCredentials && settings.provider != .ollama {
            banner("\(settings.provider.displayName) isn't set up yet. Add credentials in Settings → Providers.", systemImage: "key.fill", color: .orange) {
                Button("Settings…") { appState.selectedSection = .settings }
            }
        } else if settings.localOnly && settings.provider.isExternal {
            banner("Local-only mode is on, so \(settings.provider.shortName) is blocked. Pick Ollama in Settings → Agent.", systemImage: "lock.fill", color: .orange) {
                Button("Settings…") { appState.selectedSection = .settings }
            }
        }
    }

    private func banner<Trailing: View>(_ text: String, systemImage: String, color: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Label(text, systemImage: systemImage).foregroundStyle(color)
            Spacer()
            trailing()
        }
        .font(.callout)
        .padding(10)
        .background(color.opacity(0.1))
    }

    private var intro: some View {
        let settings = AgentSettings.load()
        return VStack(spacing: DS.Space.m) {
            Image(systemName: "cpu").font(.system(size: 40)).foregroundStyle(.mint)
            Text("Ask the agent").font(.title2.bold())
            Text("It can read, search and edit files in your workspace folders, run allowlisted commands and check system status. Every write and command is shown to you first; deletes always need your approval for the exact path.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
            VStack(alignment: .leading, spacing: 4) {
                Label("\(settings.provider.displayName) · \(settings.model)", systemImage: "sparkles")
                Label(settings.workspaceRoots.isEmpty ? "No workspace yet" : settings.workspaceRoots.joined(separator: ", "), systemImage: "folder")
                Label(String(format: "Caps: %d steps · $%.2f per task · $%.2f per day", settings.maxSteps, settings.perTaskCostCap, settings.dailyCostCap), systemImage: "gauge")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        HStack(spacing: DS.Space.s) {
            TextField("Ask the agent… e.g. “Find TODOs in my project and list them in TODO.md”", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(send)
            Button(action: send) { Label(engine.isBusy ? "Queue" : "Run", systemImage: "paperplane.fill") }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.isHalted)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(DS.Space.s)
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !engine.isHalted else { return }
        let task = engine.submit(text)
        selectedID = task.uid
        prompt = ""
    }

    private func takePending() {
        guard case .askAgent(let text)? = appState.pendingAction else { return }
        appState.pendingAction = nil
        if text.isEmpty { selectedID = nil } else { prompt = text; send() }
    }
}

struct AgentStateIcon: View {
    let state: AgentTaskState

    var body: some View {
        Group {
            switch state {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
            case .running: ProgressView().controlSize(.small)
            case .awaitingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 18)
    }
}

private struct AgentTaskDetail: View {
    let task: AgentTask
    @Query private var actions: [AgentToolAction]
    @Query private var events: [AgentEvent]
    @Query private var approvals: [AgentApproval]
    private let engine = AgentEngine.shared

    init(task: AgentTask) {
        self.task = task
        let id = task.uid
        _actions = Query(filter: #Predicate<AgentToolAction> { $0.taskID == id }, sort: \.createdAt)
        _events = Query(filter: #Predicate<AgentEvent> { $0.taskID == id }, sort: \.date)
        _approvals = Query(filter: #Predicate<AgentApproval> { $0.taskID == id && $0.decisionRaw == "pending" })
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(DS.Space.m)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        bubble(task.prompt, user: true)
                        ForEach(timeline, id: \.id) { item in
                            switch item {
                            case .action(let action): AgentActionCard(action: action)
                            case .event(let event): eventRow(event)
                            }
                        }
                        if !task.finalAnswer.isEmpty { bubble(task.finalAnswer, user: false) }
                        if let error = task.errorMessage, task.state != .done {
                            Label(error, systemImage: task.state == .failed ? "exclamationmark.triangle.fill" : "stop.circle")
                                .foregroundStyle(task.state == .failed ? .red : .secondary)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(DS.Space.m)
                }
                .onChange(of: actions.count + events.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
            }
            if let approval = approvals.first, let action = actions.first(where: { $0.uid == approval.actionID }) {
                AgentApprovalDrawer(approval: approval, action: action)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    AgentStateIcon(state: task.state)
                    Text(task.state.label).font(.headline)
                }
                if !task.pausedReason.isEmpty {
                    Label(task.pausedReason, systemImage: "lock.fill").font(.caption).foregroundStyle(.orange)
                }
                Text("\(task.provider.shortName) · \(task.model) · \(task.steps) step\(task.steps == 1 ? "" : "s") · \(task.inputTokens + task.outputTokens) tokens · " + String(format: "≈$%.3f", task.costUSD))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if task.state.isActive || task.state == .queued {
                Button(role: .destructive) { engine.stop(task.uid) } label: { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red)
            }
            if task.state.isFinished {
                Button { engine.retry(task) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .disabled(engine.isHalted)
                    .help("Starts the request again from scratch; nothing from this run is replayed.")
            }
        }
    }

    private enum Item {
        case action(AgentToolAction)
        case event(AgentEvent)
        var id: UUID { switch self { case .action(let a): return a.uid; case .event(let e): return e.uid } }
        var date: Date { switch self { case .action(let a): return a.createdAt; case .event(let e): return e.date } }
    }

    /// Tool calls as cards; model text, policy and errors as lines (cost and routine tool lines are folded into the cards).
    private var timeline: [Item] {
        let shown = events.filter { [.model, .policy, .error].contains($0.kind) }
        return (actions.map(Item.action) + shown.map(Item.event)).sorted { $0.date < $1.date }
    }

    private func eventRow(_ event: AgentEvent) -> some View {
        Group {
            if event.kind == .model {
                bubble(event.message, user: false)
            } else {
                Label(event.message, systemImage: event.kind == .error ? "exclamationmark.triangle" : "shield.lefthalf.filled")
                    .font(.caption).foregroundStyle(event.kind == .error ? .red : .orange)
            }
        }
    }

    private func bubble(_ text: String, user: Bool) -> some View {
        HStack {
            if user { Spacer(minLength: 60) }
            Text(LocalizedStringKey(text))
                .textSelection(.enabled)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(user ? Color.mint.opacity(0.18) : DS.subtleFill))
            if !user { Spacer(minLength: 60) }
        }
    }
}

private struct AgentActionCard: View {
    let action: AgentToolAction
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 18)
                Text(action.tool).font(.caption.monospaced().weight(.semibold))
                AgentRiskBadge(risk: action.risk)
                Text(action.summary.isEmpty ? action.argumentsJSON : action.summary).font(.callout).lineLimit(2)
                Spacer()
                Text(action.state.label).font(.caption).foregroundStyle(color)
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? "Hide details" : "Show details")
            }
            if expanded {
                if !action.preview.isEmpty && action.preview != action.summary {
                    Text(action.preview).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6).background(DS.subtleFill, in: RoundedRectangle(cornerRadius: 6))
                }
                if !action.output.isEmpty {
                    Text(action.output).font(.caption.monospaced()).textSelection(.enabled).lineLimit(40)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6).background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.hairline))
    }

    private var icon: String {
        switch action.state {
        case .succeeded: return "checkmark.circle.fill"
        case .running: return "gearshape.2.fill"
        case .proposed: return "hand.raised"
        case .blocked: return "nosign"
        case .denied, .expired, .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .needsReview: return "questionmark.diamond.fill"
        }
    }

    private var color: Color {
        switch action.state {
        case .succeeded: return .green
        case .running, .proposed: return .orange
        case .blocked, .failed: return .red
        case .needsReview: return .purple
        default: return .secondary
        }
    }
}

struct AgentRiskBadge: View {
    let risk: AgentRisk

    var body: some View {
        Text(risk.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var color: Color { risk == .low ? .green : risk == .medium ? .orange : .red }
}

/// Shows exactly what will run (command, path, diff) and asks once for this one action.
private struct AgentApprovalDrawer: View {
    let approval: AgentApproval
    let action: AgentToolAction
    private let engine = AgentEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Approve this action?").font(.headline)
                AgentRiskBadge(risk: action.risk)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(approval.expiresAt.timeIntervalSince(context.date)))
                    Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(action.summary).font(.callout)
            ScrollView {
                Text(action.preview.isEmpty ? action.argumentsJSON : action.preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(8)
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(action.risk == .high
                     ? "High-risk actions are approved one at a time, for this exact path only."
                     : "Approves only this exact action, once, for this task.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Deny", role: .destructive) { engine.decide(approvalID: approval.uid, approve: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Approve once") { engine.decide(approvalID: approval.uid, approve: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(action.risk == .high ? .red : .orange)
            }
        }
        .padding(DS.Space.m)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Settings

struct AgentSettingsView: View {
    @State private var settings = AgentSettings.load()
    @State private var testing = false
    @State private var testResult: String?
    @State private var allowlistText = ""
    @State private var models: [String] = []

    /// One tiny request through the same adapter the agent uses (Bedrock included).
    private func testConnection() {
        testing = true
        testResult = nil
        let adapter = AgentAdapters.make(provider: settings.provider, model: settings.model)
        Task {
            do {
                _ = try await adapter.generate(system: "Reply with OK.", messages: [.user("ping")], tools: [])
                testResult = "✓ \(settings.provider.displayName) · \(settings.model) works"
            } catch {
                testResult = AIError.describe(error)
            }
            testing = false
        }
    }

    var body: some View {
        Form {
            Section("Model") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(AIProviderID.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: settings.provider) { _, provider in
                    settings.model = Prefs.model(for: provider)
                    settings.providerExplicit = true
                    settings.providerOffer = nil
                    testResult = nil
                }
                if let alternative = settings.providerOffer {
                    HStack {
                        Label(ProviderResolver.offerText(chosen: settings.provider, alternative: alternative), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Use \(alternative.displayName)") { settings.provider = alternative }
                    }
                    .font(.callout)
                } else if !settings.provider.hasCredentials && settings.provider != .ollama {
                    Label("\(settings.provider.displayName) has no credentials yet. Add them in Settings → Providers.", systemImage: "key")
                        .font(.callout).foregroundStyle(.orange)
                }
                TextField("Model", text: $settings.model)
                HStack {
                    Button(testing ? "Testing…" : "Test connection") { testConnection() }.disabled(testing)
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("✓") ? .green : .orange).lineLimit(2) }
                }
                Toggle("Local-only mode (block cloud providers)", isOn: $settings.localOnly)
                if settings.localOnly && settings.provider.isExternal {
                    Label("\(settings.provider.shortName) is a cloud provider and will be blocked. Choose Ollama.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(settings.providerExplicit
                     ? "The agent uses exactly this provider and model. If it fails, the task fails — MacPilot never switches to another provider on its own."
                     : "Picked automatically from the providers you've set up (your default first, then Bedrock, Anthropic, OpenAI, Ollama). Choose one to pin it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Workspaces") {
                ForEach(settings.workspaceRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { settings.workspaceRoots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add folder…", action: addFolder)
                Text("The agent can only read, write and run commands inside these folders. Paths are resolved (including links) and anything outside is refused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Approvals") {
                Toggle("Ask before writes and commands (medium risk)", isOn: $settings.approveMedium)
                Text("Reads never ask. Deletes always ask, for the exact path. Approvals work once, for one task, and expire after 10 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Commands") {
                TextField("Allowed programs (comma separated)", text: $allowlistText, axis: .vertical)
                    .lineLimit(2...4)
                Stepper("Timeout: \(Int(settings.commandTimeout)) s", value: $settings.commandTimeout, in: 5...600, step: 5)
                Text("No shell: one program with plain arguments. sudo, rm, shells, curl/ssh and similar are never allowed. Commands get a clean environment without your API keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ComputerUseSection(settings: $settings)
            WebSearchKeysSection()
            TelegramSettingsSection()
            Section("Limits") {
                Stepper("Max steps: \(settings.maxSteps)", value: $settings.maxSteps, in: 1...200)
                Stepper("Max time: \(Int(settings.maxSeconds / 60)) min", value: $settings.maxSeconds, in: 60...7_200, step: 60)
                Stepper("Max tokens per task: \(settings.maxTokensPerTask / 1_000)K", value: $settings.maxTokensPerTask, in: 10_000...5_000_000, step: 50_000)
                HStack {
                    Text("Cost cap per task ($)")
                    Spacer()
                    TextField("", value: $settings.perTaskCostCap, format: .number.precision(.fractionLength(2))).frame(width: 80)
                }
                HStack {
                    Text("Cost cap per day ($)")
                    Spacer()
                    TextField("", value: $settings.dailyCostCap, format: .number.precision(.fractionLength(2))).frame(width: 80)
                }
                Text(String(format: "Spent today: ≈$%.3f (estimated from token counts).", AgentEngine.shared.costToday()))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { allowlistText = settings.commandAllowlist.joined(separator: ", ") }
        .onChange(of: settings) { _, value in value.save() }
        .onChange(of: allowlistText) { _, text in
            settings.commandAllowlist = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Workspace"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.workspaceRoots.contains(url.path) {
            settings.workspaceRoots.append(url.path)
        }
    }
}

/// Settings → Agent → Telegram: token (Keychain only), test, pairing and paired users.
private struct TelegramSettingsSection: View {
    private let bot = TelegramBot.shared
    @State private var token = ""
    @State private var hasToken = TelegramBot.hasToken
    @State private var message: String?
    @State private var code: String?
    @State private var codeExpires: Date?
    @State private var enabled = TelegramBot.shared.isEnabled

    var body: some View {
        Section {
            HStack {
                Circle().fill(bot.status.isOnline ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text("Bot: \(bot.status.label)" + (bot.botUsername.isEmpty ? "" : " · @\(bot.botUsername)")).lineLimit(2)
            }
            if hasToken {
                HStack {
                    Label("Token saved in the Keychain", systemImage: "key.fill")
                    Spacer()
                    Button("Test") { Task { message = await bot.test() } }
                    Button("Remove", role: .destructive) {
                        bot.isEnabled = false
                        enabled = false
                        TelegramBot.deleteToken()
                        hasToken = false
                    }
                }
            } else {
                HStack {
                    SecureField("Bot token from @BotFather", text: $token)
                    Button("Save") {
                        do {
                            try TelegramBot.saveToken(token)
                            token = ""
                            hasToken = true
                            Task { message = await bot.test() }
                        } catch { message = error.localizedDescription }
                    }
                    .disabled(token.isEmpty)
                }
            }
            Toggle("Connect the bot (long polling, no open ports)", isOn: $enabled)
                .disabled(!hasToken)
                .onChange(of: enabled) { _, on in bot.isEnabled = on }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }

            HStack {
                Button(code == nil ? "Pair a phone…" : "New code") {
                    code = bot.newPairingCode()
                    codeExpires = Date().addingTimeInterval(TelegramPairing.codeLifetime)
                }
                .disabled(!hasToken)
                if let code, let codeExpires {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = Int(codeExpires.timeIntervalSince(context.date))
                        if left > 0 {
                            Text("Send /pair \(code) to the bot · \(left / 60):\(String(format: "%02d", left % 60))")
                                .font(.body.monospaced()).textSelection(.enabled)
                        } else {
                            Text("Code expired").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(bot.pairing.users) { user in
                HStack {
                    Image(systemName: "person.crop.circle")
                    Text("\(user.name.isEmpty ? "Telegram user" : user.name) · ID \(String(user.userID))")
                    Text("paired \(user.pairedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { bot.removeUser(user.userID) }
                }
            }
        } header: {
            Text("Telegram")
        } footer: {
            Text("Create a bot with @BotFather, paste its token here, then pair your phone with a one-time code. Only paired users (by numeric Telegram ID, in a private chat) can start tasks, approve actions or ask for screenshots. Telegram is cloud messaging, not end-to-end encrypted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Optional search API keys (Keychain). Without one, web_search uses DuckDuckGo's HTML results.
private struct WebSearchKeysSection: View {
    @State private var brave = ""
    @State private var serp = ""
    @State private var hasBrave = KeychainStore.exists(account: WebClient.braveKeyAccount)
    @State private var hasSerp = KeychainStore.exists(account: WebClient.serpKeyAccount)

    var body: some View {
        Section {
            keyRow("Brave Search API key", text: $brave, saved: $hasBrave, account: WebClient.braveKeyAccount)
            keyRow("SerpAPI key", text: $serp, saved: $hasSerp, account: WebClient.serpKeyAccount)
        } header: {
            Text("Web search")
        } footer: {
            Text("Used by web_search (Brave first, then SerpAPI). With neither, MacPilot uses DuckDuckGo's HTML results. Pages are fetched as “MacPilot”, honoring robots.txt, at most one request every 2 seconds per site, without cookies or logins.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func keyRow(_ label: String, text: Binding<String>, saved: Binding<Bool>, account: String) -> some View {
        HStack {
            if saved.wrappedValue {
                Label("\(label) saved", systemImage: "key.fill")
                Spacer()
                Button("Remove", role: .destructive) { try? KeychainStore.delete(account: account); saved.wrappedValue = false }
            } else {
                SecureField(label, text: text)
                Button("Save") {
                    try? KeychainStore.save(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
                    text.wrappedValue = ""
                    saved.wrappedValue = true
                }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Settings → Agent → Computer use: permissions checklist, browser and app allowlists, start at login.
private struct ComputerUseSection: View {
    @Binding var settings: AgentSettings
    @State private var domains = ""
    @State private var refresh = 0
    @State private var loginEnabled = LoginItemState.shared.enabled

    var body: some View {
        let _ = refresh
        Section {
            permissionRow("Accessibility", granted: ComputerPermissions.accessibility,
                          detail: "Lets the agent read and press buttons in apps you allow.",
                          request: ComputerPermissions.requestAccessibility, settingsURL: ComputerPermissions.accessibilitySettings)
            permissionRow("Screen & System Audio Recording", granted: ComputerPermissions.screenRecording,
                          detail: "Lets the agent take screenshots (MacPilot's own windows are hidden).",
                          request: ComputerPermissions.requestScreenRecording, settingsURL: ComputerPermissions.screenRecordingSettings)
            HStack {
                Image(systemName: "envelope").frame(width: 18)
                VStack(alignment: .leading) {
                    Text("Automation → Mail")
                    Text("macOS asks the first time a job sends with Mail.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings") { NSWorkspace.shared.open(ComputerPermissions.automationSettings) }
            }
            Button("Check again") { refresh += 1 }
            Toggle("Start MacPilot at login (the agent queue and Telegram bot start with it)", isOn: $loginEnabled)
                .onChange(of: loginEnabled) { _, on in LaunchAtLogin.set(on) }
        } header: {
            Text("Computer use — permissions")
        }
        Section {
            TextField("Allowed sites, comma separated (e.g. github.com, example.com)", text: $domains, axis: .vertical)
                .lineLimit(1...3)
                .onChange(of: domains) { _, text in
                    settings.browserAllowlist = text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                }
            Text("The agent's browser is separate from Safari and Chrome (no saved logins or cookies, nothing kept after quitting). Other sites, form submits and password or payment fields always ask first. It never fills in passwords.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(settings.guiAllowlist, id: \.self) { bundleID in
                HStack {
                    Image(systemName: "app")
                    Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { $0.deletingPathExtension().lastPathComponent } ?? bundleID)
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { settings.guiAllowlist.removeAll { $0 == bundleID } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Menu("Allow an app…") {
                ForEach(AXGUIDriver.shared.apps().filter { !GUIPolicy.isForbidden($0) && !settings.guiAllowlist.contains($0.bundleID) && !$0.bundleID.isEmpty }, id: \.bundleID) { app in
                    Button(app.name) { settings.guiAllowlist.append(app.bundleID) }
                }
            }
            .fixedSize()
            Text("Actions in other apps ask first. System Settings, Keychain Access, password managers and the login window are never controlled. GUI and browser steps pause while the screen is locked and continue when you unlock.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Computer use — sites and apps")
        }
        .onAppear { domains = settings.browserAllowlist.joined(separator: ", ") }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, request: @escaping () -> Void, settingsURL: URL) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(granted ? .green : .orange).frame(width: 18)
            VStack(alignment: .leading) {
                Text(title)
                Text(granted ? "Allowed" : detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Request") { request(); refresh += 1 }
                Button("Open Settings") { NSWorkspace.shared.open(settingsURL) }
            }
        }
    }
}
