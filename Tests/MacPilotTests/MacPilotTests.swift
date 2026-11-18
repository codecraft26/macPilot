import Carbon.HIToolbox
import XCTest
@testable import MacPilot

final class SSETests: XCTestCase {
    func testPayloadStripsPrefixAndSpace() {
        XCTAssertEqual(SSE.payload(fromLine: "data: {\"a\":1}"), "{\"a\":1}")
        XCTAssertEqual(SSE.payload(fromLine: "data:[DONE]"), "[DONE]")
    }

    func testNonDataLinesAreIgnored() {
        XCTAssertNil(SSE.payload(fromLine: "event: message_start"))
        XCTAssertNil(SSE.payload(fromLine: ""))
    }
}

final class RedactorTests: XCTestCase {
    func testRedactsKeys() {
        let text = "Incorrect API key provided: sk-proj-abc123XYZ***def. Also sk-ant-api03-secretvalue"
        let redacted = Redactor.redact(text)
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("secretvalue"))
        XCTAssertTrue(redacted.contains("[redacted key]"))
    }
}

final class HotKeyTests: XCTestCase {
    func testDisplayString() {
        let hotKey = HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | cmdKey), keyLabel: "Space")
        XCTAssertEqual(hotKey.displayString, "⌥⌘Space")
    }

    func testDefaultsAreUnique() {
        let ids = Set(ShortcutAction.allCases.map(\.hotKeyID))
        XCTAssertEqual(ids.count, ShortcutAction.allCases.count)
    }
}

final class AttachmentTests: XCTestCase {
    func testComposeIncludesFiles() {
        let composed = Attachment.compose("Review this", [Attachment(name: "a.swift", content: "let x = 1")])
        XCTAssertTrue(composed.hasPrefix("Review this"))
        XCTAssertTrue(composed.contains("Attached file: a.swift"))
        XCTAssertTrue(composed.contains("let x = 1"))
    }
}

final class RecurrenceTests: XCTestCase {
    func testWeeklyAddsSevenDays() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = TaskRecurrence.weekly.next(after: start)!
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: next).day, 7)
        XCTAssertNil(TaskRecurrence.none.next(after: start))
    }
}
