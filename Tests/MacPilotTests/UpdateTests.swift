import Foundation
import XCTest
@testable import MacPilot

final class UpdateTests: XCTestCase {
    private func item(_ version: String, build: String, day: Double) -> AppcastItem {
        AppcastItem(shortVersion: version, build: build, pubDate: Date(timeIntervalSince1970: 1_790_000_000 + day * 86_400),
                    url: "https://raw.githubusercontent.com/codecraft26/macPilot/main/releases/MacPilot-\(version).dmg",
                    length: 14_000_000, edSignature: "c2lnbmF0dXJlLWZvci1\(build)==", notesHTML: "<ul><li>Notes for \(version) & more</li></ul>")
    }

    func testAppcastIsValidXMLWithTheRightFields() throws {
        let xml = Appcast.render(items: [item("0.29.0", build: "37", day: 0), item("0.30.0", build: "38", day: 1)],
                                 feedURL: "https://raw.githubusercontent.com/codecraft26/macPilot/main/appcast.xml")
        let parser = XMLParser(data: Data(xml.utf8))
        XCTAssertTrue(parser.parse(), "well-formed XML: \(parser.parserError?.localizedDescription ?? "")")
        XCTAssertTrue(xml.contains(#"xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle""#))
        XCTAssertTrue(xml.contains("<sparkle:version>38</sparkle:version>"))
        XCTAssertTrue(xml.contains("<sparkle:shortVersionString>0.30.0</sparkle:shortVersionString>"))
        XCTAssertTrue(xml.contains("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"))
        XCTAssertTrue(xml.contains(#"length="14000000""#))
        XCTAssertTrue(xml.contains(#"sparkle:edSignature="c2lnbmF0dXJlLWZvci138==""#))
        XCTAssertTrue(xml.contains("<pubDate>"))
        XCTAssertLessThan(xml.range(of: "0.30.0")!.lowerBound, xml.range(of: "0.29.0")!.lowerBound, "newest first")

        let parsed = Appcast.parse(Data(xml.utf8))
        XCTAssertEqual(parsed.map(\.shortVersion), ["0.30.0", "0.29.0"])
        XCTAssertEqual(parsed.first?.build, "38")
        XCTAssertEqual(parsed.first?.length, 14_000_000)
        XCTAssertEqual(parsed.first?.edSignature, "c2lnbmF0dXJlLWZvci138==")
        XCTAssertTrue(parsed.first?.notesHTML.contains("Notes for 0.30.0 & more") == true, "release notes survive a round trip")
    }

    func testKeepsNewestThreeAndDropsItemsWithoutDMGs() {
        let items = ["0.26.0", "0.27.0", "0.28.0", "0.29.0", "0.30.0"].enumerated().map { item($0.element, build: String(34 + $0.offset), day: Double($0.offset)) }
        let three = Appcast.parse(Data(Appcast.render(items: items, feedURL: "f").utf8)).map(\.shortVersion)
        XCTAssertEqual(three, ["0.30.0", "0.29.0", "0.28.0"])
        let available: Set<String> = ["MacPilot-0.30.0.dmg"]
        let onlyExisting = Appcast.render(items: items, feedURL: "f") { available.contains(URL(string: $0.url)!.lastPathComponent) }
        XCTAssertEqual(Appcast.parse(Data(onlyExisting.utf8)).map(\.shortVersion), ["0.30.0"], "items whose DMG was removed are dropped (no broken links)")
        let duplicate = Appcast.render(items: [item("0.30.0", build: "38", day: 1), item("0.30.0", build: "38", day: 0)], feedURL: "f")
        XCTAssertEqual(Appcast.parse(Data(duplicate.utf8)).count, 1, "re-releasing a version replaces it")
    }

    func testReleaseNotesFromChangelog() {
        let changelog = "# Changelog\n\n## 0.30.0\n- **Auto-updates** with `Sparkle`\n- Check for Updates…\n\n## 0.29.0\n- Port killer\n"
        let html = Appcast.notesHTML(changelog: changelog, version: "0.30.0")
        XCTAssertEqual(html, "<ul><li><b>Auto-updates</b> with <code>Sparkle</code></li><li>Check for Updates…</li></ul>")
        XCTAssertFalse(html.contains("Port killer"), "only this version's section")
    }

    func testVersionComparison() {
        XCTAssertTrue(VersionCompare.isNewer("0.30.0", than: "0.29.0"))
        XCTAssertTrue(VersionCompare.isNewer("0.30.10", than: "0.30.9"), "numeric, not alphabetical")
        XCTAssertTrue(VersionCompare.isNewer("1.0", than: "0.99.99"))
        XCTAssertFalse(VersionCompare.isNewer("0.30", than: "0.30.0"), "missing parts are zero")
        XCTAssertFalse(VersionCompare.isNewer("0.29.0", than: "0.30.0"))
        XCTAssertFalse(VersionCompare.isNewer("0.30.0", than: "0.30.0"))
    }

    func testUpdateSettingsArePersisted() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "updates-\(UUID().uuidString)"))
        let prefs = UpdatePreferences(defaults: defaults)
        XCTAssertTrue(prefs.automaticallyChecks, "daily checks on by default")
        XCTAssertFalse(prefs.automaticallyInstalls, "automatic install off by default")
        prefs.automaticallyChecks = false
        prefs.automaticallyInstalls = true
        let reloaded = UpdatePreferences(defaults: defaults)
        XCTAssertFalse(reloaded.automaticallyChecks)
        XCTAssertTrue(reloaded.automaticallyInstalls)
        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false, "stored under Sparkle's own keys")
        XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, true)
    }

    func testInfoPlistUpdateKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Resources/Info.plist")) as? [String: Any])
        XCTAssertEqual(plist["SUFeedURL"] as? String, "https://raw.githubusercontent.com/codecraft26/macPilot/main/appcast.xml")
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUScheduledCheckInterval"] as? Int, 86_400)
        if let key = plist["SUPublicEDKey"] as? String {
            XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "an Ed25519 public key is 32 bytes")
        }
    }

    /// No private key material may ever be committed: PEM private keys or a Sparkle EdDSA private key.
    func testNoPrivateKeyInTrackedFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let pipe = Pipe()
        git.standardOutput = pipe
        try git.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        let files = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        XCTAssertGreaterThan(files.count, 50)
        let pem = try NSRegularExpression(pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----\s*[A-Za-z0-9+/=\s]{40,}"#)
        // Sparkle's exported private key is base64 of 64 or 96 bytes (88 or 128 characters); public keys are 44.
        let sparkle = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9+/])([A-Za-z0-9+/]{86}==|[A-Za-z0-9+/]{128})(?![A-Za-z0-9+/=])"#)
        for file in files where !file.hasSuffix(".dmg") && !file.hasSuffix(".zip") && !file.hasSuffix(".png") && !file.hasSuffix(".icns") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(pem.firstMatch(in: text, range: range), "PEM private key in \(file)")
            for match in sparkle.matches(in: text, range: range) {
                let candidate = (text as NSString).substring(with: match.range)
                let bytes = Data(base64Encoded: candidate)?.count ?? 0
                XCTAssertFalse(bytes == 64 || bytes == 96, "possible Sparkle private key in \(file)")
            }
        }
    }
}
