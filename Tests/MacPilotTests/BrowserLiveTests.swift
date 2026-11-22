import XCTest
@testable import MacPilot

/// Real WKWebView against a public page. Opt in with MACPILOT_LIVE_TESTS=1.
@MainActor
final class BrowserLiveTests: XCTestCase {
    func testOpenAndReadExampleDotCom() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACPILOT_LIVE_TESTS"] == "1", "live network test")
        let browser = AgentBrowser()
        try await browser.open(URL(string: "https://example.com/")!)
        let page = try await browser.read()
        XCTAssertTrue(page.title.contains("Example"))
        XCTAssertTrue(page.elements.contains { $0.tag == "a" && !$0.href.isEmpty })
        let element = try await browser.element(page.elements[0].id)
        XCTAssertEqual(element?.id, page.elements[0].id, "ids are stable across reads")
        let shot = try await browser.screenshot()
        XCTAssertFalse(shot.isEmpty)
    }
}
