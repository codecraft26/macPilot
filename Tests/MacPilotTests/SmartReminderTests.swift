import Foundation
import SwiftData
import XCTest
@testable import MacPilot

@MainActor
final class SmartReminderTests: XCTestCase {
    private var container: ModelContainer!
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // Mon 21 Sep 2026, UTC evening

    override func setUp() async throws {
        container = try ModelContainer(for: SmartReminder.self, TaskItem.self, AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func engine() -> (ReminderEngine, () -> [String]) {
        let engine = ReminderEngine(context: container.mainContext)
        var delivered: [String] = []
        engine.deliver = { reminder, _ in delivered.append(reminder.text) }
        engine.upcomingEvents = { [] }
        return (engine, { delivered })
    }

    // MARK: Parser

    func testParserCases() throws {
        func parse(_ text: String) -> ReminderDraft? { ReminderParser.parse(text, now: now) }
        XCTAssertEqual(parse("remind me to check PR reviews when I open Xcode")?.trigger, .appOpened(app: "Xcode"))
        XCTAssertEqual(parse("remind me to check PR reviews when I open Xcode")?.text, "Check PR reviews")
        XCTAssertEqual(parse("remind me to check PR reviews when I open Xcode")?.confirmation, "When you open Xcode → “Check PR reviews” · once")
        XCTAssertEqual(parse("when I open Slack remind me to post standup")?.trigger, .appOpened(app: "Slack"))
        XCTAssertEqual(parse("remind me to stretch when I quit Zoom")?.trigger, .appQuit(app: "zoom.us"))
        XCTAssertEqual(parse("remind me to plug in when I join the Office-5G wifi")?.trigger, .wifiJoined(ssid: "Office-5G"), "SSID keeps its case")
        XCTAssertEqual(parse("remind me to lock up when I leave the Home wifi")?.trigger, .wifiLeft(ssid: "Home"))
        XCTAssertEqual(parse("remind me to take my pills when I unlock my Mac")?.trigger, .unlock)
        XCTAssertEqual(parse("remind me to drink water when my Mac wakes")?.trigger, .wake)
        XCTAssertEqual(parse("remind me to buy milk when I get home")?.trigger, .arrive(place: "Home"))
        XCTAssertEqual(parse("remind me to water the plants when I leave work")?.trigger, .leave(place: "Work"))
        XCTAssertEqual(parse("remind me to read the agenda 10 minutes before my next meeting")?.trigger, .beforeMeeting(minutes: 10))
        XCTAssertEqual(parse("remind me to read the agenda before my next meeting")?.trigger, .beforeMeeting(minutes: 5))
        if case let .time(at, repeating)? = parse("remind me in 20 minutes to check the oven")?.trigger {
            XCTAssertEqual(at.timeIntervalSince(now), 1_200, accuracy: 1)
            XCTAssertNil(repeating)
        } else { XCTFail("in 20 minutes") }
        if case let .time(_, repeating)? = parse("remind me every weekday at 8:30 to plan my day")?.trigger {
            XCTAssertEqual(repeating?.weekdays, [2, 3, 4, 5, 6])
        } else { XCTFail("recurring") }
        let windowed = try XCTUnwrap(parse("remind me to check email when I open Mail on weekdays between 9am and 5pm"))
        XCTAssertEqual(windowed.conditions, ReminderConditions(weekdaysOnly: true, windowStart: 540, windowEnd: 1_020))
        XCTAssertEqual(windowed.text, "Check email")
        let every = try XCTUnwrap(parse("whenever I open Xcode remind me to pull main"))
        XCTAssertEqual(every.repeatMode, .everyTime)
        XCTAssertGreaterThan(every.cooldownMinutes, 0, "every-time reminders get a cooldown")
        XCTAssertEqual(parse("/remind check PR reviews when I open Xcode")?.text, "Check PR reviews")
        XCTAssertNil(parse("hello there"))
        XCTAssertNil(parse("remind me to do things"), "no trigger, no reminder")
    }

    func testLLMOutputIsSchemaValidated() {
        let good = #"{"text":"Back up photos","trigger":{"type":"wifiJoined","ssid":"Home"},"weekdaysOnly":false,"windowStart":null,"windowEnd":null,"everyTime":true}"#
        XCTAssertEqual(ReminderLLMParser.decode(good, now: now)?.trigger, .wifiJoined(ssid: "Home"))
        XCTAssertEqual(ReminderLLMParser.decode(good, now: now)?.repeatMode, .everyTime)
        XCTAssertNil(ReminderLLMParser.decode(#"{"text":"x","trigger":{"type":"teleport"}}"#, now: now), "unknown trigger type")
        XCTAssertNil(ReminderLLMParser.decode(#"{"text":"","trigger":{"type":"wake"}}"#, now: now), "empty text")
        XCTAssertNil(ReminderLLMParser.decode(#"{"text":"x","trigger":{"type":"appOpened"}}"#, now: now), "missing app")
        XCTAssertNil(ReminderLLMParser.decode(#"{"text":"x","trigger":{"type":"time","at":"2001-01-01T00:00:00Z"}}"#, now: now), "time in the past")
        XCTAssertNil(ReminderLLMParser.decode(#"{"error":"unsupported"}"#, now: now))
        XCTAssertNil(ReminderLLMParser.decode("not json", now: now))
    }

    func testLocalOnlyUsesDeterministicParser() async {
        var settings = AgentSettings()
        settings.localOnly = true
        let adapter = ScriptedAdapter(turns: [AgentModelResponse(text: #"{"text":"x","trigger":{"type":"wake"}}"#, calls: [], inputTokens: 1, outputTokens: 1, stop: .done)])
        let simple = await ReminderInput.parse("remind me to stretch when I unlock my Mac", settings: settings, now: now, adapterFactory: { _, _ in adapter })
        XCTAssertEqual(simple.source, .rules)
        XCTAssertEqual(simple.draft?.trigger, .unlock)
        let hard = await ReminderInput.parse("remind me about the thing whenever the vibes are right", settings: settings, now: now, adapterFactory: { _, _ in adapter })
        XCTAssertNil(hard.draft)
        XCTAssertEqual(adapter.calls, 0, "local-only: the text is never sent to a model")

        settings.localOnly = false
        let viaModel = await ReminderInput.parse("remind me about the thing whenever the vibes are right", settings: settings, now: now, adapterFactory: { _, _ in adapter })
        XCTAssertEqual(viaModel.source, .model)
        XCTAssertEqual(adapter.calls, 1)
        XCTAssertFalse(adapter.seenMessages.first.map { "\($0)" }?.contains("latitude") ?? true, "only the words are sent")
    }

    // MARK: Matching and firing

    func testTriggerMatching() {
        XCTAssertTrue(ReminderRules.matches(.appOpened(app: "Xcode"), .appOpened(name: "Xcode", bundleID: "com.apple.dt.Xcode")))
        XCTAssertTrue(ReminderRules.matches(.appOpened(app: "com.apple.dt.Xcode"), .appOpened(name: "Xcode", bundleID: "com.apple.dt.Xcode")))
        XCTAssertFalse(ReminderRules.matches(.appOpened(app: "Xcode"), .appQuit(name: "Xcode", bundleID: "")))
        XCTAssertTrue(ReminderRules.matches(.wifiJoined(ssid: "Office"), .wifiChanged(from: "Home", to: "Office")))
        XCTAssertFalse(ReminderRules.matches(.wifiJoined(ssid: "Office"), .wifiChanged(from: "Office", to: "Office")), "already on it")
        XCTAssertTrue(ReminderRules.matches(.wifiLeft(ssid: "Office"), .wifiChanged(from: "Office", to: nil)))
        XCTAssertTrue(ReminderRules.matches(.arrive(place: "Home"), .entered(place: "home")))
        XCTAssertFalse(ReminderRules.matches(.arrive(place: "Home"), .exited(place: "Home")))
        XCTAssertTrue(ReminderRules.matches(.wake, .wake))
        XCTAssertFalse(ReminderRules.matches(.wake, .unlock))
    }

    func testCooldownAndOnceOnly() {
        let (engine, delivered) = engine()
        var clock = now
        engine.now = { clock }
        let once = engine.add(ReminderParser.parse("remind me to check reviews when I open Xcode", now: now)!, source: "")
        let every = engine.add(ReminderDraft(text: "Pull main", trigger: .appOpened(app: "Xcode"), repeatMode: .everyTime, cooldownMinutes: 60), source: "")
        let open = ReminderEvent.appOpened(name: "Xcode", bundleID: "com.apple.dt.Xcode")
        engine.handle(open)
        XCTAssertEqual(delivered().sorted(), ["Check reviews", "Pull main"])
        clock = clock.addingTimeInterval(10 * 60)
        engine.handle(open)
        XCTAssertEqual(delivered().count, 2, "once: already reminded; every time: inside the 60-minute cooldown")
        clock = clock.addingTimeInterval(61 * 60)
        engine.handle(open)
        XCTAssertEqual(delivered().filter { $0 == "Pull main" }.count, 2, "after the cooldown it fires again")
        XCTAssertEqual(delivered().filter { $0 == "Check reviews" }.count, 1, "the once reminder never repeats")
        engine.snoozeUntilNextTrigger(once)
        engine.handle(open)
        XCTAssertEqual(delivered().filter { $0 == "Check reviews" }.count, 2, "“until next time” fires on the next trigger")
        engine.done(every)
        clock = clock.addingTimeInterval(3 * 3_600)
        engine.handle(open)
        XCTAssertEqual(delivered().filter { $0 == "Pull main" }.count, 2, "done reminders stop")
    }

    func testWeekdayAndTimeWindowConditions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ text: String) -> Date {
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: text)!
        }
        let rules = ReminderConditions(weekdaysOnly: true, windowStart: 9 * 60, windowEnd: 17 * 60)
        XCTAssertTrue(rules.allows(date("2026-09-21T10:00:00Z"), calendar: calendar), "Monday 10:00")
        XCTAssertFalse(rules.allows(date("2026-09-21T18:00:00Z"), calendar: calendar), "after hours")
        XCTAssertFalse(rules.allows(date("2026-09-20T10:00:00Z"), calendar: calendar), "Sunday")
        let night = ReminderConditions(windowStart: 22 * 60, windowEnd: 6 * 60)
        XCTAssertTrue(night.allows(date("2026-09-21T23:30:00Z"), calendar: calendar), "window across midnight")
        XCTAssertTrue(night.allows(date("2026-09-21T05:00:00Z"), calendar: calendar))
        XCTAssertFalse(night.allows(date("2026-09-21T12:00:00Z"), calendar: calendar))
        XCTAssertEqual(ReminderRules.verdict(enabled: true, done: false, repeatMode: .everyTime, firedCount: 0, lastFired: nil, cooldownMinutes: 0,
                                             snoozedUntil: nil, conditions: rules, now: date("2026-09-20T10:00:00Z"), calendar: calendar),
                       .skip("outside its days or hours"))
    }

    func testTimeAndMeetingTriggers() throws {
        let (engine, delivered) = engine()
        var clock = now
        engine.now = { clock }
        engine.add(ReminderDraft(text: "Check the oven", trigger: .time(at: now.addingTimeInterval(600), repeating: nil)), source: "")
        engine.tick()
        XCTAssertTrue(delivered().isEmpty)
        clock = clock.addingTimeInterval(601)
        engine.tick()
        engine.tick()
        XCTAssertEqual(delivered(), ["Check the oven"], "fires once")

        let calendarInfo = CalendarInfo(rawID: "w", source: .apple, title: "Work", color: RGBColor(red: 0, green: 0, blue: 1), isWritable: true)
        let meeting = CalendarEvent(id: "m1", title: "Standup", start: clock.addingTimeInterval(4 * 60), end: clock.addingTimeInterval(20 * 60),
                                    isAllDay: false, location: "", notes: "", attendees: [], calendar: calendarInfo, alarmMinutes: nil)
        engine.upcomingEvents = { [meeting] }
        engine.add(ReminderDraft(text: "Open the agenda", trigger: .beforeMeeting(minutes: 5), repeatMode: .everyTime, cooldownMinutes: 0), source: "")
        engine.tick()
        engine.tick()
        XCTAssertEqual(delivered().filter { $0 == "Open the agenda" }.count, 1, "each meeting once")
    }

    // MARK: Telegram

    func testTelegramSnoozeDoneBoundToPairedUser() async throws {
        let agent = AgentEngine(context: container.mainContext, defaults: UserDefaults(suiteName: "rem-\(UUID().uuidString)")!)
        let bot = TelegramBot(engine: agent, defaults: UserDefaults(suiteName: "rem-tg-\(UUID().uuidString)")!)
        let api = MockBotAPI()
        bot.attach(transport: api)
        let (reminders, _) = engine()
        bot.reminders = reminders
        bot.parseReminder = { ReminderParser.parse($0) }
        let me: Int64 = 777, other: Int64 = 888
        for user in [me, other] {
            let code = bot.newPairingCode()
            await bot.handle(TelegramIncoming(updateID: Int(user), userID: user, chatID: user, chatType: "private", isBot: false, name: "",
                                              kind: .message(text: "/pair \(code)", messageID: 1)))
        }
        await bot.handle(TelegramIncoming(updateID: 10, userID: me, chatID: me, chatType: "private", isBot: false, name: "",
                                          kind: .message(text: "/remind check PR reviews when I open Xcode", messageID: 2)))
        let reminder = try XCTUnwrap(reminders.reminders.first)
        XCTAssertEqual(reminder.trigger, .appOpened(app: "Xcode"))
        XCTAssertTrue(api.lastText.contains("When you open Xcode → “Check PR reviews”"))

        bot.sendReminder(reminder, context: "When you open Xcode")
        try? await Task.sleep(for: .milliseconds(100))
        let mine = try XCTUnwrap(api.calls.last { ($0.params["chat_id"] as? Int64) == me && $0.params["reply_markup"] != nil })
        let buttons = ((mine.params["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: Any]]])?.first?.compactMap { $0["callback_data"] as? String } ?? []
        let done = try XCTUnwrap(buttons.first { $0.hasPrefix("r:d:") })
        func press(_ data: String, from user: Int64) async {
            await bot.handle(TelegramIncoming(updateID: Int.random(in: 100...999_999), userID: user, chatID: user, chatType: "private", isBot: false, name: "",
                                              kind: .callback(id: "cb", data: data, messageID: 1)))
        }
        await press(done, from: other)
        XCTAssertFalse(reminder.isDone, "another paired user can't press my buttons")
        XCTAssertEqual(api.calls.last { $0.method == "answerCallbackQuery" }?.params["text"] as? String, "These buttons belong to someone else.")
        await press(done, from: me)
        XCTAssertTrue(reminder.isDone)
        await press(done, from: me)
        XCTAssertEqual(api.calls.last { $0.method == "answerCallbackQuery" }?.params["text"] as? String, "These buttons are out of date.", "single use")

        // Free text that reads like a reminder becomes one (not an agent task).
        await bot.handle(TelegramIncoming(updateID: 11, userID: me, chatID: me, chatType: "private", isBot: false, name: "",
                                          kind: .message(text: "remind me to stretch when I unlock my Mac", messageID: 3)))
        XCTAssertEqual(reminders.reminders.count, 2)
        XCTAssertTrue(agent.recentTasks(limit: 5).isEmpty)
    }

    func testPilotRoutesContextReminders() {
        XCTAssertEqual(PilotCommand.parse("remind me to check reviews when I open Xcode"), .smartReminder("remind me to check reviews when I open Xcode"))
        if case .addTask = PilotCommand.parse("remind me to call mom tomorrow at 5pm") {} else { XCTFail("time-only reminders stay tasks") }
    }
}
