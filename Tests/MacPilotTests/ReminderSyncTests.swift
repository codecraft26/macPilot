import XCTest
@testable import MacPilot

final class ReminderSyncTests: XCTestCase {
    func testFingerprintNormalizes() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let a = ReminderFields(title: " Call bank ", notes: "", due: due, priority: .high, completed: false)
        let b = ReminderFields(title: "Call bank", notes: "", due: due.addingTimeInterval(10), priority: .high, completed: false)
        XCTAssertEqual(a.fingerprint, b.fingerprint, "whitespace and seconds don't count as changes")
        var c = b
        c.completed = true
        XCTAssertNotEqual(b.fingerprint, c.fingerprint)
    }

    func testPriorityMapping() {
        for priority in TaskPriority.allCases {
            XCTAssertEqual(ReminderFields.taskPriority(ReminderFields.ekPriority(priority)), priority)
        }
        XCTAssertEqual(ReminderFields.taskPriority(3), .high)
        XCTAssertEqual(ReminderFields.taskPriority(7), .low)
    }

    func testMergeDecisions() {
        XCTAssertEqual(ReminderMergeDecision.decide(local: "a", remote: "a", stored: "a"), .none)
        XCTAssertEqual(ReminderMergeDecision.decide(local: "b", remote: "a", stored: "a"), .pushToReminder)
        XCTAssertEqual(ReminderMergeDecision.decide(local: "a", remote: "b", stored: "a"), .pullFromReminder)
        XCTAssertEqual(ReminderMergeDecision.decide(local: "b", remote: "c", stored: "a"), .merge)
        XCTAssertEqual(ReminderMergeDecision.decide(local: "b", remote: "b", stored: "a"), .none)
        XCTAssertEqual(ReminderMergeDecision.decide(local: "a", remote: nil, stored: "a"), .reminderDeleted)
        XCTAssertEqual(ReminderMergeDecision.decide(local: "b", remote: nil, stored: "a"), .recreateReminder)
    }
}
