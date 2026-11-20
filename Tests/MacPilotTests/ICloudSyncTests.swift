import SwiftData
import XCTest
@testable import MacPilot

@MainActor
final class ICloudSyncTests: XCTestCase {
    /// A simulated Mac: its own database and sync state, sharing one "iCloud Drive" folder.
    struct Mac {
        let id: String
        let context: ModelContext
        let stateURL: URL
    }

    private var folder: URL!
    private var root: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        folder = root.appendingPathComponent("Sync")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeMac(_ id: String) throws -> Mac {
        let container = try ModelContainer(for: Persistence.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return Mac(id: id, context: ModelContext(container), stateURL: root.appendingPathComponent("\(id)-state.json"))
    }

    @discardableResult
    private func sync(_ mac: Mac) throws -> String {
        clock += 60
        try mac.context.save()
        return try ICloudSync.shared.performSync(context: mac.context, folder: folder, now: clock,
                                                 deviceID: mac.id, deviceName: mac.id, stateURL: mac.stateURL)
    }

    private func notes(_ mac: Mac) -> [Note] { (try? mac.context.fetch(FetchDescriptor<Note>())) ?? [] }
    private func tasks(_ mac: Mac) -> [TaskItem] { (try? mac.context.fetch(FetchDescriptor<TaskItem>())) ?? [] }

    func testTwoMacsSyncEditsAndDeletes() throws {
        let mini = try makeMac("mini"), book = try makeMac("book")
        let note = Note(title: "Launch plan", body: "Ship in March")
        mini.context.insert(note)
        let task = TaskItem(title: "Book flights")
        mini.context.insert(task)
        try sync(mini)
        try sync(book)
        XCTAssertEqual(notes(book).map(\.title), ["Launch plan"])
        XCTAssertEqual(notes(book).first?.uid, note.uid)
        XCTAssertEqual(tasks(book).map(\.title), ["Book flights"])

        // Edit on the MacBook, comes back to the mini; nothing bounces back as a new edit.
        notes(book).first?.body = "Ship in April"
        try sync(book)
        try sync(mini)
        XCTAssertEqual(notes(mini).first?.body, "Ship in April")
        try sync(book)
        XCTAssertEqual(notes(book).first?.body, "Ship in April")

        // Complete and delete travel too.
        tasks(mini).first?.isCompleted = true
        try sync(mini)
        try sync(book)
        XCTAssertEqual(tasks(book).first?.isCompleted, true)
        mini.context.delete(notes(mini)[0])
        try sync(mini)
        try sync(book)
        XCTAssertTrue(notes(book).isEmpty)
        try sync(mini)
        XCTAssertTrue(notes(mini).isEmpty, "a deleted note must not come back")
    }

    func testNewestEditWins() throws {
        let mini = try makeMac("mini"), book = try makeMac("book")
        mini.context.insert(Note(title: "Shared", body: "v1"))
        try sync(mini)
        try sync(book)
        notes(mini).first?.body = "mini edit"
        try sync(mini)
        notes(book).first?.body = "book edit (later)"
        try sync(book)
        try sync(mini)
        try sync(book)
        XCTAssertEqual(notes(mini).first?.body, "book edit (later)")
        XCTAssertEqual(notes(book).first?.body, "book edit (later)")
    }

    func testSeededPromptsAreNotDuplicated() throws {
        let mini = try makeMac("mini"), book = try makeMac("book")
        mini.context.insert(PromptTemplate(title: "Summarize", body: "Summarize this"))
        book.context.insert(PromptTemplate(title: "Summarize", body: "Summarize this"))
        for _ in 0..<3 {
            try sync(mini)
            try sync(book)
        }
        let a = try mini.context.fetch(FetchDescriptor<PromptTemplate>())
        let b = try book.context.fetch(FetchDescriptor<PromptTemplate>())
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(a.first?.uid, b.first?.uid)
    }

    func testSameReminderImportedOnBothMacsKeepsOneTask() throws {
        let mini = try makeMac("mini"), book = try makeMac("book")
        let first = TaskItem(title: "Pay rent")
        first.reminderExternalID = "EXT-1"
        mini.context.insert(first)
        let second = TaskItem(title: "Pay rent")
        second.reminderExternalID = "EXT-1"
        book.context.insert(second)
        for _ in 0..<3 {
            try sync(mini)
            try sync(book)
        }
        XCTAssertEqual(tasks(mini).count, 1)
        XCTAssertEqual(tasks(book).count, 1)
        XCTAssertEqual(tasks(mini).first?.uid, tasks(book).first?.uid)
    }

    func testChatsAndMeetingsSync() throws {
        let mini = try makeMac("mini"), book = try makeMac("book")
        let conversation = Conversation(provider: .anthropic, model: "m")
        conversation.title = "Trip ideas"
        mini.context.insert(conversation)
        let message = ChatMessage(role: .user, content: "Where to in May?")
        mini.context.insert(message)
        message.conversation = conversation
        let meeting = Recording(kind: .meeting, title: "Weekly sync")
        meeting.status = .ready
        meeting.summary = "Agreed on the roadmap."
        meeting.segments = [TranscriptSegment(start: 0, end: 2, speaker: "Me", text: "Hello")]
        mini.context.insert(meeting)
        let live = Recording(kind: .meeting, title: "Still recording")
        mini.context.insert(live)
        try sync(mini)
        try sync(book)
        let chats = try book.context.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(chats.first?.title, "Trip ideas")
        XCTAssertEqual(chats.first?.messages.first?.content, "Where to in May?")
        let meetings = try book.context.fetch(FetchDescriptor<Recording>())
        XCTAssertEqual(meetings.map(\.title), ["Weekly sync"], "in-progress recordings wait until they're done")
        XCTAssertEqual(meetings.first?.segments.first?.text, "Hello")
        // A recording still in progress on the mini must not be treated as deleted.
        try sync(mini)
        XCTAssertEqual(try mini.context.fetch(FetchDescriptor<Recording>()).count, 2)
    }

    func testPlannerIgnoresOlderAndSameContent() {
        var state = SyncState()
        let item = LocalItem(kind: .note, id: UUID(), payload: "{\"a\":1}", naturalDate: Date(timeIntervalSince1970: 100))
        SyncPlanner.stamp([item], state: &state, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(state.entries[item.key]?.modifiedAt, Date(timeIntervalSince1970: 100))
        let older = SyncRecord(kind: .note, id: item.id, modifiedAt: Date(timeIntervalSince1970: 50), payload: "{\"a\":2}")
        let sameContent = SyncRecord(kind: .note, id: item.id, modifiedAt: Date(timeIntervalSince1970: 300), payload: "{\"a\":1}")
        XCTAssertTrue(SyncPlanner.incoming([older], state: state).isEmpty)
        XCTAssertTrue(SyncPlanner.incoming([sameContent], state: state).isEmpty)
        let newer = SyncRecord(kind: .note, id: item.id, modifiedAt: Date(timeIntervalSince1970: 300), payload: "{\"a\":3}")
        XCTAssertEqual(SyncPlanner.incoming([older, newer], state: state).first?.payload, "{\"a\":3}")
    }
}
