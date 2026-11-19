import SwiftUI

/// ⌥⇧A: ask a question and get an answer drawn from your own notes, tasks, meetings and clipboard.
struct AskMyMacView: View {
    @State private var keyMonitor = PanelKeyMonitor()
    @FocusState private var fieldFocused: Bool
    private let controller = AskMyMacController.shared

    private let examples = [
        "What did we decide about the launch date?",
        "Which tasks are due this week?",
        "What did Priya say about the budget?",
        "Where did I note the Wi-Fi password for the office?"
    ]

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(systemImage: "sparkle.magnifyingglass", color: DS.violet, size: 26)
                TextField("Ask about your meetings, notes, tasks…", text: $controller.question)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { controller.ask() }
                if controller.phase == .searching || controller.phase == .answering {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            Divider()
            content
            Divider()
            HStack {
                Text("Searches on this Mac; only the best matches go to \(Prefs.analysisProvider.shortName).")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                KeyHint("↩", "Ask")
                KeyHint("esc", "Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(VisualEffectBackground(material: .hudWindow))
        .tint(DS.accent)
        .onAppear {
            fieldFocused = true
            keyMonitor.install(window: { WindowManager.shared.askMacPanel }, handler: handle)
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.phase == .idle {
            VStack(alignment: .leading, spacing: 4) {
                Text("Try asking").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
                ForEach(examples, id: \.self) { example in
                    Button {
                        controller.question = example
                        controller.ask()
                    } label: {
                        Label(example, systemImage: "text.bubble").frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                }
            }
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(controller.askedQuestion).font(.headline)
                    if case .failed(let message) = controller.phase {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if controller.answer.isEmpty && controller.phase == .answering {
                        TypingIndicator()
                    } else {
                        Text(LocalizedStringKey(controller.answer)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !controller.sources.isEmpty { sourceList }
                }
                .padding(14)
            }
        }
    }

    private var sourceList: some View {
        let cited = controller.citedNumbers
        return VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(controller.sources.enumerated()), id: \.element.id) { index, source in
                let isCited = cited.contains(index + 1)
                if isCited || controller.phase != .done || cited.isEmpty {
                    Button { controller.open(source) } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.caption.monospacedDigit().weight(.bold))
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(isCited ? DS.accent.opacity(0.25) : DS.subtleFill))
                            Image(systemName: source.systemImage).foregroundStyle(DS.accent).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.title).lineLimit(1)
                                Text("\(source.label) · \(source.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                }
            }
        }
    }

    private func handle(_ event: PanelKey.Event) -> Bool {
        switch event.key {
        case .escape:
            if controller.phase == .idle {
                WindowManager.shared.hideAskMac()
            } else {
                controller.reset()
                fieldFocused = true
            }
        case .commandDigit(let number):
            guard controller.sources.indices.contains(number - 1) else { return false }
            controller.open(controller.sources[number - 1])
        default:
            return false
        }
        return true
    }
}
