import Foundation
import Observation
import SwiftData

/// Streams one reply at a time into a saved conversation.
@Observable
@MainActor
final class ChatController {
    var isStreaming = false
    var streamingText = ""
    var errorMessage: String?
    var notice: String?

    private var streamTask: Task<Void, Never>?

    func send(_ text: String, attachments: [Attachment], conversation: Conversation, context: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !trimmed.isEmpty || !attachments.isEmpty else { return }
        errorMessage = nil
        notice = nil

        let content = Attachment.compose(trimmed, attachments)
        var turns = conversation.sortedMessages.map { ChatTurn(role: $0.role, content: $0.content) }
        turns.append(ChatTurn(role: .user, content: content))

        let userMessage = ChatMessage(role: .user, content: content)
        context.insert(userMessage)
        userMessage.conversation = conversation
        if conversation.title == Conversation.defaultTitle {
            let base = trimmed.isEmpty ? (attachments.first?.name ?? "Attachment") : trimmed
            conversation.title = String(base.split(separator: "\n").first?.prefix(60) ?? "Chat")
        }
        conversation.updatedAt = Date()
        try? context.save()

        let provider = conversation.provider
        let model = conversation.model.isEmpty ? Prefs.model(for: provider) : conversation.model
        let system = conversation.systemPrompt

        isStreaming = true
        streamingText = ""
        streamTask = Task { [weak self] in
            var failure: Error?
            do {
                for try await chunk in AIRouter.stream(provider: provider, model: model, system: system, turns: turns) {
                    guard let self else { return }
                    switch chunk {
                    case .text(let piece): self.streamingText += piece
                    case let .usage(input, output): UsageTracker.record(provider, input: input, output: output)
                    case .notice(let message): self.notice = message
                    }
                }
            } catch {
                failure = error
            }
            self?.finish(
                conversation: conversation,
                context: context,
                provider: provider,
                model: model,
                cancelled: Task.isCancelled,
                failure: failure
            )
        }
    }

    func stop() {
        streamTask?.cancel()
    }

    private func finish(
        conversation: Conversation,
        context: ModelContext,
        provider: AIProviderID,
        model: String,
        cancelled: Bool,
        failure: Error?
    ) {
        let text = streamingText
        if !text.isEmpty {
            let content = cancelled ? text + "\n\n_[stopped]_" : text
            let reply = ChatMessage(role: .assistant, content: content, provider: provider, model: model)
            context.insert(reply)
            reply.conversation = conversation
            conversation.updatedAt = Date()
            try? context.save()
        }
        if let failure, !cancelled {
            errorMessage = AIError.describe(failure)
        }
        streamingText = ""
        isStreaming = false
        streamTask = nil
    }
}
