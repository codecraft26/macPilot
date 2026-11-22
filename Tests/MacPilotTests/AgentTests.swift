import Foundation
import SwiftData
import XCTest
@testable import MacPilot

/// Replays scripted model turns; counts calls so tests can see nothing extra happened.
final class ScriptedAdapter: AgentModelAdapter {
    var provider: AIProviderID
    var model = "test-model"
    var capabilities: AgentCapabilities { AgentCapabilities(toolCalling: true, parallelToolCalls: true, isLocal: provider == .ollama) }
    var turns: [AgentModelResponse]
    private(set) var calls = 0
    private(set) var seenMessages: [[AgentMessage]] = []

    init(provider: AIProviderID = .anthropic, turns: [AgentModelResponse]) {
        self.provider = provider
        self.turns = turns
    }

    func generate(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) async throws -> AgentModelResponse {
        calls += 1
        seenMessages.append(messages)
        guard !turns.isEmpty else { return AgentModelResponse(text: "Done.", calls: [], inputTokens: 10, outputTokens: 5, stop: .done) }
        return turns.removeFirst()
    }

    func normalizeToolCalls(_ response: [String: Any]) throws -> AgentModelResponse { throw AgentProviderError.badResponse("unused") }
    func estimateCost(inputTokens: Int, outputTokens: Int) -> Double { Double(inputTokens + outputTokens) / 1_000_000 }

    static func tool(_ name: String, _ arguments: [String: Any], id: String = UUID().uuidString) -> AgentModelResponse {
        AgentModelResponse(text: "", calls: [AgentToolCall(id: id, name: name, arguments: arguments, rawArguments: AgentAdapters.jsonString(arguments))],
                           inputTokens: 100, outputTokens: 20, stop: .toolUse)
    }
}

/// A throwaway "Trash" so tests never put files in the user's real Trash.
enum TestTrash {
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macpilot-test-trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let move: AgentTools.TrashFunction = { url in
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)"))
    }
}

@MainActor
final class AgentTests: XCTestCase {
    private var workspace: URL!
    private var outside: URL!
    private var container: ModelContainer!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tests-\(UUID().uuidString)")
        workspace = base.appendingPathComponent("work")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        container = try ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        defaults = UserDefaults(suiteName: "agent-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent())
    }

    private func settings(_ change: (inout AgentSettings) -> Void = { _ in }) -> AgentSettings {
        var settings = AgentSettings()
        settings.workspaceRoots = [workspace.path]
        settings.provider = .anthropic
        settings.model = "test-model"
        settings.commandAllowlist = ["ls", "echo", "sleep", "cat"]
        change(&settings)
        return settings
    }

    private func engine(_ adapter: ScriptedAdapter, settings: AgentSettings) -> AgentEngine {
        let engine = AgentEngine(context: container.mainContext, defaults: defaults)
        engine.settingsProvider = { settings }
        engine.adapterFactory = { _, _ in adapter }
        engine.recordUsage = { _, _, _ in }
        engine.trash = TestTrash.move
        return engine
    }

    private func actions(_ engine: AgentEngine) -> [AgentToolAction] {
        (try? container.mainContext.fetch(FetchDescriptor<AgentToolAction>())) ?? []
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Workspace

    func testWriteOutsideWorkspaceIsBlocked() async throws {
        let target = outside.appendingPathComponent("evil.txt")
        let adapter = ScriptedAdapter(turns: [ScriptedAdapter.tool("write_file", ["path": target.path, "content": "x"]),
                                              ScriptedAdapter.tool("write_file", ["path": "../outside/evil2.txt", "content": "x"])])
        let engine = engine(adapter, settings: settings { $0.approveMedium = false })
        let task = engine.submit("write outside")
        await engine.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("evil2.txt").path), "../ escapes are caught")
        XCTAssertEqual(actions(engine).map(\.state), [.blocked, .blocked])
        XCTAssertEqual(task.state, .done)
    }

    func testSymlinkEscapeIsRejected() throws {
        let link = workspace.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let guardian = WorkspaceGuard(roots: [workspace.path])
        XCTAssertThrowsError(try guardian.resolve(link.appendingPathComponent("file.txt").path)) { error in
            XCTAssertEqual(error as? AgentPolicyError, .symlinkEscape(link.appendingPathComponent("file.txt").standardizedFileURL.path))
        }
        XCTAssertNoThrow(try guardian.resolve("notes/new.md"), "relative paths resolve inside the first workspace")
        XCTAssertThrowsError(try WorkspaceGuard(roots: []).resolve("a.txt")) { XCTAssertEqual($0 as? AgentPolicyError, .noWorkspace) }
    }

    func testWriteInsideWorkspaceWithApproval() async throws {
        let target = workspace.appendingPathComponent("notes.md")
        let adapter = ScriptedAdapter(turns: [ScriptedAdapter.tool("write_file", ["path": "notes.md", "content": "hello"])])
        let engine = engine(adapter, settings: settings())
        let task = engine.submit("write a note")
        await waitFor { task.state == .awaitingApproval }
        let action = try XCTUnwrap(actions(engine).first)
        XCTAssertTrue(action.preview.contains("New file"), "the drawer previews the write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing is written before approval")
        engine.decide(approvalID: try XCTUnwrap(engine.pendingApprovalID), approve: true)
        await engine.waitUntilIdle()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "hello")
        XCTAssertEqual(action.state, .succeeded)
    }

    // MARK: Delete approvals

    func testDeleteNeedsExactPathApprovalAndDenialRunsNothing() async throws {
        let file = workspace.appendingPathComponent("keep.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)
        let adapter = ScriptedAdapter(turns: [ScriptedAdapter.tool("delete_file", ["path": file.path])])
        // Even with medium approvals off, high risk always asks.
        let engine = engine(adapter, settings: settings { $0.approveMedium = false })
        let task = engine.submit("delete it")
        await waitFor { task.state == .awaitingApproval }
        let action = try XCTUnwrap(actions(engine).first)
        XCTAssertEqual(action.risk, .high)
        XCTAssertTrue(action.preview.contains(WorkspaceGuard.canonical(file).path), "the drawer shows the exact path")
        let approvalID = try XCTUnwrap(engine.pendingApprovalID)
        engine.decide(approvalID: approvalID, approve: false)
        await engine.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a denial runs nothing")
        XCTAssertEqual(action.state, .denied)
        XCTAssertEqual(adapter.calls, 2, "the model is told about the denial and finishes")
    }

    func testApprovalIsBoundToExactAction() {
        let task = UUID()
        let a = NormalizedAction(tool: "delete_file", arguments: ["path": "/w/a.txt"], risk: .high, summary: "")
        let b = NormalizedAction(tool: "delete_file", arguments: ["path": "/w/b.txt"], risk: .high, summary: "")
        XCTAssertNotEqual(a.hash(taskID: task), b.hash(taskID: task))
        XCTAssertNotEqual(a.hash(taskID: task), a.hash(taskID: UUID()), "bound to the task")
        XCTAssertEqual(a.hash(taskID: task), a.hash(taskID: task))
        let approval = AgentApproval(taskID: task, actionID: UUID(), actionHash: a.hash(taskID: task), risk: .high)
        approval.decision = .approved
        XCTAssertEqual(AgentPolicy.validate(approval, taskID: task, actionHash: b.hash(taskID: task)), .rejected("The action changed after it was approved."))
        XCTAssertEqual(AgentPolicy.validate(approval, taskID: UUID(), actionHash: a.hash(taskID: task)), .rejected("This approval belongs to another task."))
        XCTAssertEqual(AgentPolicy.validate(approval, taskID: task, actionHash: a.hash(taskID: task)), .valid)
    }

    // MARK: Replay and expiry

    func testReplayedApprovalIsRejected() {
        let task = UUID()
        let approval = AgentApproval(taskID: task, actionID: UUID(), actionHash: "h", risk: .medium)
        approval.decision = .approved
        XCTAssertEqual(AgentPolicy.validate(approval, taskID: task, actionHash: "h"), .valid)
        AgentPolicy.consume(approval)
        XCTAssertEqual(AgentPolicy.validate(approval, taskID: task, actionHash: "h"), .rejected("This approval was already used."))
    }

    func testExpiredApprovalIsRejected() async throws {
        let start = Date()
        let approval = AgentApproval(taskID: UUID(), actionID: UUID(), actionHash: "h", risk: .medium, now: start)
        approval.decision = .approved
        XCTAssertEqual(approval.expiresAt.timeIntervalSince(start), 600, accuracy: 0.001, "10 minutes")
        XCTAssertEqual(AgentPolicy.validate(approval, taskID: approval.taskID, actionHash: "h", now: start.addingTimeInterval(601)),
                       .rejected("The approval expired (10 minutes)."))

        // In the loop: an approval left unanswered expires and nothing runs.
        let file = workspace.appendingPathComponent("x.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let adapter = ScriptedAdapter(turns: [ScriptedAdapter.tool("delete_file", ["path": file.path])])
        let engine = engine(adapter, settings: settings())
        engine.approvalLifetime = 0.3
        engine.submit("delete")
        await engine.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(actions(engine).first?.state, .expired)
        let stored = try container.mainContext.fetch(FetchDescriptor<AgentApproval>())
        XCTAssertEqual(stored.first?.decision, .expired)
        // A late click on the expired approval does nothing.
        engine.decide(approvalID: try XCTUnwrap(stored.first?.uid), approve: true)
        XCTAssertEqual(stored.first?.decision, .expired)
    }

    // MARK: Providers

    func testLocalOnlyBlocksCloudProviders() async throws {
        var local = settings { $0.localOnly = true }
        for provider in [AIProviderID.anthropic, .openAI, .bedrock] {
            XCTAssertThrowsError(try AgentPolicy.checkProvider(provider, settings: local)) { XCTAssertEqual($0 as? AgentPolicyError, .localOnly(provider)) }
        }
        XCTAssertNoThrow(try AgentPolicy.checkProvider(.ollama, settings: local))

        let adapter = ScriptedAdapter(provider: .anthropic, turns: [ScriptedAdapter.tool("system_status", [:])])
        let engine = engine(adapter, settings: local)
        let task = engine.submit("status")
        await engine.waitUntilIdle()
        XCTAssertEqual(task.state, .failed)
        XCTAssertEqual(adapter.calls, 0, "no request reaches the cloud provider")
        XCTAssertTrue(task.errorMessage?.contains("Local-only") == true)

        local.provider = .ollama
        let ollama = ScriptedAdapter(provider: .ollama, turns: [])
        let localEngine = self.engine(ollama, settings: local)
        let ok = localEngine.submit("hi")
        await localEngine.waitUntilIdle()
        XCTAssertEqual(ok.state, .done)
    }

    // MARK: Stop and kill switch

    func testStopKillsSubprocess() async throws {
        let adapter = ScriptedAdapter(turns: [ScriptedAdapter.tool("run_command", ["command": "sleep 30"])])
        let engine = engine(adapter, settings: settings { $0.approveMedium = false })
        let task = engine.submit("sleep")
        await waitFor { engine.processes.runningCount > 0 }
        XCTAssertEqual(engine.processes.runningCount, 1)
        let stopped = Date()
        engine.stop(task.uid)
        await waitFor(3) { engine.processes.runningCount == 0 && task.state.isFinished }
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 2, "stops within 2 seconds")
        XCTAssertEqual(engine.processes.runningCount, 0)
        XCTAssertEqual(task.state, .cancelled)
        XCTAssertEqual(adapter.calls, 1, "no further model calls after Stop")
    }

    func testKillSwitchBlocksFutureToolCalls() async throws {
        let adapter = ScriptedAdapter(turns: [ScriptedAdapter.tool("run_command", ["command": "sleep 30"])])
        let engine = engine(adapter, settings: settings { $0.approveMedium = false })
        let task = engine.submit("sleep")
        await waitFor { engine.processes.runningCount > 0 }
        engine.killSwitch()
        await waitFor(3) { engine.processes.runningCount == 0 && task.state.isFinished }
        XCTAssertEqual(task.state, .cancelled)
        let next = engine.submit("anything")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(next.state, .queued, "nothing starts while the kill switch is on")
        XCTAssertEqual(AgentPolicy.decide(NormalizedAction(tool: "read_file", arguments: [:], risk: .low, summary: ""), settings: settings(), halted: true),
                       .deny(AgentPolicyError.halted.localizedDescription))
        engine.resume()
        await engine.waitUntilIdle()
        XCTAssertEqual(next.state, .done)
    }

    // MARK: Recovery

    func testRestartRecoveryDoesNotDuplicateActions() async throws {
        let context = container.mainContext
        let interrupted = AgentTask(prompt: "make a file", provider: .anthropic, model: "m")
        interrupted.state = .running
        interrupted.steps = 2
        context.insert(interrupted)
        let action = AgentToolAction(taskID: interrupted.uid, step: 2, callID: "c1", tool: "write_file")
        action.state = .running
        context.insert(action)
        let approval = AgentApproval(taskID: interrupted.uid, actionID: UUID(), actionHash: "h", risk: .medium)
        context.insert(approval)
        try context.save()

        let adapter = ScriptedAdapter(turns: [])
        let engine = engine(adapter, settings: settings())
        engine.recoverAfterLaunch()
        await engine.waitUntilIdle()

        XCTAssertEqual(action.state, .needsReview)
        XCTAssertEqual(interrupted.state, .failed)
        XCTAssertEqual(approval.decision, .expired, "an old approval can't be used after a restart")
        XCTAssertEqual(actions(engine).count, 1, "nothing was replayed")
        XCTAssertEqual(adapter.calls, 0, "the interrupted task isn't resumed")

        let retry = engine.retry(interrupted)
        await engine.waitUntilIdle()
        XCTAssertEqual(retry.retryOf, interrupted.uid)
        XCTAssertEqual(retry.state, .done)
        XCTAssertEqual(action.state, .needsReview, "retry starts fresh and leaves the old step alone")
    }

    // MARK: Secrets

    func testNoSecretsInDatabaseOrLogs() async throws {
        let key = "sk-ant-api03-" + String(repeating: "A", count: 40)
        let aws = "AKIA" + String(repeating: "B", count: 16)
        let github = "ghp_" + String(repeating: "c", count: 36)
        let env = workspace.appendingPathComponent(".env")
        try "OPENAI_API_KEY=\(key)\nAWS_ACCESS_KEY_ID=\(aws)\nGITHUB=\(github)\npassword=hunter2hunter2\n".write(to: env, atomically: true, encoding: .utf8)
        let adapter = ScriptedAdapter(turns: [
            ScriptedAdapter.tool("read_file", ["path": ".env"]),
            ScriptedAdapter.tool("run_command", ["command": "echo token \(github)"]),
            AgentModelResponse(text: "Your key is \(key)", calls: [], inputTokens: 1, outputTokens: 1, stop: .done)
        ])
        let engine = engine(adapter, settings: settings { $0.approveMedium = false })
        engine.submit("Use my key \(key) and read .env")
        await engine.waitUntilIdle()

        let context = container.mainContext
        var stored: [String] = []
        for task in try context.fetch(FetchDescriptor<AgentTask>()) { stored += [task.prompt, task.title, task.finalAnswer, task.errorMessage ?? ""] }
        for action in try context.fetch(FetchDescriptor<AgentToolAction>()) { stored += [action.argumentsJSON, action.output, action.preview, action.summary] }
        for event in try context.fetch(FetchDescriptor<AgentEvent>()) { stored.append(event.message) }
        let all = stored.joined(separator: "\n")
        XCTAssertTrue(all.contains("redacted"), "secrets were replaced")
        for secret in [key, aws, github, "hunter2hunter2"] {
            XCTAssertFalse(all.contains(secret), "\(secret.prefix(6))… leaked into the database")
        }
        // What the model sees from tools is redacted too.
        if case .toolResults(let results)? = adapter.seenMessages.last?.last {
            XCTAssertFalse(results.contains { $0.result.content.contains(github) })
        }
        XCTAssertFalse(adapter.seenMessages.flatMap { $0 }.contains { message in
            if case .toolResults(let results) = message { return results.contains { $0.result.content.contains(key) } }
            return false
        })
    }

    func testScrubbedEnvironmentHasNoKeys() {
        let env = CommandGuard.scrubbedEnvironment()
        XCTAssertEqual(Set(env.keys), ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "TERM", "GIT_TERMINAL_PROMPT", "GIT_PAGER", "NO_COLOR"])
    }

    // MARK: Commands

    func testCommandPolicy() throws {
        let guardian = CommandGuard(allowlist: ["ls", "git", "find", "echo"])
        XCTAssertEqual(try CommandGuard.split(#"git log --format="%h %s" -n 3"#), ["git", "log", "--format=%h %s", "-n", "3"])
        XCTAssertEqual(try guardian.validate(["ls", "-la"]), "/bin/ls")
        for line in ["ls | sh", "echo hi > out.txt", "echo $(whoami)", "ls; rm -rf /", "echo `id`", "ls && sudo id"] {
            XCTAssertThrowsError(try CommandGuard.split(line), line)
        }
        XCTAssertThrowsError(try guardian.validate(["sudo", "ls"])) { XCTAssertEqual($0 as? AgentPolicyError, .forbiddenCommand("“sudo” is never allowed for the agent.")) }
        XCTAssertThrowsError(try guardian.validate(["rm", "-rf", "x"]))
        XCTAssertThrowsError(try guardian.validate(["python3", "-c", "1"])) { XCTAssertEqual($0 as? AgentPolicyError, .commandNotAllowed("python3")) }
        XCTAssertThrowsError(try guardian.validate(["/tmp/ls"]), "no paths to other binaries")
        XCTAssertThrowsError(try guardian.validate(["find", ".", "-delete"]))
        XCTAssertThrowsError(try guardian.validate(["git", "push"]))
        XCTAssertNoThrow(try guardian.validate(["git", "status"]))
    }

    func testCommandOutputCapAndTimeout() async {
        let registry = AgentProcessRegistry()
        let long = await registry.run(executable: "/bin/echo", arguments: [String(repeating: "x", count: 5_000)], cwd: "/tmp", timeout: 10, outputCap: 100)
        XCTAssertTrue(long.content.contains("truncated"))
        let started = Date()
        let slow = await registry.run(executable: "/bin/sleep", arguments: ["30"], cwd: "/tmp", timeout: 0.5, outputCap: 100)
        XCTAssertTrue(slow.isError)
        XCTAssertTrue(slow.content.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testRiskTiers() throws {
        let s = settings()
        try "a".write(to: workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try AgentTools.normalize(tool: "read_file", arguments: ["path": "a.txt"], settings: s).risk, .low)
        XCTAssertEqual(try AgentTools.normalize(tool: "write_file", arguments: ["path": "a.txt", "content": "b"], settings: s).risk, .medium)
        XCTAssertEqual(try AgentTools.normalize(tool: "run_command", arguments: ["command": "ls"], settings: s).risk, .medium)
        XCTAssertEqual(try AgentTools.normalize(tool: "delete_file", arguments: ["path": "a.txt"], settings: s).risk, .high)
        XCTAssertEqual(try AgentTools.normalize(tool: "system_status", arguments: [:], settings: s).risk, .low)
        XCTAssertThrowsError(try AgentTools.normalize(tool: "delete_file", arguments: ["path": workspace.path], settings: s), "never the workspace itself")
        let medium = try AgentTools.normalize(tool: "write_file", arguments: ["path": "a.txt", "content": "b"], settings: s)
        XCTAssertEqual(AgentPolicy.decide(medium, settings: s, halted: false), .needsApproval)
        var relaxed = s
        relaxed.approveMedium = false
        XCTAssertEqual(AgentPolicy.decide(medium, settings: relaxed, halted: false), .allow)
        let high = try AgentTools.normalize(tool: "delete_file", arguments: ["path": "a.txt"], settings: s)
        XCTAssertEqual(AgentPolicy.decide(high, settings: relaxed, halted: false), .needsApproval, "high risk always asks")
    }

    func testCapsStopTheLoop() async {
        let adapter = ScriptedAdapter(turns: Array(repeating: ScriptedAdapter.tool("system_status", [:]), count: 10))
        let engine = engine(adapter, settings: settings { $0.maxSteps = 3 })
        let task = engine.submit("loop")
        await engine.waitUntilIdle()
        XCTAssertEqual(task.state, .failed)
        XCTAssertEqual(adapter.calls, 3)
        XCTAssertTrue(task.errorMessage?.contains("step limit") == true)

        let costly = ScriptedAdapter(turns: Array(repeating: ScriptedAdapter.tool("system_status", [:]), count: 10))
        let capped = self.engine(costly, settings: settings { $0.perTaskCostCap = 0.0001 })
        let second = capped.submit("spend")
        await capped.waitUntilIdle()
        XCTAssertEqual(second.state, .failed)
        XCTAssertTrue(second.errorMessage?.contains("cost cap") == true)
        XCTAssertEqual(costly.calls, 1)
    }

    func testRedactor() {
        let text = "Authorization: Bearer abcdefghijklmnop1234 api_key=\"zzzzzzzz\" https://user:pass1234@example.com -----BEGIN RSA PRIVATE KEY-----\nMII\n-----END RSA PRIVATE KEY-----"
        let clean = AgentRedactor.redact(text)
        XCTAssertFalse(clean.contains("abcdefghijklmnop1234"))
        XCTAssertFalse(clean.contains("zzzzzzzz"))
        XCTAssertFalse(clean.contains("pass1234"))
        XCTAssertFalse(clean.contains("MII"))
    }

    // MARK: Provider adapters

    func testAnthropicToolUseNormalization() throws {
        let adapter = AnthropicAgentAdapter(backend: .anthropic, model: "claude-opus-5-5")
        let response: [String: Any] = [
            "content": [["type": "thinking", "thinking": "", "signature": "sig"],
                        ["type": "text", "text": "Let me look."],
                        ["type": "tool_use", "id": "toolu_1", "name": "list_files", "input": ["path": "."]]],
            "stop_reason": "tool_use", "usage": ["input_tokens": 120, "output_tokens": 30]
        ]
        let normalized = try adapter.normalizeToolCalls(response)
        XCTAssertEqual(normalized.stop, .toolUse)
        XCTAssertEqual(normalized.calls.first?.name, "list_files")
        XCTAssertEqual(normalized.calls.first?.arguments?["path"] as? String, ".")
        XCTAssertEqual(normalized.inputTokens, 120)
        // The assistant turn (with its thinking block) is echoed back unchanged; results go in one user message.
        let body = adapter.body(system: "s", messages: [.user("hi"), .assistant(text: normalized.text, calls: normalized.calls, raw: normalized.raw),
                                                        .toolResults([(normalized.calls[0], AgentToolResult(content: "a.txt", isError: false))])],
                                tools: AgentTools.specs)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual((messages[1]["content"] as? [[String: Any]])?.first?["type"] as? String, "thinking")
        let result = try XCTUnwrap((messages[2]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["type"] as? String, "tool_result")
        XCTAssertEqual(result["tool_use_id"] as? String, "toolu_1")
        XCTAssertNil(body["fallbacks"], "no silent fallback to another model")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, AgentTools.specs.count)
        XCTAssertEqual(adapter.estimateCost(inputTokens: 1_000_000, outputTokens: 1_000_000), 24, accuracy: 0.001)
        XCTAssertEqual(try adapter.normalizeToolCalls(["content": [], "stop_reason": "refusal"]).stop, .refusal)
    }

    func testOpenAIToolCallNormalization() throws {
        let adapter = OpenAIAgentAdapter(model: "gpt-5")
        let response: [String: Any] = [
            "choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "call_1", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"a.txt\"}"]],
                ["id": "call_2", "type": "function", "function": ["name": "read_file", "arguments": "{not json"]]
            ]]]],
            "usage": ["prompt_tokens": 50, "completion_tokens": 10]
        ]
        let normalized = try adapter.normalizeToolCalls(response)
        XCTAssertEqual(normalized.calls.count, 2)
        XCTAssertEqual(normalized.calls[0].arguments?["path"] as? String, "a.txt")
        XCTAssertNil(normalized.calls[1].arguments, "bad JSON is reported, not guessed")
        XCTAssertEqual(normalized.stop, .toolUse)
        let body = adapter.body(system: "s", messages: [.assistant(text: "", calls: normalized.calls, raw: nil),
                                                        .toolResults([(normalized.calls[0], AgentToolResult(content: "x", isError: false))])], tools: [])
        let wire = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(wire.last?["role"] as? String, "tool")
        XCTAssertEqual(wire.last?["tool_call_id"] as? String, "call_1")
    }

    func testOllamaToolCallNormalization() throws {
        let adapter = OllamaAgentAdapter(model: "llama3.2", baseURL: URL(string: "http://localhost:11434")!)
        let normalized = try adapter.normalizeToolCalls([
            "message": ["role": "assistant", "content": "", "tool_calls": [["function": ["name": "system_status", "arguments": [:]]]]],
            "prompt_eval_count": 20, "eval_count": 5, "done": true
        ])
        XCTAssertEqual(normalized.calls.first?.name, "system_status")
        XCTAssertNotNil(normalized.calls.first?.arguments)
        XCTAssertEqual(normalized.stop, .toolUse)
        XCTAssertTrue(adapter.capabilities.isLocal)
        XCTAssertEqual(adapter.estimateCost(inputTokens: 1_000, outputTokens: 1_000), 0)
        XCTAssertThrowsError(try adapter.normalizeToolCalls(["error": "model not found"]))
    }

    func testWritePreview() {
        XCTAssertTrue(WritePreview.describe(old: nil, new: "a\nb").hasPrefix("New file, 2 lines"))
        let diff = WritePreview.describe(old: "a\nb\nc", new: "a\nB\nc")
        XCTAssertTrue(diff.contains("- 2: b"))
        XCTAssertTrue(diff.contains("+ 2: B"))
        XCTAssertEqual(WritePreview.describe(old: "same", new: "same"), "No changes (1 lines).")
    }
}
