import AppKit
import SwiftData
import SwiftUI

/// The floating assistant opened with ⌥Space from any app.
struct QuickAssistantView: View {
    @Environment(\.modelContext) private var context
    @State private var prompt = ""
    @State private var turns: [ChatTurn] = []
    @State private var streamingText = ""
    @State private var isStreaming = false
    @State private var errorMessage: String?
    @State private var streamTask: Task<Void, Never>?
    @State private var provider: AIProviderID = Prefs.preferredChatProvider
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                TextField("Ask \(provider.shortName) anything…", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($promptFocused)
                    .onSubmit(ask)
                Picker("", selection: $provider) {
                    ForEach(AIProviderID.allCases) { Text($0.shortName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if turns.isEmpty && !isStreaming {
                        Text("Press Return to ask. Esc closes this panel. Follow-up questions keep the context.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                        MessageBubble(role: turn.role, content: turn.content)
                    }
                    if isStreaming {
                        MessageBubble(role: .assistant, content: streamingText.isEmpty ? "…" : streamingText, isStreaming: true)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text("\(Prefs.model(for: provider))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isStreaming {
                    Button("Stop") { streamTask?.cancel() }
                }
                Button("Copy answer") {
                    if let last = turns.last(where: { $0.role == .assistant }) { Clipboard.copy(last.content) }
                }
                .disabled(!turns.contains { $0.role == .assistant })
                Button("Save to Assistant", action: saveConversation)
                    .disabled(turns.isEmpty)
                Button("Clear") {
                    turns = []
                    errorMessage = nil
                }
                .disabled(turns.isEmpty || isStreaming)
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 320)
        .background(.regularMaterial)
        .onAppear { promptFocused = true }
    }

    private func ask() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        prompt = ""
        errorMessage = nil
        turns.append(ChatTurn(role: .user, content: text))
        streamingText = ""
        isStreaming = true

        let provider = provider
        let model = Prefs.model(for: provider)
        let history = turns
        streamTask = Task { @MainActor in
            do {
                for try await chunk in AIRouter.stream(provider: provider, model: model, system: Prefs.defaultSystemPrompt, turns: history) {
                    switch chunk {
                    case .text(let piece): streamingText += piece
                    case let .usage(input, output): UsageTracker.record(provider, input: input, output: output)
                    case .notice(let message): errorMessage = message
                    }
                }
            } catch {
                if !Task.isCancelled { errorMessage = AIError.describe(error) }
            }
            if !streamingText.isEmpty {
                turns.append(ChatTurn(role: .assistant, content: streamingText))
            }
            streamingText = ""
            isStreaming = false
        }
    }

    private func saveConversation() {
        let conversation = Conversation(provider: provider, model: Prefs.model(for: provider), systemPrompt: Prefs.defaultSystemPrompt)
        conversation.title = String(turns.first?.content.prefix(60) ?? "Quick chat")
        context.insert(conversation)
        var timestamp = Date()
        for turn in turns {
            let message = ChatMessage(role: turn.role, content: turn.content, provider: provider)
            message.createdAt = timestamp
            timestamp = timestamp.addingTimeInterval(0.001)
            context.insert(message)
            message.conversation = conversation
        }
        try? context.save()
        WindowManager.shared.hideQuickAssistant()
        WindowManager.shared.showDashboard(section: .assistant)
    }
}
