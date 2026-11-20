import SwiftUI

/// The ⌥⇧E panel: pick an AI action for the selected text, then replace it or copy the result.
struct TextActionsView: View {
    @Environment(AppState.self) private var appState
    @State private var keyMonitor = PanelKeyMonitor()
    @FocusState private var customFocused: Bool
    private let controller = TextActionsController.shared

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if controller.phase == .idle {
                actionList
            } else {
                resultView
            }
            Divider()
            footer
        }
        .background(VisualEffectBackground(material: .hudWindow))
        .tint(DS.accent)
        .onAppear { keyMonitor.install(window: { WindowManager.shared.textActionsPanel }, handler: handle) }
    }

    private var header: some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconTile(systemImage: "wand.and.stars", color: DS.accent, size: 22)
                Text(controller.targetApp?.localizedName.map { "Selected in \($0)" } ?? "Text").font(.headline)
                Spacer()
                Text("\(controller.selection.count) characters").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Select text in any app first, or paste it here", text: $controller.selection, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .font(.callout)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
        .padding(12)
    }

    private var actionList: some View {
        @Bindable var controller = controller
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(TextAction.allCases.enumerated()), id: \.element) { index, action in
                    Button { controller.run(action) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: action.systemImage).frame(width: 20).foregroundStyle(DS.accent)
                            Text(action.title)
                            Spacer()
                            if index < 9 { Text("⌘\(index + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary) }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                }
                if !SnippetLibrary.shared.aiCommands.isEmpty {
                    Text("Your commands").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 6)
                    ForEach(SnippetLibrary.shared.aiCommands) { command in
                        Button { controller.run(command) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles").frame(width: 20).foregroundStyle(DS.violet)
                                Text(command.name)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "text.cursor").frame(width: 20).foregroundStyle(DS.accent)
                    TextField("Or tell it what to do… (Return)", text: $controller.customInstruction)
                        .textFieldStyle(.roundedBorder)
                        .focused($customFocused)
                        .onSubmit { controller.runCustom() }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
            .padding(8)
        }
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(controller.lastAction?.title ?? controller.commandName ?? "Custom").font(.headline)
                if controller.phase == .running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Back") { controller.reset() }.buttonStyle(.borderless)
            }
            if case .failed(let message) = controller.phase {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            ScrollView {
                Text(controller.result.isEmpty && controller.phase == .running ? "…" : controller.result)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !PasteService.isTrusted {
                Text("Allow Accessibility to read and replace selections").font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            if controller.phase == .done {
                Button("Try again") { controller.retry() }
                Button("Copy") { controller.copyResult() }
                if controller.canReplace {
                    Button("Replace selection") { controller.replace() }.buttonStyle(.borderedProminent)
                }
            } else {
                KeyHint("⌘1–9", "Action")
                KeyHint("esc", "Close")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func handle(_ event: PanelKey.Event) -> Bool {
        switch event.key {
        case .escape:
            WindowManager.shared.hideTextActions()
        case .commandDigit(let number):
            let actions = TextAction.allCases
            guard actions.indices.contains(number - 1), controller.phase == .idle else { return false }
            controller.run(actions[number - 1])
        case .enter where controller.phase == .done && !customFocused:
            if event.command { controller.copyResult() } else if controller.canReplace { controller.replace() } else { controller.copyResult() }
        default:
            return false
        }
        return true
    }
}
