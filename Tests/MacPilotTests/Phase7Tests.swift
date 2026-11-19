import Foundation
import SwiftData
import XCTest
@testable import MacPilot

final class AWSAudioTests: XCTestCase {
    func testBedrockReadsStandardOutputWithinTheJobPrefix() throws {
        let path = "s3://my.bucket/macpilot/job/output/id/0/standard_output/0/result.json"
        let metadata: [String: Any] = ["output_metadata": [
            ["segment_metadata": [["standard_output_path": path]]]
        ]]
        XCTAssertEqual(BedrockTranscription.standardOutputPaths(metadata), [path])
        XCTAssertEqual(try BedrockTranscription.objectKey(path, bucket: "my.bucket", prefix: "macpilot/job/output/"),
                       "macpilot/job/output/id/0/standard_output/0/result.json")
        XCTAssertThrowsError(try BedrockTranscription.objectKey(path, bucket: "other-bucket", prefix: "macpilot/job/output/"))
        XCTAssertThrowsError(try BedrockTranscription.objectKey("s3://my.bucket/macpilot/job/output/../input/audio.wav",
                                                               bucket: "my.bucket", prefix: "macpilot/job/output/"))
    }

    func testBedrockPreservesSpeakerAndTimeOffsets() throws {
        let output: [String: Any] = ["audio_segments": [
            ["type": "TRANSCRIPT", "text": " Hello ", "start_timestamp_millis": 1250, "end_timestamp_millis": 2000,
             "speaker": ["speaker_label": "spk_1"]],
            ["type": "TRANSCRIPT", "text": "Later", "start_timestamp_millis": 2500, "end_timestamp_millis": 3400,
             "speaker": ["speaker_label": "spk_0"]]
        ]]
        let result = try BedrockTranscription.segments(output, track: "Others", offset: 3)
        XCTAssertEqual(result.map(\.speaker), ["Speaker 2", "Speaker 1"])
        XCTAssertEqual(result.map(\.start), [4.25, 5.5])
        XCTAssertEqual(result.map(\.text), ["Hello", "Later"])
        XCTAssertThrowsError(try BedrockTranscription.segments([:], track: "Others", offset: 0))
    }

    func testStreamingLanguageOptionsAndPartialEventFrames() throws {
        let url = TranscribeStream.url(region: "us-east-1", language: "auto", speakers: true)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let languages = try XCTUnwrap(query.first { $0.name == "language-options" }?.value)
        let dialects = languages.split(separator: ",")
        XCTAssertEqual(Set(dialects.map { $0.prefix(2) }).count, dialects.count)
        XCTAssertEqual(url.port, 8443)

        let audio = Data([1, 2, 3, 4])
        let frame = EventStream.audioEvent(audio)
        var buffer = Data(frame.prefix(12))
        XCTAssertTrue(try EventStream.decode(&buffer).isEmpty)
        buffer.append(frame.dropFirst(12))
        let messages = try EventStream.decode(&buffer)
        XCTAssertEqual(messages.first?.headers[":event-type"], "AudioEvent")
        XCTAssertEqual(messages.first?.payload, audio)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testLocalWhisperDecodesMillisecondOffsets() throws {
        let fixture = Data(#"{"transcription":[{"offsets":{"from":250,"to":1750},"text":" A phrase "}]}"#.utf8)
        let result = try LocalWhisper.segments(fixture, speaker: "Me", offset: 4)
        XCTAssertEqual(result.first?.start, 4.25)
        XCTAssertEqual(result.first?.end, 5.75)
        XCTAssertEqual(result.first?.text, "A phrase")
    }
}

final class AutomationTests: XCTestCase {
    @MainActor
    func testMatchingRunCreatesOneNoteEvenWhenTheTriggerRepeats() throws {
        let container = try ModelContainer(for: Persistence.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let workflow = AutomationWorkflow(name: "Sync Notes")
        workflow.titleContains = "sync"
        workflow.minimumMinutes = 10
        let tooShort = AutomationEvent(trigger: .transcriptReady, id: "1", date: Date(), title: "Team Sync", body: "Done", minutes: 9)
        let event = AutomationEvent(trigger: .transcriptReady, id: "2", date: Date(), title: "Team Sync", body: "Done", minutes: 10)
        AutomationEngine.handle(tooShort, workflows: [workflow], context: context)
        AutomationEngine.handle(event, workflows: [workflow], context: context)
        AutomationEngine.handle(event, workflows: [workflow], context: context)
        let runs = try context.fetch(FetchDescriptor<AutomationRun>())
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .completed)
        XCTAssertEqual(runs.first?.payload, "")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).map(\.body), ["Done"])
    }

    @MainActor
    func testQueuedWorkRequiresApprovalAndUsesOneDecision() throws {
        let container = try ModelContainer(for: Persistence.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let rule = AutomationWorkflow(name: "Review before task")
        rule.action = .createTask
        rule.requiresApproval = true
        let copyRule = AutomationWorkflow(name: "Copy")
        copyRule.action = .copyTranscript
        let event = AutomationEvent(trigger: .transcriptReady, id: "1", date: Date(), title: "Notes", body: "Transcript")
        AutomationEngine.handle(event, workflows: [rule, copyRule], context: context)
        let runs = try context.fetch(FetchDescriptor<AutomationRun>())
        let task = try XCTUnwrap(runs.first { $0.action == .createTask })
        let copy = try XCTUnwrap(runs.first { $0.action == .copyTranscript })
        XCTAssertEqual(task.status, .pending)
        XCTAssertEqual(copy.status, .pending)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        AutomationEngine.resolve(copy, approved: false, context: context)
        AutomationEngine.resolve(task, approved: true, context: context)
        AutomationEngine.resolve(task, approved: true, context: context)
        XCTAssertEqual(copy.status, .declined)
        XCTAssertEqual(copy.payload, "")
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).map(\.notes), ["Transcript"])
    }

    @MainActor
    func testExistingStoreOpensWithAutomationModels() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("migration.store")
        let oldSchema = Schema([Conversation.self, ChatMessage.self, PromptTemplate.self, Note.self, TaskItem.self, Recording.self, ClipboardItem.self])
        do {
            let oldStore = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, url: url)])
            oldStore.mainContext.insert(Note(title: "Existing note", body: "My data"))
            try oldStore.mainContext.save()
        }
        let store = try ModelContainer(for: Persistence.schema, configurations: [ModelConfiguration(schema: Persistence.schema, url: url)])
        XCTAssertEqual(try store.mainContext.fetch(FetchDescriptor<Note>()).map(\.title), ["Existing note"])
        store.mainContext.insert(AutomationWorkflow(name: "New workflow"))
        try store.mainContext.save()
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<AutomationWorkflow>()), 1)
    }
}
