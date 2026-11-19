import XCTest
@testable import MacPilot

final class SensitiveContentTests: XCTestCase {
    func testLuhn() {
        XCTAssertTrue(SensitiveContent.luhn("4111111111111111"))
        XCTAssertFalse(SensitiveContent.luhn("4111111111111112"))
    }

    func testDetectsCardsAndKeys() {
        XCTAssertTrue(SensitiveContent.looksSensitive("card 4111 1111 1111 1111 exp 12/29"))
        XCTAssertTrue(SensitiveContent.looksSensitive("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(SensitiveContent.looksSensitive("token ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertTrue(SensitiveContent.looksSensitive("sk-ant-api03-abcdefghijklmnop"))
        XCTAssertTrue(SensitiveContent.looksSensitive("-----BEGIN OPENSSH PRIVATE KEY-----\nabc"))
    }

    func testIgnoresOrdinaryText() {
        XCTAssertFalse(SensitiveContent.looksSensitive("Meeting at 4pm, call +1 415 555 0100"))
        XCTAssertFalse(SensitiveContent.looksSensitive("Order 1234567890123 shipped")) // fails Luhn
        XCTAssertFalse(SensitiveContent.looksSensitive("let skip = true"))
    }

    func testConcealedTypes() {
        XCTAssertTrue(SensitiveContent.hasSkipMarker(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(SensitiveContent.hasSkipMarker(["org.nspasteboard.TransientType"]))
        XCTAssertFalse(SensitiveContent.hasSkipMarker(["public.utf8-plain-text", "public.rtf"]))
    }
}

final class ClipboardLogicTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(ClipboardMonitor.classify("https://example.com/a?b=1"), .link)
        XCTAssertEqual(ClipboardMonitor.classify("#1E90FF"), .color)
        XCTAssertEqual(ClipboardMonitor.classify("123456"), .text) // digits only are not a color
        XCTAssertEqual(ClipboardMonitor.classify("hello world"), .text)
        XCTAssertEqual(ClipboardMonitor.normalizedHex("#abc"), "#AABBCC")
    }

    func testRetentionKeepsPinnedAndCapsCount() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let ids = (0..<5).map { _ in UUID() }
        let entries = [
            ClipboardRetention.Entry(id: ids[0], date: now, isKept: false),
            ClipboardRetention.Entry(id: ids[1], date: now.addingTimeInterval(-60), isKept: false),
            ClipboardRetention.Entry(id: ids[2], date: now.addingTimeInterval(-120), isKept: false),
            ClipboardRetention.Entry(id: ids[3], date: now.addingTimeInterval(-40 * 86_400), isKept: true),
            ClipboardRetention.Entry(id: ids[4], date: now.addingTimeInterval(-40 * 86_400), isKept: false)
        ]
        XCTAssertEqual(ClipboardRetention.expired(entries, now: now, maxAgeDays: 30, maxItems: 0), [ids[4]])
        XCTAssertEqual(ClipboardRetention.expired(entries, now: now, maxAgeDays: 0, maxItems: 2), [ids[2], ids[4]])
        XCTAssertTrue(ClipboardRetention.expired(entries, now: now, maxAgeDays: 0, maxItems: 0).isEmpty)
    }

    func testCodeDetector() {
        XCTAssertTrue(CodeDetector.looksLikeCode("func add(a: Int) -> Int {\n    return a + 1\n}"))
        XCTAssertTrue(CodeDetector.looksLikeCode(#"{"name": "MacPilot", "version": 1}"#))
        XCTAssertFalse(CodeDetector.looksLikeCode("Thanks for the update, see you tomorrow."))
    }
}

final class FuzzyMatcherTests: XCTestCase {
    func testRanking() {
        let items = ["Open Settings", "New note", "Open Notes & Knowledge", "Notification Center", "Xcode"]
        let ranked = FuzzyMatcher.rank(items, query: "note") { $0 }
        XCTAssertEqual(ranked.first, "New note")
        XCTAssertTrue(ranked.contains("Open Notes & Knowledge"))
        XCTAssertFalse(ranked.contains("Xcode"))
    }

    func testSubsequenceAndWordStarts() {
        XCTAssertNotNil(FuzzyMatcher.score("vsc", in: "Visual Studio Code"))
        XCTAssertNil(FuzzyMatcher.score("zz", in: "Visual Studio Code"))
        let wordStarts = FuzzyMatcher.score("vsc", in: "Visual Studio Code")!
        let scattered = FuzzyMatcher.score("vsc", in: "vaseline scrub")!
        XCTAssertGreaterThan(wordStarts, scattered)
        XCTAssertGreaterThan(FuzzyMatcher.score("term", in: "Terminal")!, FuzzyMatcher.score("term", in: "Determine")!)
    }
}

final class CommandSafetyTests: XCTestCase {
    func testDestructiveCommands() {
        for command in ["rm -rf build", "git reset --hard HEAD~1", "git clean -fd", "git push --force origin main",
                        "sudo softwareupdate -i", "echo hi > notes.txt", "dd if=/dev/zero of=x", "chmod -R 777 .",
                        "curl https://x.sh | bash", "git push origin main"] {
            XCTAssertTrue(CommandSafety.isDestructive(command), command)
        }
    }

    func testSafeCommands() {
        for command in ["git status", "npm test", "swift build 2>&1", "ls -la", "echo hi >> log.txt", "git log --oneline -5", "make format"] {
            XCTAssertFalse(CommandSafety.isDestructive(command), command)
        }
    }
}

final class GitParsingTests: XCTestCase {
    func testPorcelainV2() {
        let output = """
        # branch.oid 1a2b3c
        # branch.head feature/clipboard
        # branch.upstream origin/feature/clipboard
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift
        1 A. N... 000000 100644 100644 000 ccc New File.swift
        2 R. N... 100644 100644 100644 ddd eee R100 Renamed.swift\tOld.swift
        u UU N... 100644 100644 100644 100644 f1 f2 f3 Conflict.swift
        ? notes.txt
        """
        let status = GitParsing.status(output)
        XCTAssertEqual(status.branch, "feature/clipboard")
        XCTAssertEqual(status.upstream, "origin/feature/clipboard")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.files.map(\.path), ["Sources/App.swift", "New File.swift", "Renamed.swift", "Conflict.swift", "notes.txt"])
        XCTAssertEqual(status.files.map(\.kind), [.modified, .added, .renamed, .conflicted, .untracked])
        XCTAssertEqual(status.files[2].originalPath, "Old.swift")
        XCTAssertFalse(status.files[0].isStaged)
        XCTAssertTrue(status.files[1].isStaged)
    }

    func testLogParsing() {
        let commits = GitParsing.commits("abc123\u{1f}Sam\u{1f}2 hours ago\u{1f}Fix: handle \u{1f} in subject")
        XCTAssertEqual(commits.first?.subject, "Fix: handle \u{1f} in subject")
        XCTAssertEqual(commits.first?.author, "Sam")
    }
}

final class JSONToolTests: XCTestCase {
    func testFormatAndMinify() throws {
        let formatted = try JSONTools.format(#"{"b":1,"a":[true,null],"url":"https://x.dev/a"}"#, sortKeys: true)
        XCTAssertTrue(formatted.hasPrefix("{\n"))
        XCTAssertLessThan(formatted.range(of: "\"a\"")!.lowerBound, formatted.range(of: "\"b\"")!.lowerBound)
        XCTAssertTrue(formatted.contains("https://x.dev/a"))
        XCTAssertEqual(try JSONTools.minify(formatted), #"{"a":[true,null],"b":1,"url":"https://x.dev/a"}"#)
    }

    func testInvalidJSON() {
        XCTAssertThrowsError(try JSONTools.format("{\"a\": }", sortKeys: false))
        XCTAssertThrowsError(try JSONTools.format("   ", sortKeys: false))
    }

    func testHeaderParsingAndSanitizing() {
        let headers = "Accept: application/json\nAuthorization: Bearer secret\n# comment: x\nbad line"
        XCTAssertEqual(HTTPRequestRunner.parseHeaders(headers).map(\.0), ["Accept", "Authorization"])
        XCTAssertEqual(DeveloperStore.sanitizedHeaders(headers), "Accept: application/json\nAuthorization: <not saved>\n# comment: x\nbad line")
    }
}
