import Foundation
import SwiftData

// API credentials never live in these records; they are stored in the Keychain (see KeychainStore).

enum ChatRole: String, Codable {
    case user, assistant
}

@Model
final class Conversation {
    static let defaultTitle = "New chat"

    var uid: UUID = UUID()
    var title: String = "New chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var providerRaw: String = AIProviderID.anthropic.rawValue
    var model: String = ""
    var systemPrompt: String = ""

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []

    init(provider: AIProviderID, model: String, systemPrompt: String = "") {
        self.providerRaw = provider.rawValue
        self.model = model
        self.systemPrompt = systemPrompt
    }

    var provider: AIProviderID {
        get { AIProviderID(rawValue: providerRaw) ?? .anthropic }
        set { providerRaw = newValue.rawValue }
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

@Model
final class ChatMessage {
    var uid: UUID = UUID()
    var roleRaw: String = ChatRole.user.rawValue
    var content: String = ""
    var createdAt: Date = Date()
    var providerRaw: String?
    var model: String?
    var conversation: Conversation?

    init(role: ChatRole, content: String, provider: AIProviderID? = nil, model: String? = nil) {
        self.roleRaw = role.rawValue
        self.content = content
        self.providerRaw = provider?.rawValue
        self.model = model
        self.createdAt = Date()
    }

    var role: ChatRole { ChatRole(rawValue: roleRaw) ?? .user }
}

@Model
final class PromptTemplate {
    var uid: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var category: String = "General"
    var createdAt: Date = Date()

    init(title: String, body: String, category: String = "General") {
        self.title = title
        self.body = body
        self.category = category
    }
}

@Model
final class Note {
    var uid: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var folder: String = ""
    var tagsRaw: String = ""
    var isPinned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(title: String = "", body: String = "", folder: String = "") {
        self.title = title
        self.body = body
        self.folder = folder
    }

    var tags: [String] {
        tagsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled note" : String(firstLine.prefix(60))
    }
}

enum TaskPriority: Int, CaseIterable, Identifiable {
    case none = 0, low, medium, high
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

enum TaskRecurrence: String, CaseIterable, Identifiable {
    case none, daily, weekly, monthly
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    func next(after date: Date) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .none: return nil
        case .daily: return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }
}

/// Named TaskItem to avoid clashing with Swift concurrency's `Task`.
@Model
final class TaskItem {
    var uid: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var dueDate: Date?
    var priorityRaw: Int = 0
    var recurrenceRaw: String = TaskRecurrence.none.rawValue
    var category: String = ""
    var isCompleted: Bool = false
    var completedAt: Date?
    var createdAt: Date = Date()

    init(title: String, dueDate: Date? = nil, priority: TaskPriority = .none, category: String = "") {
        self.title = title
        self.dueDate = dueDate
        self.priorityRaw = priority.rawValue
        self.category = category
    }

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue }
    }

    var recurrence: TaskRecurrence {
        get { TaskRecurrence(rawValue: recurrenceRaw) ?? .none }
        set { recurrenceRaw = newValue.rawValue }
    }

    var isOverdue: Bool {
        guard let dueDate, !isCompleted else { return false }
        return dueDate < Date()
    }

    var notificationID: String { "task-\(uid.uuidString)" }
}
