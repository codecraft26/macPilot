import Foundation
import Observation
import SwiftData

/// "Good morning" briefing: today's meetings, due/overdue tasks and open action items from recent meetings,
/// written by the analysis provider once a day (and on request). Falls back to a plain list without AI.
@Observable
@MainActor
final class DailyBriefing {
    static let shared = DailyBriefing()

    enum Phase: Equatable { case idle, writing, failed(String) }

    private(set) var text: String
    private(set) var generatedAt: Date?
    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    private let textKey = "briefing.text"
    private let dateKey = "briefing.date"

    private init() {
        text = UserDefaults.standard.string(forKey: textKey) ?? ""
        generatedAt = UserDefaults.standard.object(forKey: dateKey) as? Date
    }

    var isFromToday: Bool { generatedAt.map(Calendar.current.isDateInToday) ?? false }

    /// Called when the dashboard appears: writes today's briefing once (after 5am) if enabled.
    func generateIfNeeded() {
        guard UserDefaults.standard.bool(forKey: PrefKey.autoBriefing), !isFromToday, phase != .writing,
              Calendar.current.component(.hour, from: Date()) >= 5 else { return }
        generate()
    }

    func generate() {
        task?.cancel()
        let facts = Self.facts(now: Date(), events: CalendarService.shared.events(on: Date()), context: Persistence.container.mainContext)
        phase = .writing
        text = ""
        let provider = Prefs.analysisProvider
        task = Task {
            do {
                for try await chunk in AIRouter.stream(provider: provider, model: Prefs.model(for: provider), system: Self.systemPrompt,
                                                        turns: [ChatTurn(role: .user, content: facts)]) {
                    switch chunk {
                    case .text(let piece): text += piece
                    case let .usage(input, output): UsageTracker.record(provider, input: input, output: output)
                    case .notice: break
                    }
                }
                guard !Task.isCancelled else { return }
                save()
                phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                // No AI available: show the facts themselves.
                text = facts
                save()
                phase = .failed(AIError.describe(error))
            }
        }
    }

    private func save() {
        generatedAt = Date()
        UserDefaults.standard.set(text, forKey: textKey)
        UserDefaults.standard.set(generatedAt, forKey: dateKey)
    }

    static let systemPrompt = """
    Write the user's morning briefing from the facts below. Use **bold** section labels and "- " bullets (no # headings). Start with one friendly sentence on what the day looks like. \
    Then short sections only when they have content: "Meetings", "Due & overdue", "Open from recent meetings", and finish with \
    "Suggested focus" (1–3 bullets on what to do first and why). Be concise (under 180 words), use the times given, don't invent anything.
    """

    /// Plain-text facts for the model (also shown as-is when no AI is configured).
    static func facts(now: Date, events: [CalendarEvent], context: ModelContext) -> String {
        let calendar = Calendar.current
        var lines = ["Today is \(now.formatted(date: .complete, time: .shortened))."]

        let meetings = events.filter { !$0.isAllDay && $0.end > now.addingTimeInterval(-3_600) }.sorted { $0.start < $1.start }
        let allDay = events.filter(\.isAllDay)
        lines.append("\nMeetings today (\(meetings.count)):")
        if meetings.isEmpty { lines.append("- none") }
        for event in meetings {
            var line = "- \(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened)) \(event.title)"
            if !event.attendees.isEmpty { line += " with \(event.attendees.prefix(5).joined(separator: ", "))" }
            if !event.location.isEmpty { line += " (\(event.location.prefix(60)))" }
            lines.append(line)
        }
        if !allDay.isEmpty { lines.append("All-day: " + allDay.map(\.title).joined(separator: ", ")) }

        let open = ((try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isCompleted }))) ?? [])
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let overdue = open.filter { ($0.dueDate ?? .distantFuture) < calendar.startOfDay(for: now) }.sorted { ($0.dueDate ?? now) < ($1.dueDate ?? now) }
        let today = open.filter { guard let due = $0.dueDate else { return false }; return due >= calendar.startOfDay(for: now) && due < endOfDay }
        let important = open.filter { $0.dueDate == nil && $0.priority == .high }
        lines.append("\nTasks due today (\(today.count)):")
        lines += today.prefix(10).map { "- \($0.title)\($0.dueDate.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? "")" }
        lines.append("Overdue (\(overdue.count)):")
        lines += overdue.prefix(10).map { "- \($0.title) (was due \($0.dueDate!.formatted(date: .abbreviated, time: .omitted)))" }
        if !important.isEmpty {
            lines.append("High priority, no date:")
            lines += important.prefix(5).map { "- \($0.title)" }
        }

        let since = calendar.date(byAdding: .day, value: -3, to: now) ?? now
        let recent = ((try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.startedAt >= since }))) ?? [])
            .filter { !$0.actionItems.isEmpty }
        let taskTitles = Set(open.map { $0.title.lowercased() })
        var actionLines: [String] = []
        for recording in recent {
            for item in recording.actionItems where !taskTitles.contains(where: { $0.contains(item.task.lowercased()) }) {
                actionLines.append("- \(item.task)\(item.owner.map { " — \($0)" } ?? "")\(item.due.map { ", due \($0)" } ?? "") (from \(recording.title))")
            }
        }
        lines.append("\nOpen action items from meetings in the last 3 days (\(actionLines.count)):")
        lines += actionLines.prefix(10)
        return lines.joined(separator: "\n")
    }
}
