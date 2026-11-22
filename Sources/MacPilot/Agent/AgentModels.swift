import Foundation
import SwiftData

/// Lifecycle of an agent task. Only one task is `running` (or `awaitingApproval`) at a time.
enum AgentTaskState: String, Codable, CaseIterable {
    case queued, running, awaitingApproval, done, failed, cancelled

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .awaitingApproval: return "Waiting for approval"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    var isActive: Bool { self == .running || self == .awaitingApproval }
    var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
}

/// One tool call proposed by the model.
enum AgentActionState: String, Codable {
    /// Waiting for the policy or for approval.
    case proposed
    case blocked, denied, expired
    case running, succeeded, failed, cancelled
    /// Was running when MacPilot quit; never replayed automatically.
    case needsReview

    var label: String {
        switch self {
        case .proposed: return "Waiting"
        case .blocked: return "Blocked by policy"
        case .denied: return "Denied"
        case .expired: return "Approval expired"
        case .running: return "Running"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .needsReview: return "Interrupted — needs review"
        }
    }
}

enum AgentApprovalDecision: String, Codable {
    case pending, approved, denied, expired, used
}

enum AgentEventKind: String, Codable {
    case info, model, tool, policy, approval, error, cost
}

@Model
final class AgentTask {
    var uid: UUID = UUID()
    var prompt: String = ""
    var title: String = ""
    var stateRaw: String = AgentTaskState.queued.rawValue
    var providerRaw: String = AIProviderID.anthropic.rawValue
    var model: String = ""
    var createdAt: Date = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var steps: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var costUSD: Double = 0
    var finalAnswer: String = ""
    var errorMessage: String?
    /// Task this one retries (Retry starts a fresh task; nothing is replayed).
    var retryOf: UUID?
    /// Where the request came from: "app" or "telegram".
    var channel: String = "app"
    /// For Telegram tasks: the paired user who asked (only they can approve its actions) and their chat.
    var telegramUserID: Int64 = 0
    var telegramChatID: Int64 = 0
    /// The one progress message that is edited as the task moves on.
    var telegramMessageID: Int = 0
    /// For scheduled runs: the job, and the only tools it may use (comma separated; empty = the default set).
    var jobID: UUID?
    var allowedToolsRaw: String = ""
    /// Runs built-in code (the job finder) instead of the model loop; can't be resumed after a restart.
    var isNative: Bool = false

    var allowedTools: Set<String> {
        Set(allowedToolsRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Short ID shown in Telegram and the timeline ("a1b2c3d4").
    var shortID: String { String(uid.uuidString.prefix(8)).lowercased() }

    init(prompt: String, provider: AIProviderID, model: String) {
        self.prompt = AgentRedactor.redact(prompt)
        self.title = String(self.prompt.prefix(80))
        self.providerRaw = provider.rawValue
        self.model = model
    }

    var state: AgentTaskState {
        get { AgentTaskState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    var provider: AIProviderID { AIProviderID(rawValue: providerRaw) ?? .anthropic }
}

@Model
final class AgentToolAction {
    var uid: UUID = UUID()
    var taskID: UUID = UUID()
    var step: Int = 0
    var callID: String = ""
    var tool: String = ""
    /// Redacted, normalized arguments shown in the timeline and the approval drawer.
    var argumentsJSON: String = "{}"
    /// What the action will do, in words ("Write 12 lines to /…/notes.md").
    var summary: String = ""
    /// For writes: a preview of the change.
    var preview: String = ""
    var riskRaw: String = AgentRisk.low.rawValue
    var actionHash: String = ""
    var stateRaw: String = AgentActionState.proposed.rawValue
    var output: String = ""
    var createdAt: Date = Date()
    var startedAt: Date?
    var finishedAt: Date?

    init(taskID: UUID, step: Int, callID: String, tool: String) {
        self.taskID = taskID
        self.step = step
        self.callID = callID
        self.tool = tool
    }

    var state: AgentActionState {
        get { AgentActionState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    var risk: AgentRisk { AgentRisk(rawValue: riskRaw) ?? .high }
}

@Model
final class AgentApproval {
    var uid: UUID = UUID()
    var taskID: UUID = UUID()
    var actionID: UUID = UUID()
    /// SHA-256 of the normalized action; the approval only unlocks exactly this action.
    var actionHash: String = ""
    var riskRaw: String = AgentRisk.medium.rawValue
    var createdAt: Date = Date()
    var expiresAt: Date = Date()
    var decisionRaw: String = AgentApprovalDecision.pending.rawValue
    var decidedAt: Date?
    var usedAt: Date?

    init(taskID: UUID, actionID: UUID, actionHash: String, risk: AgentRisk, now: Date = Date(), lifetime: TimeInterval = AgentPolicy.approvalLifetime) {
        self.taskID = taskID
        self.actionID = actionID
        self.actionHash = actionHash
        self.riskRaw = risk.rawValue
        self.createdAt = now
        self.expiresAt = now.addingTimeInterval(lifetime)
    }

    var decision: AgentApprovalDecision {
        get { AgentApprovalDecision(rawValue: decisionRaw) ?? .expired }
        set { decisionRaw = newValue.rawValue }
    }
}

/// Audit log: every step, decision and error (redacted).
@Model
final class AgentEvent {
    var uid: UUID = UUID()
    var taskID: UUID = UUID()
    var date: Date = Date()
    var kindRaw: String = AgentEventKind.info.rawValue
    var message: String = ""

    init(taskID: UUID, kind: AgentEventKind, message: String, date: Date = Date()) {
        self.taskID = taskID
        self.kindRaw = kind.rawValue
        self.message = AgentRedactor.redact(String(message.prefix(4_000)))
        self.date = date
    }

    var kind: AgentEventKind { AgentEventKind(rawValue: kindRaw) ?? .info }
}

/// Agent settings (UserDefaults; nothing secret).
struct AgentSettings: Equatable {
    var provider: AIProviderID = .anthropic
    var model: String = AIProviderID.anthropic.defaultModel
    var workspaceRoots: [String] = []
    var maxSteps = 25
    var maxSeconds: TimeInterval = 15 * 60
    var maxTokensPerTask = 400_000
    var perTaskCostCap: Double = 2.00
    var dailyCostCap: Double = 10.00
    var localOnly = false
    var approveMedium = true
    var commandAllowlist: [String] = AgentSettings.defaultAllowlist
    var commandTimeout: TimeInterval = 60
    var outputCap = 32_000

    static let defaultAllowlist = ["ls", "cat", "head", "tail", "wc", "grep", "find", "pwd", "echo", "date", "du", "file",
                                   "git", "swift", "xcodebuild", "make", "npm", "node", "python3", "pytest", "go", "cargo"]

    private enum Keys {
        static let provider = "agent.provider", model = "agent.model", roots = "agent.workspaceRoots"
        static let steps = "agent.maxSteps", seconds = "agent.maxSeconds", tokens = "agent.maxTokens"
        static let taskCap = "agent.taskCostCap", dailyCap = "agent.dailyCostCap", localOnly = "agent.localOnly"
        static let approveMedium = "agent.approveMedium", allowlist = "agent.commandAllowlist", timeout = "agent.commandTimeout"
    }

    static func load(_ defaults: UserDefaults = .standard) -> AgentSettings {
        var settings = AgentSettings()
        if let raw = defaults.string(forKey: Keys.provider), let provider = AIProviderID(rawValue: raw) { settings.provider = provider }
        settings.model = defaults.string(forKey: Keys.model).flatMap { $0.isEmpty ? nil : $0 } ?? settings.provider.defaultModel
        settings.workspaceRoots = defaults.stringArray(forKey: Keys.roots) ?? []
        if defaults.object(forKey: Keys.steps) != nil { settings.maxSteps = max(1, defaults.integer(forKey: Keys.steps)) }
        if defaults.object(forKey: Keys.seconds) != nil { settings.maxSeconds = max(10, defaults.double(forKey: Keys.seconds)) }
        if defaults.object(forKey: Keys.tokens) != nil { settings.maxTokensPerTask = max(1_000, defaults.integer(forKey: Keys.tokens)) }
        if defaults.object(forKey: Keys.taskCap) != nil { settings.perTaskCostCap = max(0, defaults.double(forKey: Keys.taskCap)) }
        if defaults.object(forKey: Keys.dailyCap) != nil { settings.dailyCostCap = max(0, defaults.double(forKey: Keys.dailyCap)) }
        settings.localOnly = defaults.bool(forKey: Keys.localOnly)
        if defaults.object(forKey: Keys.approveMedium) != nil { settings.approveMedium = defaults.bool(forKey: Keys.approveMedium) }
        if let list = defaults.stringArray(forKey: Keys.allowlist) { settings.commandAllowlist = list }
        if defaults.object(forKey: Keys.timeout) != nil { settings.commandTimeout = min(600, max(5, defaults.double(forKey: Keys.timeout))) }
        return settings
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: Keys.provider)
        defaults.set(model, forKey: Keys.model)
        defaults.set(workspaceRoots, forKey: Keys.roots)
        defaults.set(maxSteps, forKey: Keys.steps)
        defaults.set(maxSeconds, forKey: Keys.seconds)
        defaults.set(maxTokensPerTask, forKey: Keys.tokens)
        defaults.set(perTaskCostCap, forKey: Keys.taskCap)
        defaults.set(dailyCostCap, forKey: Keys.dailyCap)
        defaults.set(localOnly, forKey: Keys.localOnly)
        defaults.set(approveMedium, forKey: Keys.approveMedium)
        defaults.set(commandAllowlist, forKey: Keys.allowlist)
        defaults.set(commandTimeout, forKey: Keys.timeout)
    }
}
