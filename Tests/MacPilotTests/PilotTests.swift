import XCTest
@testable import MacPilot

final class PilotTests: XCTestCase {
    func testTaskCommands() {
        guard case let .addTask(title, due) = PilotCommand.parse("Hey Pilot, add a task call mom tomorrow at 5pm") else {
            return XCTFail("expected a task")
        }
        XCTAssertEqual(title, "Call mom")
        XCTAssertNotNil(due)
        XCTAssertTrue(Calendar.current.isDateInTomorrow(due!))
        guard case let .addTask(title2, due2) = PilotCommand.parse("remind me to buy milk") else { return XCTFail() }
        XCTAssertEqual(title2, "Buy milk")
        XCTAssertNil(due2)
    }

    func testRecordingAndDayCommands() {
        XCTAssertEqual(PilotCommand.parse("start recording"), .startMeeting)
        XCTAssertEqual(PilotCommand.parse("record this meeting"), .startMeeting)
        XCTAssertEqual(PilotCommand.parse("stop the recording."), .stopRecording)
        XCTAssertEqual(PilotCommand.parse("take a voice note"), .voiceNote)
        XCTAssertEqual(PilotCommand.parse("What's next today?"), .today)
        XCTAssertEqual(PilotCommand.parse("how is my day"), .today)
        XCTAssertEqual(PilotCommand.parse("never mind"), .cancel)
    }

    func testTimerNoteOpenAndChat() {
        XCTAssertEqual(PilotCommand.parse("set a timer for 25 minutes"), .timer(seconds: 1500, label: ""))
        XCTAssertEqual(PilotCommand.parse("new note buy a gift for Sam"), .newNote("buy a gift for Sam"))
        XCTAssertEqual(PilotCommand.parse("open my calendar"), .open(.calendar))
        XCTAssertEqual(PilotCommand.parse("Pilot, what is the capital of Japan?"), .chat("what is the capital of Japan"))
    }

    func testWakeWordAndSpeakable() {
        XCTAssertTrue(WakeWordListener.containsWakeWord("um hey pilot what's up"))
        XCTAssertFalse(WakeWordListener.containsWakeWord("the pilot landed"))
        XCTAssertEqual(PilotVoice.speakable("**Yes** — see [docs](https://x.y).\n- one\n- two"), "Yes — see docs. one two")
    }

    @MainActor
    func testShelfAddsUniqueFilesWithLimit() throws {
        let shelf = NotchShelf.shared
        let before = shelf.items
        defer { shelf.setPreview(before) }
        shelf.setPreview([])
        let dir = FileManager.default.temporaryDirectory
        let urls = (0..<15).map { dir.appendingPathComponent("shelf-\($0).txt") }
        shelf.add(urls + [urls[0]])
        XCTAssertEqual(shelf.items.count, NotchShelf.limit)
        XCTAssertEqual(shelf.items.last, urls[14])
        shelf.remove(urls[14])
        XCTAssertFalse(shelf.items.contains(urls[14]))
    }
}
