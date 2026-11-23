import Foundation
import SwiftData
import XCTest
@testable import MacPilot

final class MockShortcuts: ShortcutsRunning {
    var installed: [String]? = [FocusShortcuts.onName, FocusShortcuts.offName, "Water Eject"]
    var runResult = true
    private(set) var ran: [String] = []
    func list() async -> [String]? { installed }
    func run(_ name: String) async -> Bool { ran.append(name); return runResult }
}

@MainActor
final class FocusTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func inputs(_ change: (inout FocusInputs) -> Void = { _ in }) -> FocusInputs {
        var inputs = FocusInputs(now: t0)
        change(&inputs)
        return inputs
    }

    func testTriggerEvaluationAndPriority() {
        var settings = FocusSettings()
        XCTAssertNil(FocusEvaluator.reason(inputs(), settings: settings))
        XCTAssertEqual(FocusEvaluator.reason(inputs { $0.currentMeeting = ("Standup", self.t0.addingTimeInterval(900)) }, settings: settings),
                       .meeting(title: "Standup", until: t0.addingTimeInterval(900)))
        XCTAssertEqual(FocusEvaluator.reason(inputs { $0.micInUseBy = "Zoom" }, settings: settings), .micInUse(app: "Zoom"))
        let busy = inputs {
            $0.currentMeeting = ("Standup", self.t0.addingTimeInterval(900))
            $0.micInUseBy = "Zoom"
            $0.sharingApp = "Zoom"
            $0.recording = true
        }
        XCTAssertEqual(FocusEvaluator.reasons(busy, settings: settings).map(\.kind), ["screenSharing", "recording", "meeting", "mic"], "priority order")
        XCTAssertEqual(FocusEvaluator.reason(inputs { $0.manualUntil = self.t0.addingTimeInterval(60); $0.sharingApp = "Zoom" }, settings: settings)?.kind, "manual", "manual wins")
        settings.screenSharing = false
        XCTAssertEqual(FocusEvaluator.reason(busy, settings: settings)?.kind, "recording", "disabled triggers are ignored")

        // Deep work: focus app in front for N minutes, optionally while typing.
        settings = FocusSettings()
        settings.deepWork = true
        settings.deepWorkMinutes = 5
        let xcode = { (minutes: Double, typing: TimeInterval) in self.inputs {
            $0.frontmostBundleID = "com.apple.dt.Xcode"; $0.frontmostName = "Xcode"
            $0.frontmostSince = self.t0.addingTimeInterval(-minutes * 60); $0.secondsSinceTyping = typing
        } }
        XCTAssertNil(FocusEvaluator.reason(xcode(3, 1), settings: settings))
        XCTAssertEqual(FocusEvaluator.reason(xcode(6, 1), settings: settings), .deepWork(app: "Xcode"))
        settings.deepWorkOnlyWhileTyping = true
        XCTAssertNil(FocusEvaluator.reason(xcode(6, 300), settings: settings), "not typing")

        // Not now: automatic triggers are ignored until then, manual still works.
        let snoozed = inputs { $0.micInUseBy = "Zoom"; $0.snoozedUntil = self.t0.addingTimeInterval(600) }
        XCTAssertNil(FocusEvaluator.reason(snoozed, settings: FocusSettings()))
    }

    func testGracePeriodPreventsFlapping() {
        var machine = FocusStateMachine()
        let first = FocusReason.meeting(title: "A", until: t0.addingTimeInterval(1_800))
        XCTAssertEqual(machine.step(reason: first, now: t0, grace: 120), .turnOn(first))
        XCTAssertEqual(machine.step(reason: nil, now: t0.addingTimeInterval(1_800), grace: 120), .none, "gap between meetings")
        let second = FocusReason.meeting(title: "B", until: t0.addingTimeInterval(3_600))
        XCTAssertEqual(machine.step(reason: second, now: t0.addingTimeInterval(1_860), grace: 120), .update(second), "back-to-back: no off/on")
        XCTAssertEqual(machine.step(reason: nil, now: t0.addingTimeInterval(3_600), grace: 120), .none)
        XCTAssertEqual(machine.step(reason: nil, now: t0.addingTimeInterval(3_700), grace: 120), .none)
        XCTAssertEqual(machine.step(reason: nil, now: t0.addingTimeInterval(3_721), grace: 120), .turnOff)
        var manual = FocusStateMachine()
        _ = manual.step(reason: .manual(until: t0), now: t0, grace: 120)
        XCTAssertEqual(manual.step(reason: nil, now: t0.addingTimeInterval(1), grace: 120), .turnOff, "manual ends exactly")
    }

    func testRestoresPreviousStateAndRunsTheRightShortcuts() async {
        let shortcuts = MockShortcuts()
        var current = FocusInputs(now: t0)
        let focus = FocusController()
        focus.inputsProvider = { _ in current }
        focus.now = { current.now }
        focus.shortcuts = shortcuts
        focus.systemFocusOn = { false }
        var settings = FocusSettings(); settings.graceSeconds = 60
        focus.settingsProvider = { settings }
        await focus.checkShortcuts()

        current.micInUseBy = "Zoom"
        await focus.evaluate()
        XCTAssertEqual(shortcuts.ran, [FocusShortcuts.onName])
        current.micInUseBy = nil
        current.now = t0.addingTimeInterval(30)
        await focus.evaluate()
        XCTAssertEqual(shortcuts.ran, [FocusShortcuts.onName], "still in the grace period")
        current.now = t0.addingTimeInterval(100)
        await focus.evaluate()
        XCTAssertEqual(shortcuts.ran, [FocusShortcuts.onName, FocusShortcuts.offName])
        XCTAssertFalse(focus.isActive)
        XCTAssertEqual(focus.history.first?.end, current.now)

        // A Focus the user already had on stays on: nothing is run.
        let already = MockShortcuts()
        focus.shortcuts = already
        focus.systemFocusOn = { true }
        current.micInUseBy = "Zoom"
        await focus.evaluate()
        current.micInUseBy = nil
        current.now = current.now.addingTimeInterval(1_000)
        await focus.evaluate()
        current.now = current.now.addingTimeInterval(1_000)
        await focus.evaluate()
        XCTAssertTrue(already.ran.isEmpty, "previous state restored: it was already on")
    }

    func testMissingShortcutsAreReported() async {
        let shortcuts = MockShortcuts()
        shortcuts.installed = ["Something else"]
        var current = FocusInputs(now: t0)
        let focus = FocusController()
        focus.inputsProvider = { _ in current }
        focus.shortcuts = shortcuts
        focus.systemFocusOn = { false }
        await focus.checkShortcuts()
        XCTAssertEqual(focus.missingShortcuts, [FocusShortcuts.onName, FocusShortcuts.offName])
        current.recording = true
        await focus.evaluate()
        XCTAssertTrue(focus.isActive, "MacPilot still holds its own alerts")
        XCTAssertTrue(shortcuts.ran.isEmpty, "nothing is run when the shortcut doesn't exist")
        XCTAssertTrue(focus.lastShortcutError?.contains("missing") == true)
        shortcuts.installed = nil
        await focus.checkShortcuts()
        XCTAssertEqual(focus.missingShortcuts.count, 2, "Shortcuts unavailable counts as missing")
        XCTAssertEqual(FocusShortcuts.missing(in: ["macpilot focus on", "MacPilot Focus Off"]), [], "names match case-insensitively")
    }

    func testHeldAlertsDeliveredAfterwards() async {
        let shortcuts = MockShortcuts()
        var current = FocusInputs(now: t0)
        let focus = FocusController()
        focus.inputsProvider = { c in var i = current; i.manualUntil = c.manualUntil; i.snoozedUntil = c.snoozedUntil; return i }
        focus.now = { current.now }
        focus.shortcuts = shortcuts
        focus.systemFocusOn = { false }
        var delivered: [[String]] = []
        focus.deliverSummary = { delivered.append($0) }
        XCTAssertTrue(focus.allow("Before focus", urgent: false), "not focused: shown")
        await focus.focus(minutes: 25)
        XCTAssertTrue(focus.isActive)
        XCTAssertFalse(focus.allow("Reminder: stretch", urgent: false))
        XCTAssertFalse(focus.allow("Speed test done", urgent: false))
        XCTAssertTrue(focus.allow("Agent needs your approval", urgent: true), "urgent alerts still show")
        current.now = t0.addingTimeInterval(26 * 60)
        await focus.evaluate()
        XCTAssertFalse(focus.isActive)
        XCTAssertEqual(delivered, [["Reminder: stretch", "Speed test done"]], "one summary when Focus ends")
        XCTAssertTrue(focus.held.isEmpty)
    }

    func testNotNowAndTelegram() async {
        let shortcuts = MockShortcuts()
        var current = FocusInputs(now: t0)
        let focus = FocusController()
        focus.inputsProvider = { c in var i = current; i.snoozedUntil = c.snoozedUntil; i.manualUntil = c.manualUntil; return i }
        focus.now = { current.now }
        focus.shortcuts = shortcuts
        focus.systemFocusOn = { false }
        current.micInUseBy = "Zoom"
        await focus.evaluate()
        XCTAssertTrue(focus.isActive)
        await focus.notNow()
        XCTAssertFalse(focus.isActive)
        await focus.evaluate()
        XCTAssertFalse(focus.isActive, "Not now holds off automatic triggers")

        let container = try! ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = AgentEngine(context: container.mainContext,
                                 defaults: UserDefaults(suiteName: "focus-\(UUID().uuidString)")!)
        let bot = TelegramBot(engine: engine, defaults: UserDefaults(suiteName: "focus-tg-\(UUID().uuidString)")!)
        bot.focus = focus
        let reply = await bot.focusCommand("50")
        XCTAssertEqual(reply, "Focus on for 50 minutes.")
        XCTAssertTrue(focus.isActive)
        let status = await bot.focusCommand("")
        XCTAssertTrue(status.contains("Focus until"))
        withExtendedLifetime(container) {}
    }
}
