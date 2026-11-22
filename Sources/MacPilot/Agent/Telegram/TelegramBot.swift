import Foundation
import Observation

/// Telegram remote control for the agent: long polling (no inbound port), paired users only,
/// tasks from chat with live progress, inline approvals and /screenshot.
@Observable
@MainActor
final class TelegramBot {
    static let shared = TelegramBot(engine: .shared)

    enum Status: Equatable {
        case off, connecting, online, error(String)

        var label: String {
            switch self {
            case .off: return "Off"
            case .connecting: return "Connecting…"
            case .online: return "Online"
            case .error(let message): return "Offline — \(message)"
            }
        }

        var isOnline: Bool { self == .online }
    }

    private(set) var status: Status = .off
    private(set) var botUsername = ""
    private(set) var pairing: TelegramPairing
    /// Open approval buttons by approval ID.
    private(set) var tickets: [UUID: TelegramApprovalTicket] = [:]

    let engine: AgentEngine
    var transportFactory: () -> TelegramTransport? = { TelegramHTTPTransport.fromKeychain() }
    var screen: TelegramScreenSource = SystemScreenSource()
    var now: () -> Date = Date.init
    /// Minimum gap between edits of a task's progress message.
    var progressInterval: TimeInterval = 3
    private var transport: TelegramTransport?
    private var poller: Task<Void, Never>?
    private var limiter = TelegramRateLimiter()
    private var observerID: UUID?
    private var lastProgressEdit: [UUID: Date] = [:]
    private var pendingProgress: [UUID: Task<Void, Never>] = [:]
    private let defaults: UserDefaults

    private enum Keys {
        static let users = "telegram.pairedUsers", enabled = "telegram.enabled", offset = "telegram.offset"
    }

    init(engine: AgentEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        let users = defaults.data(forKey: Keys.users).flatMap { try? JSONDecoder().decode([TelegramPairing.PairedUser].self, from: $0) } ?? []
        pairing = TelegramPairing(users: users)
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled); newValue ? start() : stop() }
    }

    static var hasToken: Bool { KeychainStore.exists(account: TelegramHTTPTransport.keychainAccount) }

    static func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TelegramHTTPTransport.looksLikeToken(trimmed) else {
            throw TelegramError.api(code: 0, description: "That doesn't look like a bot token (it looks like 123456789:AA…).")
        }
        try KeychainStore.save(trimmed, account: TelegramHTTPTransport.keychainAccount)
    }

    static func deleteToken() { try? KeychainStore.delete(account: TelegramHTTPTransport.keychainAccount) }

    // MARK: Lifecycle

    func startIfEnabled() { if isEnabled { start() } }

    func start() {
        stop()
        guard let transport = transportFactory() else { status = .error(TelegramError.noToken.localizedDescription); return }
        self.transport = transport
        attachObserver()
        status = .connecting
        poller = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() {
        poller?.cancel()
        poller = nil
        transport = nil
        status = .off
    }

    /// Settings → Test: calls getMe with the saved token.
    func test() async -> String {
        guard let transport = transportFactory() else { return TelegramError.noToken.localizedDescription }
        do {
            let me = try await transport.call("getMe", [:]) as? [String: Any]
            let name = me?["username"] as? String ?? "?"
            botUsername = name
            return "Connected to @\(name)."
        } catch {
            return AgentRedactor.redact(error.localizedDescription)
        }
    }

    /// Used by tests (with a mock transport) to process updates without polling.
    func attach(transport: TelegramTransport) {
        self.transport = transport
        attachObserver()
        status = .online
    }

    private func attachObserver() {
        guard observerID == nil else { return }
        observerID = engine.addObserver { [weak self] update in self?.engineChanged(update) }
    }

    private func pollLoop() async {
        var offset = defaults.integer(forKey: Keys.offset)
        var backoff: UInt64 = 2
        if let me = try? await transport?.call("getMe", [:]) as? [String: Any] { botUsername = me["username"] as? String ?? "" }
        while !Task.isCancelled, let transport {
            do {
                let result = try await transport.call("getUpdates", ["offset": offset, "timeout": 25, "allowed_updates": ["message", "callback_query"]])
                status = .online
                backoff = 2
                for raw in result as? [[String: Any]] ?? [] {
                    if let id = raw["update_id"] as? Int { offset = max(offset, id + 1); defaults.set(offset, forKey: Keys.offset) }
                    if let update = TelegramIncoming.parse(raw) { await handle(update) }
                }
            } catch {
                if Task.isCancelled { break }
                status = .error(AgentRedactor.redact(error.localizedDescription))
                try? await Task.sleep(for: .seconds(Double(backoff)))
                backoff = min(60, backoff * 2)
            }
        }
    }

    // MARK: Pairing (Mac side)

    func newPairingCode() -> String {
        let code = pairing.newCode(now: now())
        engine.audit("Telegram: pairing code created (valid 5 minutes)")
        return code
    }

    func cancelPairingCode() { pairing.cancelCode() }

    func removeUser(_ userID: Int64) {
        pairing.remove(userID: userID)
        saveUsers()
        engine.audit("Telegram: removed paired user \(userID)")
    }

    private func saveUsers() {
        if let data = try? JSONEncoder().encode(pairing.users) { defaults.set(data, forKey: Keys.users) }
    }

    // MARK: Incoming

    func handle(_ update: TelegramIncoming) async {
        guard limiter.allow(update.userID, now: now()) else {
            if case .callback(let id, _, _) = update.kind { await answerCallback(id, "Slow down a little.") }
            return
        }
        switch update.kind {
        case let .callback(id, data, _):
            await handleCallback(update, callbackID: id, data: data)
        case let .message(text, _):
            await handleMessage(update, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func handleMessage(_ update: TelegramIncoming, text: String) async {
        let chat = update.chatID
        guard update.chatType == "private" else {
            await send(chat, "MacPilot only works in a private chat with the bot.")
            return
        }
        let (command, argument) = Self.split(text)
        if command == "/pair" {
            switch pairing.redeem(argument, userID: update.userID, chatID: chat, chatType: update.chatType, isBot: update.isBot, name: update.name, now: now()) {
            case .paired(let user):
                saveUsers()
                engine.audit("Telegram: paired user \(user.userID)")
                await send(chat, "Paired with MacPilot. Send a request to start an agent task, or /help.")
            case .rejected(let reason):
                engine.audit("Telegram: pairing rejected for user \(update.userID): \(reason)", kind: .policy)
                await send(chat, reason)
            }
            return
        }
        guard pairing.isPaired(userID: update.userID, chatID: chat) else {
            engine.audit("Telegram: rejected message from unpaired user \(update.userID)", kind: .policy)
            await send(chat, command == "/start" ? Self.startText(paired: false)
                       : "This bot is private to its Mac. Pair first: send /start to see how.")
            return
        }
        switch command {
        case "/start": await send(chat, Self.startText(paired: true))
        case "/help": await send(chat, Self.helpText)
        case "/status": await send(chat, statusText())
        case "/tasks": await send(chat, tasksText())
        case "/model": await send(chat, modelText())
        case "/cancel": await cancel(argument, chat: chat)
        case "/screenshot": await screenshot(update)
        case "/approve", "/deny": await decideByCommand(argument, approve: command == "/approve", update: update)
        case "/jobs": await listJobs(chat)
        case "/newjob": await createJob(argument, update: update)
        case _ where command.hasPrefix("/"): await send(chat, "Unknown command. /help lists what I can do.")
        default: await startTask(text, update: update)
        }
    }

    static func split(_ text: String) -> (String, String) {
        guard text.hasPrefix("/") else { return ("", text) }
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        // "/status@MyBot" → "/status"
        let command = parts[0].split(separator: "@").first.map(String.init)?.lowercased() ?? parts[0]
        return (command, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
    }

    // MARK: Commands

    static func startText(paired: Bool) -> String {
        paired ? "You're paired with this Mac. Send a request to start an agent task, or /help for commands." : """
        This bot controls MacPilot on one Mac and only answers people paired with it.
        To pair: on the Mac open MacPilot → Settings → Agent → Telegram → “Pair a phone”, then send /pair followed by the code shown (it works once and expires in 5 minutes).
        """
    }

    static let helpText = """
    Send any request to start an agent task (it runs on your Mac with the same rules as in the app; risky steps ask you first).
    /status — active task, queue, connection, screen lock
    /tasks — recent tasks
    /jobs — scheduled jobs (pause, resume, run now)
    /newjob <words> — e.g. “/newjob find remote iOS jobs every weekday at 9 email me at me@example.com”
    /cancel <id> — stop a task
    /model — provider and model in use
    /screenshot — picture of the main screen (MacPilot's own windows hidden)
    /approve <id>, /deny <id> — answer an approval
    Privacy: Telegram is cloud messaging, not end-to-end encrypted. What you send and what MacPilot replies (task summaries, screenshots) passes through Telegram's servers. Secrets are removed from replies, but avoid sending sensitive data.
    """

    private func statusText() -> String {
        let active = engine.activeTaskID.flatMap(engine.fetchTask)
        var lines = ["MacPilot is online."]
        lines.append(active.map { "Active: \($0.shortID) — \($0.state.label), step \($0.steps): \($0.title)" } ?? "No active task.")
        lines.append("Queued: \(engine.queuedCount)")
        if engine.isHalted { lines.append("Kill switch is ON — nothing will run until it's resumed on the Mac.") }
        let network = NetworkMonitor.shared
        lines.append("Network: " + (network.interfaceDisplayName.isEmpty ? "unknown" : network.interfaceDisplayName))
        lines.append("Screen: " + (screen.isScreenLocked ? "locked" : "unlocked"))
        lines.append("Session: \(engine.session.statusText)" + (engine.session.isAvailable ? "" : " — GUI and browser steps are paused"))
        return lines.joined(separator: "\n")
    }

    private func tasksText() -> String {
        let tasks = engine.recentTasks(limit: 8)
        guard !tasks.isEmpty else { return "No tasks yet." }
        return tasks.map { "\($0.shortID) · \($0.state.label) · \($0.title.prefix(60))" }.joined(separator: "\n")
    }

    private func modelText() -> String {
        let settings = engine.settingsProvider()
        return "Provider: \(settings.provider.displayName)\nModel: \(settings.model)" + (settings.localOnly ? "\nLocal-only mode: on" : "")
    }

    private func cancel(_ argument: String, chat: Int64) async {
        let id = argument.lowercased()
        guard id.count >= 4, let task = engine.recentTasks(limit: 200).first(where: { $0.shortID.hasPrefix(id) }) else {
            await send(chat, "Which task? Use /tasks to see IDs, then /cancel <id>.")
            return
        }
        guard !task.state.isFinished else { await send(chat, "Task \(task.shortID) already finished (\(task.state.label))."); return }
        engine.stop(task.uid)
        engine.audit("Telegram: cancel requested for task \(task.shortID)")
        await send(chat, "Stopping task \(task.shortID).")
    }

    private func screenshot(_ update: TelegramIncoming) async {
        let chat = update.chatID
        guard pairing.isPaired(userID: update.userID, chatID: chat) else { return }
        if engine.isHalted {
            await send(chat, "The kill switch is on, so screenshots are off too.")
            return
        }
        if screen.isScreenLocked {
            engine.audit("Telegram: screenshot refused (screen locked) for user \(update.userID)", kind: .policy)
            await send(chat, "The Mac's screen is locked, so I won't take a screenshot.")
            return
        }
        guard screen.hasPermission else {
            engine.audit("Telegram: screenshot refused (no Screen Recording permission)", kind: .policy)
            await send(chat, "MacPilot doesn't have Screen Recording permission. On the Mac: System Settings → Privacy & Security → Screen & System Audio Recording → turn on MacPilot.")
            return
        }
        do {
            let jpeg = try await screen.captureMainDisplay()
            try await transport?.sendPhoto(chatID: chat, jpeg: jpeg, caption: "Main display · \(now().formatted(date: .omitted, time: .shortened))")
            engine.audit("Telegram: screenshot sent to user \(update.userID) (\(jpeg.count / 1024) KB)")
        } catch {
            engine.audit("Telegram: screenshot failed: \(error.localizedDescription)", kind: .error)
            await send(chat, "Couldn't take the screenshot: \(error.localizedDescription)")
        }
    }

    // MARK: Tasks from chat

    private func startTask(_ text: String, update: TelegramIncoming) async {
        guard !text.isEmpty else { return }
        if engine.isHalted {
            await send(update.chatID, "The kill switch is on, so I can't start tasks. Resume the agent on the Mac first.")
            return
        }
        let task = engine.submit(text, channel: "telegram", telegramUserID: update.userID, telegramChatID: update.chatID)
        // Reply right away with the ID; this message is edited as the task progresses.
        if let message = try? await transport?.call("sendMessage", ["chat_id": update.chatID, "text": progressText(task)]) as? [String: Any],
           let id = message["message_id"] as? Int {
            task.telegramMessageID = id
            try? engine.context.save()
        }
    }

    private func progressText(_ task: AgentTask) -> String {
        var lines = ["Task \(task.shortID) — \(task.state.label)"]
        if task.steps > 0 { lines.append("Step \(task.steps) · " + String(format: "≈$%.3f", task.costUSD)) }
        if let last = engine.fetchActions(taskID: task.uid).last { lines.append("Last: \(last.summary.isEmpty ? last.tool : last.summary) — \(last.state.label)") }
        if task.state == .queued { lines.append("Use /cancel \(task.shortID) to stop it.") }
        return lines.joined(separator: "\n")
    }

    private func engineChanged(_ update: AgentEngine.Update) {
        switch update {
        case .taskChanged(let id), .actionFinished(_, let id):
            guard let task = engine.fetchTask(id), task.channel == "telegram" else { return }
            if task.state.isFinished { Task { await finished(task) } } else { scheduleProgress(task) }
        case let .approvalRequested(approvalID, taskID):
            guard let task = engine.fetchTask(taskID), task.channel == "telegram" else { return }
            Task { await requestApproval(approvalID, task: task) }
        case let .approvalResolved(approvalID, decision):
            Task { await closeTicket(approvalID, note: decision == .approved ? "Approved" : decision == .expired ? "Expired" : "Denied") }
        }
    }

    /// One edit per `progressInterval` at most; later changes are folded into the next edit.
    private func scheduleProgress(_ task: AgentTask) {
        guard task.telegramMessageID != 0, pendingProgress[task.uid] == nil else { return }
        let wait = max(0, progressInterval - now().timeIntervalSince(lastProgressEdit[task.uid] ?? .distantPast))
        let id = task.uid
        pendingProgress[id] = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, let task = self.engine.fetchTask(id) else { return }
            self.pendingProgress[id] = nil
            self.lastProgressEdit[id] = self.now()
            _ = try? await self.transport?.call("editMessageText", ["chat_id": task.telegramChatID, "message_id": task.telegramMessageID,
                                                                   "text": AgentRedactor.redact(self.progressText(task))])
        }
    }

    private func finished(_ task: AgentTask) async {
        pendingProgress.removeValue(forKey: task.uid)?.cancel()
        if task.telegramMessageID != 0 {
            _ = try? await transport?.call("editMessageText", ["chat_id": task.telegramChatID, "message_id": task.telegramMessageID,
                                                              "text": AgentRedactor.redact(progressText(task))])
        }
        await send(task.telegramChatID, Self.finalText(task, events: engine.events(for: task.uid)))
    }

    static func finalText(_ task: AgentTask, events: [AgentEvent]) -> String {
        var text = "Task \(task.shortID) — \(task.state.label)\n"
        if !task.finalAnswer.isEmpty { text += "\n" + String(task.finalAnswer.prefix(2_500)) + "\n" }
        if let error = task.errorMessage, task.state != .done { text += "\n" + error + "\n" }
        let log = events.filter { $0.kind != .cost }.suffix(8).map { "• " + String($0.message.prefix(160)) }
        if !log.isEmpty { text += "\nLog:\n" + log.joined(separator: "\n") }
        text += String(format: "\n\n%d steps · %d tokens · ≈$%.3f", task.steps, task.inputTokens + task.outputTokens, task.costUSD)
        return AgentRedactor.redact(text)
    }

    // MARK: Approvals

    private func requestApproval(_ approvalID: UUID, task: AgentTask) async {
        guard let approval = engine.fetchApproval(approvalID),
              let action = engine.fetchActions(taskID: task.uid).first(where: { $0.uid == approval.actionID }) else { return }
        var ticket = TelegramApprovalTicket(approvalID: approvalID, taskID: task.uid, actionHash: approval.actionHash,
                                            userID: task.telegramUserID, chatID: task.telegramChatID,
                                            nonce: TelegramRandom.string(length: 10, alphabet: Array("abcdefghijkmnpqrstuvwxyz23456789")),
                                            expiresAt: approval.expiresAt)
        let text = AgentRedactor.redact("""
        Approve? (\(action.risk.label), task \(task.shortID))
        \(action.summary)

        \(String(action.preview.prefix(1_500)))

        Expires in 10 minutes. Or reply /approve \(ticket.shortID) or /deny \(ticket.shortID).
        """)
        let keyboard: [String: Any] = ["inline_keyboard": [[["text": "✅ Approve once", "callback_data": ticket.callbackData(approve: true)],
                                                            ["text": "✖️ Deny", "callback_data": ticket.callbackData(approve: false)]]]]
        tickets[approvalID] = ticket
        if let message = try? await transport?.call("sendMessage", ["chat_id": ticket.chatID, "text": String(text.prefix(4_000)), "reply_markup": keyboard]) as? [String: Any] {
            ticket.messageID = message["message_id"] as? Int ?? 0
            if tickets[approvalID] != nil { tickets[approvalID] = ticket }
        }
    }

    private func handleCallback(_ update: TelegramIncoming, callbackID: String, data: String) async {
        guard pairing.isPaired(userID: update.userID, chatID: update.chatID) else {
            engine.audit("Telegram: rejected button press from unpaired user \(update.userID)", kind: .policy)
            await answerCallback(callbackID, "Not paired with this Mac.")
            return
        }
        if data.hasPrefix("j:") {
            await answerCallback(callbackID, jobButton(data, update: update))
            return
        }
        guard let parsed = TelegramApprovalTicket.parseCallback(data),
              let ticket = tickets.values.first(where: { $0.approvalHex == parsed.approvalHex }) else {
            await answerCallback(callbackID, "This approval is no longer open.")
            return
        }
        let message = decide(ticket, approve: parsed.approve, fromUser: update.userID, nonce: parsed.nonce)
        await answerCallback(callbackID, message)
    }

    private func decideByCommand(_ argument: String, approve: Bool, update: TelegramIncoming) async {
        let id = argument.lowercased()
        guard id.count >= 4, let ticket = tickets.values.first(where: { $0.shortID.hasPrefix(id) }) else {
            await send(update.chatID, "No open approval with that ID.")
            return
        }
        await send(update.chatID, decide(ticket, approve: approve, fromUser: update.userID, nonce: nil))
    }

    /// Checks the ticket (user, nonce, digest, expiry, single use), then answers the engine.
    private func decide(_ ticket: TelegramApprovalTicket, approve: Bool, fromUser: Int64, nonce: String?) -> String {
        let approval = engine.fetchApproval(ticket.approvalID)
        switch ticket.check(fromUser: fromUser, nonce: nonce, approval: approval, now: now()) {
        case .rejected(let reason):
            engine.audit("Telegram: approval rejected for user \(fromUser): \(reason)", kind: .policy)
            return reason
        case .ok:
            tickets[ticket.approvalID]?.used = true
            engine.decide(approvalID: ticket.approvalID, approve: approve, via: "Telegram user \(fromUser)")
            return approve ? "Approved once." : "Denied — nothing was run."
        }
    }

    /// Removes the buttons once the approval is answered or expires.
    private func closeTicket(_ approvalID: UUID, note: String) async {
        guard let ticket = tickets.removeValue(forKey: approvalID), ticket.messageID != 0 else { return }
        _ = try? await transport?.call("editMessageReplyMarkup", ["chat_id": ticket.chatID, "message_id": ticket.messageID,
                                                                 "reply_markup": ["inline_keyboard": [[String: Any]]()]])
        await send(ticket.chatID, "\(note): approval \(ticket.shortID).")
    }

    // MARK: Jobs

    struct JobTicket: Equatable {
        var jobID: UUID
        var userID: Int64
        var digest: String
        var expiresAt: Date
    }
    /// Telegram "Approve sending" buttons for jobs created in chat, by nonce.
    private(set) var jobTickets: [String: JobTicket] = [:]
    /// Overridable for tests.
    var jobScheduler: JobScheduler = .shared

    static func hex(_ id: UUID) -> String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    private func listJobs(_ chat: Int64) async {
        let jobs = jobScheduler.jobs
        guard !jobs.isEmpty else {
            await send(chat, "No scheduled jobs. Create one in MacPilot → Agent → Jobs, or with /newjob.")
            return
        }
        for job in jobs.prefix(15) {
            let text = "\(job.enabled ? "▶️" : "⏸") \(job.name) — \(job.schedule.summary)" +
                (job.nextRun.map { "\nNext: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "") +
                (job.wantsEmail ? "\nEmails \(job.recipient)" + (JobSendApproval.isApproved(job) ? "" : " (not approved yet)") : "")
            let keyboard: [String: Any] = ["inline_keyboard": [[
                ["text": job.enabled ? "Pause" : "Resume", "callback_data": "j:p:\(Self.hex(job.uid))"],
                ["text": "Run now", "callback_data": "j:r:\(Self.hex(job.uid))"]
            ]]]
            _ = try? await transport?.call("sendMessage", ["chat_id": chat, "text": AgentRedactor.redact(text), "reply_markup": keyboard])
        }
    }

    /// "/newjob find remote iOS jobs every weekday at 9 email me at me@x.com" → a job draft.
    static func jobDraft(from words: String, timeZone: TimeZone = .current) -> AgentJob? {
        guard let schedule = ScheduleParser.parse(words, timeZone: timeZone) else { return nil }
        let lower = words.lowercased()
        let isFinder = lower.range(of: #"\b(jobs?|roles?|openings|positions|postings)\b"#, options: .regularExpression) != nil
            && lower.range(of: #"\b(find|search|look|watch|new)\b"#, options: .regularExpression) != nil
        let job = AgentJob(name: String(words.prefix(40)), template: isFinder ? .jobFinder : .custom, prompt: words, schedule: schedule)
        if isFinder {
            var config = JobFinderConfig()
            if let match = lower.range(of: #"(?:find|search for|look for|watch for)\s+(.+?)\s+(?:jobs?|roles?|openings|positions|postings)\b"#, options: .regularExpression) {
                let phrase = String(lower[match]).replacingOccurrences(of: #"^(find|search for|look for|watch for)\s+|\s+(jobs?|roles?|openings|positions|postings)$"#,
                                                                       with: "", options: .regularExpression)
                let filler: Set<String> = ["remote", "senior", "junior", "lead", "staff", "new", "the", "some", "any", "for", "me"]
                let kept = phrase.split(separator: " ").map(String.init).filter { !filler.contains($0) }
                if !kept.isEmpty { config.keywords = [kept.joined(separator: " ")] }
                if phrase.contains("senior") { config.level = .senior }
                if phrase.contains("staff") || phrase.contains("lead") { config.level = .lead }
                if phrase.contains("junior") { config.level = .entry }
            }
            if lower.contains("remote") { config.remoteOnly = true }
            job.finder = config
            job.name = "Job finder: " + config.keywords.joined(separator: ", ")
        }
        // Only an address the user typed in this message.
        if let address = EmailAddress.all(in: words).first {
            job.recipient = address
            job.sender = .mailApp
        }
        return job
    }

    private func createJob(_ words: String, update: TelegramIncoming) async {
        let chat = update.chatID
        guard let job = Self.jobDraft(from: words) else {
            await send(chat, "I couldn't find a schedule. Try: /newjob find remote iOS jobs every weekday at 9 email me at me@example.com")
            return
        }
        job.notifyTelegram = !job.wantsEmail
        jobScheduler.add(job)
        engine.audit("Telegram: user \(update.userID) created job “\(job.name)”")
        var text = "Created job \(job.shortID): \(job.name)\n\(job.schedule.summary) (\(job.schedule.timeZone.identifier))"
        if job.template == .jobFinder { text += "\nKeywords: \(job.finder.keywords.joined(separator: ", "))\(job.finder.remoteOnly ? " · remote only" : "")" }
        guard job.wantsEmail else {
            await send(chat, text + "\nResults will be posted here and shown in the app. Fine-tune it on the Mac in Agent → Jobs.")
            return
        }
        let sample = JobScheduler.sampleEmail(for: job)
        let nonce = TelegramRandom.string(length: 10, alphabet: Array("abcdefghijkmnpqrstuvwxyz23456789"))
        jobTickets[nonce] = JobTicket(jobID: job.uid, userID: update.userID,
                                      digest: JobSendApproval.digest(jobID: job.uid, recipient: job.recipient, sender: job.sender, account: job.senderAccount),
                                      expiresAt: now().addingTimeInterval(AgentPolicy.approvalLifetime))
        text += "\n\nIt will email \(job.recipient) from the Mail app. Sample:\nSubject: \(sample.subject)\n\n\(sample.text.prefix(1_200))\n\nApprove sending once (valid 10 minutes):"
        let keyboard: [String: Any] = ["inline_keyboard": [[["text": "✅ Approve sending", "callback_data": "j:a:\(Self.hex(job.uid)):\(nonce)"]]]]
        _ = try? await transport?.call("sendMessage", ["chat_id": chat, "text": String(AgentRedactor.redact(text).prefix(4_000)), "reply_markup": keyboard])
    }

    /// Pause/Resume, Run now and Approve sending buttons on job messages.
    private func jobButton(_ data: String, update: TelegramIncoming) -> String {
        let parts = data.split(separator: ":").map(String.init)
        guard parts.count >= 3, let job = jobScheduler.jobs.first(where: { Self.hex($0.uid) == parts[2] }) else { return "That job no longer exists." }
        switch parts[1] {
        case "p":
            jobScheduler.setEnabled(job, !job.enabled)
            engine.audit("Telegram: user \(update.userID) \(job.enabled ? "resumed" : "paused") job “\(job.name)”")
            return job.enabled ? "Resumed \(job.name)." : "Paused \(job.name)."
        case "r":
            if engine.isHalted { return "The kill switch is on." }
            jobScheduler.run(job, reason: "run from Telegram")
            engine.audit("Telegram: user \(update.userID) ran job “\(job.name)”")
            return "Running \(job.name)…"
        case "a":
            guard parts.count == 4, let ticket = jobTickets[parts[3]], ticket.jobID == job.uid else { return "These buttons are out of date." }
            guard ticket.userID == update.userID else { return "Only the person who created this job can approve it." }
            guard now() < ticket.expiresAt else { jobTickets[parts[3]] = nil; return "This approval expired (10 minutes)." }
            guard ticket.digest == JobSendApproval.digest(jobID: job.uid, recipient: job.recipient, sender: job.sender, account: job.senderAccount) else {
                return "The recipient or sender changed. Approve it again on the Mac."
            }
            jobTickets[parts[3]] = nil
            jobScheduler.approveSending(job, via: "Telegram (user \(update.userID))")
            return "Approved: \(job.name) may email \(job.recipient)."
        default:
            return "Unknown button."
        }
    }

    /// Posts a finished run to paired users when the job asks for it.
    func jobFinished(_ job: AgentJob, run: JobRun) {
        guard job.notifyTelegram, transport != nil else { return }
        var text = "Job \(job.name) — \(AgentTaskState(rawValue: run.statusRaw)?.label ?? run.statusRaw)\n\(run.summary)"
        for posting in run.results.prefix(15) { text += "\n• \(posting.company): \(posting.title) — \(posting.url)" }
        if run.results.count > 15 { text += "\n…and \(run.results.count - 15) more in the app." }
        for user in pairing.users { Task { await send(user.chatID, text) } }
    }

    // MARK: Sending

    private func send(_ chatID: Int64, _ text: String) async {
        guard chatID != 0 else { return }
        _ = try? await transport?.call("sendMessage", ["chat_id": chatID, "text": String(AgentRedactor.redact(text).prefix(4_000))])
    }

    private func answerCallback(_ id: String, _ text: String) async {
        _ = try? await transport?.call("answerCallbackQuery", ["callback_query_id": id, "text": String(AgentRedactor.redact(text).prefix(190))])
    }
}
