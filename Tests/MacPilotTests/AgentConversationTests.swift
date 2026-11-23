import SwiftData
import XCTest
@testable import MacPilot

@MainActor
final class AgentConversationTests: XCTestCase {
    private var container: ModelContainer!

    private func engine(_ adapter: ScriptedAdapter) throws -> AgentEngine {
        container = try ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = AgentEngine(context: container.mainContext, defaults: UserDefaults(suiteName: "chat-\(UUID().uuidString)")!)
        engine.recordUsage = { _, _, _ in }
        var settings = AgentSettings()
        settings.provider = .anthropic
        engine.settingsProvider = { settings }
        engine.adapterFactory = { _, _ in adapter }
        return engine
    }

    private func answer(_ text: String) -> AgentModelResponse {
        AgentModelResponse(text: text, calls: [], inputTokens: 10, outputTokens: 5, stop: .done)
    }

    private func texts(_ messages: [AgentMessage]) -> [String] {
        messages.map {
            switch $0 {
            case .user(let text): return "user: " + text
            case let .assistant(text, _, _): return "assistant: " + text
            case .toolResults: return "tools"
            }
        }
    }

    func testFollowUpAppendsToTheSameChatWithHistory() async throws {
        let adapter = ScriptedAdapter(turns: [answer("There are 3 TODOs."), answer("Done: wrote TODO.md.")])
        let engine = try engine(adapter)
        let first = engine.submit("Find TODOs in my project")
        await engine.waitUntilIdle()
        let second = engine.submit("Now write them to TODO.md", conversation: first.conversationKey)
        await engine.waitUntilIdle()

        XCTAssertEqual(second.conversationKey, first.uid, "the follow-up joins the first message's chat")
        XCTAssertEqual(AgentChat.group(engine.fetchConversation(first.uid)).count, 1)
        XCTAssertEqual(engine.fetchConversation(first.uid).map(\.uid), [first.uid, second.uid])
        let sent = try XCTUnwrap(adapter.seenMessages.last)
        XCTAssertEqual(texts(sent), ["user: Find TODOs in my project", "assistant: There are 3 TODOs.", "user: Now write them to TODO.md"],
                       "the model sees the earlier messages")
        XCTAssertEqual(texts(adapter.seenMessages[0]), ["user: Find TODOs in my project"], "the first message has no history")
        withExtendedLifetime(container) {}
    }

    func testNewChatIsSeparate() async throws {
        let adapter = ScriptedAdapter(turns: [answer("A"), answer("B")])
        let engine = try engine(adapter)
        let first = engine.submit("one")
        await engine.waitUntilIdle()
        let other = engine.submit("two")
        await engine.waitUntilIdle()
        XCTAssertNotEqual(other.conversationKey, first.conversationKey)
        XCTAssertEqual(texts(adapter.seenMessages[1]), ["user: two"], "a new chat carries no history")
        XCTAssertEqual(AgentChat.group([first, other]).count, 2)
        withExtendedLifetime(container) {}
    }

    func testRetryRunsTheLastTurnAgainInTheSameChat() async throws {
        let adapter = ScriptedAdapter(turns: [answer("first"), answer("second try")])
        let engine = try engine(adapter)
        let first = engine.submit("hello")
        await engine.waitUntilIdle()
        let retry = engine.retry(first)
        await engine.waitUntilIdle()
        XCTAssertEqual(retry.conversationKey, first.conversationKey)
        XCTAssertEqual(texts(adapter.seenMessages[1]), ["user: hello"], "the retried turn isn't given to the model as history")
        withExtendedLifetime(container) {}
    }

    func testToolCallsAndErrorsAreGivenAsContext() {
        let history = [AgentTurnContext(prompt: "list files", actions: ["list_dir . — Succeeded: a.txt b.txt"], answer: "Two files.", error: nil),
                       AgentTurnContext(prompt: "delete a.txt", actions: [], answer: "", error: "Denied by you")]
        let messages = AgentConversationContext.messages(history: history, current: "ok, read b.txt")
        XCTAssertEqual(texts(messages), ["user: list files", "assistant: Tools used:\n- list_dir . — Succeeded: a.txt b.txt\n\nTwo files.",
                                         "user: delete a.txt", "assistant: (This turn ended with: Denied by you)", "user: ok, read b.txt"])
    }

    func testTrimmingKeepsTheLatestTurns() {
        let history = (1...10).map { AgentTurnContext(prompt: "question \($0) " + String(repeating: "x", count: 100), actions: [], answer: "answer \($0)", error: nil) }
        let messages = AgentConversationContext.messages(history: history, current: "latest", budget: 400)
        let lines = texts(messages)
        XCTAssertEqual(lines.last, "user: latest", "the new message is always sent")
        XCTAssertTrue(lines.contains { $0.contains("question 10") }, "the newest turns are kept")
        XCTAssertFalse(lines.contains { $0.contains("question 1 ") }, "the oldest are dropped")
        XCTAssertTrue(lines.first?.contains("earlier messages in this chat omitted") == true)
        XCTAssertLessThan(lines.joined().count, 600)
        // Nothing fits: just the new message, with the note.
        XCTAssertEqual(texts(AgentConversationContext.messages(history: history, current: "q", budget: 10)),
                       ["user: (10 earlier messages in this chat omitted.)\n\nq"])
    }

    func testOldTasksAreSingleTurnChats() throws {
        container = try ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        // Tasks saved before chats existed have no conversation ID.
        let a = AgentTask(prompt: "old one", provider: .anthropic, model: "m")
        let b = AgentTask(prompt: "old two", provider: .anthropic, model: "m")
        b.createdAt = a.createdAt.addingTimeInterval(60)
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        let chats = AgentChat.group([a, b])
        XCTAssertEqual(chats.map(\.id), [b.uid, a.uid], "each is its own chat, newest first")
        XCTAssertEqual(chats.map(\.title), ["old two", "old one"])
        a.conversationTitle = "Renamed"
        XCTAssertEqual(AgentChat.group([a]).first?.title, "Renamed")
    }

    func testSelectionIsStableWhenTasksFinish() async throws {
        let adapter = ScriptedAdapter(turns: [answer("A"), answer("B")])
        let engine = try engine(adapter)
        let chat = engine.submit("in this chat")
        await engine.waitUntilIdle()
        let selected = chat.conversationKey
        // Another chat (e.g. from Telegram or a job) starts and finishes.
        _ = engine.submit("somewhere else", channel: "telegram")
        await engine.waitUntilIdle()
        let chats = AgentChat.group(engine.fetchConversation(selected) + [])
        XCTAssertTrue(chats.contains { $0.id == selected }, "the selected chat still exists with the same id")
        XCTAssertEqual(chat.conversationKey, selected, "a finished task keeps its chat")
        // The Agent view no longer follows engine.activeTaskID, so nothing moves the selection.
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/MacPilotTests/AgentConversationTests.swift",
                                                                                  with: "Sources/MacPilot/Views/Agent/AgentView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("onChange(of: engine.activeTaskID)"), "the view must not jump to whichever task is running")
        withExtendedLifetime(container) {}
    }

    // MARK: Telegram

    func testTelegramContinuationNewAndIdleCutoff() {
        var chats = TelegramConversations()
        let start = Date()
        XCTAssertNil(chats.conversation(for: 1, now: start))
        let id = UUID()
        chats.touch(1, conversation: id, now: start)
        XCTAssertEqual(chats.conversation(for: 1, now: start.addingTimeInterval(29 * 60)), id, "continues within 30 minutes")
        XCTAssertNil(chats.conversation(for: 2, now: start), "per user")
        XCTAssertNil(chats.conversation(for: 1, now: start.addingTimeInterval(31 * 60)), "30 minutes idle starts fresh")
        chats.touch(1, conversation: id, now: start)
        chats.reset(1)
        XCTAssertNil(chats.conversation(for: 1, now: start), "/new starts fresh")
    }

    func testTelegramMessagesContinueTheChat() async throws {
        let adapter = ScriptedAdapter(turns: [answer("A"), answer("B"), answer("C")])
        let engine = try engine(adapter)
        let bot = TelegramBot(engine: engine, defaults: UserDefaults(suiteName: "chat-tg-\(UUID().uuidString)")!)
        let api = MockBotAPI()
        bot.attach(transport: api)
        let code = bot.newPairingCode()
        func message(_ text: String) -> TelegramIncoming {
            TelegramIncoming(updateID: Int.random(in: 10...999_999), userID: 7, chatID: 7, chatType: "private", isBot: false, name: "", kind: .message(text: text, messageID: 2))
        }
        await bot.handle(message("/pair \(code)"))
        await bot.handle(message("first question"))
        await engine.waitUntilIdle()
        await bot.handle(message("follow up"))
        await engine.waitUntilIdle()
        await bot.handle(message("/new"))
        XCTAssertTrue(api.sentTexts.contains { $0.contains("New chat started") })
        await bot.handle(message("fresh start"))
        await engine.waitUntilIdle()
        let tasks = try container.mainContext.fetch(FetchDescriptor<AgentTask>(sortBy: [SortDescriptor(\.createdAt)]))
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[1].conversationKey, tasks[0].uid, "the second message continues the chat")
        XCTAssertNotEqual(tasks[2].conversationKey, tasks[0].uid, "/new starts a new one")
        XCTAssertEqual(texts(adapter.seenMessages[1]).first, "user: first question")
        withExtendedLifetime(container) {}
    }
}
