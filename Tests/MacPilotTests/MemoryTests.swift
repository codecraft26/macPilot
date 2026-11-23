import Foundation
import Network
import SwiftData
import XCTest
@testable import MacPilot

struct MockNode: AXTextNode {
    var role: String
    var title: String = ""
    var value: String = ""
    var subrole: String = ""
    var children: [AXTextNode] = []
}

@MainActor
final class MockWindowReader: FocusedWindowReader {
    var title = "Inbox"
    var root: AXTextNode = MockNode(role: "AXWindow")
    private(set) var reads = 0
    func focusedWindow(pid: pid_t) -> (title: String, root: AXTextNode)? {
        reads += 1
        return (title, root)
    }
}

@MainActor
final class MemoryTests: XCTestCase {
    private var store: MemoryStore!
    private var dbURL: URL!

    override func setUp() async throws {
        dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString).sqlite")
        store = try MemoryStore(url: dbURL)
        store.embedder = nil
    }

    override func tearDown() async throws {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) }
    }

    private func settings(_ change: (inout MemorySettings) -> Void = { _ in }) -> MemorySettings {
        var settings = MemorySettings()
        settings.enabled = true
        settings.allowlist = ["com.apple.mail"]
        change(&settings)
        return settings
    }

    private func capture(app: (String, String) = ("Mail", "com.apple.mail"), settings: MemorySettings, reader: MockWindowReader) -> MemoryCapture {
        let capture = MemoryCapture(store: store)
        capture.settingsProvider = { settings }
        capture.reader = reader
        capture.frontmost = { (app.0, app.1, 42) }
        return capture
    }

    private let mailTree = MockNode(role: "AXWindow", title: "Inbox", children: [
        MockNode(role: "AXStaticText", value: "From: Priya — Could you send me the Q3 deck by Friday?"),
        MockNode(role: "AXSecureTextField", value: "hunter2-SECRET"),
        MockNode(role: "AXTextField", subrole: "AXSecureTextField", children: []),
        MockNode(role: "AXGroup", children: [MockNode(role: "AXTextArea", value: "Sure, I'll send the deck Friday. api_key=sk-abcdefghijklmnop")])
    ])

    // MARK: Opt-in capture

    func testOffByDefaultAndAllowlistOnly() {
        XCTAssertFalse(MemorySettings().enabled, "memory is off by default")
        let reader = MockWindowReader()
        reader.root = mailTree
        XCTAssertNil(capture(settings: MemorySettings(), reader: reader).captureFocused())
        XCTAssertNil(capture(app: ("Slack", "com.tinyspeck.slackmacgap"), settings: settings(), reader: reader).captureFocused())
        XCTAssertNil(capture(app: ("1Password", "com.1password.1password"), settings: settings { $0.allowlist.append("com.1password.1password") }, reader: reader).captureFocused(),
                     "password managers are never read, even if allowlisted")
        XCTAssertNil(capture(settings: settings { $0.paused = true }, reader: reader).captureFocused(), "global pause")
        XCTAssertEqual(reader.reads, 0, "the window isn't even opened for apps that aren't allowed")

        reader.title = "Private Browsing — Safari"
        XCTAssertNil(capture(app: ("Safari", "com.apple.Safari"), settings: settings { $0.allowlist = ["com.apple.Safari"] }, reader: reader).captureFocused(),
                     "private browsing windows are skipped")
    }

    func testSecureFieldsNeverReadAndSecretsRedacted() throws {
        let text = AXTextFlattener.flatten(mailTree)
        XCTAssertTrue(text.contains("Q3 deck"))
        XCTAssertFalse(text.contains("hunter2"), "secure text fields are skipped")
        let reader = MockWindowReader()
        reader.root = mailTree
        let id = try XCTUnwrap(capture(settings: settings(), reader: reader).captureFocused())
        let stored = try XCTUnwrap(store.snippet(id))
        XCTAssertFalse(stored.text.contains("hunter2"))
        XCTAssertFalse(stored.text.contains("sk-abcdefghijklmnop"), "secrets are redacted before storing")
        XCTAssertEqual(stored.app, "Mail")
        XCTAssertEqual(stored.window, "Inbox")
    }

    func testThrottleAndHashDedupe() throws {
        let reader = MockWindowReader()
        reader.root = mailTree
        let capture = capture(settings: settings(), reader: reader)
        var clock = Date()
        capture.now = { clock }
        XCTAssertNotNil(capture.captureFocused())
        clock = clock.addingTimeInterval(10)
        XCTAssertNil(capture.captureFocused(), "at most once per 30 s per window")
        clock = clock.addingTimeInterval(25)
        XCTAssertNil(capture.captureFocused(), "unchanged text isn't stored again")
        reader.root = MockNode(role: "AXWindow", children: [MockNode(role: "AXStaticText", value: "A brand new email arrived about the offsite venue booking")])
        clock = clock.addingTimeInterval(31)
        XCTAssertNotNil(capture.captureFocused(), "changed text after the throttle is stored")
        XCTAssertEqual(store.count, 2)
        XCTAssertNil(try store.insert(app: "Mail", bundleID: "com.apple.mail", window: "Inbox", text: AXTextFlattener.flatten(mailTree)), "same text, same window: deduped by hash")
    }

    // MARK: Store

    func testFullTextSearchAndRetention() throws {
        let old = Date().addingTimeInterval(-40 * 86_400)
        try store.insert(app: "Slack", bundleID: "com.tinyspeck.slackmacgap", window: "#design", text: "Old note about the Figma handoff", date: old)
        try store.insert(app: "Mail", bundleID: "com.apple.mail", window: "Re: Q3 deck", text: "Here's the Q3 deck you asked for")
        XCTAssertEqual(store.search("deck").map(\.window), ["Re: Q3 deck"])
        XCTAssertEqual(store.search("figma handoff").count, 1)
        XCTAssertTrue(store.search("\" OR 1=1 -- NEAR(").isEmpty, "FTS syntax is reduced to plain words, no error")
        store.purge(olderThan: 30)
        XCTAssertEqual(store.count, 1, "retention removes snippets older than the setting")
        XCTAssertTrue(store.search("figma").isEmpty, "and they're gone from the search index")
        store.forget(bundleID: "com.apple.mail")
        XCTAssertEqual(store.count, 0)
        try store.insert(app: "Notes", bundleID: "com.apple.Notes", window: "n", text: "something to delete later on")
        store.deleteEverything()
        XCTAssertEqual(store.count, 0)
    }

    func testSemanticSearchUsesEmbeddings() throws {
        store.embedder = { text in text.contains("invoice") || text.contains("bill") ? [1, 0] : [0, 1] }
        try store.insert(app: "Mail", bundleID: "com.apple.mail", window: "Billing", text: "Your invoice for October is ready")
        try store.insert(app: "Mail", bundleID: "com.apple.mail", window: "Lunch", text: "Lunch on Thursday?")
        XCTAssertEqual(store.semanticSearch("the bill", limit: 1).first?.window, "Billing")
    }

    // MARK: Loops

    func testLoopExtractionParsingFixture() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/loops-response.json"), encoding: .utf8)
        let result = try XCTUnwrap(LoopParser.parse(text, snippetIDs: [1, 2, 3], loopIDs: ["loop-a"]))
        XCTAssertEqual(result.loops.map(\.what), ["Send the Q3 deck to Priya", "Review Sam's pull request #482", "Book the offsite venue"],
                       "unknown snippet ids and empty items are dropped")
        XCTAssertEqual(result.loops[0].who, "Priya")
        XCTAssertNotNil(result.loops[0].due, "date-only due dates parse")
        XCTAssertNil(result.loops[1].due)
        XCTAssertEqual(result.loops[2].confidence, 1, "confidence is clamped")
        XCTAssertEqual(result.completions.map(\.loopID), ["loop-a"], "completions for unknown loops are dropped")
        XCTAssertNil(LoopParser.parse("no json here", snippetIDs: [1], loopIDs: []))
    }

    private func loopsEngine(local: Bool = false, ollama: Bool = false, response: String) -> (OpenLoops, ScriptedAdapter, [AIProviderID]) {
        let loops = OpenLoops(store: store)
        loops.settingsProvider = { var s = MemorySettings(); s.enabled = true; return s }
        loops.agentSettings = { var s = AgentSettings(); s.localOnly = local; s.provider = .anthropic; s.dailyCostCap = 0; return s }
        loops.ollamaAvailable = { ollama }
        loops.reminders = nil
        let adapter = ScriptedAdapter(turns: [AgentModelResponse(text: response, calls: [], inputTokens: 100, outputTokens: 50, stop: .done)])
        var used: [AIProviderID] = []
        loops.adapterFactory = { provider, _ in used.append(provider); return adapter }
        return (loops, adapter, used)
    }

    func testLocalOnlyBlocksCloudExtraction() async throws {
        try store.insert(app: "Mail", bundleID: "com.apple.mail", window: "Inbox", text: "Can you review the budget doc by Monday?")
        let (blocked, adapter, _) = loopsEngine(local: true, ollama: false, response: "{}")
        let message = await blocked.process()
        XCTAssertTrue(message.contains("Ollama"), message)
        XCTAssertEqual(adapter.calls, 0, "no snippet is sent to a cloud model in local-only mode")
        XCTAssertEqual(store.unprocessed(limit: 10).count, 1, "snippets wait for a local model")

        let local = OpenLoops(store: store)
        local.agentSettings = { var s = AgentSettings(); s.localOnly = true; return s }
        local.ollamaAvailable = { true }
        XCTAssertEqual(local.extractionModel()?.0, .ollama, "local-only uses Ollama")
        let cloud = OpenLoops(store: store)
        cloud.agentSettings = { var s = AgentSettings(); s.provider = .anthropic; return s }
        cloud.ollamaAvailable = { false }
        XCTAssertEqual(cloud.extractionModel()?.1, "claude-haiku-5-5", "otherwise a small cloud model")
    }

    func testExtractionCreatesLoopsAndAutoClose() async throws {
        let id = try XCTUnwrap(try store.insert(app: "Mail", bundleID: "com.apple.mail", window: "Inbox", text: "Priya: could you send the Q3 deck by Friday?"))
        let response = #"{"loops":[{"snippet_id":\#(id),"who":"Priya","what":"Send the Q3 deck to Priya","due":null,"confidence":0.9}],"completions":[]}"#
        let (loops, adapter, _) = loopsEngine(response: response)
        _ = await loops.process()
        XCTAssertEqual(adapter.calls, 1)
        let loop = try XCTUnwrap(store.loops().first)
        XCTAssertEqual(loop.what, "Send the Q3 deck to Priya")
        XCTAssertEqual(loop.app, "com.apple.mail")
        XCTAssertEqual(loop.snippetID, id)
        XCTAssertTrue(store.unprocessed(limit: 10).isEmpty)

        // Later: a sent reply with the deck → "probably done" (auto-close is off).
        let later = MemorySnippet(id: 50, app: "Mail", bundleID: "com.apple.mail", window: "Re: Q3 deck", date: Date().addingTimeInterval(3_600),
                                  hash: "", text: "Hi Priya, here's the Q3 deck attached.")
        XCTAssertGreaterThanOrEqual(LoopCloser.heuristicConfidence(loop: loop, snippet: later), 0.6)
        loops.applyHeuristics(snippets: [later], loops: [loop], settings: MemorySettings())
        XCTAssertEqual(store.loop(loop.id)?.status, .probablyDone, "needs a one-tap confirm")
        loops.set(loop.id, status: .done)
        XCTAssertEqual(store.loop(loop.id)?.status, .done)

        XCTAssertEqual(LoopCloser.status(for: 0.95, autoClose: true, threshold: 0.9), .done, "auto-close above the threshold")
        XCTAssertEqual(LoopCloser.status(for: 0.8, autoClose: true, threshold: 0.9), .probablyDone)
        XCTAssertEqual(LoopCloser.status(for: 0.95, autoClose: false, threshold: 0.9), .probablyDone)
        XCTAssertNil(LoopCloser.status(for: 0.3, autoClose: true, threshold: 0.9))
        let unrelated = MemorySnippet(id: 51, app: "Slack", bundleID: "x", window: "#random", date: Date().addingTimeInterval(7_200), hash: "", text: "done with lunch")
        XCTAssertEqual(LoopCloser.heuristicConfidence(loop: loop, snippet: unrelated), 0)
        let meeting = OpenLoop(id: "m", who: "", what: "Meeting with Sam about pricing", due: Date().addingTimeInterval(-3_600), app: "", snippetID: 0,
                               confidence: 0.8, status: .open, created: Date().addingTimeInterval(-86_400), updated: Date())
        XCTAssertTrue(LoopCloser.meetingPassed(loop: meeting, now: Date()), "a meeting that happened")
    }

    func testRemindMeCreatesSmartReminder() throws {
        let container = try ModelContainer(for: SmartReminder.self, TaskItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let reminders = ReminderEngine(context: container.mainContext)
        let loops = OpenLoops(store: store)
        loops.reminders = reminders
        store.upsert(OpenLoop(id: "abc", who: "Sam", what: "Review PR #482", due: nil, app: "", snippetID: 0, confidence: 0.8, status: .open,
                              created: Date(), updated: Date()))
        let reminder = try XCTUnwrap(loops.remind("abc"))
        XCTAssertEqual(reminder.text, "Review PR #482")
        XCTAssertEqual(store.loop("abc")?.reminderID, reminder.uid.uuidString)
    }

    // MARK: MCP

    private func handler() -> MemoryMCPHandler {
        var audited: [String] = []
        return MemoryMCPHandler(store: store, audit: { audited.append($0) }, markDone: { _ in true })
    }

    func testMCPHandler() throws {
        try store.insert(app: "Mail", bundleID: "com.apple.mail", window: "Re: Q3 deck", text: "Here's the Q3 deck")
        let handler = handler()
        let initialize = try XCTUnwrap(handler.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)))
        XCTAssertTrue(String(decoding: initialize, as: UTF8.self).contains("macpilot-memory"))
        XCTAssertNil(handler.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)), "notifications get no reply")
        let list = String(decoding: try XCTUnwrap(handler.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))), as: UTF8.self)
        for tool in ["search_memory", "get_open_loops", "mark_loop_done"] { XCTAssertTrue(list.contains(tool)) }
        let search = String(decoding: try XCTUnwrap(handler.handle(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"deck"}}}"#.utf8))), as: UTF8.self)
        XCTAssertTrue(search.contains("Q3 deck"))
    }

    func testMCPHTTPRefusesWithoutTokenAndBindsLoopbackOnly() async throws {
        let request = { (auth: String?) -> MCPHTTP.Request in
            MCPHTTP.Request(method: "POST", path: "/mcp", headers: auth.map { ["authorization": $0] } ?? [:],
                            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        }
        let token = "test-token-1234567890"
        func status(_ data: Data) -> String { String(decoding: data.prefix(12), as: UTF8.self) }
        XCTAssertEqual(status(MCPHTTP.respond(request(nil), token: token, handler: handler())), "HTTP/1.1 401")
        XCTAssertEqual(status(MCPHTTP.respond(request("Bearer wrong"), token: token, handler: handler())), "HTTP/1.1 401")
        XCTAssertEqual(status(MCPHTTP.respond(request("Bearer \(token)"), token: token, handler: handler())), "HTTP/1.1 200")
        var browser = request("Bearer \(token)")
        browser.headers["origin"] = "https://evil.example"
        XCTAssertEqual(status(MCPHTTP.respond(browser, token: token, handler: handler())), "HTTP/1.1 403", "DNS-rebinding guard")
        XCTAssertFalse(MCPHTTP.authorized(request("Bearer "), token: ""), "an empty token never authorizes")

        // A real listener: loopback works with the token, without it is refused, and it isn't reachable on the LAN address.
        let server = MemoryMCPServer()
        server.store = store
        server.tokenProvider = { token }
        let port = UInt16.random(in: 40_000...49_000)
        server.start(port: port)
        let deadline = Date().addingTimeInterval(5)
        while !server.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(server.isRunning, server.lastError ?? "")
        XCTAssertEqual(server.localEndpointHost, "127.0.0.1")
        defer { server.stop() }

        func post(host: String, auth: String?) async -> Int? {
            var request = URLRequest(url: URL(string: "http://\(host):\(port)/mcp")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 2
            request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
            if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
            let session = URLSession(configuration: .ephemeral)
            return (try? await session.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
        }
        let ok = await post(host: "127.0.0.1", auth: "Bearer \(token)")
        XCTAssertEqual(ok, 200)
        let refused = await post(host: "127.0.0.1", auth: nil)
        XCTAssertEqual(refused, 401)
        if let lan = NetworkMonitor.readCounters().addresses.values.first(where: { !$0.hasPrefix("127.") }) {
            let fromLAN = await post(host: lan, auth: "Bearer \(token)")
            XCTAssertNil(fromLAN, "not reachable on \(lan)")
        }
    }

    func testAgentAndPilotIntegration() {
        XCTAssertEqual(PilotCommand.parse("what did I promise this week?"), .openLoops)
        XCTAssertTrue(AgentTools.specs.contains { $0.name == "recall_memory" })
        XCTAssertFalse(AgentTools.jobToolNames.contains("recall_memory"), "scheduled jobs don't read memory")
        let settings = AgentSettings()
        XCTAssertEqual(try AgentTools.normalize(tool: "recall_memory", arguments: ["query": "deck"], settings: settings).risk, .low)
        XCTAssertEqual(try AgentTools.normalize(tool: "list_open_loops", arguments: [:], settings: settings).risk, .low)
    }
}
