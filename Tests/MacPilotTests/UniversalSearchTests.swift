import Foundation
import XCTest
@testable import MacPilot

struct FakeProvider: SearchProviding {
    var source: SearchSource
    var timeout: TimeInterval = 1
    var delay: TimeInterval = 0
    var results: [UniversalResult]
    var fails = false
    func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if fails { throw URLError(.notConnectedToInternet) }
        return results
    }
}

@MainActor
final class UniversalSearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func result(_ source: SearchSource, _ title: String, days: Double = 1, score: Double = 0.8, from: String = "", messageID: String = "", target: SearchTarget? = nil) -> UniversalResult {
        UniversalResult(source: source, target: target ?? .note(UUID()), title: title, subtitle: "", snippet: title, date: now.addingTimeInterval(-days * 86_400),
                        textScore: score, from: from, messageID: messageID)
    }

    func testQueryParsingFilters() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let query = SearchQuery.parse("budget review in:mail from:sam after:2026-09-01 before:today", now: now, calendar: calendar)
        XCTAssertEqual(query.text, "budget review")
        XCTAssertEqual(query.sources, [.mail, .gmail])
        XCTAssertEqual(query.from, "sam")
        XCTAssertEqual(query.after, ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        XCTAssertEqual(query.before, calendar.startOfDay(for: now))
        XCTAssertEqual(SearchQuery.parse("x after:7d", now: now, calendar: calendar).after, calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(SearchQuery.parse("in:notes in:meetings plan").sources, [.notes, .transcripts])
        XCTAssertEqual(SearchQuery.parse("in:nowhere plan").text, "in:nowhere plan", "unknown filters stay as text")
        XCTAssertTrue(SearchQuery.parse("in:mail").isEmpty, "filters alone don't search")
        XCTAssertFalse(SearchQuery.parse("from:sam").isEmpty)
        XCTAssertEqual(SearchQuery.parse("Budget-Q3 plan!").words, ["budget", "q3", "plan"])
    }

    func testRankingOrder() {
        let fresh = result(.notes, "Q3 budget", days: 1, score: 0.9)
        let old = result(.notes, "Q3 budget (old)", days: 300, score: 0.9)
        let weak = result(.notes, "Budget mentions", days: 1, score: 0.3)
        let clip = result(.clipboard, "Q3 budget", days: 1, score: 0.9)
        let ranked = SearchRanking.rank([weak, old, clip, fresh], now: now)
        XCTAssertEqual(ranked.first?.title, "Q3 budget")
        XCTAssertEqual(ranked.first?.source, .notes, "source weight: a note beats the same clipboard text")
        XCTAssertLessThan(ranked.firstIndex { $0.title == "Q3 budget (old)" }!, ranked.firstIndex { $0.title == "Budget mentions" }!, "text match outweighs recency")
        XCTAssertGreaterThan(SearchRanking.recency(now, now: now), SearchRanking.recency(now.addingTimeInterval(-90 * 86_400), now: now))
        XCTAssertEqual(SearchRanking.textScore(words: ["budget", "q3"], title: "Q3 budget", body: ""), 1)
        XCTAssertEqual(SearchRanking.textScore(words: ["budget", "q3"], title: "", body: "budget"), 0.25)
    }

    func testDedupe() {
        let spotlight = result(.mail, "Offsite plan", days: 2, messageID: "<abc@mail>", target: .mailFile(URL(fileURLWithPath: "/tmp/1.emlx")))
        let gmail = result(.gmail, "Offsite plan", days: 2, score: 0.7, messageID: "abc@mail", target: .gmail(account: "a", id: "1", thread: "t"))
        let other = result(.gmail, "Offsite plan", days: 9, messageID: "zzz", target: .gmail(account: "a", id: "2", thread: "t2"))
        let ranked = SearchRanking.rank([gmail, spotlight, other], now: now)
        XCTAssertEqual(ranked.count, 2, "the same message from Spotlight and Gmail appears once")
        XCTAssertEqual(ranked.first?.source, .mail, "the better-scored copy is kept")
        let same = result(.notes, "Same", target: .note(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        XCTAssertEqual(SearchRanking.dedupe([same, same]).count, 1)
    }

    func testTimeoutDoesNotBlockOtherSources() async {
        let search = UniversalSearch(providers: [
            FakeProvider(source: .notes, results: [result(.notes, "Fast note")]),
            FakeProvider(source: .gmail, timeout: 0.2, delay: 5, results: [result(.gmail, "Slow mail")]),
            FakeProvider(source: .files, results: [], fails: true)
        ])
        search.semantic = false
        search.now = { self.now }
        let started = Date()
        search.search("note")
        await search.finish()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a slow source is cut off at its timeout")
        XCTAssertEqual(search.results.map(\.title), ["Fast note"])
        XCTAssertEqual(search.timedOut, [.gmail, .files], "slow and failing sources are reported, not waited for")
        XCTAssertTrue(search.pending.isEmpty)
    }

    func testFiltersApplyToResultsAndSources() async {
        let search = UniversalSearch(providers: [
            FakeProvider(source: .notes, results: [result(.notes, "Plan")]),
            FakeProvider(source: .mail, results: [result(.mail, "Plan from Sam", days: 3, from: "Sam Lee <sam@x.com>"),
                                                  result(.mail, "Plan from Ana", days: 3, from: "Ana <ana@x.com>"),
                                                  result(.mail, "Old plan", days: 400, from: "sam@x.com")])
        ])
        search.semantic = false
        search.now = { self.now }
        search.search("plan in:mail from:sam after:30d")
        await search.finish()
        XCTAssertEqual(search.results.map(\.title), ["Plan from Sam"])
    }

    func testStreamingNewSearchCancelsOld() async {
        let search = UniversalSearch(providers: [FakeProvider(source: .notes, delay: 0.3, results: [result(.notes, "Stale")])])
        search.semantic = false
        search.search("first")
        search.search("")
        await search.finish()
        XCTAssertTrue(search.results.isEmpty, "results from a superseded search never appear")
    }

    func testActionsRoutedCorrectly() {
        var log: [String] = []
        var router = SearchActionRouter()
        router.open = { log.append("open \($0.title)") }
        router.reveal = { log.append("reveal \($0.lastPathComponent)") }
        router.copy = { log.append("copy \($0)") }
        router.quickLook = { log.append("ql \($0.lastPathComponent)") }
        router.askAI = { log.append("ask \($0.prefix(10))") }
        router.addToShelf = { log.append("shelf \($0.map(\.lastPathComponent))") }
        router.replyDraft = { log.append("reply \($0.title)") }
        router.jump = { _, seconds in log.append("jump \(Int(seconds))") }

        let file = result(.files, "report.pdf", target: .file(URL(fileURLWithPath: "/tmp/report.pdf")))
        XCTAssertEqual(SearchActionRouter.actions(for: file), [.open, .reveal, .quickLook, .addToShelf, .copy, .askAI])
        for action in SearchActionRouter.actions(for: file) { router.perform(action, on: file) }
        XCTAssertEqual(log, ["open report.pdf", "reveal report.pdf", "ql report.pdf", "shelf [\"report.pdf\"]", "copy /tmp/report.pdf", "ask About this"])

        log = []
        let mail = result(.mail, "Offsite", target: .mailFile(URL(fileURLWithPath: "/tmp/1.emlx")))
        XCTAssertTrue(SearchActionRouter.actions(for: mail).contains(.replyDraft))
        router.perform(.replyDraft, on: mail)
        XCTAssertEqual(log, ["reply Offsite"])

        log = []
        let transcript = result(.transcripts, "Standup", target: .recording(UUID(), seconds: 754))
        XCTAssertTrue(SearchActionRouter.actions(for: transcript).contains(.jumpToTimestamp))
        router.perform(.jumpToTimestamp, on: transcript)
        XCTAssertEqual(log, ["jump 754"])
        XCTAssertFalse(SearchActionRouter.actions(for: result(.notes, "Note")).contains(.reveal), "no file actions for notes")
    }

    func testAskModeRespectsLocalOnly() async {
        let search = UniversalSearch(providers: [FakeProvider(source: .notes, results: [result(.notes, "Q3 budget is $40k")])])
        search.semantic = false
        search.search("budget")
        await search.finish()
        var settings = AgentSettings()
        settings.localOnly = true
        settings.provider = .anthropic
        let adapter = ScriptedAdapter(turns: [AgentModelResponse(text: "It's $40k [1].", calls: [], inputTokens: 1, outputTokens: 1, stop: .done)])
        var used: [AIProviderID] = []
        let answer = await search.answer("what's the budget?", settings: settings) { provider, _ in used.append(provider); return adapter }
        if Prefs.isEnabled(.ollama) {
            XCTAssertEqual(used, [.ollama])
        } else {
            XCTAssertTrue(answer.contains("Local-only"), answer)
            XCTAssertTrue(used.isEmpty, "nothing is sent to a cloud model")
        }
        settings.localOnly = false
        let cloud = await search.answer("what's the budget?", settings: settings) { provider, _ in used.append(provider); return adapter }
        XCTAssertEqual(cloud, "It's $40k [1].")
        XCTAssertTrue(adapter.seenMessages.last.map { "\($0)" }?.contains("[1] Notes") == true, "sources are numbered for citations")
    }

    func testGmailQueryAndShortcut() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let query = SearchQuery.parse("invoice from:billing@x.com after:2026-09-01", now: now, calendar: calendar)
        XCTAssertEqual(GmailSearch.gmailQuery(query), "invoice from:billing@x.com after:2026/09/01")
        XCTAssertEqual(ShortcutAction.search.defaultHotKey.displayString, "⌥F", "⌥Space is the assistant, so search defaults to ⌥F")
        XCTAssertNotEqual(ShortcutAction.search.defaultHotKey, ShortcutAction.assistant.defaultHotKey)
    }
}
