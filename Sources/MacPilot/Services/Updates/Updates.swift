import Foundation
import Observation
import Sparkle

/// Auto-updates with Sparkle 2. Updates are EdDSA-signed; the public key is SUPublicEDKey in Info.plist and the
/// feed is SUFeedURL (appcast.xml on the main branch). Nothing is installed without Sparkle verifying the signature.
@Observable
@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    /// Sparkle's own controller (standard UI: "A new version is available", release notes, install & relaunch).
    private var controller: SPUStandardUpdaterController?
    private(set) var latestKnown: AppcastItem?
    private(set) var lastFeedCheck: Date?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// Sparkle only runs inside the bundled app with a feed and a public key configured.
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    func start() {
        guard isAvailable, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        guard let controller else { return }
        controller.checkForUpdates(nil)
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Sparkle stores these in the app's user defaults (SUEnableAutomaticChecks / SUAutomaticallyUpdate).
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? UpdatePreferences(defaults: .standard).automaticallyChecks }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            var prefs = UpdatePreferences(defaults: .standard)
            prefs.automaticallyChecks = newValue
        }
    }

    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? UpdatePreferences(defaults: .standard).automaticallyInstalls }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            var prefs = UpdatePreferences(defaults: .standard)
            prefs.automaticallyInstalls = newValue
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// Read-only look at the feed (for Telegram /version). Never downloads or installs anything.
    func latestFromFeed() async -> AppcastItem? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, let url = URL(string: raw),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return latestKnown }
        latestKnown = Appcast.parse(data).max { VersionCompare.isNewer($1.shortVersion, than: $0.shortVersion) }
        lastFeedCheck = Date()
        return latestKnown
    }

    func versionText() async -> String {
        var text = "MacPilot \(currentVersion) (build \(currentBuild))"
        guard isAvailable else { return text + "\nAuto-updates aren't set up in this build." }
        if let latest = await latestFromFeed() {
            text += VersionCompare.isNewer(latest.shortVersion, than: currentVersion)
                ? "\nUpdate available: \(latest.shortVersion). Install it on the Mac (MacPilot menu → Check for Updates…)."
                : "\nUp to date."
        } else {
            text += "\nCouldn't reach the update feed."
        }
        return text
    }
}

/// The two update settings, stored under Sparkle's own keys so Sparkle and MacPilot agree.
struct UpdatePreferences {
    static let checksKey = "SUEnableAutomaticChecks"
    static let installsKey = "SUAutomaticallyUpdate"
    let defaults: UserDefaults

    /// Daily checks are on by default.
    var automaticallyChecks: Bool {
        get { defaults.object(forKey: Self.checksKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.checksKey) }
    }

    /// Downloading and installing silently is off by default.
    var automaticallyInstalls: Bool {
        get { defaults.object(forKey: Self.installsKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.installsKey) }
    }
}

/// Sparkle-style version comparison: numeric parts left to right ("0.30.10" > "0.30.9"), missing parts are 0.
enum VersionCompare {
    static func parts(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// One release in appcast.xml.
struct AppcastItem: Equatable {
    var shortVersion: String
    var build: String
    var pubDate: Date
    var url: String
    var length: Int
    var edSignature: String
    var minimumSystemVersion = "14.0"
    var notesHTML = ""
}

/// Reads and writes the Sparkle appcast (RSS 2.0 with the sparkle namespace).
enum Appcast {
    static let sparkleNS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Newest first, at most `keep` items, and only items whose DMG still exists (no broken links).
    static func render(items: [AppcastItem], title: String = "MacPilot", feedURL: String, keep: Int = 3,
                       exists: (AppcastItem) -> Bool = { _ in true }) -> String {
        let kept = items.filter(exists)
            .sorted { VersionCompare.isNewer($0.shortVersion, than: $1.shortVersion) }
            .reduce(into: [AppcastItem]()) { list, item in if !list.contains(where: { $0.shortVersion == item.shortVersion }) { list.append(item) } }
            .prefix(keep)
        var xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="\(sparkleNS)" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>\(escape(title))</title>
            <link>\(escape(feedURL))</link>
            <description>MacPilot updates</description>
            <language>en</language>

        """
        for item in kept {
            xml += """
                <item>
                  <title>Version \(escape(item.shortVersion))</title>
                  <pubDate>\(rfc822(item.pubDate))</pubDate>
                  <sparkle:version>\(escape(item.build))</sparkle:version>
                  <sparkle:shortVersionString>\(escape(item.shortVersion))</sparkle:shortVersionString>
                  <sparkle:minimumSystemVersion>\(escape(item.minimumSystemVersion))</sparkle:minimumSystemVersion>
                  <description><![CDATA[\(item.notesHTML.replacingOccurrences(of: "]]>", with: "]]&gt;"))]]></description>
                  <enclosure url="\(escape(item.url))" length="\(item.length)" type="application/octet-stream" sparkle:edSignature="\(escape(item.edSignature))"/>
                </item>

            """
        }
        xml += "  </channel>\n</rss>\n"
        return xml
    }

    /// Items in an existing appcast (so a release keeps the previous ones).
    static func parse(_ data: Data) -> [AppcastItem] {
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = false
        xml.delegate = parser
        xml.parse()
        return parser.items
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: [String: String]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { current = [:] }
            if name == "enclosure", current != nil {
                current?["url"] = attributes["url"]
                current?["length"] = attributes["length"]
                current?["edSignature"] = attributes["sparkle:edSignature"]
                if let v = attributes["sparkle:version"] { current?["sparkle:version"] = v }
                if let v = attributes["sparkle:shortVersionString"] { current?["sparkle:shortVersionString"] = v }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "item", let item = current {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                items.append(AppcastItem(shortVersion: item["sparkle:shortVersionString"] ?? "", build: item["sparkle:version"] ?? "",
                                         pubDate: item["pubDate"].flatMap { formatter.date(from: $0) } ?? Date(), url: item["url"] ?? "",
                                         length: Int(item["length"] ?? "") ?? 0, edSignature: item["edSignature"] ?? "",
                                         minimumSystemVersion: item["sparkle:minimumSystemVersion"] ?? "14.0", notesHTML: item["description"] ?? ""))
                current = nil
            } else if current != nil, ["pubDate", "sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion", "description"].contains(name) {
                current?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text = ""
        }
    }

    /// "## 0.30.0" section of CHANGELOG.md → simple HTML (bullets and paragraphs).
    static func notesHTML(changelog: String, version: String) -> String {
        var inSection = false
        var lines: [String] = []
        for line in changelog.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                if inSection { break }
                inSection = line.dropFirst(3).trimmingCharacters(in: .whitespaces).hasPrefix(version)
                continue
            }
            if inSection { lines.append(line) }
        }
        var html = ""
        var inList = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { html += "<ul>"; inList = true }
                html += "<li>\(inline(String(line.dropFirst(2))))</li>"
            } else {
                if inList { html += "</ul>"; inList = false }
                if !line.isEmpty { html += "<p>\(inline(line))</p>" }
            }
        }
        if inList { html += "</ul>" }
        return html
    }

    private static func inline(_ text: String) -> String {
        escape(text).replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
            .replacingOccurrences(of: #"`(.+?)`"#, with: "<code>$1</code>", options: .regularExpression)
    }

    /// `MacPilot --update-appcast …` (used by scripts/release.sh): adds one release and rewrites appcast.xml.
    nonisolated static func runCLI(_ arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let path = value("--appcast"), let version = value("--version"), let build = value("--build"), let url = value("--url"),
              let length = value("--length").flatMap(Int.init), let signature = value("--signature"), let feed = value("--feed"),
              let releases = value("--releases-dir") else {
            FileHandle.standardError.write(Data("usage: MacPilot --update-appcast --appcast PATH --version V --build B --url URL --length N --signature SIG --feed URL --releases-dir DIR [--changelog PATH]\n".utf8))
            exit(2)
        }
        let existing = (try? Data(contentsOf: URL(fileURLWithPath: path))).map(parse) ?? []
        let changelog = value("--changelog").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let item = AppcastItem(shortVersion: version, build: build, pubDate: Date(), url: url, length: length, edSignature: signature,
                               notesHTML: notesHTML(changelog: changelog, version: version))
        let xml = render(items: [item] + existing.filter { $0.shortVersion != version }, feedURL: feed) { item in
            // Drop items whose DMG was removed from releases/.
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: releases).appendingPathComponent(URL(string: item.url)?.lastPathComponent ?? "").path)
        }
        do {
            try xml.write(toFile: path, atomically: true, encoding: .utf8)
            print("Updated \(path) with \(version)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Couldn't write \(path): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
