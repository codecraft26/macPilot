import XCTest
@testable import MacPilot

@MainActor
final class GoogleAccountsTests: XCTestCase {
    func testCalendarIDsCarryTheAccount() {
        let item: [String: Any] = ["id": "team@group.calendar.google.com", "summary": "Team", "accessRole": "writer"]
        let work = GoogleMapping.calendar(item, account: "me@work.com")!
        XCTAssertEqual(work.rawID, "me@work.com::team@group.calendar.google.com")
        XCTAssertEqual(work.account, "me@work.com")
        XCTAssertTrue(work.isWritable)
        let (account, calendarID) = GoogleMapping.split(work.rawID)
        XCTAssertEqual(account, "me@work.com")
        XCTAssertEqual(calendarID, "team@group.calendar.google.com")
        // Event ids still resolve with the account inside the calendar part.
        let eventID = GoogleMapping.compositeID(calendar: work.rawID, event: "abc123")
        XCTAssertEqual(GoogleMapping.eventID(from: eventID), "abc123")
    }

    func testSameCalendarInTwoAccountsShowsOnceFromTheEditableAccount() {
        let shared: [String: Any] = ["id": "family@group.calendar.google.com", "summary": "Family", "accessRole": "reader"]
        let sharedOwner: [String: Any] = ["id": "family@group.calendar.google.com", "summary": "Family", "accessRole": "owner"]
        let personal: [String: Any] = ["id": "me@gmail.com", "summary": "Me", "accessRole": "owner"]
        let calendars = [GoogleMapping.calendar(shared, account: "me@work.com")!,
                         GoogleMapping.calendar(personal, account: "me@gmail.com")!,
                         GoogleMapping.calendar(sharedOwner, account: "me@gmail.com")!]
        let result = GoogleMapping.deduplicated(calendars)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.title == "Family" }?.account, "me@gmail.com")
    }

    func testDistinctCalendarsWithTheSameNameStaySeparate() {
        let a = GoogleMapping.calendar(["id": "a@x.com", "summary": "Primary", "accessRole": "owner"], account: "a@x.com")!
        let b = GoogleMapping.calendar(["id": "b@y.com", "summary": "Primary", "accessRole": "owner"], account: "b@y.com")!
        XCTAssertEqual(GoogleMapping.deduplicated([a, b]).count, 2)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(GoogleCalendarService.refreshTokenAccount(for: "Me@Gmail.com"), "google.refreshToken.me@gmail.com")
    }
}
