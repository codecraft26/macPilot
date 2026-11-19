import SwiftUI

/// The last 50 dictations, with copy and re-insert.
struct DictationHistoryView: View {
    @State private var entries = DictationHistory.entries
    @State private var flash: String?
    private let controller = DictationController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hold \(ShortcutManager.shared.hotKey(for: .dictation)?.displayString ?? "⌥D") anywhere to dictate.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let flash { Text(flash).font(.caption).foregroundStyle(.green) }
                Button("Clear history", role: .destructive) {
                    DictationHistory.clear()
                    entries = []
                }
                .disabled(entries.isEmpty)
            }
            .padding(16)
            if entries.isEmpty {
                EmptyStateView(systemImage: "mic.badge.plus", title: "No dictations yet",
                               message: "Hold ⌥D in any app, speak, and release. The cleaned-up text is typed where your cursor is.")
            } else {
                List(entries) { entry in
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        IconTile(systemImage: entry.mode.systemImage, color: AppSection.voice.tint, size: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text).textSelection(.enabled).lineLimit(4)
                            Text("\(entry.mode.label) · \(entry.app.isEmpty ? "Copied" : entry.app) · \(entry.date.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            PasteService.write(text: entry.text)
                            flash = "Copied."
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy")
                        .accessibilityLabel("Copy dictation")
                        Button {
                            PasteService.paste(text: entry.text, into: WindowManager.shared.previousApp)
                        } label: { Image(systemName: "text.insert") }
                        .buttonStyle(.borderless)
                        .help("Insert into the app you used last")
                        .accessibilityLabel("Insert dictation")
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            DictationHistory.remove(entry.id)
                            entries = DictationHistory.entries
                        }
                    }
                }
            }
        }
        .onChange(of: controller.phase) { _, _ in entries = DictationHistory.entries }
    }
}
