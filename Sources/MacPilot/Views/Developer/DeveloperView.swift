import AppKit
import SwiftUI

private enum DevTab: String, CaseIterable, Identifiable {
    case repos = "Repositories", ai = "AI Tools", terminal = "Terminal", api = "API", json = "JSON"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .repos: return "arrow.triangle.branch"
        case .ai: return "sparkles"
        case .terminal: return "terminal"
        case .api: return "network"
        case .json: return "curlybraces"
        }
    }
}

struct DeveloperView: View {
    @State private var tab: DevTab = .repos
    @State private var repos = DeveloperStore.repositories
    @State private var selectedRepo: String? = DeveloperStore.repositories.first

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Tool", selection: $tab) {
                    ForEach(DevTab.allCases) { Label($0.rawValue, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 560)
                Spacer()
                if tab == .repos || tab == .terminal || tab == .ai {
                    Picker("Repository", selection: $selectedRepo) {
                        Text("No repository").tag(String?.none)
                        ForEach(repos, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag(String?.some($0)) }
                    }
                    .frame(width: 220)
                    Button { addRepository() } label: { Image(systemName: "plus") }
                        .help("Add a repository folder")
                }
            }
            .padding(12)
            Divider()
            Group {
                switch tab {
                case .repos: RepositoryPane(repo: selectedRepo, onRemove: removeRepository, onAdd: addRepository)
                case .ai: DevAIPane(repo: selectedRepo)
                case .terminal: TerminalPane(repo: selectedRepo)
                case .api: APIRequestPane()
                case .json: JSONToolPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Developer Workspace")
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if !repos.contains(path) {
            repos.append(path)
            DeveloperStore.repositories = repos
        }
        selectedRepo = path
    }

    private func removeRepository(_ path: String) {
        repos.removeAll { $0 == path }
        DeveloperStore.repositories = repos
        if selectedRepo == path { selectedRepo = repos.first }
    }
}

// MARK: - Repositories

private struct RepositoryPane: View {
    let repo: String?
    var onRemove: (String) -> Void
    var onAdd: () -> Void

    @State private var status: GitStatus?
    @State private var commits: [GitCommit] = []
    @State private var branches: [String] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var commitMessage = ""
    @State private var isGenerating = false
    @State private var pending: PendingGitAction?
    @State private var resultText: String?

    struct PendingGitAction: Identifiable {
        let id = UUID()
        let title: String
        let command: String
        let run: () async -> ShellResult
    }

    var body: some View {
        if let repo {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(repo)
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                    if let resultText {
                        Text(resultText).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    }
                    HStack(alignment: .top, spacing: 16) {
                        changesCard(repo).frame(maxWidth: .infinity)
                        commitsCard.frame(maxWidth: .infinity)
                    }
                    commitCard(repo)
                }
                .padding(16)
            }
            .task(id: repo) { await reload(repo) }
            .sheet(item: $pending) { action in
                CommandConfirmSheet(title: action.title, command: action.command, directory: repo) {
                    pending = nil
                    Task {
                        let result = await action.run()
                        resultText = Redactor.redact(result.combined.isEmpty ? "Done." : result.combined)
                        await reload(repo)
                    }
                } onCancel: { pending = nil }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Add a git repository folder to see its status, branches and commits.").foregroundStyle(.secondary)
                Button("Add Repository…", action: onAdd).buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ repo: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: repo).lastPathComponent).font(.title2.bold())
                Text(repo).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let status {
                Label(status.branch, systemImage: "arrow.triangle.branch").font(.headline)
                if status.ahead > 0 { Label("\(status.ahead) ahead", systemImage: "arrow.up").font(.caption) }
                if status.behind > 0 { Label("\(status.behind) behind", systemImage: "arrow.down").font(.caption) }
                if let upstream = status.upstream { Text(upstream).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Menu("Branch") {
                ForEach(branches, id: \.self) { branch in
                    Button(branch) {
                        pending = PendingGitAction(title: "Switch branch", command: "git checkout \(branch)") {
                            await GitService.checkout(repo, branch: branch)
                        }
                    }
                    .disabled(branch == status?.branch)
                }
            }
            .fixedSize()
            Button { Task { await reload(repo) } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            Menu {
                Button("Open in VS Code") { open(repo, app: "Visual Studio Code") }
                Button("Open in Terminal") { open(repo, app: "Terminal") }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo)]) }
                Divider()
                Button("Remove from list", role: .destructive) { onRemove(repo) }
            } label: { Image(systemName: "ellipsis.circle") }
            .fixedSize()
        }
    }

    private func changesCard(_ repo: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Changes").font(.headline)
                Spacer()
                Button("Stage all") {
                    pending = PendingGitAction(title: "Stage all changes", command: "git add -A") { await GitService.stageAll(repo) }
                }
                .controlSize(.small)
                .disabled(status?.files.isEmpty ?? true)
            }
            if let files = status?.files, !files.isEmpty {
                ForEach(files.prefix(200)) { file in
                    HStack(spacing: 6) {
                        Text(badge(file)).font(.caption.monospaced().bold()).foregroundStyle(color(file)).frame(width: 18)
                        Text(file.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if file.isStaged { Text("staged").font(.caption2).foregroundStyle(.green) }
                    }
                }
                if files.count > 200 { Text("+\(files.count - 200) more").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(status == nil ? "…" : "Working tree clean.").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var commitsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent commits").font(.headline)
            ForEach(commits) { commit in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(commit.hash).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(commit.subject).lineLimit(1)
                    }
                    Text("\(commit.author) · \(commit.date)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if commits.isEmpty { Text("No commits yet.").foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func commitCard(_ repo: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commit").font(.headline)
                Spacer()
                Button {
                    generateMessage(repo)
                } label: {
                    if isGenerating { ProgressView().controlSize(.small) } else { Label("Write with AI", systemImage: "sparkles") }
                }
                .disabled(isGenerating || (status?.files.isEmpty ?? true))
            }
            TextEditor(text: $commitMessage)
                .font(.body.monospaced())
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Text(status?.files.contains(where: \.isStaged) == true ? "Commits the staged changes." : "Nothing staged yet: stage changes first.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Commit…") {
                    let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    pending = PendingGitAction(title: "Create commit", command: "git commit -m \"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"") {
                        let result = await GitService.commit(repo, message: message)
                        if result.ok { commitMessage = "" }
                        return result
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status?.files.contains(where: \.isStaged) != true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func badge(_ file: GitFileChange) -> String {
        switch file.kind {
        case .untracked: return "?"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .conflicted: return "U"
        case .typeChanged: return "T"
        case .modified: return "M"
        }
    }

    private func color(_ file: GitFileChange) -> Color {
        switch file.kind {
        case .added, .untracked: return .green
        case .deleted, .conflicted: return .red
        default: return .orange
        }
    }

    private func reload(_ repo: String) async {
        isLoading = true
        defer { isLoading = false }
        guard await GitService.isRepository(repo) else {
            error = "This folder is not a git repository."
            status = nil
            commits = []
            return
        }
        do {
            status = try await GitService.status(repo)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        commits = await GitService.log(repo)
        branches = await GitService.branches(repo)
    }

    private func generateMessage(_ repo: String) {
        isGenerating = true
        Task {
            defer { isGenerating = false }
            let (diff, staged) = await GitService.diffForCommit(repo)
            guard !diff.isEmpty else {
                error = "No changes to describe."
                return
            }
            do {
                commitMessage = try await AIRouter.complete(
                    provider: Prefs.analysisProvider,
                    system: "You write git commit messages: a subject line under 72 characters in the imperative mood, a blank line, then a short body explaining what and why. Reply with the message only, no code fences.",
                    prompt: (staged ? "" : "(These changes are not staged yet.)\n") + diff
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                error = nil
            } catch {
                self.error = AIError.describe(error)
            }
        }
    }

    private func open(_ path: String, app: String) {
        Task { _ = await Shell.run("/usr/bin/open", ["-a", app, path]) }
    }
}

// MARK: - Confirmation for every command

struct CommandConfirmSheet: View {
    let title: String
    let command: String
    let directory: String
    var onConfirm: () -> Void
    var onCancel: () -> Void
    @State private var understood = false

    private var risks: [String] { CommandSafety.risks(in: command) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                Text(command).font(.body.monospaced()).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                Text("In \(directory)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !risks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This command may be destructive", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.headline)
                    ForEach(risks, id: \.self) { Text("• It \($0).").font(.callout) }
                    Toggle("I understand what this command does", isOn: $understood)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Run", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(risks.isEmpty ? .accentColor : .red)
                    .disabled(!risks.isEmpty && !understood)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - AI tools

private enum DevAITool: String, CaseIterable, Identifiable {
    case explainError = "Explain error", review = "Code review", tests = "Generate tests", explainCode = "Explain code", prSummary = "PR summary"
    var id: String { rawValue }

    var system: String {
        switch self {
        case .explainError: return "You are a senior engineer. Explain the root cause of this error in plain language, then give the most likely fix with code. Be concise."
        case .review: return "You are a careful code reviewer. List concrete bugs, risks and improvements, most important first, with line references and suggested code. Skip praise."
        case .tests: return "Write focused unit tests for this code using the project's apparent language and test framework. Cover edge cases. Reply with code and one line per test explaining it."
        case .explainCode: return "Explain what this code does, step by step, for a developer new to it."
        case .prSummary: return "Write a pull request description in Markdown: a one-paragraph summary, a bullet list of changes, and a testing section. Base it only on the commits and diff provided."
        }
    }

    var placeholder: String {
        switch self {
        case .explainError: return "Paste an error message or stack trace…"
        case .review, .tests, .explainCode: return "Paste code, or use the staged diff of the selected repository…"
        case .prSummary: return "Uses the commits and diff of the selected repository since main."
        }
    }
}

private struct DevAIPane: View {
    let repo: String?
    @State private var tool: DevAITool = .explainError
    @State private var input = ""
    @State private var output = ""
    @State private var isRunning = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Tool", selection: $tool) {
                    ForEach(DevAITool.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if tool != .prSummary {
                    TextEditor(text: $input)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(alignment: .topLeading) {
                            if input.isEmpty { Text(tool.placeholder).foregroundStyle(.tertiary).padding(10).allowsHitTesting(false) }
                        }
                } else {
                    Text(tool.placeholder).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Button("Paste clipboard") { input = NSPasteboard.general.string(forType: .string) ?? input }
                        .disabled(tool == .prSummary)
                    if repo != nil && (tool == .review || tool == .tests || tool == .explainCode) {
                        Button("Use staged diff") {
                            Task { if let repo { input = await GitService.diffForCommit(repo).diff } }
                        }
                    }
                    Spacer()
                    if isRunning {
                        Button("Stop") { task?.cancel() }
                    }
                    Button("Run with \(Prefs.analysisProvider.shortName)") { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning || (tool == .prSummary ? repo == nil : input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Result").font(.headline)
                    Spacer()
                    Button("Copy") { PasteService.write(text: output) }.disabled(output.isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                ScrollView {
                    Text(output.isEmpty ? (isRunning ? "…" : "") : output)
                        .textSelection(.enabled)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    private func run() {
        isRunning = true
        output = ""
        error = nil
        let tool = tool
        let input = input
        let repo = repo
        task = Task {
            defer { isRunning = false }
            let prompt: String
            if tool == .prSummary, let repo {
                prompt = await GitService.branchSummary(repo)
            } else {
                prompt = String(input.prefix(150_000))
            }
            let provider = Prefs.analysisProvider
            do {
                for try await chunk in AIRouter.stream(provider: provider, model: Prefs.model(for: provider), system: tool.system,
                                                        turns: [ChatTurn(role: .user, content: prompt)]) {
                    switch chunk {
                    case .text(let piece): output += piece
                    case let .usage(input, out): UsageTracker.record(provider, input: input, output: out)
                    case .notice(let message): error = message
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = AIError.describe(error) }
            }
        }
    }
}

// MARK: - Terminal shortcuts

private struct TerminalPane: View {
    let repo: String?
    @State private var commands: [DeveloperStore.SavedCommand] = []
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var adHoc = ""
    @State private var runner = CommandRunner()
    @State private var pending: String?
    @State private var history = CommandHistory.entries

    private var directory: String { repo ?? NSHomeDirectory() }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Saved commands").font(.headline)
                Text(repo == nil ? "Runs in your home folder. Pick a repository to save commands for it." : "For \(URL(fileURLWithPath: directory).lastPathComponent). Every run asks for confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(commands) { command in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(command.name)
                                Text(command.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if CommandSafety.isDestructive(command.command) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Needs a second confirmation")
                            }
                            Button { pending = command.command } label: { Image(systemName: "play.fill") }
                                .disabled(runner.isRunning)
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                commands.removeAll { $0.id == command.id }
                                save()
                            }
                        }
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    TextField("Name", text: $newName).frame(width: 120)
                    TextField("Command, e.g. npm test", text: $newCommand).font(.body.monospaced())
                    Button("Save") {
                        commands.append(.init(name: newName.isEmpty ? newCommand : newName, command: newCommand))
                        newName = ""
                        newCommand = ""
                        save()
                    }
                    .disabled(newCommand.trimmingCharacters(in: .whitespaces).isEmpty || repo == nil)
                }
                .textFieldStyle(.roundedBorder)
                Divider()
                Text("Run once").font(.headline)
                HStack {
                    TextField("Command", text: $adHoc).textFieldStyle(.roundedBorder).font(.body.monospaced())
                        .onSubmit { if !adHoc.isEmpty { pending = adHoc } }
                    Button("Run…") { pending = adHoc }.disabled(adHoc.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                }
                Text("History").font(.headline)
                List(history.prefix(30)) { entry in
                    HStack {
                        Image(systemName: entry.status == 0 ? "checkmark.circle" : "xmark.circle").foregroundStyle(entry.status == 0 ? .green : .red)
                        Text(entry.command).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        Text(entry.date.formatted(.relative(presentation: .numeric))).font(.caption2).foregroundStyle(.secondary)
                    }
                    .onTapGesture(count: 2) { adHoc = entry.command }
                }
            }
            .padding(16)
            .frame(width: 440)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Output").font(.headline)
                    if runner.isRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    if runner.isRunning { Button("Stop", role: .destructive) { runner.stop() } }
                    Button("Copy") { PasteService.write(text: runner.output) }.disabled(runner.output.isEmpty)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(runner.output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("end")
                    }
                    .onChange(of: runner.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
            .padding(16)
        }
        .task(id: repo) { commands = repo.map(DeveloperStore.commands(for:)) ?? [] }
        .onChange(of: runner.isRunning) { _, running in if !running { history = CommandHistory.entries } }
        .sheet(item: Binding(get: { pending.map(IdentifiedString.init) }, set: { pending = $0?.value })) { item in
            CommandConfirmSheet(title: "Run command", command: item.value, directory: directory) {
                pending = nil
                runner.run(item.value, in: directory)
            } onCancel: { pending = nil }
        }
    }

    private func save() {
        if let repo { DeveloperStore.setCommands(commands, for: repo) }
    }
}

private struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

// MARK: - API request builder

private struct APIRequestPane: View {
    @State private var method = "GET"
    @State private var url = "https://"
    @State private var headers = "Accept: application/json"
    @State private var requestBody = ""
    @State private var response: HTTPRequestRunner.Response?
    @State private var error: String?
    @State private var isSending = false
    @State private var saved = DeveloperStore.requests
    @State private var saveName = ""

    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Method", selection: $method) { ForEach(methods, id: \.self) { Text($0) } }
                        .labelsHidden().frame(width: 100)
                    TextField("URL", text: $url).textFieldStyle(.roundedBorder).onSubmit(send)
                    Button("Send", action: send).buttonStyle(.borderedProminent).disabled(isSending)
                }
                Text("Headers (one per line, Name: value)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $headers).font(.caption.monospaced()).frame(height: 80)
                    .scrollContentBackground(.hidden).padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                Text("Body").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $requestBody).font(.caption.monospaced())
                    .scrollContentBackground(.hidden).padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                HStack {
                    Button("Format body") { if let pretty = try? JSONTools.format(requestBody, sortKeys: false) { requestBody = pretty } }
                    Spacer()
                    TextField("Name", text: $saveName).textFieldStyle(.roundedBorder).frame(width: 140)
                    Button("Save request") {
                        saved.append(.init(name: saveName.isEmpty ? "\(method) \(url)" : saveName, method: method, url: url,
                                           headers: DeveloperStore.sanitizedHeaders(headers), body: requestBody))
                        DeveloperStore.requests = saved
                        saveName = ""
                    }
                }
                Text("Saved requests keep credentials out: Authorization, Cookie and API-key headers are not stored.")
                    .font(.caption2).foregroundStyle(.secondary)
                if !saved.isEmpty {
                    List(saved) { request in
                        HStack {
                            Text(request.method).font(.caption.monospaced().bold()).frame(width: 52, alignment: .leading)
                            Text(request.name).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            method = request.method
                            url = request.url
                            headers = request.headers
                            requestBody = request.body
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                saved.removeAll { $0.id == request.id }
                                DeveloperStore.requests = saved
                            }
                        }
                    }
                    .frame(height: 130)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if isSending { ProgressView() }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let response {
                    HStack {
                        Text("\(response.status)").font(.title3.bold())
                            .foregroundStyle((200..<300).contains(response.status) ? .green : (response.status >= 400 ? .red : .orange))
                        Text(String(format: "%.0f ms", response.duration * 1000)).foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(response.size), countStyle: .file)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy body") { PasteService.write(text: response.body) }
                    }
                    DisclosureGroup("Headers (\(response.headers.count))") {
                        ForEach(Array(response.headers.enumerated()), id: \.offset) { _, header in
                            Text("\(header.0): \(header.1)").font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ScrollView {
                        Text(response.body.prefix(400_000))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !isSending {
                    Text("Send a request to see the response.").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func send() {
        isSending = true
        error = nil
        Task {
            do {
                response = try await HTTPRequestRunner.send(method: method, url: url, headers: headers, body: requestBody)
            } catch {
                response = nil
                self.error = Redactor.redact(error.localizedDescription)
            }
            isSending = false
        }
    }
}

// MARK: - JSON

private struct JSONToolPane: View {
    @State private var input = ""
    @State private var output = ""
    @State private var error: String?
    @State private var sortKeys = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Format") { apply { try JSONTools.format($0, sortKeys: sortKeys) } }
                    .buttonStyle(.borderedProminent)
                Button("Minify") { apply { try JSONTools.minify($0) } }
                Button("Validate") {
                    do {
                        _ = try JSONTools.parse(input)
                        error = nil
                        output = "✓ Valid JSON"
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                Toggle("Sort keys", isOn: $sortKeys)
                Spacer()
                Button("Paste clipboard") { input = NSPasteboard.general.string(forType: .string) ?? input }
                Button("Copy result") { PasteService.write(text: output) }.disabled(output.isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack(spacing: 10) {
                editor($input)
                editor($output)
            }
        }
        .padding(16)
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.caption.monospaced())
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }

    private func apply(_ transform: (String) throws -> String) {
        do {
            output = try transform(input)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
