import AppKit
import ApplicationServices
import Foundation
import Observation

// MARK: - Quick links

/// "jira 123" → https://yourcompany.atlassian.net/browse/123
struct QuickLink: Codable, Identifiable, Hashable {
    var id = UUID()
    var keyword: String
    var name: String
    /// URL with {query} where the typed text goes.
    var template: String

    func url(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }

    static let defaults: [QuickLink] = [
        QuickLink(keyword: "g", name: "Google", template: "https://www.google.com/search?q={query}"),
        QuickLink(keyword: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query={query}"),
        QuickLink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}"),
        QuickLink(keyword: "maps", name: "Apple Maps", template: "https://maps.apple.com/?q={query}"),
        QuickLink(keyword: "wiki", name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search={query}"),
        QuickLink(keyword: "tr", name: "Google Translate", template: "https://translate.google.com/?sl=auto&tl=en&text={query}"),
        QuickLink(keyword: "so", name: "Stack Overflow", template: "https://stackoverflow.com/search?q={query}"),
        QuickLink(keyword: "jira", name: "Jira issue", template: "https://YOUR-COMPANY.atlassian.net/browse/{query}")
    ]
}

/// Words that begin with a semicolon and expand into longer text anywhere you type.
struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var keyword: String
    var name: String
    var text: String

    static let defaults: [Snippet] = [
        Snippet(keyword: ";date", name: "Today's date", text: "{date}"),
        Snippet(keyword: ";time", name: "Current time", text: "{time}"),
        Snippet(keyword: ";sig", name: "Email signature", text: "Best regards,\nYour Name"),
        Snippet(keyword: ";standup", name: "Stand-up template", text: "Yesterday:\n- \n\nToday:\n- \n\nBlockers:\n- ")
    ]

    /// Fills {date}, {time}, {datetime} and {clipboard}.
    static func expand(_ text: String, now: Date = Date(), clipboard: String? = nil) -> String {
        var result = text
        result = result.replacingOccurrences(of: "{date}", with: now.formatted(date: .long, time: .omitted))
        result = result.replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
        result = result.replacingOccurrences(of: "{datetime}", with: now.formatted(date: .long, time: .shortened))
        if result.contains("{clipboard}") {
            result = result.replacingOccurrences(of: "{clipboard}", with: clipboard ?? NSPasteboard.general.string(forType: .string) ?? "")
        }
        return result
    }
}

@Observable
@MainActor
final class SnippetLibrary {
    static let shared = SnippetLibrary()

    var links: [QuickLink] { didSet { save(links, key: Self.linksKey) } }
    var snippets: [Snippet] { didSet { save(snippets, key: Self.snippetsKey) } }

    private static let linksKey = "launcher.quickLinks"
    private static let snippetsKey = "launcher.snippets"

    private init() {
        links = Self.load(Self.linksKey) ?? QuickLink.defaults
        snippets = Self.load(Self.snippetsKey) ?? Snippet.defaults
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// "jira 123" → (link, "123"). Keywords match case-insensitively.
    func matchLink(_ input: String) -> (QuickLink, String)? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let keyword = parts[0].lowercased()
        guard let link = links.first(where: { $0.keyword.lowercased() == keyword }) else { return nil }
        return (link, String(parts[1]).trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Text expansion

/// Watches typing and replaces a snippet keyword with its text. Needs Accessibility; password fields are never seen.
@MainActor
final class SnippetExpander {
    static let shared = SnippetExpander()

    private var monitor: Any?
    private var typed = ""
    private var isExpanding = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.snippetsEnabled) }

    func start() {
        stop()
        guard Self.isEnabled, PasteService.isTrusted else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let chars = event.characters ?? ""
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated { SnippetExpander.shared.handle(chars: chars, keyCode: keyCode, flags: flags) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        typed = ""
    }

    private func handle(chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard !isExpanding else { return }
        if flags.contains(.command) || flags.contains(.control) || keyCode == 53 || (123...126).contains(keyCode) {
            typed = ""
            return
        }
        if keyCode == 51 { // delete
            typed = String(typed.dropLast())
            return
        }
        guard !chars.isEmpty else { return }
        if chars == "\r" || chars == "\t" {
            typed = ""
            return
        }
        typed = String((typed + chars).suffix(40))
        if let snippet = Self.match(typed: typed, in: SnippetLibrary.shared.snippets) {
            expand(snippet)
        }
    }

    /// The snippet whose keyword the typed text ends with (keyword must start a word).
    static func match(typed: String, in snippets: [Snippet]) -> Snippet? {
        snippets
            .filter { !$0.keyword.isEmpty && typed.hasSuffix($0.keyword) }
            .filter { snippet in
                let before = typed.dropLast(snippet.keyword.count).last
                return before == nil || before!.isWhitespace || before!.isPunctuation && snippet.keyword.first?.isPunctuation == true
            }
            .max { $0.keyword.count < $1.keyword.count }
    }

    private func expand(_ snippet: Snippet) {
        isExpanding = true
        typed = ""
        let text = Snippet.expand(snippet.text)
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<snippet.keyword.count {
            CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)?.post(tap: .cghidEventTap)
        }
        let snapshot = PasteboardSnapshot.capture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            PasteService.paste(text: text, into: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                snapshot.restore()
                ClipboardMonitor.shared.ignoreCurrentChange()
                SnippetExpander.shared.isExpanding = false
            }
        }
    }
}
