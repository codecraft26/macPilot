import AppKit
import Foundation
import SwiftData

extension AIRouter {
    /// Runs a single prompt to completion and returns the full text (usage is recorded).
    static func complete(provider: AIProviderID, system: String?, prompt: String) async throws -> String {
        let model = Prefs.model(for: provider)
        var text = ""
        for try await chunk in stream(provider: provider, model: model, system: system, turns: [ChatTurn(role: .user, content: prompt)]) {
            switch chunk {
            case .text(let piece): text += piece
            case let .usage(input, output): UsageTracker.record(provider, input: input, output: output)
            case .notice: break
            }
        }
        return text
    }
}

enum AnalysisError: LocalizedError {
    case emptyTranscript
    case unreadable

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "There is no transcript to analyze yet."
        case .unreadable: return "The AI reply could not be read as meeting notes. Try Analyze again or pick another provider in Settings → Routing."
        }
    }
}

/// Summaries, decisions, action items and follow-ups from a transcript, using the analysis provider.
enum MeetingIntelligence {
    /// Large transcripts are clipped to keep requests reasonable for every provider.
    static let maxTranscriptCharacters = 300_000

    static let systemPrompt = """
    You turn meeting and voice-note transcripts into accurate, concise notes. Only use what is in the transcript; \
    never invent owners, dates or decisions. Reply with a single JSON object and nothing else.
    """

    static func prompt(title: String, attendees: String, prepNotes: String, transcript: String) -> String {
        var context = "Title: \(title)\n"
        if !attendees.isEmpty { context += "Attendees: \(attendees)\n" }
        if !prepNotes.isEmpty { context += "Prep notes:\n\(prepNotes)\n" }
        let clipped = transcript.count > maxTranscriptCharacters
            ? String(transcript.prefix(maxTranscriptCharacters)) + "\n[transcript truncated]"
            : transcript
        return """
        \(context)
        Return JSON with exactly these keys:
        {
          "summary": "3-6 sentence summary",
          "decisions": ["decision", ...],
          "action_items": [{"task": "what", "owner": "who or null", "due": "when or null"}],
          "deadlines": ["date — what is due", ...],
          "open_questions": ["question", ...],
          "follow_up_email": "short follow-up email to attendees with decisions and owners"
        }
        Use empty arrays when there is nothing. "Me" is the person who recorded; "Others" is everyone heard through the computer.

        Transcript:
        \(clipped)
        """
    }

    static func analyze(title: String, attendees: String, prepNotes: String, transcript: String) async throws -> MeetingAnalysis {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AnalysisError.emptyTranscript }
        let reply = try await AIRouter.complete(
            provider: Prefs.analysisProvider,
            system: systemPrompt,
            prompt: prompt(title: title, attendees: attendees, prepNotes: prepNotes, transcript: transcript)
        )
        guard let analysis = parse(reply) else { throw AnalysisError.unreadable }
        return analysis
    }

    /// Lenient parse: tolerates code fences, prose around the JSON, snake_case or camelCase keys.
    static func parse(_ reply: String) -> MeetingAnalysis? {
        guard let data = JSONExtraction.object(in: reply) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let analysis = try? decoder.decode(MeetingAnalysis.self, from: data) else { return nil }
        let empty = analysis.summary.isEmpty && analysis.decisions.isEmpty && analysis.actionItems.isEmpty
            && analysis.openQuestions.isEmpty && analysis.followUpEmail.isEmpty
        return empty ? nil : analysis
    }

    static func summarize(note: String) async throws -> String {
        let reply = try await AIRouter.complete(
            provider: Prefs.analysisProvider,
            system: "You summarize notes. Reply in Markdown: a one-line TL;DR, then up to 6 bullet points, then action items as a checklist if there are any.",
            prompt: note
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum JSONExtraction {
    /// Returns the outermost JSON object in `text`, if any.
    static func object(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let candidate = String(text[start...end])
        guard let data = candidate.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return data
    }
}

/// Runs transcription and analysis for a recording and stores the results.
@MainActor
enum RecordingProcessor {
    private static var running: Set<UUID> = []

    static func isRunning(_ recording: Recording) -> Bool { running.contains(recording.uid) }

    /// Transcribes (if needed) and then analyzes.
    static func process(_ recording: Recording, liveMicrophone: [TranscriptSegment] = []) {
        guard !running.contains(recording.uid) else { return }
        running.insert(recording.uid)
        Task {
            defer { running.remove(recording.uid) }
            if recording.segments.isEmpty {
                guard await transcribeNow(recording, liveMicrophone: liveMicrophone) else { return }
            }
            await analyzeNow(recording)
        }
    }

    static func transcribe(_ recording: Recording) {
        guard !running.contains(recording.uid) else { return }
        running.insert(recording.uid)
        Task {
            defer { running.remove(recording.uid) }
            await transcribeNow(recording)
        }
    }

    static func analyze(_ recording: Recording) {
        guard !running.contains(recording.uid) else { return }
        running.insert(recording.uid)
        Task {
            defer { running.remove(recording.uid) }
            await analyzeNow(recording)
        }
    }

    @discardableResult
    private static func transcribeNow(_ recording: Recording, liveMicrophone: [TranscriptSegment] = []) async -> Bool {
        let context = Persistence.container.mainContext
        recording.status = .transcribing
        recording.errorMessage = nil
        try? context.save()
        let tracking = S3Tracking()
        defer {
            // Remember S3 folders even when the job failed, so deleting the recording removes leftovers.
            let found = tracking.locations.filter { !recording.s3Locations.contains($0) }
            if !found.isEmpty {
                recording.s3Locations += found
                try? context.save()
            }
        }
        do {
            let segments = try await S3Tracking.$current.withValue(tracking) {
                try await TranscriptionService.transcribe(RecordingSnapshot(recording), liveMicrophone: liveMicrophone)
            }
            recording.segments = segments
            recording.status = .transcribed
            if segments.isEmpty { recording.notice = "No speech was detected." }
            try? context.save()
            if !segments.isEmpty { AutomationEngine.shared.transcriptReady(recording) }
            return true
        } catch {
            recording.status = .failed
            recording.errorMessage = "Transcription failed (\(Prefs.transcriptionProvider.displayName)): \(AIError.describe(error))"
                + (Prefs.transcriptionProvider == .openAI ? " To use AWS instead, choose Amazon Transcribe in Settings → Routing → Audio transcription." : "")
            try? context.save()
            return false
        }
    }

    private static func analyzeNow(_ recording: Recording) async {
        let context = Persistence.container.mainContext
        guard !recording.segments.isEmpty else { return }
        recording.status = .analyzing
        recording.errorMessage = nil
        try? context.save()
        do {
            let analysis = try await MeetingIntelligence.analyze(
                title: recording.title,
                attendees: recording.attendees,
                prepNotes: recording.prepNotes,
                transcript: recording.transcriptText
            )
            recording.apply(analysis)
            NotchController.shared.peek(NotchPeek(systemImage: "sparkles", tint: .accent, title: "Summary ready: \(recording.title)",
                                                   subtitle: "\(recording.actionItems.count) action item\(recording.actionItems.count == 1 ? "" : "s")",
                                                   duration: 7, action: .openRecording(recording.uid, kind: recording.kind)))
            recording.status = .ready
        } catch {
            recording.status = .failed
            recording.errorMessage = "Analysis failed: \(AIError.describe(error))"
        }
        try? context.save()
    }
}

// MARK: - Turning results into notes and tasks

@MainActor
enum RecordingActions {
    static func saveAsNote(_ recording: Recording, context: ModelContext) -> Note {
        let note = Note(title: recording.title, body: TranscriptExport.markdown(for: recording), folder: "Meetings")
        note.recordingID = recording.uid
        note.eventID = recording.calendarEventID
        note.tagsRaw = recording.kind == .meeting ? "meeting" : "voice"
        context.insert(note)
        try? context.save()
        return note
    }

    static func addTask(_ item: ActionItem, from recording: Recording, context: ModelContext) {
        let title = item.owner.map { "\(item.task) (\($0))" } ?? item.task
        let task = TaskItem(title: title, dueDate: item.due.flatMap { DateParsing.firstDate(in: $0) }, category: "Meeting")
        task.notes = "From \(recording.title) on \(recording.startedAt.formatted(date: .abbreviated, time: .shortened))"
        if let due = item.due, task.dueDate == nil { task.notes += "\nDue: \(due)" }
        context.insert(task)
        try? context.save()
        NotificationService.schedule(id: task.notificationID, title: task.title, at: task.dueDate)
    }

    static func delete(_ recording: Recording, context: ModelContext) {
        let locations = recording.s3Locations
        if !locations.isEmpty {
            Task { await deleteS3(locations, title: recording.title) }
        }
        RecordingStorage.deleteFiles(for: recording.uid)
        AutomationEngine.discardPending(for: recording.uid, context: context)
        context.delete(recording)
        try? context.save()
    }

    /// Removes a deleted recording's files from S3; tells the user if that isn't possible.
    private static func deleteS3(_ locations: [S3Location], title: String) async {
        var failures: [String] = []
        for location in locations {
            do {
                try await S3Client.deletePrefix(bucket: location.bucket, prefix: location.prefix, region: location.region)
            } catch {
                failures.append("\(location.displayPath): \(AIError.describe(error))")
            }
        }
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "“\(title)” was deleted on this Mac, but its files in S3 could not be removed."
        alert.informativeText = failures.joined(separator: "\n") + "\n\nCheck that your AWS key allows s3:ListBucket and s3:DeleteObject, or delete these folders in the S3 console. Settings → Routing → “Clean up S3” retries all of them."
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// A chat whose system prompt carries the transcript, so the user can ask follow-up questions.
    static func startChat(about recording: Recording, context: ModelContext) {
        let provider = Prefs.preferredChatProvider
        let transcript = String(recording.transcriptText.prefix(MeetingIntelligence.maxTranscriptCharacters))
        let system = Prefs.defaultSystemPrompt + "\n\nAnswer questions about this recording (\(recording.title), \(recording.startedAt.formatted())). Transcript:\n" + transcript
        let conversation = Conversation(provider: provider, model: Prefs.model(for: provider), systemPrompt: system)
        conversation.title = "About: \(recording.title)"
        context.insert(conversation)
        try? context.save()
        WindowManager.shared.showDashboard(section: .assistant)
    }
}

enum DateParsing {
    /// The first date mentioned in free text ("Friday", "next Tuesday 3pm", "2026-12-01"), using the local calendar.
    static func firstDate(in text: String, relativeTo now: Date = Date()) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.date
    }
}
