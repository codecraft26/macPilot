import Foundation

struct GitFileChange: Hashable, Identifiable {
    enum Kind: String { case modified, added, deleted, renamed, copied, untracked, conflicted, typeChanged }

    var path: String
    var originalPath: String?
    /// Index (staged) and worktree status letters from porcelain v2, "." when unchanged.
    var staged: Character
    var unstaged: Character
    var kind: Kind

    var id: String { path }
    var isStaged: Bool { staged != "." && kind != .untracked }
}

struct GitStatus: Equatable {
    var branch = ""
    var upstream: String?
    var ahead = 0
    var behind = 0
    var files: [GitFileChange] = []

    var isDetached: Bool { branch == "(detached)" }
}

struct GitCommit: Hashable, Identifiable {
    var hash: String
    var author: String
    var date: String
    var subject: String
    var id: String { hash }
}

enum GitParsing {
    /// Parses `git status --porcelain=v2 --branch`.
    static func status(_ output: String) -> GitStatus {
        var status = GitStatus()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("# branch.head ") {
                status.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") {
                // 1 XY sub mH mI mW hH hI path
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                let xy = Array(fields[1])
                status.files.append(GitFileChange(path: String(fields[8]), staged: xy[0], unstaged: xy[1], kind: kind(xy)))
            } else if line.hasPrefix("2 ") {
                // 2 XY sub mH mI mW hH hI Xscore path<TAB>origPath
                let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                let xy = Array(fields[1])
                let paths = fields[9].split(separator: "\t", maxSplits: 1).map(String.init)
                status.files.append(GitFileChange(path: paths[0], originalPath: paths.count > 1 ? paths[1] : nil,
                                                  staged: xy[0], unstaged: xy[1], kind: fields[8].hasPrefix("C") ? .copied : .renamed))
            } else if line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard let path = fields.last else { continue }
                status.files.append(GitFileChange(path: String(path), staged: "U", unstaged: "U", kind: .conflicted))
            } else if line.hasPrefix("? ") {
                status.files.append(GitFileChange(path: String(line.dropFirst(2)), staged: ".", unstaged: "?", kind: .untracked))
            }
        }
        return status
    }

    private static func kind(_ xy: [Character]) -> GitFileChange.Kind {
        let letters = Set(xy)
        if letters.contains("D") { return .deleted }
        if letters.contains("A") { return .added }
        if letters.contains("T") { return .typeChanged }
        return .modified
    }

    static let logFormat = "%h%x1f%an%x1f%ar%x1f%s"

    static func commits(_ output: String) -> [GitCommit] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { return nil }
            return GitCommit(hash: parts[0], author: parts[1], date: parts[2], subject: parts[3])
        }
    }
}

/// Read-mostly git access through /usr/bin/git with argument arrays and timeouts.
enum GitService {
    static let git = "/usr/bin/git"

    static func isRepository(_ path: String) async -> Bool {
        await Shell.run(git, ["rev-parse", "--is-inside-work-tree"], in: path, timeout: 10).stdout.hasPrefix("true")
    }

    static func status(_ path: String) async throws -> GitStatus {
        let result = await Shell.run(git, ["status", "--porcelain=v2", "--branch"], in: path)
        guard result.ok else { throw GitError(result) }
        return GitParsing.status(result.stdout)
    }

    static func log(_ path: String, count: Int = 20) async -> [GitCommit] {
        GitParsing.commits(await Shell.run(git, ["log", "-\(count)", "--pretty=format:\(GitParsing.logFormat)"], in: path).stdout)
    }

    static func branches(_ path: String) async -> [String] {
        await Shell.run(git, ["branch", "--format=%(refname:short)"], in: path).stdout
            .split(separator: "\n").map(String.init)
    }

    /// Staged diff, or the unstaged diff when nothing is staged. Clipped for AI prompts.
    static func diffForCommit(_ path: String, limit: Int = 120_000) async -> (diff: String, staged: Bool) {
        let staged = await Shell.run(git, ["diff", "--staged", "--no-color"], in: path).stdout
        if !staged.isEmpty { return (String(staged.prefix(limit)), true) }
        return (String(await Shell.run(git, ["diff", "--no-color"], in: path).stdout.prefix(limit)), false)
    }

    /// Commits and diff stat since the base branch, for a PR summary.
    static func branchSummary(_ path: String) async -> String {
        var base = "main"
        if await !Shell.run(git, ["rev-parse", "--verify", "--quiet", "main"], in: path).ok {
            base = await Shell.run(git, ["rev-parse", "--verify", "--quiet", "master"], in: path).ok ? "master" : "HEAD~10"
        }
        let log = await Shell.run(git, ["log", "\(base)..HEAD", "--pretty=format:- %s%n%b"], in: path).stdout
        let stat = await Shell.run(git, ["diff", "--stat", "\(base)...HEAD"], in: path).stdout
        let diff = await Shell.run(git, ["diff", "--no-color", "\(base)...HEAD"], in: path).stdout
        return "Base: \(base)\n\nCommits:\n\(log)\n\nDiff stat:\n\(stat)\n\nDiff (clipped):\n\(diff.prefix(80_000))"
    }

    static func commit(_ path: String, message: String) async -> ShellResult {
        await Shell.run(git, ["commit", "-m", message], in: path, timeout: 60)
    }

    static func stageAll(_ path: String) async -> ShellResult {
        await Shell.run(git, ["add", "-A"], in: path)
    }

    static func checkout(_ path: String, branch: String) async -> ShellResult {
        await Shell.run(git, ["checkout", branch], in: path)
    }

    struct GitError: LocalizedError {
        let result: ShellResult
        init(_ result: ShellResult) { self.result = result }
        var errorDescription: String? {
            result.timedOut ? "git timed out." : Redactor.redact(result.stderr.isEmpty ? "git failed (\(result.status))." : result.stderr)
        }
    }
}

/// Repositories, saved commands and saved API requests, kept in preferences (paths and text only).
enum DeveloperStore {
    struct SavedCommand: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        var command: String
    }

    struct SavedRequest: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        var method: String
        var url: String
        var headers: String
        var body: String
    }

    static var repositories: [String] {
        get { UserDefaults.standard.stringArray(forKey: PrefKey.developerRepos) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.developerRepos) }
    }

    private static func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func store<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func commands(for repo: String) -> [SavedCommand] {
        (load("developer.commands", as: [String: [SavedCommand]].self) ?? [:])[repo] ?? []
    }

    static func setCommands(_ commands: [SavedCommand], for repo: String) {
        var all = load("developer.commands", as: [String: [SavedCommand]].self) ?? [:]
        all[repo] = commands
        store(all, key: "developer.commands")
    }

    static var requests: [SavedRequest] {
        get { load("developer.requests", as: [SavedRequest].self) ?? [] }
        set { store(newValue, key: "developer.requests") }
    }

    /// Header values that look like credentials are not saved.
    static func sanitizedHeaders(_ headers: String) -> String {
        let secretNames = ["authorization", "cookie", "x-api-key", "api-key", "x-auth-token", "proxy-authorization"]
        return headers.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return String(line) }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if secretNames.contains(name.lowercased()) || SensitiveContent.looksSensitive(value) {
                return "\(name): <not saved>"
            }
            return String(line)
        }.joined(separator: "\n")
    }
}

/// Plain HTTP requests for the API request builder.
enum HTTPRequestRunner {
    struct Response {
        var status: Int
        var duration: TimeInterval
        var headers: [(String, String)]
        var body: String
        var size: Int
    }

    static func parseHeaders(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("#") else { return nil }
            return (name, parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    static func send(method: String, url: String, headers: String, body: String) async throws -> Response {
        guard let target = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), target.scheme != nil else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = 60
        for (name, value) in parseHeaders(headers) { request.setValue(value, forHTTPHeaderField: name) }
        if !body.isEmpty && !["GET", "HEAD"].contains(method) {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil, (try? JSONTools.parse(body)) != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:]).map { ("\($0.key)", "\($0.value)") }.sorted { $0.0 < $1.0 }
        var text = String(decoding: data.prefix(5_000_000), as: UTF8.self)
        if let pretty = try? JSONTools.format(text, sortKeys: false) { text = pretty }
        return Response(status: http?.statusCode ?? 0, duration: Date().timeIntervalSince(start), headers: headers, body: text, size: data.count)
    }
}
