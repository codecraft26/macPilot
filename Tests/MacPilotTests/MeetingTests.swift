import XCTest
@testable import MacPilot

final class AnalysisParserTests: XCTestCase {
    func testParsesSnakeCaseInsideCodeFence() {
        let reply = """
        Here are the notes:
        ```json
        {"summary": "We agreed to ship Friday.",
         "decisions": ["Ship on Friday"],
         "action_items": [{"task": "Write release notes", "owner": "Sam", "due": "Thursday"},
                          {"task": "Tag the build", "owner": null, "due": "null"}],
         "deadlines": ["Friday — release"],
         "open_questions": [],
         "follow_up_email": "Hi all, ..."}
        ```
        """
        let analysis = MeetingIntelligence.parse(reply)
        XCTAssertEqual(analysis?.summary, "We agreed to ship Friday.")
        XCTAssertEqual(analysis?.decisions, ["Ship on Friday"])
        XCTAssertEqual(analysis?.actionItems.count, 2)
        XCTAssertEqual(analysis?.actionItems.first?.owner, "Sam")
        XCTAssertNil(analysis?.actionItems.last?.owner)
        XCTAssertNil(analysis?.actionItems.last?.due)
        XCTAssertEqual(analysis?.deadlines, ["Friday — release"])
        XCTAssertEqual(analysis?.followUpEmail, "Hi all, ...")
    }

    func testToleratesLooseShapes() {
        let reply = #"{"summary": ["Line one", "Line two"], "decisions": "Use Postgres", "actionItems": ["Email Ana"]}"#
        let analysis = MeetingIntelligence.parse(reply)
        XCTAssertEqual(analysis?.summary, "Line one\nLine two")
        XCTAssertEqual(analysis?.decisions, ["Use Postgres"])
        XCTAssertEqual(analysis?.actionItems.map(\.task), ["Email Ana"])
    }

    func testRejectsNonJSON() {
        XCTAssertNil(MeetingIntelligence.parse("Sorry, I can't help with that."))
        XCTAssertNil(MeetingIntelligence.parse("{}"))
    }
}

final class TranscriptFormattingTests: XCTestCase {
    func testTimestampFormat() {
        XCTAssertEqual(TranscriptSegment.format(0), "00:00")
        XCTAssertEqual(TranscriptSegment.format(65.9), "01:05")
        XCTAssertEqual(TranscriptSegment.format(3_725), "1:02:05")
        XCTAssertEqual(TranscriptSegment.format(-3), "00:00")
    }

    func testSRTExport() {
        let segments = [
            TranscriptSegment(start: 0, end: 2.5, speaker: "Me", text: "Hello."),
            TranscriptSegment(start: 3_661.25, end: 3_661.25, speaker: "Others", text: "Hi!")
        ]
        let srt = TranscriptExport.srt(segments)
        XCTAssertEqual(srt, """
        1
        00:00:00,000 --> 00:00:02,500
        Me: Hello.

        2
        01:01:01,250 --> 01:01:01,750
        Others: Hi!

        """)
    }

    func testPlainText() {
        let text = TranscriptExport.plainText([TranscriptSegment(start: 61, end: 62, speaker: "Me", text: "Okay")])
        XCTAssertEqual(text, "[01:01] Me: Okay")
    }
}

final class TranscriptParsingTests: XCTestCase {
    func testSegmentsAreOffset() {
        let json: [String: Any] = ["segments": [["start": 1.0, "end": 2.0, "text": " First "], ["start": 2, "end": 4, "text": "Second"]]]
        let segments = TranscriptParsing.segments(from: json, offset: 120, duration: 120, speaker: "Me")
        XCTAssertEqual(segments.map(\.start), [121, 122])
        XCTAssertEqual(segments.first?.text, "First")
        XCTAssertEqual(segments.first?.speaker, "Me")
    }

    func testPlainTextIsSpreadOverChunk() {
        let json: [String: Any] = ["text": "One two. Three four."]
        let segments = TranscriptParsing.segments(from: json, offset: 10, duration: 20, speaker: "Others")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.start, 10)
        XCTAssertEqual(segments.last?.end ?? 0, 30, accuracy: 0.001)
    }

    func testMergeInterleavesTracks() {
        let me = [TranscriptSegment(start: 0, end: 1, speaker: "Me", text: "a"), TranscriptSegment(start: 5, end: 6, speaker: "Me", text: "c")]
        let others = [TranscriptSegment(start: 2, end: 3, speaker: "Others", text: "b")]
        XCTAssertEqual(TranscriptMerger.merge([me, others]).map(\.text), ["a", "b", "c"])
    }
}

final class CalendarLogicTests: XCTestCase {
    private func span(_ id: String, _ start: Double, _ end: Double) -> EventSpan {
        EventSpan(id: id, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    func testConflicts() {
        let spans = [span("a", 0, 60), span("b", 30, 90), span("c", 90, 120), span("d", 200, 260)]
        XCTAssertEqual(EventSpan.conflictingIDs(spans), ["a", "b"])
        XCTAssertEqual(EventSpan.overlapping(span("new", 100, 210), in: spans).map(\.id), ["c", "d"])
    }

    func testQuickAddParsesAIReply() {
        let reply = #"{"title": "Lunch with Sam", "start": "2026-11-20T13:00:00+05:30", "end": "2026-11-20T14:00:00+05:30", "all_day": false, "location": "Cafe"}"#
        let draft = EventQuickAdd.parse(reply)
        XCTAssertEqual(draft?.title, "Lunch with Sam")
        XCTAssertEqual(draft?.location, "Cafe")
        XCTAssertEqual(draft.map { $0.end.timeIntervalSince($0.start) }, 3600)
    }

    func testCountdown() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Countdown.text(to: now.addingTimeInterval(600), end: now.addingTimeInterval(1200), now: now), "in 10 min")
        XCTAssertEqual(Countdown.text(to: now.addingTimeInterval(-60), end: now.addingTimeInterval(600), now: now), "Now")
        XCTAssertEqual(Countdown.text(to: now.addingTimeInterval(5400), end: now.addingTimeInterval(7200), now: now), "in 1 h 30 min")
    }
}

final class GoogleCalendarTests: XCTestCase {
    private let calendar = CalendarInfo(rawID: "team@group.calendar.google.com", source: .google, title: "Team",
                                        color: RGBColor(red: 0, green: 0, blue: 1), isWritable: true)

    func testPKCEChallengeIsBase64URLSHA256() {
        // Expected value: base64url(SHA-256(verifier)) without padding, computed independently with openssl.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r7wW1gFWFOEjXk"), "bwWFMyPfdG9qreDhH2lmftFx_dFeLDalzcT1gb_j68g")
        let verifier = PKCE.verifier()
        XCTAssertEqual(verifier.count, 43)
        XCTAssertFalse(verifier.contains("="))
    }

    func testTimedEventParsing() {
        let json: [String: Any] = [
            "id": "abc123", "summary": "Standup", "location": "Zoom",
            "start": ["dateTime": "2026-11-20T09:30:00+05:30"],
            "end": ["dateTime": "2026-11-20T09:45:00+05:30"],
            "attendees": [["email": "me@x.com", "self": true], ["email": "sam@x.com", "displayName": "Sam"], ["email": "bob@x.com"]],
            "reminders": ["useDefault": false, "overrides": [["method": "popup", "minutes": 10]]]
        ]
        let event = GoogleMapping.event(json, calendar: calendar)
        XCTAssertEqual(event?.title, "Standup")
        XCTAssertEqual(event?.isAllDay, false)
        XCTAssertEqual(event.map { $0.end.timeIntervalSince($0.start) }, 900)
        XCTAssertEqual(event?.attendees, ["Sam", "bob@x.com"])
        XCTAssertEqual(event?.alarmMinutes, 10)
        XCTAssertEqual(event?.id, "google:team@group.calendar.google.com|abc123")
        XCTAssertEqual(event.flatMap { GoogleMapping.eventID(from: $0.id) }, "abc123")
    }

    func testAllDayEventParsingAndCancelledSkipped() {
        let json: [String: Any] = ["id": "d1", "summary": "Offsite", "start": ["date": "2026-11-20"], "end": ["date": "2026-11-22"]]
        let event = GoogleMapping.event(json, calendar: calendar)
        XCTAssertEqual(event?.isAllDay, true)
        XCTAssertEqual(event.map { Calendar.current.dateComponents([.day], from: $0.start, to: $0.end).day }, 2)
        var cancelled = json
        cancelled["status"] = "cancelled"
        XCTAssertNil(GoogleMapping.event(cancelled, calendar: calendar))
    }

    func testEventBodyForAllDayUsesExclusiveEndDate() {
        var draft = EventDraft()
        draft.title = "Holiday"
        draft.isAllDay = true
        draft.start = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 24))!
        draft.end = draft.start
        let body = GoogleMapping.body(for: draft)
        XCTAssertEqual((body["start"] as? [String: String])?["date"], "2026-12-24")
        XCTAssertEqual((body["end"] as? [String: String])?["date"], "2026-12-25")
    }

    func testAccessTokenExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let token = AccessToken(response: ["access_token": "abc", "expires_in": 3600], now: now)
        XCTAssertEqual(token.validValue(now: now), "abc")
        XCTAssertEqual(token.validValue(now: now.addingTimeInterval(3_500)), "abc")
        XCTAssertNil(token.validValue(now: now.addingTimeInterval(3_545)), "treated as expired a minute early")
        XCTAssertNil(AccessToken().validValue(now: now))
    }

    func testLoopbackQueryParsing() {
        let request = "GET /?state=xyz&code=4%2F0Abc&scope=email HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n\r\n"
        let query = LoopbackReceiver.query(fromRequest: request)
        XCTAssertEqual(query["code"], "4/0Abc")
        XCTAssertEqual(query["state"], "xyz")
    }

    func testJWTEmail() {
        let payload = PKCE.base64URL(Data(#"{"email":"me@example.com"}"#.utf8))
        XCTAssertEqual(JWT.email("header.\(payload).signature"), "me@example.com")
    }
}
