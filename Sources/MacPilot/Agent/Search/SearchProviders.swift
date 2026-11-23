import Foundation
import SwiftData

/// MacPilot's own data, Spotlight files and Mail, calendar, and Gmail search.
@MainActor
enum LocalSearchProviders {
    static func all() -> [SearchProviding] {
        [NotesSearch(), TranscriptSearch(), MemorySearch(), LoopsSearch(), SnippetsSearch(), ClipboardSearch(), TasksSearch(),
         RemindersSearch(), AgentHistorySearch(), CalendarSearch(), FilesSearch(), MailSpotlightSearch(), GmailSearch()]
    }

    static var context: ModelContext { Persistence.container.mainContext }

    /// Every query word appears somewhere (or the query has no words, e.g. only filters).
    nonisolated static func matches(_ words: [String], _ texts: String...) -> Bool {
        let haystack = texts.joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    nonisolated static func excerpt(_ text: String, around words: [String], length: Int = 160) -> String {
        let lower = text.lowercased()
        guard let word = words.first, let range = lower.range(of: word) else { return String(text.prefix(length)) }
        let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
        let start = text.index(text.startIndex, offsetBy: max(0, offset - 50))
        let piece = String(text[start...].prefix(length)).replacingOccurrences(of: "\n", with: " ")
        return (start > text.startIndex ? "…" : "") + piece
    }

    static let folderKey = "search.folders"
    static var folders: [String] {
        get { UserDefaults.standard.stringArray(forKey: folderKey) ?? ["~/Documents", "~/Desktop", "~/Downloads"].map { ($0 as NSString).expandingTildeInPath } }
        set { UserDefaults.standard.set(newValue, forKey: folderKey) }
    }
}

struct NotesSearch: SearchProviding {
    let source = SearchSource.notes
    let timeout: TimeInterval = 1.5
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        let notes = try LocalSearchProviders.context.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        return notes.filter { LocalSearchProviders.matches(query.words, $0.title, $0.body, $0.tagsRaw) }.prefix(30).map {
            UniversalResult(source: .notes, target: .note($0.uid), title: $0.title.isEmpty ? "Untitled note" : $0.title, subtitle: $0.folder,
                            snippet: LocalSearchProviders.excerpt($0.body, around: query.words), date: $0.updatedAt,
                            textScore: SearchRanking.textScore(words: query.words, title: $0.title, body: $0.body))
        }
    }
}

struct TranscriptSearch: SearchProviding {
    let source = SearchSource.transcripts
    let timeout: TimeInterval = 2
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        let recordings = try LocalSearchProviders.context.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
        var results: [UniversalResult] = []
        for recording in recordings.prefix(500) {
            let segments = recording.segments
            // A matching line in the transcript: jump to its time.
            if let segment = segments.first(where: { LocalSearchProviders.matches(query.words, $0.text) }), !query.words.isEmpty {
                results.append(UniversalResult(source: .transcripts, target: .recording(recording.uid, seconds: segment.start), title: recording.title,
                                               subtitle: "\(segment.speaker) at \(segment.timestamp)", snippet: segment.text, date: recording.startedAt,
                                               textScore: SearchRanking.textScore(words: query.words, title: recording.title, body: segment.text)))
            } else if LocalSearchProviders.matches(query.words, recording.title, recording.summary, recording.attendees) {
                results.append(UniversalResult(source: .transcripts, target: .recording(recording.uid, seconds: nil), title: recording.title,
                                               subtitle: "Summary", snippet: LocalSearchProviders.excerpt(recording.summary, around: query.words),
                                               date: recording.startedAt, textScore: SearchRanking.textScore(words: query.words, title: recording.title, body: recording.summary)))
            }
            if results.count >= 25 { break }
        }
        return results
    }
}

struct MemorySearch: SearchProviding {
    let source = SearchSource.memory
    let timeout: TimeInterval = 1.5
    func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        let hits = MemoryStore.shared.search(query.text, limit: 20, since: query.after)
        return hits.enumerated().map { index, snippet in
            UniversalResult(source: .memory, target: .memory(snippet.id), title: snippet.window.isEmpty ? snippet.app : snippet.window, subtitle: snippet.app,
                            snippet: LocalSearchProviders.excerpt(snippet.text, around: query.words), date: snippet.date,
                            textScore: max(0.3, 1 - Double(index) * 0.04))
        }
    }
}

struct LoopsSearch: SearchProviding {
    let source = SearchSource.loops
    let timeout: TimeInterval = 1
    func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        MemoryStore.shared.loops().filter { LocalSearchProviders.matches(query.words, $0.what, $0.who) }.prefix(15).map {
            UniversalResult(source: .loops, target: .loop($0.id), title: $0.what, subtitle: [$0.who, $0.status.label].filter { !$0.isEmpty }.joined(separator: " · "),
                            snippet: $0.due.map { "Due \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "", date: $0.created,
                            textScore: SearchRanking.textScore(words: query.words, title: $0.what, body: $0.who), from: $0.who)
        }
    }
}

struct SnippetsSearch: SearchProviding {
    let source = SearchSource.snippets
    let timeout: TimeInterval = 1
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        SnippetLibrary.shared.snippets.filter { LocalSearchProviders.matches(query.words, $0.name, $0.keyword, $0.text) }.prefix(10).map {
            UniversalResult(source: .snippets, target: .snippet($0.text), title: $0.name, subtitle: $0.keyword, snippet: String($0.text.prefix(160)),
                            date: nil, textScore: SearchRanking.textScore(words: query.words, title: $0.name + " " + $0.keyword, body: $0.text))
        }
    }
}

struct ClipboardSearch: SearchProviding {
    let source = SearchSource.clipboard
    let timeout: TimeInterval = 1.5
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        var descriptor = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        descriptor.fetchLimit = 2_000
        return try LocalSearchProviders.context.fetch(descriptor).filter { !$0.text.isEmpty && LocalSearchProviders.matches(query.words, $0.text) }.prefix(15).map {
            UniversalResult(source: .clipboard, target: .clipboard($0.uid), title: String($0.text.prefix(80)).replacingOccurrences(of: "\n", with: " "),
                            subtitle: $0.sourceAppName, snippet: LocalSearchProviders.excerpt($0.text, around: query.words), date: $0.lastUsedAt,
                            textScore: SearchRanking.textScore(words: query.words, title: "", body: $0.text))
        }
    }
}

struct TasksSearch: SearchProviding {
    let source = SearchSource.tasks
    let timeout: TimeInterval = 1
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        try LocalSearchProviders.context.fetch(FetchDescriptor<TaskItem>()).filter { LocalSearchProviders.matches(query.words, $0.title, $0.notes) }.prefix(20).map {
            UniversalResult(source: .tasks, target: .task($0.uid), title: $0.title, subtitle: $0.isCompleted ? "Done" : ($0.dueDate.map { "Due \($0.shortRelative)" } ?? "Open"),
                            snippet: String($0.notes.prefix(160)), date: $0.dueDate ?? $0.createdAt,
                            textScore: SearchRanking.textScore(words: query.words, title: $0.title, body: $0.notes))
        }
    }
}

struct RemindersSearch: SearchProviding {
    let source = SearchSource.reminders
    let timeout: TimeInterval = 1
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        try LocalSearchProviders.context.fetch(FetchDescriptor<SmartReminder>()).filter { LocalSearchProviders.matches(query.words, $0.text, $0.sourceText) }.prefix(15).map {
            UniversalResult(source: .reminders, target: .reminder($0.uid), title: $0.text, subtitle: $0.trigger.summary, snippet: "", date: $0.createdAt,
                            textScore: SearchRanking.textScore(words: query.words, title: $0.text, body: $0.sourceText))
        }
    }
}

struct AgentHistorySearch: SearchProviding {
    let source = SearchSource.agent
    let timeout: TimeInterval = 1
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        var descriptor = FetchDescriptor<AgentTask>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 500
        return try LocalSearchProviders.context.fetch(descriptor).filter { LocalSearchProviders.matches(query.words, $0.prompt, $0.finalAnswer) }.prefix(10).map {
            UniversalResult(source: .agent, target: .agentTask($0.uid), title: $0.title, subtitle: $0.state.label,
                            snippet: String($0.finalAnswer.prefix(160)), date: $0.createdAt,
                            textScore: SearchRanking.textScore(words: query.words, title: $0.prompt, body: $0.finalAnswer))
        }
    }
}

struct CalendarSearch: SearchProviding {
    let source = SearchSource.calendar
    let timeout: TimeInterval = 1.5
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        let now = Date()
        let events = CalendarService.shared.events(from: query.after ?? now.addingTimeInterval(-180 * 86_400), to: query.before ?? now.addingTimeInterval(180 * 86_400))
        return events.filter { LocalSearchProviders.matches(query.words, $0.title, $0.location, $0.notes, $0.attendees.joined(separator: " ")) }.prefix(20).map {
            UniversalResult(source: .calendar, target: .event($0.id), title: $0.title,
                            subtitle: $0.start.formatted(date: .abbreviated, time: .shortened) + ($0.location.isEmpty ? "" : " · \($0.location)"),
                            snippet: $0.attendees.joined(separator: ", "), date: $0.start,
                            textScore: SearchRanking.textScore(words: query.words, title: $0.title, body: $0.notes), from: $0.attendees.joined(separator: " "))
        }
    }
}

/// NSMetadataQuery wrapper (Spotlight). Must run on the main run loop.
@MainActor
final class SpotlightQuery: NSObject {
    private let query = NSMetadataQuery()
    private var continuation: CheckedContinuation<[NSMetadataItem], Never>?

    func run(predicate: NSPredicate, scopes: [Any], limit: Int) async -> [NSMetadataItem] {
        query.predicate = predicate
        query.searchScopes = scopes
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                NotificationCenter.default.addObserver(self, selector: #selector(done), name: .NSMetadataQueryDidFinishGathering, object: query)
                if !query.start() { finish([]) }
            }
        } onCancel: {
            Task { @MainActor in self.finish([]) }
        }
    }

    @objc private func done() {
        query.disableUpdates()
        let items = (0..<min(query.resultCount, 50)).compactMap { query.result(at: $0) as? NSMetadataItem }
        finish(items)
    }

    private func finish(_ items: [NSMetadataItem]) {
        query.stop()
        NotificationCenter.default.removeObserver(self)
        continuation?.resume(returning: items)
        continuation = nil
    }

    /// Spotlight predicate: every word in the name or the content.
    static func wordsPredicate(_ words: [String]) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: words.prefix(6).map { word in
            NSPredicate(format: "(kMDItemFSName CONTAINS[cd] %@) OR (kMDItemTextContent CONTAINS[cd] %@) OR (kMDItemTitle CONTAINS[cd] %@)", word, word, word)
        })
    }
}

struct FilesSearch: SearchProviding {
    let source = SearchSource.files
    let timeout: TimeInterval = 3
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        guard !query.words.isEmpty else { return [] }
        let items = await SpotlightQuery().run(predicate: SpotlightQuery.wordsPredicate(query.words),
                                               scopes: LocalSearchProviders.folders.map { URL(fileURLWithPath: $0) }, limit: 30)
        return items.compactMap { item in
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            let url = URL(fileURLWithPath: path)
            let date = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            return UniversalResult(source: .files, target: .file(url), title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().path
                .replacingOccurrences(of: NSHomeDirectory(), with: "~"), snippet: "", date: date,
                                   textScore: SearchRanking.textScore(words: query.words, title: url.lastPathComponent, body: "") * 0.5 + 0.5)
        }
    }
}

/// Mail.app messages through Spotlight metadata (works where Mail's messages are indexed; may need Full Disk Access).
struct MailSpotlightSearch: SearchProviding {
    let source = SearchSource.mail
    let timeout: TimeInterval = 3
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        guard !query.words.isEmpty || query.from != nil else { return [] }
        var parts = [NSPredicate(format: "kMDItemContentType == 'com.apple.mail.emlx'")]
        for word in query.words.prefix(6) {
            parts.append(NSPredicate(format: "(kMDItemSubject CONTAINS[cd] %@) OR (kMDItemTextContent CONTAINS[cd] %@)", word, word))
        }
        if let from = query.from {
            parts.append(NSPredicate(format: "(kMDItemAuthors CONTAINS[cd] %@) OR (kMDItemAuthorEmailAddresses CONTAINS[cd] %@)", from, from))
        }
        let items = await SpotlightQuery().run(predicate: NSCompoundPredicate(andPredicateWithSubpredicates: parts),
                                               scopes: [NSMetadataQueryUserHomeScope], limit: 30)
        return items.compactMap { item in
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            let subject = item.value(forAttribute: "kMDItemSubject") as? String ?? (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ?? "Message")
            let from = (item.value(forAttribute: "kMDItemAuthors") as? [String])?.joined(separator: ", ") ?? ""
            let emails = (item.value(forAttribute: "kMDItemAuthorEmailAddresses") as? [String])?.joined(separator: ", ") ?? ""
            let date = item.value(forAttribute: NSMetadataItemContentCreationDateKey) as? Date
            return UniversalResult(source: .mail, target: .mailFile(URL(fileURLWithPath: path)), title: subject, subtitle: from, snippet: "",
                                   date: date, textScore: SearchRanking.textScore(words: query.words, title: subject, body: ""), from: from + " " + emails,
                                   messageID: item.value(forAttribute: "com_apple_mail_messageID") as? String ?? "")
        }
    }
}

/// Gmail's own search for connected accounts that allowed reading (the only search that leaves the Mac).
struct GmailSearch: SearchProviding {
    let source = SearchSource.gmail
    let timeout: TimeInterval = 4
    @MainActor func search(_ query: SearchQuery) async throws -> [UniversalResult] {
        let google = GoogleCalendarService.shared
        let accounts = google.accounts.filter { google.hasScope(GoogleCalendarService.gmailReadScope, account: $0) }
        guard !accounts.isEmpty, !query.isEmpty else { return [] }
        let q = GmailSearch.gmailQuery(query)
        var results: [UniversalResult] = []
        for account in accounts {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            components.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "maxResults", value: "8")]
            let list = try JSONSerialization.jsonObject(with: try await google.authorizedRequest("GET", url: components.url!, account: account)) as? [String: Any]
            for item in (list?["messages"] as? [[String: Any]] ?? []) {
                guard let id = item["id"] as? String,
                      let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Message-ID") else { continue }
                let message = try JSONSerialization.jsonObject(with: try await google.authorizedRequest("GET", url: url, account: account)) as? [String: Any]
                results.append(GmailSearch.result(message ?? [:], account: account, words: query.words))
            }
        }
        return results
    }

    static func gmailQuery(_ query: SearchQuery) -> String {
        var parts = [query.text]
        if let from = query.from { parts.append("from:\(from)") }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        if let after = query.after { parts.append("after:\(formatter.string(from: after))") }
        if let before = query.before { parts.append("before:\(formatter.string(from: before))") }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func result(_ message: [String: Any], account: String, words: [String]) -> UniversalResult {
        let headers = ((message["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) {
            if let name = $1["name"] as? String, let value = $1["value"] as? String { $0[name.lowercased()] = value }
        }
        let date = (message["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000) }
        let subject = headers["subject"] ?? "(no subject)"
        return UniversalResult(source: .gmail, target: .gmail(account: account, id: message["id"] as? String ?? "", thread: message["threadId"] as? String ?? ""),
                               title: subject, subtitle: headers["from"] ?? account, snippet: HTMLText.decode(message["snippet"] as? String ?? ""), date: date,
                               textScore: SearchRanking.textScore(words: words, title: subject, body: message["snippet"] as? String ?? ""),
                               from: headers["from"] ?? "", messageID: headers["message-id"] ?? "")
    }
}
