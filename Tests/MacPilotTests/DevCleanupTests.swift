import SwiftData
import XCTest
@testable import MacPilot

/// A fake home with projects, caches and a symlink that points outside.
private struct CleanupFixture {
    let base: URL
    var home: URL { base.appendingPathComponent("home") }
    var developer: URL { home.appendingPathComponent("Developer") }
    var outside: URL { base.appendingPathComponent("outside") }
    let now = Date()

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("macpilot-cleanup-\(UUID().uuidString)")
        let fm = FileManager.default
        func file(_ url: URL, bytes: Int, modified: Date? = nil) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
        let old = Date().addingTimeInterval(-100 * 86_400)
        try file(developer.appendingPathComponent("old-app/node_modules/left-pad/index.js"), bytes: 40_000)
        try file(developer.appendingPathComponent("old-app/package.json"), bytes: 100, modified: old)
        try file(developer.appendingPathComponent("fresh-app/node_modules/react/index.js"), bytes: 20_000)
        try file(developer.appendingPathComponent("fresh-app/package.json"), bytes: 100)
        try file(developer.appendingPathComponent("tool/.build/debug/tool"), bytes: 30_000)
        try file(developer.appendingPathComponent("tool/Package.swift"), bytes: 100, modified: old)
        try file(developer.appendingPathComponent("py/.venv/pyvenv.cfg"), bytes: 100)
        try file(developer.appendingPathComponent("py/.venv/lib/site.py"), bytes: 10_000)
        try file(developer.appendingPathComponent("py/main.py"), bytes: 100, modified: old)
        try file(home.appendingPathComponent(".npm/_cacache/index-v5/aa"), bytes: 50_000)
        try file(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/MacPilot-abcdef/Build/x.o"), bytes: 60_000)
        // A link inside the root that leads out of it, with a node_modules behind it.
        try file(outside.appendingPathComponent("secret/node_modules/x.js"), bytes: 5_000)
        try fm.createSymbolicLink(at: developer.appendingPathComponent("escape"), withDestinationURL: outside.appendingPathComponent("secret"))
    }

    func scanner() -> CleanupScanner {
        CleanupScanner(home: home, roots: [developer], includeSwiftBuild: true, includeVenvs: true, runCommand: { _, _ in nil })
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

@MainActor
final class DevCleanupTests: XCTestCase {
    private var fixture: CleanupFixture!

    override func setUp() async throws { fixture = try CleanupFixture() }
    override func tearDown() async throws { fixture.remove() }

    private func runner(trashed: @escaping (URL) -> Void = { _ in }, removed: @escaping (URL) -> Void = { _ in },
                        commands: @escaping ([String]) -> Void = { _ in }) -> DevCleanup {
        let cleanup = DevCleanup()
        cleanup.trash = { trashed($0); try TestTrash.move($0) }
        cleanup.remove = { removed($0); try FileManager.default.removeItem(at: $0) }
        cleanup.runCommand = { commands($0); return ShellResult(status: 0, stdout: "", stderr: "") }
        cleanup.audit = { _ in }
        return cleanup
    }

    // MARK: Scanning and aggregation

    func testScanFindsCategoriesAndAggregatesSizes() async throws {
        let items = await fixture.scanner().scan()
        let categories = Set(items.map(\.category))
        XCTAssertEqual(categories, [.nodeModules, .swiftBuild, .pythonVenv, .npmCache, .derivedData])
        let modules = items.filter { $0.category == .nodeModules }
        XCTAssertEqual(Set(modules.map(\.title)), ["old-app", "fresh-app"], "the symlinked folder isn't followed")
        XCTAssertTrue(modules.allSatisfy { $0.bytes >= 20_000 })
        XCTAssertEqual(CleanupRules.total(items), items.map(\.bytes).reduce(0, +))
        let groups = CleanupRules.byCategory(items)
        XCTAssertEqual(groups.map(\.1), groups.map(\.1).sorted(by: >), "largest category first")
        XCTAssertEqual(groups.first { $0.0 == .nodeModules }?.1, modules.map(\.bytes).reduce(0, +))
    }

    func testOptionalCategoriesAreOffByDefault() async {
        var scanner = fixture.scanner()
        scanner.includeSwiftBuild = false
        scanner.includeVenvs = false
        let items = await scanner.scan()
        XCTAssertFalse(items.contains { $0.category == .swiftBuild || $0.category == .pythonVenv })
    }

    func testAgeFilter() {
        let now = Date()
        let items = [CleanupItem(category: .nodeModules, title: "a", url: URL(fileURLWithPath: "/a"), bytes: 1, modified: now.addingTimeInterval(-10 * 86_400)),
                     CleanupItem(category: .nodeModules, title: "b", url: URL(fileURLWithPath: "/b"), bytes: 1, modified: now.addingTimeInterval(-45 * 86_400)),
                     CleanupItem(category: .nodeModules, title: "c", url: URL(fileURLWithPath: "/c"), bytes: 1, modified: now.addingTimeInterval(-120 * 86_400)),
                     CleanupItem(category: .npmCache, title: "d", url: URL(fileURLWithPath: "/d"), bytes: 1, modified: nil)]
        XCTAssertEqual(CleanupRules.untouched(items, days: 0, now: now).map(\.title), ["a", "b", "c", "d"])
        XCTAssertEqual(CleanupRules.untouched(items, days: 30, now: now).map(\.title), ["b", "c", "d"])
        XCTAssertEqual(CleanupRules.untouched(items, days: 90, now: now).map(\.title), ["c", "d"])
    }

    func testRecentProjectIsSkippedUnlessExplicitlySelected() async {
        let items = await fixture.scanner().scan()
        let fresh = try! XCTUnwrap(items.first { $0.title == "fresh-app" })
        let old = try! XCTUnwrap(items.first { $0.title == "old-app" })
        XCTAssertTrue(fresh.isRecent, "package.json changed today")
        XCTAssertFalse(old.isRecent)
        let all = CleanupRules.selectAll(items)
        XCTAssertFalse(all.contains(fresh.id), "Select all leaves active projects alone")
        XCTAssertTrue(all.contains(old.id))
        XCTAssertTrue(CleanupRules.isRecent(Date().addingTimeInterval(-6 * 86_400)))
        XCTAssertFalse(CleanupRules.isRecent(Date().addingTimeInterval(-8 * 86_400)))
    }

    // MARK: Safety

    func testGuardRefusesSymlinkEscapesAndOutsidePaths() throws {
        let scanner = fixture.scanner()
        let guardian = CleanupGuard(roots: scanner.roots, cachePaths: scanner.knownCachePaths)
        let escape = fixture.developer.appendingPathComponent("escape")
        XCTAssertThrowsError(try guardian.check(escape)) { XCTAssertEqual($0 as? CleanupGuard.Refusal, .symlink(escape.path)) }
        let through = escape.appendingPathComponent("node_modules")
        XCTAssertThrowsError(try guardian.check(through)) { XCTAssertEqual($0 as? CleanupGuard.Refusal, .symlink(through.path)) }
        let outside = fixture.outside.appendingPathComponent("secret/node_modules")
        XCTAssertThrowsError(try guardian.check(outside)) { XCTAssertEqual($0 as? CleanupGuard.Refusal, .outside(outside.path)) }
        XCTAssertThrowsError(try guardian.check(fixture.developer), "a scanned root itself is never removed")
        XCTAssertThrowsError(try guardian.check(fixture.developer.appendingPathComponent("../Developer/../../outside/secret")))
        XCTAssertNoThrow(try guardian.check(fixture.developer.appendingPathComponent("old-app/node_modules")))
        XCTAssertNoThrow(try guardian.check(fixture.home.appendingPathComponent(".npm/_cacache")), "a known cache folder may go whole")
    }

    func testCleanRefusesAnInjectedEscapeAndTouchesNothing() async {
        var trashed: [URL] = []
        let cleanup = runner(trashed: { trashed.append($0) })
        await cleanup.scan(using: fixture.scanner())
        let forged = CleanupItem(category: .nodeModules, title: "evil", url: fixture.developer.appendingPathComponent("escape/node_modules"), bytes: 1)
        let outcome = await cleanup.clean([forged], permanent: false)
        XCTAssertEqual(outcome.refused.count, 1)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("secret/node_modules/x.js").path))
    }

    func testTrashByDefaultPermanentOnlyForCaches() async throws {
        var trashed: [String] = [], removed: [String] = []
        let cleanup = runner(trashed: { trashed.append($0.lastPathComponent) }, removed: { removed.append($0.lastPathComponent) })
        await cleanup.scan(using: fixture.scanner())
        let modules = try XCTUnwrap(cleanup.items.first { $0.title == "old-app" })
        let npm = try XCTUnwrap(cleanup.items.first { $0.category == .npmCache })
        let derived = try XCTUnwrap(cleanup.items.first { $0.category == .derivedData })

        XCTAssertFalse(CleanupRules.canDeletePermanently([modules, npm]), "mixed selections only go to the Trash")
        XCTAssertTrue(CleanupRules.canDeletePermanently([npm, derived]))

        // Asking for permanent on node_modules still uses the Trash.
        var outcome = await cleanup.clean([modules], permanent: true)
        XCTAssertEqual(trashed, ["node_modules"])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(outcome.freed, modules.bytes)

        outcome = await cleanup.clean([derived], permanent: false)
        XCTAssertEqual(trashed.last, derived.url?.lastPathComponent, "caches go to the Trash unless permanent is confirmed")
        XCTAssertTrue(removed.isEmpty)

        outcome = await cleanup.clean([npm], permanent: true)
        XCTAssertEqual(removed, ["_cacache"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".npm/_cacache").path))
        XCTAssertFalse(cleanup.items.contains(npm), "cleaned items leave the list")
    }

    func testConfirmationShowsCountSizeAndDestination() {
        let items = [CleanupItem(category: .nodeModules, title: "a", url: URL(fileURLWithPath: "/a"), bytes: 1_000_000),
                     CleanupItem(category: .dockerBuildCache, title: "Docker build cache", bytes: 2_000_000, command: CleanupCommands.dockerBuilderPrune)]
        let text = CleanupRules.confirmation(items, permanent: false)
        XCTAssertTrue(text.hasPrefix("2 items, \(CleanupFormat.bytes(3_000_000))."))
        XCTAssertTrue(text.contains("Files go to the Trash."))
        XCTAssertTrue(text.contains("  docker builder prune -f"), "the exact command is shown before it runs")
        XCTAssertTrue(CleanupRules.confirmation([items[0]], permanent: true).contains("deleted permanently"))
    }

    // MARK: Commands

    func testExactCommandStrings() {
        XCTAssertEqual(CleanupCommands.simctlDeleteUnavailable.joined(separator: " "), "xcrun simctl delete unavailable")
        XCTAssertEqual(CleanupCommands.dockerImagePrune.joined(separator: " "), "docker image prune -f")
        XCTAssertEqual(CleanupCommands.dockerContainerPrune.joined(separator: " "), "docker container prune -f")
        XCTAssertEqual(CleanupCommands.dockerBuilderPrune.joined(separator: " "), "docker builder prune -f")
        XCTAssertEqual(CleanupCommands.brewCleanup.joined(separator: " "), "brew cleanup")
        XCTAssertEqual(CleanupCommands.brewPreview.joined(separator: " "), "brew cleanup -n")
        XCTAssertEqual(CleanupCommands.dockerDF.joined(separator: " "), "docker system df --format {{json .}}")
        XCTAssertFalse(CleanupCommands.dockerImagePrune.contains("-a"), "only dangling images, never all unused ones")
    }

    func testCommandItemsRunExactlyTheirCommand() async {
        var ran: [[String]] = []
        let cleanup = runner(commands: { ran.append($0) })
        let item = CleanupItem(category: .unavailableSimulators, title: "2 unavailable simulators", bytes: 0, command: CleanupCommands.simctlDeleteUnavailable)
        let outcome = await cleanup.clean([item], permanent: false)
        XCTAssertEqual(ran, [["xcrun", "simctl", "delete", "unavailable"]])
        XCTAssertEqual(outcome.done, ["xcrun simctl delete unavailable"])
    }

    func testParsesDockerAndBrewOutput() async {
        let df = """
        {"Active":"2","Reclaimable":"1.2GB (40%)","Size":"3GB","TotalCount":"5","Type":"Images"}
        {"Active":"0","Reclaimable":"512MB","Size":"512MB","TotalCount":"3","Type":"Containers"}
        {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"2.5GB","Size":"2.5GB","TotalCount":"40","Type":"Build Cache"}
        """
        let sizes = CleanupCommands.parseDockerDF(df)
        XCTAssertEqual(sizes["Images"], 1_200_000_000)
        XCTAssertEqual(sizes["Containers"], 512_000_000)
        XCTAssertEqual(sizes["Build Cache"], 2_500_000_000)
        XCTAssertEqual(sizes["Local Volumes"], 0)
        XCTAssertEqual(CleanupCommands.parseBrewPreview("Would remove: /x (1.1MB)\n==> This operation would free approximately 845.3MB of disk space."), 845_300_000)
        XCTAssertEqual(CleanupCommands.parseBrewPreview(""), 0)

        // Scanner turns tool output into command items, but only when the tool exists on this Mac.
        var scanner = fixture.scanner()
        scanner.runCommand = { executable, arguments in
            if executable.hasSuffix("docker") { return df }
            if executable.hasSuffix("brew") { return "This operation would free approximately 1GB of disk space." }
            if arguments.starts(with: ["simctl", "list"]) { return "-- iOS 15.0 --\n    iPhone 8 (ABC) (Shutdown) (unavailable, runtime profile not found)" }
            return nil
        }
        let items = await scanner.commandItems()
        if CleanupCommands.executable("docker") != nil {
            XCTAssertEqual(items.first { $0.category == .dockerImages }?.command, CleanupCommands.dockerImagePrune)
            XCTAssertNil(items.first { $0.category == .dockerContainers && $0.bytes == 0 })
        } else {
            XCTAssertFalse(items.contains { $0.category == .dockerImages }, "no docker, no Docker items")
        }
        if CleanupCommands.executable("xcrun") != nil {
            XCTAssertEqual(items.first { $0.category == .unavailableSimulators }?.title, "1 unavailable simulator")
        }
    }

    func testLauncherPhrases() {
        XCTAssertTrue(CleanupRules.isLauncherQuery("Clean up developer files"))
        XCTAssertTrue(CleanupRules.isLauncherQuery("how much can I free?"))
        XCTAssertTrue(CleanupRules.isLauncherQuery("clean up dev"))
        XCTAssertTrue(CleanupRules.isLauncherQuery("delete node_modules"))
        XCTAssertFalse(CleanupRules.isLauncherQuery("kill port 3000"))
        XCTAssertFalse(CleanupRules.isLauncherQuery("cl"))
    }

    // MARK: Telegram

    func testTelegramReportsAndOnlyCleansCachesAfterApprove() async throws {
        let container = try ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = AgentEngine(context: container.mainContext, defaults: UserDefaults(suiteName: "cleanup-\(UUID().uuidString)")!)
        let bot = TelegramBot(engine: engine, defaults: UserDefaults(suiteName: "cleanup-tg-\(UUID().uuidString)")!)
        let api = MockBotAPI()
        bot.attach(transport: api)
        var trashed: [String] = [], removed: [String] = []
        bot.cleanup = runner(trashed: { trashed.append($0.path) }, removed: { removed.append($0.path) })
        bot.cleanupScanner = fixture.scanner()
        for user: Int64 in [1, 2] {
            let code = bot.newPairingCode()
            await bot.handle(TelegramIncoming(updateID: Int(user), userID: user, chatID: user, chatType: "private", isBot: false, name: "",
                                              kind: .message(text: "/pair \(code)", messageID: 1)))
        }
        func message(_ text: String, from user: Int64 = 1) -> TelegramIncoming {
            TelegramIncoming(updateID: Int.random(in: 10...999_999), userID: user, chatID: user, chatType: "private", isBot: false, name: "", kind: .message(text: text, messageID: 2))
        }
        func press(_ data: String, from user: Int64 = 1) -> TelegramIncoming {
            TelegramIncoming(updateID: Int.random(in: 10...999_999), userID: user, chatID: user, chatType: "private", isBot: false, name: "", kind: .callback(id: "c", data: data, messageID: 3))
        }

        await bot.handle(message("/cleanup"))
        XCTAssertTrue(api.lastText.contains("reclaimable"))
        XCTAssertTrue(api.lastText.contains("node_modules"), "the report covers everything")
        XCTAssertTrue(trashed.isEmpty && removed.isEmpty, "a report never deletes")
        let approve = try XCTUnwrap(api.lastKeyboardData().first { $0.hasPrefix("c:y:") })

        await bot.handle(press(approve, from: 2))
        XCTAssertTrue(trashed.isEmpty, "only the person who asked can approve")
        await bot.handle(press(approve))
        XCTAssertTrue(removed.isEmpty, "Telegram never deletes permanently")
        XCTAssertEqual(Set(trashed.map { URL(fileURLWithPath: $0).lastPathComponent }), ["_cacache", "MacPilot-abcdef"], "caches only: no node_modules, .build or venv")
        let count = trashed.count
        await bot.handle(press(approve))
        XCTAssertEqual(trashed.count, count, "an approval can't be replayed")
        XCTAssertEqual(TelegramBot.telegramCleanable([CleanupItem(category: .dockerImages, title: "x", bytes: 1, command: CleanupCommands.dockerImagePrune)]), [],
                       "CLI prunes stay on the Mac")
        withExtendedLifetime(container) {}
    }

    // MARK: Agent

    func testAgentScanIsLowRiskAndCleanupNeedsExactApproval() async throws {
        let container = try ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = AgentEngine(context: container.mainContext, defaults: UserDefaults(suiteName: "cleanup-agent-\(UUID().uuidString)")!)
        var trashed: [String] = []
        engine.cleanup = runner(trashed: { trashed.append($0.path) })
        engine.cleanupScanner = fixture.scanner()
        engine.recordUsage = { _, _, _ in }
        var settings = AgentSettings()
        settings.approveMedium = false
        engine.settingsProvider = { settings }
        let target = fixture.developer.appendingPathComponent("old-app/node_modules").path
        let adapter = ScriptedAdapter(turns: [ScriptedAdapter.tool("scan_cleanup", [:]),
                                              ScriptedAdapter.tool("run_cleanup", ["items": [target]]),
                                              ScriptedAdapter.tool("run_cleanup", ["items": [target], "permanent": true]),
                                              ScriptedAdapter.tool("run_cleanup", ["items": ["/etc/hosts"]])])
        engine.adapterFactory = { _, _ in adapter }
        let task = engine.submit("free some disk space")
        let deadline = Date().addingTimeInterval(10)
        while task.state != .awaitingApproval, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        let actions = engine.fetchActions(taskID: task.uid)
        XCTAssertEqual(actions.first?.state, .succeeded, "scan_cleanup is low risk")
        XCTAssertTrue(actions.first?.output.contains(target) == true)
        let run = try XCTUnwrap(actions.last)
        XCTAssertEqual(run.risk, .high)
        XCTAssertTrue(run.summary.contains(target), "the approval lists the exact path")
        XCTAssertTrue(run.summary.contains("Files go to the Trash"))
        XCTAssertTrue(trashed.isEmpty, "nothing happens before approval")
        engine.decide(approvalID: try XCTUnwrap(engine.pendingApprovalID), approve: true)
        await engine.waitUntilIdle()
        XCTAssertTrue(trashed.first?.hasSuffix("old-app/node_modules") == true, "exactly the approved folder went to the Trash")
        XCTAssertEqual(trashed.count, 1)
        let after = engine.fetchActions(taskID: task.uid)
        XCTAssertEqual(after.count, 4)
        XCTAssertEqual(after[2].state, .blocked, "permanent delete of node_modules is refused by policy")
        XCTAssertEqual(after[3].state, .blocked, "ids that weren't in the scan are refused")
        withExtendedLifetime(container) {}
    }
}

/// Real Xcode/cache/tool scan on this Mac (read-only). Opt in with MACPILOT_LIVE_TESTS=1.
final class DevCleanupLiveTests: XCTestCase {
    func testRealScanIsReadOnly() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACPILOT_LIVE_TESTS"] == "1", "live system test")
        let items = await CleanupScanner(roots: []).scan()
        for (category, bytes, list) in CleanupRules.byCategory(items) {
            print("cleanup-live:", category.title, CleanupFormat.bytes(bytes), list.count, list.first?.commandLine ?? "")
        }
        XCTAssertTrue(items.allSatisfy { $0.category.isCommand || $0.url != nil })
    }
}
