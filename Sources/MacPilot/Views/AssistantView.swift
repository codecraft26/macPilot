import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AssistantView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var selection: Conversation?
    @State private var search = ""

    private var filtered: [Conversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(search)
                || conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search chats", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Button(action: newConversation) {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New chat")
                }
                .padding(10)
                List(filtered, selection: $selection) { conversation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title).lineLimit(1)
                        Text("\(conversation.provider.shortName) · \(conversation.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(conversation)
                    .contextMenu {
                        Button("Delete", role: .destructive) { delete(conversation) }
                    }
                }
            }
            .frame(width: 250)

            Divider()

            if let selection {
                ChatPane(conversation: selection, onDelete: { delete(selection) })
                    .id(selection.persistentModelID)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Start a conversation with Claude, OpenAI or a local model.")
                        .foregroundStyle(.secondary)
                    Button("New chat", action: newConversation)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("AI Assistant")
        .onAppear {
            if selection == nil { selection = conversations.first }
        }
    }

    private func newConversation() {
        let provider = Prefs.preferredChatProvider
        let conversation = Conversation(
            provider: provider,
            model: Prefs.model(for: provider),
            systemPrompt: Prefs.defaultSystemPrompt
        )
        context.insert(conversation)
        try? context.save()
        selection = conversation
    }

    private func delete(_ conversation: Conversation) {
        if selection == conversation { selection = nil }
        context.delete(conversation)
        try? context.save()
    }
}

struct ChatPane: View {
    @Bindable var conversation: Conversation
    var onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @State private var controller = ChatController()
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var showingImporter = false
    @State private var showingPrompts = false
    @State private var showingSystemPrompt = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            messageList
            if let notice = controller.notice {
                banner(notice, systemImage: "info.circle", color: .orange)
            }
            if let error = controller.errorMessage {
                banner(error, systemImage: "exclamationmark.triangle", color: .red)
            }
            Divider()
            composer
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.plainText, .sourceCode, .json, .commaSeparatedText, .xml, .yaml, .text],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if let attachment = try? Attachment.load(from: url) { attachments.append(attachment) }
            }
        }
        .sheet(isPresented: $showingPrompts) {
            PromptLibraryView { prompt in
                draft = prompt.body + draft
                showingPrompts = false
            }
        }
        .sheet(isPresented: $showingSystemPrompt) {
            SystemPromptEditor(text: $conversation.systemPrompt)
        }
    }

    // MARK: Toolbar

    private var providerBinding: Binding<AIProviderID> {
        Binding(
            get: { conversation.provider },
            set: { newValue in
                conversation.provider = newValue
                conversation.model = Prefs.model(for: newValue)
            }
        )
    }

    private var modelOptions: [String] {
        var models = Prefs.cachedModels(for: conversation.provider)
        if !conversation.model.isEmpty, !models.contains(conversation.model) {
            models.insert(conversation.model, at: 0)
        }
        return models
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Title", text: $conversation.title)
                .textFieldStyle(.plain)
                .font(.headline)
            Spacer()
            Picker("Provider", selection: providerBinding) {
                ForEach(AIProviderID.allCases) { provider in
                    Text(provider.shortName).tag(provider)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Picker("Model", selection: $conversation.model) {
                ForEach(modelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .frame(width: 200)
            Menu {
                Button("Prompt library…") { showingPrompts = true }
                Button("System prompt…") { showingSystemPrompt = true }
                Divider()
                Button("Copy conversation as Markdown") { Clipboard.copy(Exporter.markdown(for: conversation)) }
                Button("Export as Markdown…") {
                    Exporter.save(
                        text: Exporter.markdown(for: conversation),
                        suggestedName: Exporter.safeFileName(conversation.title) + ".md"
                    )
                }
                Divider()
                Button("Delete conversation", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 36)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.messages.isEmpty && !controller.isStreaming {
                        Text(conversation.provider.dataNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                    ForEach(conversation.sortedMessages) { message in
                        MessageBubble(role: message.role, content: message.content)
                    }
                    if controller.isStreaming {
                        MessageBubble(
                            role: .assistant,
                            content: controller.streamingText.isEmpty ? "…" : controller.streamingText,
                            isStreaming: true
                        )
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: controller.streamingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func banner(_ text: String, systemImage: String, color: Color) -> some View {
        HStack {
            Label(text, systemImage: systemImage)
                .foregroundStyle(color)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                Text(attachment.name).lineLimit(1)
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { showingImporter = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .help("Attach text or code files")
                Button { showingPrompts = true } label: { Image(systemName: "text.book.closed") }
                    .buttonStyle(.borderless)
                    .help("Prompt library")
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Message \(conversation.provider.shortName)…  (⌘↩ to send)")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.vertical, 4)
                }
                .frame(minHeight: 44, maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

                if controller.isStreaming {
                    Button("Stop") { controller.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Send", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                }
            }
        }
        .padding(12)
    }

    private func send() {
        controller.send(draft, attachments: attachments, conversation: conversation, context: context)
        draft = ""
        attachments = []
    }
}

struct MessageBubble: View {
    let role: ChatRole
    let content: String
    var isStreaming = false

    var body: some View {
        HStack(alignment: .top) {
            if role == .user { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(role == .user ? "You" : "Assistant")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    if isStreaming { ProgressView().controlSize(.mini) }
                    Spacer()
                    if !isStreaming {
                        Button { Clipboard.copy(content) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy")
                    }
                }
                Text(MarkdownText.attributed(content))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(role == .user ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            if role == .assistant { Spacer(minLength: 80) }
        }
    }
}

private struct SystemPromptEditor: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System prompt").font(.headline)
            Text("Instructions sent with every message in this conversation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
