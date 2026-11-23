import XCTest
@testable import MacPilot

final class AutoRecordTests: XCTestCase {
    private let work = CalendarInfo(rawID: "w", source: .apple, title: "Work", color: RGBColor(red: 0, green: 0, blue: 1), isWritable: true)
    private let home = CalendarInfo(rawID: "h", source: .apple, title: "Home", color: RGBColor(red: 1, green: 0, blue: 0), isWritable: true)

    private func event(_ id: String, _ calendar: CalendarInfo, start: Date, minutes: Double = 30, attendees: [String] = ["Sam"],
                       location: String = "", allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(minutes * 60), isAllDay: allDay, location: location,
                      notes: "", attendees: attendees, calendar: calendar, alarmMinutes: nil)
    }

    func testRules() {
        let now = Date()
        let standup = event("standup", work, start: now)
        let lunch = event("lunch", home, start: now, attendees: [])
        let zoom = event("zoom", home, start: now, attendees: [], location: "https://zoom.us/j/123")
        var rules = MeetingAutoRecord.Rules()
        XCTAssertFalse(MeetingAutoRecord.shouldRecord(standup, rules: rules), "nothing is recorded by default")

        rules.marked = ["lunch"]
        XCTAssertTrue(MeetingAutoRecord.shouldRecord(lunch, rules: rules), "a marked event is recorded even without attendees")

        rules = MeetingAutoRecord.Rules(mode: .all)
        XCTAssertTrue(MeetingAutoRecord.shouldRecord(standup, rules: rules))
        XCTAssertFalse(MeetingAutoRecord.shouldRecord(lunch, rules: rules), "not a meeting: no attendees, no video link")
        XCTAssertTrue(MeetingAutoRecord.shouldRecord(zoom, rules: rules), "a video link counts as a meeting")
        rules.skipped = ["standup"]
        XCTAssertFalse(MeetingAutoRecord.shouldRecord(standup, rules: rules), "skipped wins over record-all")

        rules = MeetingAutoRecord.Rules(mode: .calendars, calendars: [work.id])
        XCTAssertTrue(MeetingAutoRecord.shouldRecord(standup, rules: rules))
        XCTAssertFalse(MeetingAutoRecord.shouldRecord(event("other", home, start: now), rules: rules))
        XCTAssertFalse(MeetingAutoRecord.shouldRecord(event("offsite", work, start: now, allDay: true), rules: rules), "all-day events never")
    }

    func testWhichMeetingStartsNow() {
        let now = Date()
        let rules = MeetingAutoRecord.Rules(mode: .all)
        let soon = event("soon", work, start: now.addingTimeInterval(45))
        let later = event("later", work, start: now.addingTimeInterval(600))
        let ending = event("ending", work, start: now.addingTimeInterval(-1_770), minutes: 30)
        XCTAssertEqual(MeetingAutoRecord.meetingToStart([later, soon, ending], rules: rules, started: [], now: now)?.id, "soon")
        XCTAssertNil(MeetingAutoRecord.meetingToStart([soon], rules: rules, started: [MeetingAutoRecord.occurrence(soon)], now: now),
                     "a meeting already started (and maybe stopped by hand) isn't restarted")
        XCTAssertNil(MeetingAutoRecord.meetingToStart([later, ending], rules: rules, started: [], now: now))
    }

    func testVideoLinkMode() {
        let now = Date()
        let rules = MeetingAutoRecord.Rules(mode: .videoLink)
        XCTAssertTrue(MeetingAutoRecord.shouldRecord(event("meet", home, start: now, attendees: [], location: "https://meet.google.com/abc-defg-hij"), rules: rules))
        XCTAssertFalse(MeetingAutoRecord.shouldRecord(event("room", work, start: now, location: "Room 4"), rules: rules),
                       "attendees alone aren't enough in video-link mode")
        var skip = rules
        skip.skipped = ["meet"]
        XCTAssertFalse(MeetingAutoRecord.shouldRecord(event("meet", home, start: now, location: "https://zoom.us/j/1"), rules: skip))
    }

    func testOffModeRecordsOnlyMarked() {
        let now = Date()
        var rules = MeetingAutoRecord.Rules(mode: .off, calendars: [work.id])
        XCTAssertFalse(MeetingAutoRecord.shouldRecord(event("standup", work, start: now), rules: rules), "calendars are ignored when off")
        XCTAssertFalse(rules.isActive)
        rules.marked = ["standup"]
        XCTAssertTrue(MeetingAutoRecord.shouldRecord(event("standup", work, start: now), rules: rules))
        XCTAssertTrue(rules.isActive)
    }

    func testAllWithoutMeetingCheck() {
        let rules = MeetingAutoRecord.Rules(mode: .all, onlyRealMeetings: false)
        XCTAssertTrue(MeetingAutoRecord.shouldRecord(event("focus", home, start: Date(), attendees: []), rules: rules))
    }

    func testRecordedFilterAndStartMessage() {
        let now = Date()
        let a = event("a", work, start: now), b = event("b", work, start: now), solo = event("solo", home, start: now, attendees: [])
        XCTAssertEqual(MeetingAutoRecord.recorded([a, b], ids: ["b"]).map(\.id), ["b"])
        XCTAssertTrue(MeetingAutoRecord.recorded([a, b], ids: []).isEmpty)
        XCTAssertTrue(MeetingAutoRecord.startMessage(for: a, remindToTell: true, stopAtEnd: true).contains("attendees"))
        XCTAssertTrue(MeetingAutoRecord.startMessage(for: solo, remindToTell: true, stopAtEnd: true).contains("tell"))
        XCTAssertEqual(MeetingAutoRecord.startMessage(for: a, remindToTell: false, stopAtEnd: true), "Stops when the meeting ends")
    }
}
