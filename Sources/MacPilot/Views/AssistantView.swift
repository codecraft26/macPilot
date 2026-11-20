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
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    if conversation.messages.isEmpty && !controller.isStreaming {
                        ChatEmptyState(provider: conversation.provider) { example in draft = example }
                    }
                    ForEach(conversation.sortedMessages) { message in
                        MessageBubble(role: message.role, content: message.content)
                    }
                    if controller.isStreaming {
                        MessageBubble(role: .assistant, content: controller.streamingText, isStreaming: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
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
            HStack(alignment: .bottom, spacing: DS.Space.xs) {
                Button { showingImporter = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .help("Attach text or code files")
                    .accessibilityLabel("Attach files")
                    .padding(.bottom, 7)
                Button { showingPrompts = true } label: { Image(systemName: "text.book.closed") }
                    .buttonStyle(.borderless)
                    .help("Prompt library")
                    .accessibilityLabel("Prompt library")
                    .padding(.bottom, 7)
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Message \(conversation.provider.shortName)…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.vertical, 2)
                }
                .frame(minHeight: 30, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)

                if controller.isStreaming {
                    Button { controller.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop (⌘.)")
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                    .help("Send (⌘↩)")
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.inset))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.hairline))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            Text("⌘↩ to send · \(conversation.provider.dataNotice)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
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
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            if role == .user {
                Spacer(minLength: 60)
            } else {
                IconTile(systemImage: "sparkles", color: DS.accent, size: 26)
            }
            VStack(alignment: role == .user ? .trailing : .leading, spacing: DS.Space.xxs) {
                if isStreaming && content.isEmpty {
                    TypingIndicator().padding(DS.Space.s)
                } else if role == .user {
                    Text(MarkdownText.attributed(content))
                        .textSelection(.enabled)
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, DS.Space.xs)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.accent.opacity(0.14)))
                } else {
                    RichMessageText(content: content)
                }
                if !isStreaming {
                    HStack(spacing: DS.Space.s) {
                        Button { Clipboard.copy(content) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .accessibilityLabel("Copy message")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
        }
        .onHover { hovering = $0 }
    }
}

/// Splits Markdown into prose and fenced code blocks; code gets a monospaced box with a copy button.
struct RichMessageText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Array(MessageBlocks.parse(content).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(MarkdownText.attributed(text))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .code(language, code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 6)
            .background(DS.subtleFill)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(DS.Space.s)
            }
        }
        .insetWell()
    }
}

enum MessageBlocks {
    enum Block: Equatable {
        case text(String)
        case code(language: String, code: String)
    }

    /// Fenced ``` blocks become code; an unterminated fence (while streaming) is treated as code too.
    static func parse(_ content: String) -> [Block] {
        var blocks: [Block] = []
        var text: [Substring] = []
        var code: [Substring] = []
        var language = ""
        var inCode = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    let prose = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    if !prose.isEmpty { blocks.append(.text(prose)) }
                    text = []
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode {
                code.append(line)
            } else {
                text.append(line)
            }
        }
        if inCode {
            blocks.append(.code(language: language, code: code.joined(separator: "\n")))
        } else {
            let prose = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !prose.isEmpty { blocks.append(.text(prose)) }
        }
        return blocks
    }
}

/// Shown in an empty conversation: what the assistant can do, with tappable examples.
private struct ChatEmptyState: View {
    let provider: AIProviderID
    var onPick: (String) -> Void

    private let examples: [(String, String)] = [
        ("doc.text.magnifyingglass", "Summarize this article in 5 bullet points:"),
        ("chevron.left.forwardslash.chevron.right", "Explain what this code does and point out bugs:"),
        ("envelope", "Draft a short, friendly reply to this email:"),
        ("lightbulb", "Give me 5 ideas for a team offsite agenda")
    ]

    var body: some View {
        VStack(spacing: DS.Space.m) {
            IconTile(systemImage: "sparkles", color: DS.accent, size: 44)
            Text("How can I help?").font(.title2.weight(.semibold))
            Text("Chatting with \(provider.displayName) · \(Prefs.model(for: provider))")
                .font(.callout)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Space.s) {
                ForEach(examples, id: \.1) { icon, text in
                    Button { onPick(text + (text.hasSuffix(":") ? "\n\n" : "")) } label: {
                        HStack(alignment: .top, spacing: DS.Space.xs) {
                            Image(systemName: icon).foregroundStyle(DS.accent)
                            Text(text).multilineTextAlignment(.leading).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .padding(DS.Space.s)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                        .card(padding: 0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Space.xl)
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
