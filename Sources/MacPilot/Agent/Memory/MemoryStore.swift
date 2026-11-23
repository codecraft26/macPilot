import CryptoKit
import Foundation
import NaturalLanguage
import SQLite3

struct MemorySnippet: Equatable, Codable, Identifiable {
    var id: Int64
    var app: String
    var bundleID: String
    var window: String
    var date: Date
    var hash: String
    var text: String
}

enum LoopStatus: String, Codable, CaseIterable {
    case open, probablyDone, done, dismissed, snoozed
    var label: String {
        switch self {
        case .open: return "Open"
        case .probablyDone: return "Probably done"
        case .done: return "Done"
        case .dismissed: return "Dismissed"
        case .snoozed: return "Snoozed"
        }
    }
}

struct OpenLoop: Equatable, Codable, Identifiable {
    var id: String
    var who: String
    var what: String
    var due: Date?
    var app: String
    var snippetID: Int64
    var confidence: Double
    var status: LoopStatus
    var snoozedUntil: Date?
    var created: Date
    var updated: Date
    /// Why it looks done (a later snippet), when status is probablyDone or done automatically.
    var closeEvidence: String = ""
    var reminderID: String = ""
}

enum MemoryError: LocalizedError {
    case sqlite(String)
    var errorDescription: String? {
        if case .sqlite(let message) = self { return "Memory database: \(message)" }
        return nil
    }
}

/// The local memory database: snippets with FTS5 full-text search and optional on-device embeddings,
/// plus open loops. It lives in Application Support and never leaves the Mac by itself.
final class MemoryStore: @unchecked Sendable {
    static let shared: MemoryStore = {
        let url = Persistence.storeDirectory.appendingPathComponent("Memory.sqlite")
        return (try? MemoryStore(url: url)) ?? (try! MemoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("MacPilot-Memory.sqlite")))
    }()

    private var db: OpaquePointer?
    private let lock = NSLock()
    let url: URL
    /// On-device sentence embedding (NaturalLanguage); nil where unavailable.
    var embedder: ((String) -> [Float]?)? = MemoryStore.defaultEmbedder()

    init(url: URL) throws {
        self.url = url
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw MemoryError.sqlite("can't open \(url.lastPathComponent)")
        }
        try execute("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS snippets(id INTEGER PRIMARY KEY AUTOINCREMENT, app TEXT, bundle TEXT, window TEXT, ts REAL, hash TEXT, text TEXT,
                                            embedding BLOB, processed INTEGER DEFAULT 0);
        CREATE INDEX IF NOT EXISTS snippets_ts ON snippets(ts);
        CREATE INDEX IF NOT EXISTS snippets_hash ON snippets(hash);
        CREATE VIRTUAL TABLE IF NOT EXISTS snippets_fts USING fts5(text, window, app, content='snippets', content_rowid='id');
        CREATE TRIGGER IF NOT EXISTS snippets_ai AFTER INSERT ON snippets BEGIN
            INSERT INTO snippets_fts(rowid, text, window, app) VALUES (new.id, new.text, new.window, new.app); END;
        CREATE TRIGGER IF NOT EXISTS snippets_ad AFTER DELETE ON snippets BEGIN
            INSERT INTO snippets_fts(snippets_fts, rowid, text, window, app) VALUES ('delete', old.id, old.text, old.window, old.app); END;
        CREATE TABLE IF NOT EXISTS loops(id TEXT PRIMARY KEY, who TEXT, what TEXT, due REAL, app TEXT, snippet INTEGER, confidence REAL,
                                         status TEXT, snoozed REAL, created REAL, updated REAL, evidence TEXT, reminder TEXT);
        """)
        // Not world-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { sqlite3_close(db) }

    static func defaultEmbedder() -> ((String) -> [Float]?)? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        return { text in embedding.vector(for: String(text.prefix(2_000))).map { $0.map(Float.init) } }
    }

    // MARK: SQL helpers

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "error"
            sqlite3_free(error)
            throw MemoryError.sqlite(message)
        }
    }

    private enum Value { case text(String), real(Double), int(Int64), blob(Data), null }

    private func run(_ sql: String, _ values: [Value] = [], row: ((OpaquePointer) -> Void)? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, i, s, -1, transient)
            case .real(let d): sqlite3_bind_double(statement, i, d)
            case .int(let n): sqlite3_bind_int64(statement, i, n)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32(data.count), transient) }
            case .null: sqlite3_bind_null(statement, i)
            }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { row?(statement); continue }
            if result == SQLITE_DONE { break }
            throw MemoryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func lastID() -> Int64 { lock.withLock { sqlite3_last_insert_rowid(db) } }

    private static func snippet(_ s: OpaquePointer) -> MemorySnippet {
        MemorySnippet(id: sqlite3_column_int64(s, 0), app: text(s, 1), bundleID: text(s, 2), window: text(s, 3),
                      date: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)), hash: text(s, 5), text: text(s, 6))
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Snippets

    /// Stores a (redacted) snippet; returns nil when the same text was already stored for this window.
    @discardableResult
    func insert(app: String, bundleID: String, window: String, text: String, date: Date = Date()) throws -> Int64? {
        let clean = AgentRedactor.redact(text)
        let hash = Self.hash(bundleID + "|" + window + "|" + clean)
        var exists = false
        try run("SELECT 1 FROM snippets WHERE hash = ? LIMIT 1", [.text(hash)]) { _ in exists = true }
        if exists { return nil }
        var embedding: Value = .null
        if let vector = embedder?(clean) { embedding = .blob(vector.withUnsafeBufferPointer { Data(buffer: $0) }) }
        try run("INSERT INTO snippets(app, bundle, window, ts, hash, text, embedding) VALUES (?,?,?,?,?,?,?)",
                [.text(app), .text(bundleID), .text(AgentRedactor.redact(window)), .real(date.timeIntervalSince1970), .text(hash), .text(clean), embedding])
        return lastID()
    }

    func snippet(_ id: Int64) -> MemorySnippet? {
        var result: MemorySnippet?
        try? run("SELECT id, app, bundle, window, ts, hash, text FROM snippets WHERE id = ?", [.int(id)]) { result = Self.snippet($0) }
        return result
    }

    var count: Int {
        var n = 0
        try? run("SELECT COUNT(*) FROM snippets") { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    /// FTS5 keyword search (bm25 ranking). The query is reduced to plain words so FTS syntax can't be injected.
    func search(_ query: String, limit: Int = 10, since: Date? = nil) -> [MemorySnippet] {
        let words = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }.prefix(12)
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " OR ")
        var results: [MemorySnippet] = []
        try? run("""
        SELECT s.id, s.app, s.bundle, s.window, s.ts, s.hash, s.text FROM snippets_fts f JOIN snippets s ON s.id = f.rowid
        WHERE snippets_fts MATCH ? AND s.ts >= ? ORDER BY bm25(snippets_fts) LIMIT ?
        """, [.text(match), .real(since?.timeIntervalSince1970 ?? 0), .int(Int64(limit))]) { results.append(Self.snippet($0)) }
        return results
    }

    /// Semantic search with on-device embeddings (falls back to keyword search).
    func semanticSearch(_ query: String, limit: Int = 10) -> [MemorySnippet] {
        guard let embedder, let wanted = embedder(query) else { return search(query, limit: limit) }
        var scored: [(Float, MemorySnippet)] = []
        try? run("SELECT id, app, bundle, window, ts, hash, text, embedding FROM snippets WHERE embedding IS NOT NULL ORDER BY ts DESC LIMIT 5000") { s in
            guard let blob = sqlite3_column_blob(s, 7) else { return }
            let count = Int(sqlite3_column_bytes(s, 7)) / MemoryLayout<Float>.size
            let vector = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: count))
            scored.append((Self.cosine(wanted, vector), Self.snippet(s)))
        }
        let semantic = scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        // Merge with keyword hits so exact names still win.
        var seen = Set<Int64>()
        return (search(query, limit: limit) + semantic).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    func unprocessed(limit: Int) -> [MemorySnippet] {
        var results: [MemorySnippet] = []
        try? run("SELECT id, app, bundle, window, ts, hash, text FROM snippets WHERE processed = 0 ORDER BY ts LIMIT ?", [.int(Int64(limit))]) { results.append(Self.snippet($0)) }
        return results
    }

    func markProcessed(_ ids: [Int64]) {
        for id in ids { try? run("UPDATE snippets SET processed = 1 WHERE id = ?", [.int(id)]) }
    }

    func recent(limit: Int, app: String? = nil) -> [MemorySnippet] {
        var results: [MemorySnippet] = []
        if let app {
            try? run("SELECT id, app, bundle, window, ts, hash, text FROM snippets WHERE bundle = ? ORDER BY ts DESC LIMIT ?", [.text(app), .int(Int64(limit))]) { results.append(Self.snippet($0)) }
        } else {
            try? run("SELECT id, app, bundle, window, ts, hash, text FROM snippets ORDER BY ts DESC LIMIT ?", [.int(Int64(limit))]) { results.append(Self.snippet($0)) }
        }
        return results
    }

    /// Retention: deletes snippets older than `days` (loops keep their text).
    func purge(olderThan days: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        try? run("DELETE FROM snippets WHERE ts < ?", [.real(cutoff)])
    }

    func forget(bundleID: String) {
        try? run("DELETE FROM snippets WHERE bundle = ?", [.text(bundleID)])
        try? run("DELETE FROM loops WHERE app = ?", [.text(bundleID)])
    }

    func deleteEverything() {
        try? run("DELETE FROM snippets")
        try? run("DELETE FROM loops")
        try? execute("INSERT INTO snippets_fts(snippets_fts) VALUES('rebuild'); VACUUM;")
    }

    // MARK: Loops

    func upsert(_ loop: OpenLoop) {
        try? run("""
        INSERT OR REPLACE INTO loops(id, who, what, due, app, snippet, confidence, status, snoozed, created, updated, evidence, reminder)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.text(loop.id), .text(loop.who), .text(loop.what), loop.due.map { .real($0.timeIntervalSince1970) } ?? .null, .text(loop.app),
              .int(loop.snippetID), .real(loop.confidence), .text(loop.status.rawValue), loop.snoozedUntil.map { .real($0.timeIntervalSince1970) } ?? .null,
              .real(loop.created.timeIntervalSince1970), .real(loop.updated.timeIntervalSince1970), .text(loop.closeEvidence), .text(loop.reminderID)])
    }

    func loops(statuses: Set<LoopStatus> = [.open, .probablyDone, .snoozed], since: Date? = nil) -> [OpenLoop] {
        var results: [OpenLoop] = []
        try? run("SELECT id, who, what, due, app, snippet, confidence, status, snoozed, created, updated, evidence, reminder FROM loops WHERE created >= ? ORDER BY created DESC",
                 [.real(since?.timeIntervalSince1970 ?? 0)]) { s in
            let status = LoopStatus(rawValue: Self.text(s, 7)) ?? .open
            guard statuses.contains(status) else { return }
            results.append(OpenLoop(id: Self.text(s, 0), who: Self.text(s, 1), what: Self.text(s, 2),
                                    due: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                                    app: Self.text(s, 4), snippetID: sqlite3_column_int64(s, 5), confidence: sqlite3_column_double(s, 6), status: status,
                                    snoozedUntil: sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 8)),
                                    created: Date(timeIntervalSince1970: sqlite3_column_double(s, 9)), updated: Date(timeIntervalSince1970: sqlite3_column_double(s, 10)),
                                    closeEvidence: Self.text(s, 11), reminderID: Self.text(s, 12)))
        }
        return results
    }

    func loop(_ id: String) -> OpenLoop? {
        loops(statuses: Set(LoopStatus.allCases)).first { $0.id == id || $0.id.hasPrefix(id.lowercased()) }
    }
}
