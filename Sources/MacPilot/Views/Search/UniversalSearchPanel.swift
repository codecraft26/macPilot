import AppKit
import SwiftUI

/// The universal search window (⌥F by default; ⌥K "?" or "/" also opens it).
@MainActor
final class UniversalSearchPanel {
    static let shared = UniversalSearchPanel()
    private var panel: FloatingPanel?
    let model = SearchPanelModel()

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    func show(query: String? = nil) {
        WindowManager.shared.hidePanels()
        UniversalSearch.shared.useDefaultProviders()
        if let query { model.text = query; model.run() }
        if panel == nil {
            panel = FloatingPanel(rootView: UniversalSearchView(model: model), size: NSSize(width: 760, height: 520))
        }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 80))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
    }

    func hide() { panel?.orderOut(nil) }
}

@Observable
@MainActor
final class SearchPanelModel {
    var text = ""
    var selection: String?
    var askMode = false
    var answer = ""
    var answering = false
    var focusToken = 0
    let search = UniversalSearch.shared
    var router = SearchActionRouter()

    func run() {
        answer = ""
        search.search(text)
        selection = nil
    }

    var flat: [UniversalResult] { search.grouped.flatMap(\.1) }

    var selected: UniversalResult? {
        flat.first { $0.id == selection } ?? flat.first
    }

    func move(_ delta: Int) {
        let list = flat
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selected?.id } ?? 0
        selection = list[max(0, min(list.count - 1, index + delta))].id
    }

    func perform(_ action: SearchAction, on result: UniversalResult) {
        router.perform(action, on: result)
        if [.open, .reveal, .replyDraft, .jumpToTimestamp, .askAI].contains(action) { UniversalSearchPanel.shared.hide() }
    }

    func toggleAsk() {
        askMode.toggle()
        guard askMode, !text.isEmpty else { return }
        answering = true
        answer = ""
        let question = SearchQuery.parse(text).text
        Task {
            await search.finish()
            answer = await search.answer(question.isEmpty ? text : question)
            answering = false
        }
    }
}

struct UniversalSearchView: View {
    @Bindable var model: SearchPanelModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: model.askMode ? "sparkles" : "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes, meetings, mail, files… (in:mail from:sam after:7d · Tab to ask)", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if let result = model.selected { model.perform(.open, on: result) } }
                    .onChange(of: model.text) { _, _ in model.askMode = false; model.run() }
                if !model.search.pending.isEmpty { ProgressView().controlSize(.small) }
            }
            .padding(DS.Space.m)
            Divider()
            if model.askMode { askView } else { resultsView }
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
        .onKeyPress(.tab) { model.toggleAsk(); return .handled }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { UniversalSearchPanel.shared.hide(); return .handled }
        .onChange(of: model.focusToken) { _, _ in focused = true }
        .onAppear { focused = true }
    }

    private var resultsView: some View {
        HStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.search.grouped, id: \.0) { source, results in
                    Section(source.label) {
                        ForEach(results.prefix(8)) { result in
                            row(result).tag(result.id)
                                .onTapGesture(count: 2) { model.perform(.open, on: result) }
                                .contextMenu {
                                    ForEach(SearchActionRouter.actions(for: result)) { action in
                                        Button { model.perform(action, on: result) } label: { Label(action.label, systemImage: action.systemImage) }
                                    }
                                }
                        }
                    }
                }
                if model.search.results.isEmpty && !model.text.isEmpty && model.search.pending.isEmpty {
                    Text("No results.").foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            if let result = model.selected { detail(result).frame(width: 260) }
        }
    }

    private func row(_ result: UniversalResult) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: result.source.systemImage).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).lineLimit(1)
                Text([result.subtitle, result.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func detail(_ result: UniversalResult) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label(result.source.label, systemImage: result.source.systemImage).font(.caption).foregroundStyle(.secondary)
            Text(result.title).font(.headline).lineLimit(3)
            if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
            ScrollView { Text(result.snippet).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(SearchActionRouter.actions(for: result)) { action in
                Button { model.perform(action, on: result) } label: { Label(action.label, systemImage: action.systemImage).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(DS.Space.s)
    }

    private var askView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if model.answering { ProgressView("Reading the top results…") }
                Text(LocalizedStringKey(model.answer)).textSelection(.enabled)
                if !model.answer.isEmpty {
                    Divider()
                    ForEach(Array(model.search.results.prefix(8).enumerated()), id: \.element.id) { index, result in
                        Button { model.perform(.open, on: result) } label: {
                            Text("[\(index + 1)] \(result.source.label) · \(result.title)").font(.caption)
                        }.buttonStyle(.link)
                    }
                }
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.askMode ? "Answer from your top results (local-only mode uses Ollama). Tab: back to results"
                               : "↩ open · ↑↓ select · Tab ask · right-click for actions")
            Spacer()
            if !model.search.timedOut.isEmpty {
                Text("Slow: \(model.search.timedOut.map(\.label).sorted().joined(separator: ", "))").foregroundStyle(.orange)
            }
            Text("Only Gmail and Ask leave this Mac").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 6)
    }
}
