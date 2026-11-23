import Foundation

/// One finished turn of a chat, as context for the next one.
struct AgentTurnContext: Equatable {
    var prompt: String
    /// Tool calls as short lines: "read_file docs/a.md — succeeded: first lines…".
    var actions: [String]
    var answer: String
    var error: String?
}

/// Builds the model's messages for a follow-up: earlier turns (newest kept first when trimming) + the new message.
/// The system prompt is separate and always sent; earlier tool calls are given as text, never re-run.
enum AgentConversationContext {
    static let defaultBudget = 24_000

    static func render(_ turn: AgentTurnContext) -> String {
        var parts: [String] = []
        if !turn.actions.isEmpty { parts.append("Tools used:\n" + turn.actions.map { "- " + $0 }.joined(separator: "\n")) }
        if !turn.answer.isEmpty { parts.append(turn.answer) }
        if let error = turn.error, !error.isEmpty { parts.append("(This turn ended with: \(error))") }
        return parts.isEmpty ? "(No answer.)" : parts.joined(separator: "\n\n")
    }

    /// Keeps the latest turns that fit in `budget` characters; older ones are replaced by a one-line note.
    static func messages(history: [AgentTurnContext], current: String, budget: Int = defaultBudget) -> [AgentMessage] {
        var kept: [(String, String)] = []
        var used = current.count
        for turn in history.reversed() {
            let reply = render(turn)
            let cost = turn.prompt.count + reply.count
            if used + cost > budget { break }
            used += cost
            kept.insert((turn.prompt, reply), at: 0)
        }
        var messages: [AgentMessage] = []
        let dropped = history.count - kept.count
        for (index, pair) in kept.enumerated() {
            let prefix = index == 0 && dropped > 0 ? "(\(dropped) earlier message\(dropped == 1 ? "" : "s") in this chat omitted.)\n\n" : ""
            messages.append(.user(prefix + pair.0))
            messages.append(.assistant(text: pair.1, calls: [], raw: nil))
        }
        let prefix = kept.isEmpty && dropped > 0 ? "(\(dropped) earlier message\(dropped == 1 ? "" : "s") in this chat omitted.)\n\n" : ""
        messages.append(.user(prefix + current))
        return messages
    }

    /// One tool call as a context line, output trimmed.
    static func line(tool: String, summary: String, state: String, output: String) -> String {
        let out = output.replacingOccurrences(of: "\n", with: " ").prefix(300)
        return "\(tool) \(summary) — \(state)" + (out.isEmpty ? "" : ": \(out)")
    }
}

/// Telegram: free text continues the user's current chat until /new or 30 minutes of quiet.
struct TelegramConversations {
    static let idleLimit: TimeInterval = 30 * 60
    private(set) var current: [Int64: (id: UUID, last: Date)] = [:]

    /// The chat to continue, or nil to start a new one.
    func conversation(for user: Int64, now: Date) -> UUID? {
        guard let entry = current[user], now.timeIntervalSince(entry.last) < Self.idleLimit else { return nil }
        return entry.id
    }

    mutating func touch(_ user: Int64, conversation: UUID, now: Date) { current[user] = (conversation, now) }
    mutating func reset(_ user: Int64) { current[user] = nil }
}

/// A chat in the Agent tab: its turns (tasks) oldest first.
struct AgentChat: Identifiable, Equatable {
    var id: UUID
    var turns: [AgentTask]

    var latest: AgentTask { turns.last! }
    var title: String {
        let custom = turns.first?.conversationTitle ?? ""
        if !custom.isEmpty { return custom }
        let first = turns.first?.title ?? ""
        return first.isEmpty ? "Chat" : first
    }
    /// Changes whenever a turn is added or moves on (for scrolling to the bottom).
    var signature: String { turns.map { "\($0.uid)\($0.stateRaw)\($0.steps)" }.joined() }

    /// Groups tasks into chats; tasks from before chats existed are single-turn chats. Newest activity first.
    static func group(_ tasks: [AgentTask]) -> [AgentChat] {
        Dictionary(grouping: tasks, by: \.conversationKey)
            .map { AgentChat(id: $0.key, turns: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.latest.createdAt > $1.latest.createdAt }
    }

    static func == (lhs: AgentChat, rhs: AgentChat) -> Bool { lhs.id == rhs.id && lhs.signature == rhs.signature }
}
