import AppKit
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum Clipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

enum MarkdownText {
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A text file attached to a chat message. Its content is sent inline with the prompt.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let content: String

    static let maxBytes = 200_000

    static func load(from url: URL) throws -> Attachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let clipped = data.prefix(maxBytes)
        let text = String(decoding: clipped, as: UTF8.self)
        let note = data.count > maxBytes ? "\n[…truncated at \(maxBytes / 1000) KB]" : ""
        return Attachment(name: url.lastPathComponent, content: text + note)
    }

    static func compose(_ text: String, _ attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let files = attachments.map { "Attached file: \($0.name)\n```\n\($0.content)\n```" }
        return ([text] + files).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

@MainActor
enum Exporter {
    static func save(text: String, suggestedName: String, fileExtension: String = "md") {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func markdown(for conversation: Conversation) -> String {
        var lines = ["# \(conversation.title)", "", "_\(conversation.provider.shortName) · \(conversation.model)_", ""]
        for message in conversation.sortedMessages {
            lines.append(message.role == .user ? "## You" : "## Assistant")
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return cleaned.isEmpty ? "MacPilot" : String(cleaned.prefix(80))
    }
}

/// Export and deletion of everything MacPilot stores (PRD section 11).
@MainActor
enum DataManager {
    static func exportAllJSON(context: ModelContext) throws -> String {
        let iso = ISO8601DateFormatter()
        func date(_ value: Date?) -> Any { value.map { iso.string(from: $0) } ?? NSNull() }

        let conversations = try context.fetch(FetchDescriptor<Conversation>()).map { conversation -> [String: Any] in
            [
                "id": conversation.uid.uuidString,
                "title": conversation.title,
                "provider": conversation.providerRaw,
                "model": conversation.model,
                "createdAt": date(conversation.createdAt),
                "messages": conversation.sortedMessages.map { message -> [String: Any] in
                    ["role": message.roleRaw, "content": message.content, "createdAt": date(message.createdAt)]
                }
            ]
        }
        let notes = try context.fetch(FetchDescriptor<Note>()).map { note -> [String: Any] in
            [
                "id": note.uid.uuidString, "title": note.title, "body": note.body, "folder": note.folder,
                "tags": note.tags, "pinned": note.isPinned,
                "createdAt": date(note.createdAt), "updatedAt": date(note.updatedAt)
            ]
        }
        let tasks = try context.fetch(FetchDescriptor<TaskItem>()).map { task -> [String: Any] in
            [
                "id": task.uid.uuidString, "title": task.title, "notes": task.notes, "category": task.category,
                "priority": task.priority.label, "recurrence": task.recurrenceRaw,
                "dueDate": date(task.dueDate), "completed": task.isCompleted, "completedAt": date(task.completedAt)
            ]
        }
        let recordings = try context.fetch(FetchDescriptor<Recording>()).map { recording -> [String: Any] in
            [
                "id": recording.uid.uuidString, "title": recording.title, "kind": recording.kindRaw,
                "startedAt": date(recording.startedAt), "durationSeconds": recording.duration,
                "attendees": recording.attendees, "prepNotes": recording.prepNotes,
                "summary": recording.summary, "decisions": recording.decisions,
                "actionItems": recording.actionItems.map { ["task": $0.task, "owner": $0.owner ?? NSNull(), "due": $0.due ?? NSNull()] as [String: Any] },
                "deadlines": recording.deadlines, "openQuestions": recording.openQuestions,
                "followUpEmail": recording.followUpEmail,
                "transcript": recording.segments.map { ["start": $0.start, "end": $0.end, "speaker": $0.speaker, "text": $0.text] as [String: Any] },
                "audioFiles": recording.audioURLs.map(\.path)
            ]
        }
        let prompts = try context.fetch(FetchDescriptor<PromptTemplate>()).map { prompt -> [String: Any] in
            ["title": prompt.title, "body": prompt.body, "category": prompt.category]
        }
        let root: [String: Any] = [
            "exportedAt": iso.string(from: Date()),
            "app": "MacPilot",
            "conversations": conversations,
            "notes": notes,
            "tasks": tasks,
            "recordings": recordings,
            "prompts": prompts
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func deleteAllConversations(context: ModelContext) throws {
        try context.delete(model: ChatMessage.self)
        try context.delete(model: Conversation.self)
        try context.save()
    }

    static func deleteAllLocalData(context: ModelContext) throws {
        try context.delete(model: ChatMessage.self)
        try context.delete(model: Conversation.self)
        try context.delete(model: Note.self)
        try context.delete(model: TaskItem.self)
        try context.delete(model: PromptTemplate.self)
        try context.delete(model: Recording.self)
        try context.delete(model: ClipboardItem.self)
        try context.save()
        RecordingStorage.deleteAll()
        ClipboardStorage.deleteAll()
        CommandHistory.clear()
        NotificationService.cancelAll()
        for provider in AIProviderID.allCases {
            UsageTracker.reset(provider)
        }
    }

    static func deleteAllAPIKeys() {
        for provider in AIProviderID.allCases {
            try? KeychainStore.delete(account: provider.rawValue)
        }
        BedrockConfig.deleteAll()
        try? KeychainStore.delete(account: GoogleCalendarService.clientSecretAccount)
        GoogleCalendarService.shared.disconnect()
    }
}

/// Task reminders. Only available when running as a bundled .app.
enum NotificationService {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func schedule(id: String, title: String, at date: Date?) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let date, date > Date() else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Task due"
            content.body = title
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    static func cancel(id: String) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    static func cancelAll() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

extension Date {
    var shortRelative: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today \(formatted(date: .omitted, time: .shortened))" }
        if calendar.isDateInTomorrow(self) { return "Tomorrow \(formatted(date: .omitted, time: .shortened))" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        return formatted(date: .abbreviated, time: .shortened)
    }
}
