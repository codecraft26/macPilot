import Foundation
import SwiftData

enum RecordingKind: String, Codable, CaseIterable {
    case meeting, voiceNote, imported

    var label: String {
        switch self {
        case .meeting: return "Meeting"
        case .voiceNote: return "Voice note"
        case .imported: return "Imported audio"
        }
    }

    var systemImage: String {
        switch self {
        case .meeting: return "person.2.wave.2"
        case .voiceNote: return "mic"
        case .imported: return "square.and.arrow.down"
        }
    }
}

enum RecordingStatus: String, Codable {
    case recording, recorded, transcribing, transcribed, analyzing, ready, failed

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .recorded: return "Not transcribed"
        case .transcribing: return "Transcribing…"
        case .transcribed: return "Transcribed"
        case .analyzing: return "Analyzing…"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        }
    }

    var isBusy: Bool { self == .recording || self == .transcribing || self == .analyzing }
}

/// One line of a transcript. Microphone audio is labelled "Me" and system audio "Others"
/// unless the transcription provider returned its own speaker labels. Labels can be renamed.
struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var speaker: String
    var text: String

    var timestamp: String { Self.format(start) }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

struct ActionItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var task: String
    var owner: String?
    var due: String?

    enum CodingKeys: String, CodingKey { case task, owner, due }

    init(task: String, owner: String? = nil, due: String? = nil) {
        self.task = task
        self.owner = owner
        self.due = due
    }

    /// Accepts `{"task": …, "owner": …, "due": …}` or a bare string.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            self.init(task: text)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            task: (try? container.decode(String.self, forKey: .task)) ?? "",
            owner: Self.clean((try? container.decodeIfPresent(String.self, forKey: .owner)) ?? nil),
            due: Self.clean((try? container.decodeIfPresent(String.self, forKey: .due)) ?? nil)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(task, forKey: .task)
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encodeIfPresent(due, forKey: .due)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !["null", "none", "n/a", "unknown"].contains(value.lowercased()) else { return nil }
        return value
    }
}

/// Meeting intelligence produced by the analysis provider (one JSON response).
struct MeetingAnalysis: Codable, Equatable {
    var title: String?
    var summary: String = ""
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
    var deadlines: [String] = []
    var openQuestions: [String] = []
    var followUpEmail: String = ""

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions, actionItems, deadlines, openQuestions, followUpEmail
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        summary = Self.text(c, .summary)
        decisions = Self.list(c, .decisions)
        actionItems = ((try? c.decode([ActionItem].self, forKey: .actionItems)) ?? []).filter { !$0.task.isEmpty }
        deadlines = Self.list(c, .deadlines)
        openQuestions = Self.list(c, .openQuestions)
        followUpEmail = Self.text(c, .followUpEmail)
    }

    /// A string, or a list of strings joined into paragraphs.
    private static func text(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String {
        if let value = try? c.decode(String.self, forKey: key) { return value }
        if let values = try? c.decode([String].self, forKey: key) { return values.joined(separator: "\n") }
        return ""
    }

    /// A list of strings, a single string, or a list of objects with a text-like field.
    private static func list(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String] {
        if let values = try? c.decode([String].self, forKey: key) { return values.filter { !$0.isEmpty } }
        if let value = try? c.decode(String.self, forKey: key) { return value.isEmpty ? [] : [value] }
        if let objects = try? c.decode([[String: String]].self, forKey: key) {
            return objects.compactMap { $0.values.sorted { $0.count > $1.count }.first }
        }
        return []
    }
}

@Model
final class Recording {
    var uid: UUID = UUID()
    var title: String = "Recording"
    var kindRaw: String = RecordingKind.meeting.rawValue
    var statusRaw: String = RecordingStatus.recording.rawValue
    var startedAt: Date = Date()
    var duration: Double = 0
    /// File names inside `folderURL`.
    var micFileName: String?
    var systemFileName: String?
    /// Seconds from the start of the microphone track to the start of the system audio track.
    var systemAudioOffset: Double = 0
    var calendarEventID: String?
    var attendees: String = ""
    var prepNotes: String = ""
    /// Transcript segments, JSON-encoded.
    var segmentsData: Data?
    /// S3 folders used to transcribe this recording, deleted together with it.
    var s3LocationsData: Data?
    // Meeting intelligence
    var summary: String = ""
    var decisionsData: Data?
    var actionItemsData: Data?
    var deadlinesData: Data?
    var openQuestionsData: Data?
    var followUpEmail: String = ""
    /// Shown in the detail view, e.g. "System audio was not captured".
    var notice: String?
    var errorMessage: String?
    var createdAt: Date = Date()

    init(kind: RecordingKind, title: String, calendarEventID: String? = nil, attendees: String = "") {
        self.kindRaw = kind.rawValue
        self.title = title
        self.calendarEventID = calendarEventID
        self.attendees = attendees
        self.startedAt = Date()
    }

    var kind: RecordingKind {
        get { RecordingKind(rawValue: kindRaw) ?? .meeting }
        set { kindRaw = newValue.rawValue }
    }

    var status: RecordingStatus {
        get { RecordingStatus(rawValue: statusRaw) ?? .recorded }
        set { statusRaw = newValue.rawValue }
    }

    var segments: [TranscriptSegment] {
        get { Self.decode(segmentsData) ?? [] }
        set { segmentsData = Self.encode(newValue) }
    }

    var s3Locations: [S3Location] {
        get { Self.decode(s3LocationsData) ?? [] }
        set { s3LocationsData = newValue.isEmpty ? nil : Self.encode(newValue) }
    }

    var decisions: [String] {
        get { Self.decode(decisionsData) ?? [] }
        set { decisionsData = Self.encode(newValue) }
    }

    var actionItems: [ActionItem] {
        get { Self.decode(actionItemsData) ?? [] }
        set { actionItemsData = Self.encode(newValue) }
    }

    var deadlines: [String] {
        get { Self.decode(deadlinesData) ?? [] }
        set { deadlinesData = Self.encode(newValue) }
    }

    var openQuestions: [String] {
        get { Self.decode(openQuestionsData) ?? [] }
        set { openQuestionsData = Self.encode(newValue) }
    }

    var hasAnalysis: Bool {
        !summary.isEmpty || !actionItems.isEmpty || !decisions.isEmpty
    }

    func apply(_ analysis: MeetingAnalysis) {
        summary = analysis.summary
        decisions = analysis.decisions
        actionItems = analysis.actionItems
        deadlines = analysis.deadlines
        openQuestions = analysis.openQuestions
        followUpEmail = analysis.followUpEmail
    }

    var folderURL: URL { RecordingStorage.folder(for: uid) }
    var micURL: URL? { micFileName.map { folderURL.appendingPathComponent($0) } }
    var systemURL: URL? { systemFileName.map { folderURL.appendingPathComponent($0) } }

    /// Audio files that still exist on disk.
    var audioURLs: [URL] {
        [micURL, systemURL].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var speakers: [String] {
        var seen: [String] = []
        for segment in segments where !seen.contains(segment.speaker) {
            seen.append(segment.speaker)
        }
        return seen
    }

    func renameSpeaker(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        segments = segments.map { segment in
            var copy = segment
            if copy.speaker == old { copy.speaker = name }
            return copy
        }
    }

    var transcriptText: String { TranscriptExport.plainText(segments) }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }
}

enum RecordingStorage {
    static var root: URL {
        let dir = Persistence.storeDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func folder(for uid: UUID) -> URL {
        let dir = root.appendingPathComponent(uid.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func deleteFiles(for uid: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(uid.uuidString, isDirectory: true))
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Deletes audio older than `days` days but keeps transcripts and analysis. 0 keeps everything.
    @MainActor
    static func applyRetention(days: Int, context: SwiftData.ModelContext) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let recordings = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        var changed = false
        for recording in recordings where recording.startedAt < cutoff && !recording.status.isBusy {
            guard recording.micFileName != nil || recording.systemFileName != nil else { continue }
            deleteFiles(for: recording.uid)
            recording.micFileName = nil
            recording.systemFileName = nil
            recording.notice = "Audio deleted after \(days) days (Settings → Privacy & Data)."
            changed = true
        }
        if changed { try? context.save() }
    }
}

enum TranscriptExport {
    static func plainText(_ segments: [TranscriptSegment]) -> String {
        segments.map { "[\($0.timestamp)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    static func srtTime(_ seconds: Double) -> String {
        let millis = max(0, Int((seconds * 1000).rounded()))
        let hours = millis / 3_600_000
        let minutes = (millis % 3_600_000) / 60_000
        let secs = (millis % 60_000) / 1000
        let ms = millis % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, ms)
    }

    static func srt(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            let end = max(segment.end, segment.start + 0.5)
            return "\(index + 1)\n\(srtTime(segment.start)) --> \(srtTime(end))\n\(segment.speaker): \(segment.text)\n"
        }.joined(separator: "\n")
    }

    static func markdown(for recording: Recording) -> String {
        var lines = ["# \(recording.title)", ""]
        lines.append("_\(recording.kind.label) · \(recording.startedAt.formatted(date: .complete, time: .shortened)) · \(TranscriptSegment.format(recording.duration))_")
        if !recording.attendees.isEmpty { lines += ["", "**Attendees:** \(recording.attendees)"] }
        if !recording.prepNotes.isEmpty { lines += ["", "## Prep notes", "", recording.prepNotes] }
        if !recording.summary.isEmpty { lines += ["", "## Summary", "", recording.summary] }
        func list(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines += ["", "## \(title)", ""]
            lines += items.map { "- \($0)" }
        }
        list("Decisions", recording.decisions)
        if !recording.actionItems.isEmpty {
            lines += ["", "## Action items", ""]
            for item in recording.actionItems {
                var line = "- [ ] \(item.task)"
                if let owner = item.owner { line += " — \(owner)" }
                if let due = item.due { line += " (due \(due))" }
                lines.append(line)
            }
        }
        list("Deadlines", recording.deadlines)
        list("Open questions", recording.openQuestions)
        if !recording.followUpEmail.isEmpty { lines += ["", "## Follow-up email", "", recording.followUpEmail] }
        if !recording.segments.isEmpty {
            lines += ["", "## Transcript", ""]
            lines += recording.segments.map { "**[\($0.timestamp)] \($0.speaker):** \($0.text)  " }
        }
        return lines.joined(separator: "\n")
    }
}
