import CryptoKit
import Foundation

/// Risk tiers, decided by MacPilot (never by the model).
enum AgentRisk: String, Codable, Comparable, CaseIterable {
    /// Reads: run without asking.
    case low
    /// Writes and commands: ask first (on by default, can be turned off in Settings).
    case medium
    /// Deletes, sending data out, security changes: always ask, one exact action at a time.
    case high

    private var order: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
    static func < (lhs: AgentRisk, rhs: AgentRisk) -> Bool { lhs.order < rhs.order }

    var label: String {
        switch self {
        case .low: return "Low risk"
        case .medium: return "Medium risk"
        case .high: return "High risk"
        }
    }
}

enum AgentPolicyError: LocalizedError, Equatable {
    case noWorkspace
    case outsideWorkspace(String)
    case symlinkEscape(String)
    case invalidPath(String)
    case commandNotAllowed(String)
    case forbiddenCommand(String)
    case invalidArguments(String)
    case unknownTool(String)
    case localOnly(AIProviderID)
    case halted

    var errorDescription: String? {
        switch self {
        case .noWorkspace: return "No workspace folder is set. Add one in Settings → Agent → Workspaces."
        case .outsideWorkspace(let path): return "\(path) is outside your agent workspaces."
        case .symlinkEscape(let path): return "\(path) is a link that leads outside your agent workspaces."
        case .invalidPath(let path): return "“\(path)” isn't a valid path."
        case .commandNotAllowed(let name): return "“\(name)” isn't on the agent's command allowlist (Settings → Agent)."
        case .forbiddenCommand(let reason): return reason
        case .invalidArguments(let reason): return "Invalid tool arguments: \(reason)"
        case .unknownTool(let name): return "Unknown tool “\(name)”."
        case .localOnly(let provider): return "Local-only mode is on, so \(provider.displayName) (a cloud provider) can't be used. Pick Ollama or turn local-only off in Settings → Agent."
        case .halted: return "The agent kill switch is on. Resume the agent from the menu bar or the Agent tab."
        }
    }
}

/// Keeps every file path inside the workspace roots the user picked.
struct WorkspaceGuard {
    let roots: [URL]
    /// The roots as the user typed them (for telling a symlink escape from a plain outside path).
    private let givenRoots: [URL]

    init(roots: [String]) {
        givenRoots = roots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        self.roots = givenRoots.map(Self.canonical)
    }

    /// Standardized path with every existing symlink resolved (including in parent folders).
    static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var trailing: [String] = []
        // Resolve the longest existing prefix, then re-append the rest (for files that don't exist yet).
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        // /private/var vs /var etc.: resolvingSymlinksInPath strips /private; realpath keeps the true path.
        if let real = realpath(existing.path, nil) {
            resolved = URL(fileURLWithPath: String(cString: real))
            free(real)
        }
        for component in trailing { resolved.appendPathComponent(component) }
        // Not `standardizedFileURL`: it drops "/private" only for paths that exist, which would make
        // a new file under /private/var look like it's outside its (existing) root.
        return resolved
    }

    static func isInside(_ path: URL, root: URL) -> Bool {
        let p = path.pathComponents, r = root.pathComponents
        return p.count >= r.count && Array(p.prefix(r.count)) == r
    }

    /// Resolves `raw` (absolute, ~, or relative to the first root) to a canonical URL inside a root, or throws.
    func resolve(_ raw: String) throws -> URL {
        guard !roots.isEmpty else { throw AgentPolicyError.noWorkspace }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { throw AgentPolicyError.invalidPath(raw) }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : roots[0].appendingPathComponent(expanded)
        let lexical = url.standardizedFileURL
        let resolved = Self.canonical(url)
        guard roots.contains(where: { Self.isInside(resolved, root: $0) }) else {
            // Lexically inside but resolved outside: a symlink escape.
            if (roots + givenRoots).contains(where: { Self.isInside(lexical, root: $0) }) { throw AgentPolicyError.symlinkEscape(lexical.path) }
            throw AgentPolicyError.outsideWorkspace(lexical.path)
        }
        return resolved
    }
}

/// Which commands the agent may run, and how.
struct CommandGuard {
    let allowlist: Set<String>
    static let searchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
    /// Never allowed, whatever the allowlist says.
    static let forbidden: Set<String> = ["sudo", "su", "doas", "rm", "rmdir", "shred", "dd", "mkfs", "diskutil", "chmod", "chown",
                                         "sh", "bash", "zsh", "fish", "csh", "tcsh", "ksh", "osascript", "launchctl", "defaults",
                                         "security", "csrutil", "spctl", "curl", "wget", "nc", "ssh", "scp", "sftp", "rsync",
                                         "open", "kill", "killall", "pkill", "shutdown", "reboot", "passwd", "crontab", "eval", "env", "xargs"]

    init(allowlist: [String]) {
        self.allowlist = Set(allowlist.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Splits a command line like a shell would for words and quotes, but never interprets pipes,
    /// redirects, globs, substitutions or variables (they're refused instead).
    static func split(_ line: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        var escaped = false
        for char in line {
            if escaped { current.append(char); escaped = false; inWord = true; continue }
            if let q = quote {
                if char == q { quote = nil } else if char == "\\" && q == "\"" { escaped = true } else { current.append(char) }
                continue
            }
            switch char {
            case "\\": escaped = true
            case "\"", "'": quote = char; inWord = true
            case " ", "\t": if inWord { words.append(current); current = ""; inWord = false }
            case "|", "&", ";", "<", ">", "`", "$", "\n", "(", ")":
                throw AgentPolicyError.forbiddenCommand("Shell syntax (“\(char)”) isn't allowed. Run one program with plain arguments.")
            default: current.append(char); inWord = true
            }
        }
        if quote != nil { throw AgentPolicyError.invalidArguments("unclosed quote") }
        if inWord { words.append(current) }
        guard !words.isEmpty else { throw AgentPolicyError.invalidArguments("empty command") }
        return words
    }

    /// Checks the program and its arguments; returns the absolute executable path.
    func validate(_ argv: [String]) throws -> String {
        guard let first = argv.first else { throw AgentPolicyError.invalidArguments("empty command") }
        let name = (first as NSString).lastPathComponent
        if Self.forbidden.contains(name) {
            throw AgentPolicyError.forbiddenCommand(name == "rm" || name == "rmdir"
                ? "Deleting with “\(name)” isn't allowed; use the delete_file tool, which asks you first."
                : "“\(name)” is never allowed for the agent.")
        }
        guard allowlist.contains(name), first == name else { throw AgentPolicyError.commandNotAllowed(name) }
        // Dangerous flags on otherwise harmless tools.
        if name == "find", argv.contains(where: { ["-exec", "-execdir", "-delete", "-ok", "-okdir", "-fprint", "-fls"].contains($0) }) {
            throw AgentPolicyError.forbiddenCommand("find with -exec or -delete isn't allowed.")
        }
        if name == "git", let sub = argv.dropFirst().first(where: { !$0.hasPrefix("-") }),
           ["push", "clean", "reset", "filter-branch", "gc", "config", "remote", "credential"].contains(sub) {
            throw AgentPolicyError.forbiddenCommand("git \(sub) isn't allowed for the agent.")
        }
        guard let path = Self.searchPath.map({ "\($0)/\(name)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AgentPolicyError.commandNotAllowed(name)
        }
        return path
    }

    /// Only these variables reach a command (no API keys, tokens or the user's shell setup).
    static func scrubbedEnvironment(home: String = NSHomeDirectory()) -> [String: String] {
        ["PATH": searchPath.joined(separator: ":"), "HOME": home, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
         "TMPDIR": NSTemporaryDirectory(), "TERM": "dumb", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "NO_COLOR": "1"]
    }
}

/// A tool call after MacPilot has checked and normalized it.
struct NormalizedAction: Equatable {
    var tool: String
    /// Canonical arguments (paths resolved), used for display and hashing.
    var arguments: [String: String]
    var risk: AgentRisk
    var summary: String

    /// SHA-256 over task, tool and sorted arguments: an approval unlocks only this exact action.
    func hash(taskID: UUID) -> String {
        let canonical = ([taskID.uuidString, tool] + arguments.keys.sorted().map { "\($0)=\(arguments[$0] ?? "")" }).joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var argumentsJSON: String {
        let readable = arguments.mapValues { $0.replacingOccurrences(of: "\u{1F}", with: " ") }
        let data = (try? JSONSerialization.data(withJSONObject: readable, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        return AgentRedactor.redact(String(data: data, encoding: .utf8) ?? "{}")
    }
}

/// What the policy says about one action.
enum PolicyDecision: Equatable {
    case allow
    case needsApproval
    case deny(String)
}

enum AgentPolicy {
    static let approvalLifetime: TimeInterval = 10 * 60

    /// Decides outside the model: low runs, medium asks when configured, high always asks.
    static func decide(_ action: NormalizedAction, settings: AgentSettings, halted: Bool) -> PolicyDecision {
        if halted { return .deny(AgentPolicyError.halted.localizedDescription) }
        switch action.risk {
        case .low: return .allow
        case .medium: return settings.approveMedium ? .needsApproval : .allow
        case .high: return .needsApproval
        }
    }

    /// The provider check that runs before every model call; there is never a silent switch to another provider.
    static func checkProvider(_ provider: AIProviderID, settings: AgentSettings) throws {
        if settings.localOnly && provider.isExternal { throw AgentPolicyError.localOnly(provider) }
    }

    enum ApprovalCheck: Equatable {
        case valid
        case rejected(String)
    }

    /// An approval is valid once, for its own task, before it expires, and only for the action it was made for.
    static func validate(_ approval: AgentApproval, taskID: UUID, actionHash: String, now: Date = Date()) -> ApprovalCheck {
        if approval.usedAt != nil || approval.decision == .used { return .rejected("This approval was already used.") }
        if approval.taskID != taskID { return .rejected("This approval belongs to another task.") }
        if approval.actionHash != actionHash { return .rejected("The action changed after it was approved.") }
        if now >= approval.expiresAt || approval.decision == .expired { return .rejected("The approval expired (10 minutes).") }
        switch approval.decision {
        case .approved: return .valid
        case .denied: return .rejected("You denied this action.")
        case .pending: return .rejected("Not approved yet.")
        case .expired, .used: return .rejected("The approval is no longer valid.")
        }
    }

    /// Marks the approval used; call only after `validate` returned `.valid`.
    static func consume(_ approval: AgentApproval, now: Date = Date()) {
        approval.usedAt = now
        approval.decision = .used
    }
}

/// Removes secrets before anything is stored, logged or shown.
enum AgentRedactor {
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[redacted private key]"),
        (#"gh[pousr]_[A-Za-z0-9]{20,}"#, "[redacted token]"),
        (#"github_pat_[A-Za-z0-9_]{20,}"#, "[redacted token]"),
        (#"xox[abprs]-[A-Za-z0-9-]{10,}"#, "[redacted token]"),
        (#"[0-9]{6,12}:[A-Za-z0-9_-]{30,}"#, "[redacted token]"),
        (#"\bAIza[0-9A-Za-z_\-]{30,}\b"#, "[redacted key]"),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, "[redacted token]"),
        (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{12,}"#, "$1 [redacted]"),
        (#"(?i)\b(aws_secret_access_key|aws_session_token|secret[_-]?key|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd|pwd)(\s*["']?\s*[:=]\s*["']?)[^\s"',;]{4,}"#, "$1$2[redacted]"),
        (#"(?i)(://[^/\s:@]+:)[^@\s/]+@"#, "$1[redacted]@")
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    static func redact(_ text: String) -> String {
        var result = Redactor.redact(text)
        for (regex, template) in patterns {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }
}
