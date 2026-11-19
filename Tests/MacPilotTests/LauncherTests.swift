import XCTest
@testable import MacPilot

final class CalculatorTests: XCTestCase {
    func testArithmetic() {
        XCTAssertEqual(Calculator.evaluate("2+3*4"), 14)
        XCTAssertEqual(Calculator.evaluate("(2+3)*4"), 20)
        XCTAssertEqual(Calculator.evaluate("2^3^2"), 512) // right-associative
        XCTAssertEqual(Calculator.evaluate("-5 + 10 / 4"), -2.5)
        XCTAssertEqual(Calculator.evaluate("1,200 x 3"), 3600)
        XCTAssertEqual(Calculator.evaluate("10 % 3"), 1)
    }

    func testRejectsNonMath() {
        XCTAssertNil(Calculator.evaluate("42")) // a plain number is not a calculation
        XCTAssertNil(Calculator.evaluate("notes 2+2"))
        XCTAssertNil(Calculator.evaluate("1/0"))
        XCTAssertNil(Calculator.evaluate("(1+2"))
        XCTAssertNil(Calculator.evaluate("2024-11-19 meeting"))
    }

    func testFormatting() {
        XCTAssertEqual(Calculator.format(14), "14")
        XCTAssertEqual(Calculator.format(2.5), "2.5")
        XCTAssertEqual(Calculator.format(1.0 / 3.0), "0.3333333333")
    }
}

final class LauncherExtrasTests: XCTestCase {
    func testUnitConversion() {
        XCTAssertEqual(UnitConversion.convert("10 km to mi")?.result ?? 0, 6.2137, accuracy: 0.001)
        XCTAssertEqual(UnitConversion.convert("212 f in c")?.result ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(UnitConversion.convert("2 kg -> lb")?.text, "4.4092 lb")
        XCTAssertNil(UnitConversion.convert("10 km to kg")) // different kinds
        XCTAssertNil(UnitConversion.convert("buy milk"))
    }

    func testURLsAndSearch() {
        XCTAssertEqual(WebLinks.url(from: "apple.com")?.absoluteString, "https://apple.com")
        XCTAssertEqual(WebLinks.url(from: "https://x.dev/a?b=1")?.host, "x.dev")
        XCTAssertNil(WebLinks.url(from: "new note"))
        XCTAssertNil(WebLinks.url(from: "v1.2"))
        XCTAssertEqual(WebLinks.search("Google", "swift actors")?.absoluteString, "https://www.google.com/search?q=swift%20actors")
    }

    func testWindowLayouts() {
        let screen = CGRect(x: 0, y: 25, width: 1500, height: 900)
        let window = CGRect(x: 100, y: 100, width: 600, height: 400)
        XCTAssertEqual(WindowLayout.leftHalf.frame(in: screen, current: window), CGRect(x: 0, y: 25, width: 750, height: 900))
        XCTAssertEqual(WindowLayout.rightThird.frame(in: screen, current: window), CGRect(x: 1000, y: 25, width: 500, height: 900))
        XCTAssertEqual(WindowLayout.center.frame(in: screen, current: window), CGRect(x: 450, y: 275, width: 600, height: 400))
        XCTAssertEqual(WindowLayout.maximize.frame(in: screen, current: window), screen)
    }

    func testUsageBoostFadesAndGroups() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries: [String: LauncherUsage.Entry] = [
            "app./Applications/Slack.app": .init(count: 7, last: now),
            "sys.lock": .init(count: 7, last: now.addingTimeInterval(-30 * 86_400))
        ]
        XCTAssertEqual(LauncherUsage.boost("app./Applications/Slack.app", entries: entries, now: now), 3, accuracy: 0.001)
        XCTAssertLessThan(LauncherUsage.boost("sys.lock", entries: entries, now: now), 0.5)
        XCTAssertEqual(LauncherUsage.boost("never", entries: entries, now: now), 0)
        XCTAssertEqual(LauncherUsage.stableID("calc:= 42"), "calc")
        XCTAssertEqual(LauncherUsage.stableID("web.Google:swift"), "web.Google")
    }
}

final class NotchTests: XCTestCase {
    func testMeetingLinks() {
        XCTAssertEqual(MeetingLink.find(in: ["Join: https://us02web.zoom.us/j/123456?pwd=abc."])?.host, "us02web.zoom.us")
        XCTAssertEqual(MeetingLink.find(in: ["", "Video call: https://meet.google.com/abc-defg-hij"])?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertNotNil(MeetingLink.find(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=y>"]))
        XCTAssertNil(MeetingLink.find(in: ["Room 4, https://example.com/agenda"]))
    }

    @MainActor
    func testCompactShapeWrapsTheNotch() {
        let controller = NotchController.shared
        let notch = NotchGeometry(notch: CGRect(x: 0, y: 0, width: 200, height: 32), hasHardwareNotch: true)
        controller.setPreview(geometry: notch, activity: .idle, expanded: false)
        XCTAssertEqual(controller.shapeSize, CGSize(width: 200, height: 32))
        controller.setPreview(geometry: notch, activity: .recording(paused: false), expanded: false)
        XCTAssertEqual(controller.shapeSize.width, 200 + NotchController.compactSideWidth * 2)
        controller.setPreview(geometry: notch, activity: .idle, expanded: true)
        XCTAssertEqual(controller.shapeSize, NotchController.expandedSize)
        let noNotch = NotchGeometry(notch: CGRect(x: 0, y: 0, width: 190, height: 24), hasHardwareNotch: false)
        controller.setPreview(geometry: noNotch, activity: .idle, expanded: false)
        XCTAssertEqual(controller.shapeSize, .zero, "nothing shows on screens without a notch when idle")
    }
}
