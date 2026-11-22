import Foundation
import SwiftData
import XCTest
@testable import MacPilot

/// Records every Bot API call and returns plausible results.
final class MockBotAPI: TelegramTransport {
    struct Call { var method: String; var params: [String: Any] }
    private(set) var calls: [Call] = []
    private(set) var photos: [(chatID: Int64, bytes: Int)] = []
    private var nextMessageID = 100

    func call(_ method: String, _ params: [String: Any]) async throws -> Any {
        calls.append(Call(method: method, params: params))
        switch method {
        case "getMe": return ["id": 1, "is_bot": true, "username": "macpilot_test_bot"]
        case "sendMessage":
            nextMessageID += 1
            return ["message_id": nextMessageID, "chat": ["id": params["chat_id"] ?? 0]]
        default: return true
        }
    }

    func sendPhoto(chatID: Int64, jpeg: Data, caption: String) async throws {
        photos.append((chatID, jpeg.count))
    }

    var sentTexts: [String] { calls.filter { $0.method == "sendMessage" }.compactMap { $0.params["text"] as? String } }
    var lastText: String { sentTexts.last ?? "" }

    func lastKeyboardData() -> [String] {
        guard let markup = calls.last(where: { $0.params["reply_markup"] != nil && $0.method == "sendMessage" })?.params["reply_markup"] as? [String: Any],
              let rows = markup["inline_keyboard"] as? [[[String: Any]]] else { return [] }
        return rows.flatMap { $0 }.compactMap { $0["callback_data"] as? String }
    }
}

struct MockScreen: TelegramScreenSource {
    var isScreenLocked = false
    var hasPermission = true
    func captureMainDisplay() async throws -> Data { Data(repeating: 0xFF, count: 2_048) }
}

@MainActor
final class TelegramTests: XCTestCase {
    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var workspace: URL!
    private let me: Int64 = 424_242
    private let stranger: Int64 = 999_001

    override func setUp() async throws {
        container = try ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        defaults = UserDefaults(suiteName: "telegram-tests-\(UUID().uuidString)")
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func make(turns: [AgentModelResponse] = [], screen: MockScreen = MockScreen()) -> (TelegramBot, MockBotAPI, ScriptedAdapter, AgentEngine) {
        let engine = AgentEngine(context: container.mainContext, defaults: defaults)
        let adapter = ScriptedAdapter(turns: turns)
        var settings = AgentSettings()
        settings.workspaceRoots = [workspace.path]
        settings.model = "test-model"
        engine.settingsProvider = { settings }
        engine.adapterFactory = { _, _ in adapter }
        engine.recordUsage = { _, _, _ in }
        let bot = TelegramBot(engine: engine, defaults: defaults)
        let api = MockBotAPI()
        bot.screen = screen
        bot.progressInterval = 0.05
        bot.attach(transport: api)
        return (bot, api, adapter, engine)
    }

    private var nextUpdate = 1
    private func message(_ text: String, from user: Int64? = nil, chatType: String = "private", chat: Int64? = nil) -> TelegramIncoming {
        nextUpdate += 1
        let user = user ?? me
        return TelegramIncoming(updateID: nextUpdate, userID: user, chatID: chat ?? user, chatType: chatType, isBot: false, name: "Sam",
                                kind: .message(text: text, messageID: nextUpdate))
    }

    private func press(_ data: String, from user: Int64? = nil) -> TelegramIncoming {
        nextUpdate += 1
        let user = user ?? me
        return TelegramIncoming(updateID: nextUpdate, userID: user, chatID: user, chatType: "private", isBot: false, name: "Sam",
                                kind: .callback(id: "cb\(nextUpdate)", data: data, messageID: 1))
    }

    private func pair(_ bot: TelegramBot) async {
        let code = bot.newPairingCode()
        await bot.handle(message("/pair \(code)"))
        XCTAssertTrue(bot.pairing.isPaired(userID: me, chatID: me))
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Pairing

    func testUnpairedSenderIsDeniedAndNoToolRuns() async throws {
        let (bot, api, adapter, engine) = make(turns: [ScriptedAdapter.tool("system_status", [:])])
        await bot.handle(message("list my files", from: stranger))
        await bot.handle(message("/screenshot", from: stranger))
        await bot.handle(message("/tasks", from: stranger))
        XCTAssertTrue(api.sentTexts.allSatisfy { $0.contains("private") || $0.contains("Pair") })
        XCTAssertTrue(api.photos.isEmpty)
        XCTAssertEqual(adapter.calls, 0)
        XCTAssertTrue(engine.recentTasks(limit: 10).isEmpty, "no task was created")
        await bot.handle(press("a:\(String(repeating: "0", count: 32)):nonce", from: stranger))
        XCTAssertTrue(api.calls.contains { $0.method == "answerCallbackQuery" && ($0.params["text"] as? String)?.contains("Not paired") == true })
    }

    func testPairingCodeIsOneTimeAndExpires() async {
        let (bot, api, _, _) = make()
        var clock = Date()
        bot.now = { clock }
        let code = bot.newPairingCode()
        XCTAssertTrue((6...8).contains(code.count))
        await bot.handle(message("/pair \(code)", chatType: "group", chat: -100))
        XCTAssertFalse(bot.pairing.isPaired(userID: me, chatID: -100), "groups can't pair")
        await bot.handle(message("/pair \(code.lowercased())"))
        XCTAssertTrue(bot.pairing.isPaired(userID: me, chatID: me))

        await bot.handle(message("/pair \(code)", from: stranger))
        XCTAssertFalse(bot.pairing.isPaired(userID: stranger, chatID: stranger), "a used code can't be reused")
        XCTAssertTrue(api.lastText.contains("no active pairing code"))

        let second = bot.newPairingCode()
        clock = clock.addingTimeInterval(TelegramPairing.codeLifetime + 1)
        await bot.handle(message("/pair \(second)", from: stranger))
        XCTAssertFalse(bot.pairing.isPaired(userID: stranger, chatID: stranger))
        XCTAssertTrue(api.lastText.contains("expired"))
    }

    func testWrongGuessesBurnTheCode() {
        var pairing = TelegramPairing()
        let code = pairing.newCode()
        for _ in 0..<TelegramPairing.maxAttempts {
            _ = pairing.redeem("WRONG123", userID: 1, chatID: 1, chatType: "private", isBot: false, name: "")
        }
        XCTAssertEqual(pairing.redeem(code, userID: 1, chatID: 1, chatType: "private", isBot: false, name: ""),
                       .rejected("There's no active pairing code. Create one in MacPilot → Settings → Agent → Telegram."))
    }

    func testIdentityIsNumericIDNotUsername() async {
        let (bot, _, _, _) = make()
        await pair(bot)
        XCTAssertFalse(bot.pairing.isPaired(userID: me, chatID: me + 1), "a different chat doesn't count")
        XCTAssertFalse(bot.pairing.isPaired(userID: stranger, chatID: me))
        bot.removeUser(me)
        XCTAssertFalse(bot.pairing.isPaired(userID: me, chatID: me))
    }

    // MARK: Approvals

    private func startDeleteTask(_ bot: TelegramBot, engine: AgentEngine) async throws -> (AgentTask, [String], URL) {
        let file = workspace.appendingPathComponent("doomed.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        await pair(bot)
        await bot.handle(message("delete doomed.txt"))
        let task = try XCTUnwrap(engine.recentTasks(limit: 1).first)
        XCTAssertEqual(task.channel, "telegram")
        await waitFor { task.state == .awaitingApproval && !bot.tickets.isEmpty && bot.tickets.values.first?.messageID != 0 }
        return (task, [], file)
    }

    func testTelegramApprovalFlowAndReplayRejected() async throws {
        let file = workspace.appendingPathComponent("doomed.txt")
        let (bot, api, _, engine) = make(turns: [ScriptedAdapter.tool("delete_file", ["path": file.path])])
        let (task, _, _) = try await startDeleteTask(bot, engine: engine)
        XCTAssertTrue(api.sentTexts.first { $0.contains("Task \(task.shortID)") } != nil, "the task ID is sent right away")
        let buttons = api.lastKeyboardData()
        XCTAssertEqual(buttons.count, 2)
        XCTAssertTrue(buttons.allSatisfy { $0.utf8.count <= 64 })
        let approve = try XCTUnwrap(buttons.first { $0.hasPrefix("a:") })

        await bot.handle(press(approve))
        await engine.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "approved delete ran (to the Trash)")
        XCTAssertTrue(api.calls.contains { $0.method == "editMessageReplyMarkup" }, "buttons removed after the decision")

        // The same button again is rejected and nothing else runs.
        let before = engine.fetchActions(taskID: task.uid).count
        await bot.handle(press(approve))
        XCTAssertTrue(api.calls.last { $0.method == "answerCallbackQuery" }?.params["text"] as? String == "This approval is no longer open.")
        XCTAssertEqual(engine.fetchActions(taskID: task.uid).count, before)
        XCTAssertTrue(api.sentTexts.contains { $0.contains("Task \(task.shortID) — Done") }, "final summary sent")
    }

    func testApprovalFromAnotherPairedUserIsRejected() async throws {
        let file = workspace.appendingPathComponent("doomed.txt")
        let (bot, api, _, engine) = make(turns: [ScriptedAdapter.tool("delete_file", ["path": file.path])])
        _ = try await startDeleteTask(bot, engine: engine)
        // Pair a second person, who tries to approve someone else's task.
        let code = bot.newPairingCode()
        await bot.handle(message("/pair \(code)", from: stranger))
        let approve = try XCTUnwrap(api.lastKeyboardData().first { $0.hasPrefix("a:") })
        await bot.handle(press(approve, from: stranger))
        XCTAssertEqual(api.calls.last { $0.method == "answerCallbackQuery" }?.params["text"] as? String,
                       "Only the person who asked for this task can approve it.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let ticket = try XCTUnwrap(bot.tickets.values.first)
        await bot.handle(message("/approve \(ticket.shortID)", from: stranger))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the command form is checked the same way")
        // A forged nonce is rejected too.
        let forged = String(approve.dropLast(10)) + "zzzzzzzzzz"
        await bot.handle(press(forged))
        XCTAssertEqual(api.calls.last { $0.method == "answerCallbackQuery" }?.params["text"] as? String, "These buttons are out of date.")
        // Deny by command from the right user: nothing runs.
        await bot.handle(message("/deny \(ticket.shortID)"))
        await engine.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testExpiredTelegramApprovalIsRejected() async throws {
        let file = workspace.appendingPathComponent("doomed.txt")
        let (bot, api, _, engine) = make(turns: [ScriptedAdapter.tool("delete_file", ["path": file.path])])
        _ = try await startDeleteTask(bot, engine: engine)
        let approve = try XCTUnwrap(api.lastKeyboardData().first { $0.hasPrefix("a:") })
        bot.now = { Date().addingTimeInterval(11 * 60) }
        await bot.handle(press(approve))
        XCTAssertEqual(api.calls.last { $0.method == "answerCallbackQuery" }?.params["text"] as? String, "This approval expired (10 minutes).")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let task = try XCTUnwrap(engine.recentTasks(limit: 1).first)
        engine.stop(task.uid)
        await engine.waitUntilIdle()
    }

    func testTicketChecks() {
        let approval = AgentApproval(taskID: UUID(), actionID: UUID(), actionHash: "h", risk: .high)
        let ticket = TelegramApprovalTicket(approvalID: approval.uid, taskID: approval.taskID, actionHash: "h", userID: 1, chatID: 1,
                                            nonce: "abc", expiresAt: Date().addingTimeInterval(600))
        XCTAssertEqual(ticket.check(fromUser: 1, nonce: "abc", approval: approval, now: Date()), .ok)
        XCTAssertNotEqual(ticket.check(fromUser: 2, nonce: "abc", approval: approval, now: Date()), .ok)
        approval.actionHash = "changed"
        XCTAssertEqual(ticket.check(fromUser: 1, nonce: "abc", approval: approval, now: Date()),
                       .rejected("The action changed, so this approval no longer applies."))
        var used = ticket
        used.used = true
        XCTAssertEqual(used.check(fromUser: 1, nonce: "abc", approval: approval, now: Date()), .rejected("This approval was already used."))
        XCTAssertNotNil(TelegramApprovalTicket.parseCallback(ticket.callbackData(approve: true)))
        XCTAssertNil(TelegramApprovalTicket.parseCallback("x:1:2"))
    }

    // MARK: Screenshot

    func testScreenshotRefusedWhileLockedOrWithoutPermission() async {
        let (locked, lockedAPI, _, engine) = make(screen: MockScreen(isScreenLocked: true))
        await pair(locked)
        await locked.handle(message("/screenshot"))
        XCTAssertTrue(lockedAPI.photos.isEmpty)
        XCTAssertTrue(lockedAPI.lastText.contains("locked"))

        let (noPermission, api, _, _) = make(screen: MockScreen(hasPermission: false))
        await pair(noPermission)
        await noPermission.handle(message("/screenshot"))
        XCTAssertTrue(api.photos.isEmpty)
        XCTAssertTrue(api.lastText.contains("Screen Recording"))

        let (ok, okAPI, _, _) = make()
        await pair(ok)
        await ok.handle(message("/screenshot"))
        XCTAssertEqual(okAPI.photos.count, 1)
        let audit = engine.events(for: AgentEngine.systemLogID).map(\.message)
        XCTAssertTrue(audit.contains { $0.contains("screenshot refused (screen locked)") })
        XCTAssertTrue(audit.contains { $0.contains("screenshot sent") }, "every capture is audited")
    }

    func testScreenshotDownscaleMath() {
        XCTAssertEqual(SystemScreenSource.fit(width: 5_120, height: 2_880, maxDimension: 2_560).width, 2_560)
        XCTAssertEqual(SystemScreenSource.fit(width: 5_120, height: 2_880, maxDimension: 2_560).height, 1_440)
        XCTAssertEqual(SystemScreenSource.fit(width: 1_000, height: 800, maxDimension: 2_560).width, 1_000)
    }

    // MARK: Commands, limits and secrets

    func testCommands() async {
        let (bot, api, _, _) = make()
        await bot.handle(message("/start"))
        XCTAssertTrue(api.lastText.contains("/pair"))
        await pair(bot)
        await bot.handle(message("/help"))
        XCTAssertTrue(api.lastText.contains("cloud messaging"))
        await bot.handle(message("/status@macpilot_test_bot"))
        XCTAssertTrue(api.lastText.contains("Queued: 0"))
        XCTAssertTrue(api.lastText.contains("Screen: unlocked"))
        await bot.handle(message("/model"))
        XCTAssertTrue(api.lastText.contains("test-model"))
        XCTAssertFalse(api.lastText.lowercased().contains("key"))
        await bot.handle(message("/tasks"))
        XCTAssertEqual(api.lastText, "No tasks yet.")
    }

    func testKillSwitchAppliesToChat() async {
        let (bot, api, adapter, engine) = make()
        await pair(bot)
        engine.killSwitch()
        await bot.handle(message("do something"))
        await bot.handle(message("/screenshot"))
        XCTAssertTrue(api.lastText.contains("kill switch"))
        XCTAssertTrue(api.photos.isEmpty)
        XCTAssertEqual(adapter.calls, 0)
        engine.resume()
    }

    func testRateLimitPerUser() {
        var limiter = TelegramRateLimiter(limit: 3, window: 60)
        let start = Date()
        XCTAssertTrue(limiter.allow(1, now: start))
        XCTAssertTrue(limiter.allow(1, now: start))
        XCTAssertTrue(limiter.allow(1, now: start))
        XCTAssertFalse(limiter.allow(1, now: start))
        XCTAssertTrue(limiter.allow(2, now: start), "per user")
        XCTAssertTrue(limiter.allow(1, now: start.addingTimeInterval(61)))
    }

    func testNoTokenInDatabaseOrMessages() async throws {
        let token = "123456789:AAH" + String(repeating: "x", count: 32)
        XCTAssertTrue(TelegramHTTPTransport.looksLikeToken(token))
        XCTAssertFalse(TelegramHTTPTransport.looksLikeToken("hello"))
        XCTAssertFalse(TelegramError.api(code: -1, description: "could not connect to https://api.telegram.org/bot\(token)/getMe").localizedDescription.contains(token))

        let (bot, api, _, engine) = make(turns: [AgentModelResponse(text: "Here: \(token)", calls: [], inputTokens: 1, outputTokens: 1, stop: .done)])
        await pair(bot)
        await bot.handle(message("my bot token is \(token)"))
        await engine.waitUntilIdle()
        await waitFor { api.sentTexts.contains { $0.contains("Done") } }
        XCTAssertFalse(api.sentTexts.joined().contains(token), "never sent back out")
        var stored: [String] = []
        for task in try container.mainContext.fetch(FetchDescriptor<AgentTask>()) { stored += [task.prompt, task.title, task.finalAnswer] }
        for event in try container.mainContext.fetch(FetchDescriptor<AgentEvent>()) { stored.append(event.message) }
        XCTAssertFalse(stored.joined().contains(token))
        XCTAssertNil(defaults.dictionaryRepresentation().values.first { "\($0)".contains(token) }, "not in settings either")
    }

    func testParsesUpdates() {
        let message = TelegramIncoming.parse(["update_id": 7, "message": ["message_id": 3, "text": "/status",
                                                                         "chat": ["id": 42, "type": "private"],
                                                                         "from": ["id": 42, "is_bot": false, "first_name": "Sam", "username": "sammy"]]])
        XCTAssertEqual(message?.userID, 42)
        XCTAssertEqual(message?.name, "Sam", "the username isn't used")
        let callback = TelegramIncoming.parse(["update_id": 8, "callback_query": ["id": "q", "data": "a:x:y", "from": ["id": 42],
                                                                                   "message": ["message_id": 9, "chat": ["id": 42, "type": "private"]]]])
        XCTAssertEqual(callback?.kind, .callback(id: "q", data: "a:x:y", messageID: 9))
        XCTAssertNil(TelegramIncoming.parse(["update_id": 9, "edited_message": [:]]))
        XCTAssertEqual(TelegramBot.split("/cancel ab12cd34").0, "/cancel")
        XCTAssertEqual(TelegramBot.split("/cancel ab12cd34").1, "ab12cd34")
    }
}
