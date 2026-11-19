import CryptoKit
import Foundation

/// What a sync record holds.
enum SyncKind: String, Codable, CaseIterable {
    case note, task, recording, conversation, prompt, library

    var label: String {
        switch self {
        case .note: return "Notes"
        case .task: return "Tasks"
        case .recording: return "Meetings (transcripts & summaries)"
        case .conversation: return "AI chats"
        case .prompt: return "Prompt library"
        case .library: return "Snippets & quick links"
        }
    }
}

/// One item (or deletion) as written to a device's file in iCloud Drive.
struct SyncRecord: Codable, Equatable {
    var kind: SyncKind
    var id: UUID
    var modifiedAt: Date
    var deleted = false
    /// JSON of the item's DTO; nil for deletions.
    var payload: String?

    var key: String { SyncKeys.key(kind, id) }
}

/// Everything one Mac has, written only by that Mac (so two Macs never edit the same file).
struct SyncFile: Codable {
    var version = 1
    var deviceID: String
    var deviceName: String
    var updatedAt: Date
    var records: [SyncRecord]
}

enum SyncKeys {
    static func key(_ kind: SyncKind, _ id: UUID) -> String { "\(kind.rawValue):\(id.uuidString)" }
    static let libraryID = UUID(uuidString: "00000000-0000-0000-0000-00000000005A")!
}

/// What this Mac remembers between syncs.
struct SyncState: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var fingerprint: String
        var modifiedAt: Date
    }

    var entries: [String: Entry] = [:]
    var tombstones: [String: Date] = [:]
    var lastWrittenHash: String?
}

/// A local item as seen at sync time.
struct LocalItem {
    var kind: SyncKind
    var id: UUID
    var payload: String
    /// Used as the change time the first time an item is seen.
    var naturalDate: Date

    var key: String { SyncKeys.key(kind, id) }
    var fingerprint: String { SyncCodec.hash(payload) }
}

enum SyncCodec {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: Data(text.utf8))
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Last-writer-wins merge. Pure, so it can be tested as two simulated Macs.
enum SyncPlanner {
    /// Records local edits (new fingerprint → modified now) and deletions (known before, gone now) in the state.
    /// `present` lists keys that exist but aren't exported (e.g. a meeting still recording) so they aren't seen as deleted.
    static func stamp(_ items: [LocalItem], present: Set<String> = [], state: inout SyncState, now: Date) {
        var seen = present
        for item in items {
            seen.insert(item.key)
            let fingerprint = item.fingerprint
            if let entry = state.entries[item.key] {
                if entry.fingerprint != fingerprint { state.entries[item.key] = .init(fingerprint: fingerprint, modifiedAt: now) }
            } else {
                state.entries[item.key] = .init(fingerprint: fingerprint, modifiedAt: min(item.naturalDate, now))
            }
            state.tombstones.removeValue(forKey: item.key)
        }
        for key in state.entries.keys where !seen.contains(key) {
            state.entries.removeValue(forKey: key)
            state.tombstones[key] = now
        }
    }

    /// Remote records that are newer than what this Mac has (newest across all other Macs wins).
    static func incoming(_ remote: [SyncRecord], state: SyncState) -> [SyncRecord] {
        var best: [String: SyncRecord] = [:]
        for record in remote {
            if let current = best[record.key], current.modifiedAt >= record.modifiedAt { continue }
            best[record.key] = record
        }
        return best.values.filter { record in
            let localTime = state.entries[record.key]?.modifiedAt ?? state.tombstones[record.key]
            guard let localTime else { return !record.deleted }
            guard record.modifiedAt > localTime else { return false }
            if !record.deleted, let payload = record.payload, state.entries[record.key]?.fingerprint == SyncCodec.hash(payload) { return false }
            if record.deleted && state.entries[record.key] == nil { return false }
            return true
        }
        .sorted { $0.key < $1.key }
    }

    /// The file this Mac publishes: every item plus recent deletions.
    static func outgoing(_ items: [LocalItem], state: SyncState, now: Date, keepTombstonesFor days: Double = 90) -> [SyncRecord] {
        var records = items.map { item in
            SyncRecord(kind: item.kind, id: item.id, modifiedAt: state.entries[item.key]?.modifiedAt ?? item.naturalDate, payload: item.payload)
        }
        for (key, date) in state.tombstones where now.timeIntervalSince(date) < days * 86_400 {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let kind = SyncKind(rawValue: String(parts[0])), let id = UUID(uuidString: String(parts[1])) else { continue }
            records.append(SyncRecord(kind: kind, id: id, modifiedAt: date, deleted: true))
        }
        return records.sorted { $0.key < $1.key }
    }
}

// MARK: - DTOs

struct NoteDTO: Codable, Equatable {
    var title: String, body: String, folder: String, tagsRaw: String, isPinned: Bool
    var createdAt: Date, updatedAt: Date
    var eventID: String?, recordingID: UUID?
}

struct TaskDTO: Codable, Equatable {
    var title: String, notes: String, dueDate: Date?, priorityRaw: Int, recurrenceRaw: String, category: String
    var isCompleted: Bool, completedAt: Date?, createdAt: Date
    /// Apple's cross-device reminder id, so both Macs link to the same reminder.
    var reminderExternalID: String?
}

struct RecordingDTO: Codable, Equatable {
    var title: String, kindRaw: String, statusRaw: String, startedAt: Date, duration: Double
    var calendarEventID: String?, attendees: String, prepNotes: String
    var segments: [TranscriptSegment]
    var s3Locations: [S3Location]
    var summary: String, decisions: [String], actionItems: [ActionItem], deadlines: [String], openQuestions: [String]
    var followUpEmail: String, notice: String?, errorMessage: String?, createdAt: Date
}

struct ChatMessageDTO: Codable, Equatable {
    var uid: UUID, roleRaw: String, content: String, createdAt: Date, providerRaw: String?, model: String?
}

struct ConversationDTO: Codable, Equatable {
    var title: String, createdAt: Date, updatedAt: Date, providerRaw: String, model: String, systemPrompt: String
    var messages: [ChatMessageDTO]
}

struct PromptDTO: Codable, Equatable {
    var title: String, body: String, category: String, createdAt: Date
}

struct LibraryDTO: Codable, Equatable {
    var links: [QuickLink]
    var snippets: [Snippet]
}
