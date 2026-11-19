import XCTest
@testable import MacPilot

final class SnippetTests: XCTestCase {
    func testQuickLinkURL() {
        let link = QuickLink(keyword: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query={query}")
        XCTAssertEqual(link.url(for: "lofi beats")?.absoluteString, "https://www.youtube.com/results?search_query=lofi%20beats")
    }

    @MainActor
    func testMatchLink() {
        let library = SnippetLibrary.shared
        let saved = library.links
        defer { library.links = saved }
        library.links = QuickLink.defaults
        XCTAssertEqual(library.matchLink("GH macpilot")?.0.name, "GitHub")
        XCTAssertEqual(library.matchLink("jira ABC-123")?.1, "ABC-123")
        XCTAssertNil(library.matchLink("gh"))
        XCTAssertNil(library.matchLink("unknown thing"))
    }

    func testSnippetMatchNeedsWordStart() {
        let snippets = [Snippet(keyword: ";sig", name: "Sig", text: "x"), Snippet(keyword: ";signature", name: "Long", text: "y")]
        XCTAssertEqual(SnippetExpander.match(typed: "hello ;sig", in: snippets)?.name, "Sig")
        XCTAssertEqual(SnippetExpander.match(typed: ";signature", in: snippets)?.name, "Long")
        XCTAssertNil(SnippetExpander.match(typed: "abc;sig", in: snippets))
        XCTAssertNil(SnippetExpander.match(typed: "hello ;si", in: snippets))
    }

    func testPlaceholders() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = Snippet.expand("On {date}: {clipboard}", now: now, clipboard: "pasted")
        XCTAssertTrue(text.hasSuffix(": pasted"))
        XCTAssertFalse(text.contains("{date}"))
    }
}
