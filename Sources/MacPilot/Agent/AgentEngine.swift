import Foundation
import Observation
import SwiftData

/// Runs agent tasks one at a time: plan → policy → approval → execute → observe, bounded by steps, time, tokens and cost.
@Observable
@MainActor
final class AgentEngine {
    static let shared = AgentEngine(context: Persistence.container.mainContext)

    let context: ModelContext
    let processes = AgentProcessRegistry()
    /// Overridable for tests.
    var settingsProvider: () -> AgentSettings = { AgentSettings.load() }
    var adapterFactory: (AIProviderID, String) -> any AgentModelAdapter = { AgentAdapters.make(provider: $0, model: $1) }
    var approvalLifetime: TimeInterval = AgentPolicy.approvalLifetime
    var now: () -> Date = Date.init
    var recordUsage: (AIProviderID, Int, Int) -> Void = { UsageTracker.record($0, input: $1, output: $2) }

    /// What changed, for the Telegram bot and other listeners.
    enum Update: Equatable {
        case taskChanged(UUID)
        case approvalRequested(approvalID: UUID, taskID: UUID)
        case approvalResolved(approvalID: UUID, decision: AgentApprovalDecision)
        case actionFinished(actionID: UUID, taskID: UUID)
    }
    private var observers: [UUID: (Update) -> Void] = [:]

    @discardableResult
    func addObserver(_ observer: @escaping (Update) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func emit(_ update: Update) {
        for observer in observers.values { observer(update) }
    }

    /// The kill switch: while on, no model call or tool call happens.
    private(set) var isHalted: Bool
    private(set) var activeTaskID: UUID?
    private(set) var pendingApprovalID: UUID?
    private var runner: Task<Void, Never>?
    private var waiting: [UUID: CheckedContinuation<AgentApprovalDecision, Never>] = [:]
    /// Unredacted prompts of tasks submitted this session (the stored copy is redacted).
    private var prompts: [UUID: String] = [:]
    private let defaults: UserDefaults
    private let haltedKey = "agent.halted"

    init(context: ModelContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
        self.isHalted = defaults.bool(forKey: haltedKey)
    }

    var isBusy: Bool { activeTaskID != nil }

    // MARK: Public controls

    @discardableResult
    func submit(_ prompt: String, retryOf: UUID? = nil, channel: String = "app", telegramUserID: Int64 = 0, telegramChatID: Int64 = 0) -> AgentTask {
        let settings = settingsProvider()
        let task = AgentTask(prompt: prompt, provider: settings.provider, model: settings.model)
        task.retryOf = retryOf
        task.channel = channel
        task.telegramUserID = telegramUserID
        task.telegramChatID = telegramChatID
        context.insert(task)
        prompts[task.uid] = prompt
        log(task.uid, .info, "Queued on \(settings.provider.displayName) · \(settings.model)" + (channel == "app" ? "" : " (from \(channel))"))
        save()
        emit(.taskChanged(task.uid))
        startNextIfIdle()
        return task
    }

    /// A fresh run of the same request; nothing from the old run is replayed.
    @discardableResult
    func retry(_ task: AgentTask) -> AgentTask {
        submit(prompts[task.uid] ?? task.prompt, retryOf: task.uid, channel: task.channel,
               telegramUserID: task.telegramUserID, telegramChatID: task.telegramChatID)
    }

    /// Stops one task: cancels the model call, kills its command and denies any pending approval.
    func stop(_ taskID: UUID) {
        if activeTaskID == taskID {
            runner?.cancel()
            processes.killAll()
            resolveAllWaiting(.denied)
        } else if let task = fetchTask(taskID), task.state == .queued {
            task.state = .cancelled
            task.finishedAt = now()
            log(taskID, .info, "Removed from the queue")
            save()
            emit(.taskChanged(taskID))
        }
    }

    /// Menu bar kill switch: stops the running command and blocks every future tool call until resumed.
    func killSwitch() {
        isHalted = true
        defaults.set(true, forKey: haltedKey)
        processes.killAll()
        resolveAllWaiting(.denied)
        runner?.cancel()
        for task in fetchTasks(where: .queued) {
            task.state = .cancelled
            task.finishedAt = now()
            log(task.uid, .policy, "Cancelled by the kill switch")
        }
        if let id = activeTaskID { log(id, .policy, "Kill switch: stopped") }
        save()
    }

    func resume() {
        isHalted = false
        defaults.set(false, forKey: haltedKey)
        startNextIfIdle()
    }

    /// The user's answer in the approval drawer. Applies only to that one approval.
    func decide(approvalID: UUID, approve: Bool, via: String = "") {
        guard let approval = fetchApproval(approvalID), approval.decision == .pending else { return }
        if now() >= approval.expiresAt {
            approval.decision = .expired
        } else {
            approval.decision = approve ? .approved : .denied
        }
        approval.decidedAt = now()
        log(approval.taskID, .approval, "\(approve ? "Approved" : "Denied") one action" + (via.isEmpty ? "" : " (\(via))"))
        save()
        resume(approvalID, with: approval.decision)
    }

    /// After a restart: anything that was mid-flight is marked for review and never run again.
    func recoverAfterLaunch() {
        for action in fetchActions(in: [.running]) {
            action.state = .needsReview
            action.output += (action.output.isEmpty ? "" : "\n") + "MacPilot quit while this was running. It was not run again — check whether it finished."
            action.finishedAt = now()
            log(action.taskID, .error, "Step \(action.step) (\(action.tool)) was interrupted and needs review")
        }
        for action in fetchActions(in: [.proposed]) {
            action.state = .cancelled
        }
        let all = (try? context.fetch(FetchDescriptor<AgentApproval>())) ?? []
        for approval in all where approval.decision == .pending || approval.decision == .approved {
            approval.decision = .expired
        }
        for task in fetchTasks(where: .running) + fetchTasks(where: .awaitingApproval) {
            task.state = .failed
            task.finishedAt = now()
            task.errorMessage = "Interrupted when MacPilot quit (step \(task.steps)). Nothing was replayed; review the timeline and press Retry to start again."
            log(task.uid, .error, task.errorMessage ?? "")
        }
        save()
        startNextIfIdle()
    }

    func startNextIfIdle() {
        guard runner == nil, !isHalted else { return }
        var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.stateRaw == "queued" }, sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        guard let next = try? context.fetch(descriptor).first else { return }
        activeTaskID = next.uid
        let id = next.uid
        runner = Task { [weak self] in
            await self?.run(id)
            guard let self else { return }
            self.runner = nil
            self.activeTaskID = nil
            self.pendingApprovalID = nil
            self.startNextIfIdle()
        }
    }

    /// Waits until the active task (if any) finishes. For tests and the Pilot voice.
    func waitUntilIdle() async {
        while let runner { await runner.value; if self.runner == runner { break } }
    }

    // MARK: Loop

    private struct LimitError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func run(_ id: UUID) async {
        guard let task = fetchTask(id) else { return }
        let settings = settingsProvider()
        task.state = .running
        task.startedAt = now()
        save()
        emit(.taskChanged(id))
        let started = now()
        do {
            try AgentPolicy.checkProvider(task.provider, settings: settings)
            let adapter = adapterFactory(task.provider, task.model)
            guard adapter.capabilities.toolCalling else { throw AgentProviderError.noToolSupport(task.model) }
            var messages: [AgentMessage] = [.user(prompts[id] ?? task.prompt)]
            let system = systemPrompt(settings)

            for step in 1...max(1, settings.maxSteps) {
                try checkRunnable()
                if now().timeIntervalSince(started) > settings.maxSeconds {
                    throw LimitError(message: "Stopped at the time limit (\(Int(settings.maxSeconds / 60)) min).")
                }
                if task.inputTokens + task.outputTokens >= settings.maxTokensPerTask {
                    throw LimitError(message: "Stopped at the token limit (\(settings.maxTokensPerTask) tokens).")
                }
                if settings.perTaskCostCap > 0, task.costUSD >= settings.perTaskCostCap {
                    throw LimitError(message: String(format: "Stopped at the per-task cost cap ($%.2f).", settings.perTaskCostCap))
                }
                if settings.dailyCostCap > 0, costToday() >= settings.dailyCostCap {
                    throw LimitError(message: String(format: "Today's agent cost cap ($%.2f) is reached.", settings.dailyCostCap))
                }
                // The provider is re-checked before every call, so turning on local-only takes effect mid-task.
                try AgentPolicy.checkProvider(task.provider, settings: settingsProvider())

                let response = try await adapter.generate(system: system, messages: messages, tools: AgentTools.specs)
                try checkRunnable()
                task.steps = step
                task.inputTokens += response.inputTokens
                task.outputTokens += response.outputTokens
                let cost = adapter.estimateCost(inputTokens: response.inputTokens, outputTokens: response.outputTokens)
                task.costUSD += cost
                recordUsage(task.provider, response.inputTokens, response.outputTokens)
                log(id, .cost, String(format: "Step %d: %d in / %d out tokens, ≈$%.4f", step, response.inputTokens, response.outputTokens, cost))
                if response.stop == .refusal { throw AgentProviderError.refused }
                if !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { log(id, .model, response.text) }
                messages.append(.assistant(text: response.text, calls: response.calls, raw: response.raw))
                save()

                if response.calls.isEmpty {
                    if response.stop == .maxTokens { throw LimitError(message: "The model's reply was cut off (maximum length).") }
                    task.finalAnswer = AgentRedactor.redact(response.text)
                    finish(task, .done)
                    return
                }
                var results: [(call: AgentToolCall, result: AgentToolResult)] = []
                for call in response.calls {
                    let result = await handle(call, task: task, step: step, settings: settings)
                    results.append((call, AgentToolResult(content: AgentRedactor.redact(result.content), isError: result.isError)))
                    try checkRunnable()
                }
                messages.append(.toolResults(results))
            }
            throw LimitError(message: "Stopped at the step limit (\(settings.maxSteps) steps).")
        } catch is CancellationError {
            finish(task, .cancelled, message: isHalted ? "Stopped by the kill switch." : "Stopped.")
        } catch let error as AgentPolicyError where error == .halted {
            finish(task, .cancelled, message: error.localizedDescription)
        } catch {
            if Task.isCancelled {
                finish(task, .cancelled, message: isHalted ? "Stopped by the kill switch." : "Stopped.")
            } else {
                finish(task, .failed, message: AIError.describe(error))
            }
        }
    }

    private func checkRunnable() throws {
        if isHalted { throw AgentPolicyError.halted }
        try Task.checkCancellation()
    }

    private func finish(_ task: AgentTask, _ state: AgentTaskState, message: String? = nil) {
        task.state = state
        task.finishedAt = now()
        if let message {
            task.errorMessage = AgentRedactor.redact(message)
            log(task.uid, state == .failed ? .error : .info, message)
        } else {
            log(task.uid, .info, "Finished in \(task.steps) step\(task.steps == 1 ? "" : "s")")
        }
        // Nothing can still be waiting or running for a finished task.
        for action in fetchActions(taskID: task.uid) where action.state == .proposed || action.state == .running {
            action.state = .cancelled
            action.finishedAt = now()
        }
        save()
        emit(.taskChanged(task.uid))
    }

    /// One tool call through normalize → policy → approval → execute.
    private func handle(_ call: AgentToolCall, task: AgentTask, step: Int, settings: AgentSettings) async -> AgentToolResult {
        let action = AgentToolAction(taskID: task.uid, step: step, callID: call.id, tool: call.name)
        context.insert(action)
        action.argumentsJSON = AgentRedactor.redact(String(call.rawArguments.prefix(8_000)))
        save()

        guard let arguments = call.arguments else {
            return reject(action, .failed, "The tool arguments weren't valid JSON.")
        }
        let normalized: NormalizedAction
        do {
            normalized = try AgentTools.normalize(tool: call.name, arguments: arguments, settings: settings)
        } catch {
            return reject(action, .blocked, "Blocked by MacPilot policy: \(error.localizedDescription)")
        }
        let hash = normalized.hash(taskID: task.uid)
        action.summary = AgentRedactor.redact(normalized.summary)
        action.argumentsJSON = String(normalized.argumentsJSON.prefix(8_000))
        action.riskRaw = normalized.risk.rawValue
        action.actionHash = hash
        action.preview = AgentRedactor.redact(String(AgentTools.preview(normalized).prefix(8_000)))
        save()

        switch AgentPolicy.decide(normalized, settings: settings, halted: isHalted) {
        case .deny(let reason):
            return reject(action, .blocked, reason)
        case .allow:
            break
        case .needsApproval:
            let approval = AgentApproval(taskID: task.uid, actionID: action.uid, actionHash: hash, risk: normalized.risk,
                                         now: now(), lifetime: approvalLifetime)
            context.insert(approval)
            task.state = .awaitingApproval
            pendingApprovalID = approval.uid
            log(task.uid, .approval, "Waiting for approval: \(action.summary)")
            save()
            emit(.approvalRequested(approvalID: approval.uid, taskID: task.uid))
            NotchController.shared.peek(NotchPeek(systemImage: "hand.raised.fill", tint: .orange, title: "Agent needs your approval",
                                                  subtitle: action.summary, duration: 10))
            let decision = await waitForDecision(approval)
            pendingApprovalID = nil
            emit(.approvalResolved(approvalID: approval.uid, decision: decision))
            if task.state == .awaitingApproval { task.state = .running }
            guard decision == .approved else {
                if approval.decision == .pending { approval.decision = decision }
                return reject(action, decision == .expired ? .expired : .denied,
                              decision == .expired ? "The approval expired after 10 minutes, so this was not run." : "The user denied this action, so it was not run.")
            }
            // The exact action must still be the one that was approved (paths re-resolved now).
            guard let again = try? AgentTools.normalize(tool: call.name, arguments: arguments, settings: settingsProvider()),
                  case .valid = AgentPolicy.validate(approval, taskID: task.uid, actionHash: again.hash(taskID: task.uid), now: now()) else {
                return reject(action, .blocked, "The approval no longer matches this action, so it was not run.")
            }
            AgentPolicy.consume(approval, now: now())
            save()
        }

        if isHalted || Task.isCancelled { return reject(action, .cancelled, "Stopped before it ran.") }
        // Persisted before running, so a crash or quit leaves it marked as needing review (never replayed).
        action.state = .running
        action.startedAt = now()
        save()
        let result = await AgentTools.execute(normalized, settings: settings, processes: processes)
        action.output = AgentRedactor.redact(String(result.content.prefix(8_000)))
        action.state = Task.isCancelled || isHalted ? .cancelled : (result.isError ? .failed : .succeeded)
        action.finishedAt = now()
        log(task.uid, .tool, "\(action.summary) — \(action.state.label)")
        save()
        emit(.actionFinished(actionID: action.uid, taskID: task.uid))
        return result
    }

    private func reject(_ action: AgentToolAction, _ state: AgentActionState, _ message: String) -> AgentToolResult {
        action.state = state
        action.output = AgentRedactor.redact(message)
        action.finishedAt = now()
        log(action.taskID, state == .blocked ? .policy : .tool, "\(action.tool): \(message)")
        save()
        return AgentToolResult(content: message, isError: true)
    }

    // MARK: Approvals

    private func waitForDecision(_ approval: AgentApproval) async -> AgentApprovalDecision {
        let id = approval.uid
        let lifetime = max(0, approval.expiresAt.timeIntervalSince(now()))
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled, let self, let approval = self.fetchApproval(id), approval.decision == .pending else { return }
            approval.decision = .expired
            self.log(approval.taskID, .approval, "Approval expired")
            self.save()
            self.resume(id, with: .expired)
        }
        defer { expiry.cancel() }
        if Task.isCancelled || isHalted { return .denied }
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
        }
    }

    private func resume(_ id: UUID, with decision: AgentApprovalDecision) {
        waiting.removeValue(forKey: id)?.resume(returning: decision)
    }

    private func resolveAllWaiting(_ decision: AgentApprovalDecision) {
        for (id, continuation) in waiting {
            if let approval = fetchApproval(id), approval.decision == .pending { approval.decision = decision }
            continuation.resume(returning: decision)
        }
        waiting.removeAll()
    }

    // MARK: Helpers

    func costToday() -> Double {
        let start = Calendar.current.startOfDay(for: now())
        let tasks = (try? context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.createdAt >= start }))) ?? []
        return tasks.reduce(0) { $0 + $1.costUSD }
    }

    private func systemPrompt(_ settings: AgentSettings) -> String {
        """
        You are MacPilot's agent, working on the user's Mac through the tools provided. \
        You can only touch files inside these workspace folders: \(settings.workspaceRoots.isEmpty ? "(none configured)" : settings.workspaceRoots.joined(separator: ", ")). \
        Commands run without a shell (no pipes, redirects or variables) and only allowlisted programs work: \(settings.commandAllowlist.joined(separator: ", ")). \
        MacPilot checks every action against its own policy; writes, commands and deletes may need the user's approval, and a denied or blocked action \
        returns an error you should respect rather than work around. Prefer reading before changing anything, keep changes minimal, \
        and finish with a short summary of what you did and anything the user should check.
        """
    }

    /// Audit entries that don't belong to a task (Telegram pairing, screenshots…).
    static let systemLogID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func audit(_ message: String, kind: AgentEventKind = .info) {
        log(Self.systemLogID, kind, message)
        save()
    }

    func events(for taskID: UUID) -> [AgentEvent] {
        (try? context.fetch(FetchDescriptor<AgentEvent>(predicate: #Predicate { $0.taskID == taskID }, sortBy: [SortDescriptor(\.date)]))) ?? []
    }

    func recentTasks(limit: Int) -> [AgentTask] {
        var descriptor = FetchDescriptor<AgentTask>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    var queuedCount: Int {
        (try? context.fetchCount(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.stateRaw == "queued" }))) ?? 0
    }

    func log(_ taskID: UUID, _ kind: AgentEventKind, _ message: String) {
        context.insert(AgentEvent(taskID: taskID, kind: kind, message: message, date: now()))
    }

    private func save() {
        try? context.save()
    }

    func fetchTask(_ id: UUID) -> AgentTask? {
        var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.uid == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchTasks(where state: AgentTaskState) -> [AgentTask] {
        let raw = state.rawValue
        return (try? context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.stateRaw == raw }))) ?? []
    }

    func fetchApproval(_ id: UUID) -> AgentApproval? {
        var descriptor = FetchDescriptor<AgentApproval>(predicate: #Predicate { $0.uid == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func fetchActions(taskID: UUID) -> [AgentToolAction] {
        (try? context.fetch(FetchDescriptor<AgentToolAction>(predicate: #Predicate { $0.taskID == taskID },
                                                              sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    private func fetchActions(in states: [AgentActionState]) -> [AgentToolAction] {
        let raws = states.map(\.rawValue)
        return (try? context.fetch(FetchDescriptor<AgentToolAction>(predicate: #Predicate { raws.contains($0.stateRaw) }))) ?? []
    }
}
