import Darwin
import Foundation
import SwiftData
import XCTest
@testable import MacPilot

final class FakeSignals: ProcessSignaling {
    var alive: Set<Int32>
    var ignoresTERM: Set<Int32> = []
    private(set) var sent: [(Int32, Int32)] = []
    init(alive: Set<Int32>) { self.alive = alive }
    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append((signal, pid))
        if signal == SIGKILL || !ignoresTERM.contains(pid) { alive.remove(pid) }
        return true
    }
    func isAlive(_ pid: Int32) -> Bool { alive.contains(pid) }
}

@MainActor
final class PortKillerTests: XCTestCase {
    private var fixture: String {
        (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lsof-listen.txt"), encoding: .utf8)) ?? ""
    }

    private func killer(_ signals: FakeSignals) -> PortKiller {
        let killer = PortKiller()
        let output = fixture
        killer.lister = { output }
        killer.enricher = { _ in }
        killer.signaling = signals
        killer.sleep = { _ in }
        return killer
    }

    func testParsesLsofOutput() {
        let ports = LsofParser.parse(fixture)
        XCTAssertEqual(ports.map(\.port), [22, 3000, 3000, 5432, 5432, 6379, 5353, 49152].sorted())
        XCTAssertFalse(ports.contains { $0.process == "identityservicesd" }, "*:* (no port) is skipped")
        let node = ports.first { $0.port == 3000 }!
        XCTAssertEqual(node.process, "node")
        XCTAssertEqual(node.pid, 4120)
        XCTAssertEqual(node.user, "aman")
        XCTAssertEqual(node.proto, "TCP")
        XCTAssertEqual(ports.first { $0.port == 5432 && $0.address == "127.0.0.1" }?.isLocalOnly, true)
        XCTAssertEqual(LsofParser.endpoint("[::1]:8080")?.1, 8080)
        XCTAssertEqual(LsofParser.endpoint("192.168.1.20:5353->224.0.0.251:5353")?.0, "192.168.1.20")
        XCTAssertNil(LsofParser.endpoint("*:*"))
    }

    func testProtections() {
        let me = Int32(getuid())
        func port(_ name: String, pid: Int32 = 4000, uid: Int32? = nil, path: String = "") -> ListeningPort {
            ListeningPort(port: 1, proto: "TCP", address: "*", pid: pid, process: name, uid: uid ?? me, user: "u", executablePath: path)
        }
        XCTAssertNil(PortProtection.reason(port("node", path: "/opt/homebrew/bin/node")))
        XCTAssertNotNil(PortProtection.reason(port("launchd", pid: 1)), "core system process")
        XCTAssertTrue(PortProtection.reason(port("sshd", uid: 0))?.contains("sudo") == true, "root-owned: no sudo")
        XCTAssertTrue(PortProtection.reason(port("redis", uid: me + 1))?.contains("another user") == true)
        XCTAssertNotNil(PortProtection.reason(port("rapportd")), "macOS daemon by name")
        XCTAssertNotNil(PortProtection.reason(port("helper", path: "/System/Library/CoreServices/helper")), "macOS daemon by path")
        XCTAssertNotNil(PortProtection.reason(port("MacPilot")))
        XCTAssertNotNil(PortProtection.reason(port("anything", pid: getpid())), "MacPilot itself")
    }

    func testTermThenKillEscalation() async {
        let signals = FakeSignals(alive: [4120, 4188])
        let killer = killer(signals)
        await killer.refresh()
        let node = killer.owners(of: 3000).first!
        let polite = await killer.terminate(node)
        XCTAssertEqual(polite, .stopped)
        XCTAssertEqual(signals.sent.map(\.0), [SIGTERM], "SIGTERM only")

        signals.ignoresTERM = [4188]
        let postgres = killer.owners(of: 5432).first!
        let first = await killer.terminate(postgres)
        XCTAssertEqual(first, .stillRunning, "after the grace period it reports instead of escalating")
        XCTAssertFalse(signals.sent.contains { $0.0 == SIGKILL }, "never SIGKILL without asking")
        let forced = await killer.forceKill(postgres)
        XCTAssertEqual(forced, .forceKilled)
        XCTAssertEqual(signals.sent.last.map { $0.0 }, SIGKILL)

        let refusedSignals = FakeSignals(alive: [1, 777])
        let guarded = self.killer(refusedSignals)
        await guarded.refresh()
        for number in [22, 6379] {
            let outcome = await guarded.terminate(guarded.owners(of: number).first!)
            if case .refused = outcome {} else { XCTFail("port \(number) must be refused") }
            let force = await guarded.forceKill(guarded.owners(of: number).first!)
            if case .refused = force {} else { XCTFail("force on \(number) must be refused") }
        }
        XCTAssertTrue(refusedSignals.sent.isEmpty, "no signal is ever sent to protected processes")
    }

    func testCommandParsingAndFilter() async {
        XCTAssertEqual(PortKiller.command("kill port 3000"), .kill(3000))
        XCTAssertEqual(PortKiller.command("stop :8080"), .kill(8080))
        XCTAssertEqual(PortKiller.command("what's on port 5432"), .show(5432))
        XCTAssertEqual(PortKiller.command("who is using port 6379?"), .show(6379))
        XCTAssertNil(PortKiller.command("kill port 99999"))
        XCTAssertNil(PortKiller.command("airport codes"))
        let killer = killer(FakeSignals(alive: []))
        await killer.refresh()
        XCTAssertEqual(Set(killer.filtered("543").map(\.port)), [5432])
        XCTAssertEqual(Set(killer.filtered("postgres").map(\.port)), [5432])
        XCTAssertEqual(PortKiller.commonPorts, [3000, 5173, 8080, 5432, 6379])
    }

    // MARK: Approvals

    private var container: ModelContainer!

    private func telegram(_ signals: FakeSignals) async -> (TelegramBot, MockBotAPI, PortKiller) {
        container = try! ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = AgentEngine(context: container.mainContext, defaults: UserDefaults(suiteName: "ports-\(UUID().uuidString)")!)
        let bot = TelegramBot(engine: engine, defaults: UserDefaults(suiteName: "ports-tg-\(UUID().uuidString)")!)
        let api = MockBotAPI()
        bot.attach(transport: api)
        let killer = killer(signals)
        bot.ports = killer
        for user: Int64 in [1, 2] {
            let code = bot.newPairingCode()
            await bot.handle(TelegramIncoming(updateID: Int(user), userID: user, chatID: user, chatType: "private", isBot: false, name: "",
                                              kind: .message(text: "/pair \(code)", messageID: 1)))
        }
        return (bot, api, killer)
    }

    private func message(_ text: String, from user: Int64 = 1) -> TelegramIncoming {
        TelegramIncoming(updateID: Int.random(in: 10...999_999), userID: user, chatID: user, chatType: "private", isBot: false, name: "", kind: .message(text: text, messageID: 2))
    }

    private func press(_ data: String, from user: Int64 = 1) -> TelegramIncoming {
        TelegramIncoming(updateID: Int.random(in: 10...999_999), userID: user, chatID: user, chatType: "private", isBot: false, name: "", kind: .callback(id: "c", data: data, messageID: 3))
    }

    func testTelegramKillNeedsApproval() async throws {
        let signals = FakeSignals(alive: [4120, 4188])
        signals.ignoresTERM = [4188]
        let (bot, api, _) = await telegram(signals)
        await bot.handle(message("/ports"))
        XCTAssertTrue(api.lastText.contains("3000 · node (PID 4120)"))
        await bot.handle(message("/killport 6379"))
        XCTAssertTrue(api.lastText.contains("can't be stopped"), "another user's process is refused before any button")
        await bot.handle(message("/killport 5432"))
        XCTAssertTrue(signals.sent.isEmpty, "nothing happens until Approve")
        let stop = try XCTUnwrap(api.lastKeyboardData().first { $0.hasPrefix("k:y:") })
        await bot.handle(press(stop, from: 2))
        XCTAssertTrue(signals.sent.isEmpty, "only the person who asked can approve")
        await bot.handle(press(stop))
        XCTAssertEqual(signals.sent.map(\.0), [SIGTERM])
        // Still running → a separate Force kill approval.
        let force = try XCTUnwrap(api.lastKeyboardData().first { $0.hasPrefix("k:y:") && $0 != stop })
        await bot.handle(press(stop))
        XCTAssertEqual(signals.sent.count, 1, "an approval can't be replayed")
        await bot.handle(press(force))
        XCTAssertEqual(signals.sent.last.map { $0.0 }, SIGKILL)
        withExtendedLifetime(container) {}
    }

    func testAgentKillPortNeedsExactApproval() async throws {
        let container = try ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = AgentEngine(context: container.mainContext, defaults: UserDefaults(suiteName: "ports-agent-\(UUID().uuidString)")!)
        let signals = FakeSignals(alive: [4120])
        engine.ports = killer(signals)
        engine.recordUsage = { _, _, _ in }
        var settings = AgentSettings()
        settings.approveMedium = false
        engine.settingsProvider = { settings }
        let adapter = ScriptedAdapter(turns: [ScriptedAdapter.tool("list_ports", [:]), ScriptedAdapter.tool("kill_port", ["port": 3000]),
                                              ScriptedAdapter.tool("kill_port", ["port": 22])])
        engine.adapterFactory = { _, _ in adapter }
        let task = engine.submit("free port 3000")
        let deadline = Date().addingTimeInterval(5)
        while task.state != .awaitingApproval, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        let actions = engine.fetchActions(taskID: task.uid)
        XCTAssertEqual(actions.first?.state, .succeeded, "list_ports is low risk")
        let kill = try XCTUnwrap(actions.last)
        XCTAssertEqual(kill.risk, .high)
        XCTAssertTrue(kill.summary.contains("node (PID 4120)"), "the approval shows the exact process")
        XCTAssertTrue(signals.sent.isEmpty)
        engine.decide(approvalID: try XCTUnwrap(engine.pendingApprovalID), approve: true)
        await engine.waitUntilIdle()
        XCTAssertEqual(signals.sent.map(\.1), [4120])
        XCTAssertEqual(engine.fetchActions(taskID: task.uid).last?.state, .blocked, "launchd on :22 is refused by policy, not asked about")
    }
}

/// Real lsof on this Mac. Opt in with MACPILOT_LIVE_TESTS=1.
@MainActor
final class PortKillerLiveTests: XCTestCase {
    func testRealListing() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACPILOT_LIVE_TESTS"] == "1", "live system test")
        let killer = PortKiller()
        await killer.refresh()
        XCTAssertNil(killer.error)
        for port in killer.ports.prefix(15) {
            print("LIVE:", port.proto, port.port, port.process, port.pid, port.user, port.projectName, PortProtection.reason(port) ?? "stoppable")
        }
    }
}
