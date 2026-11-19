import AppKit
import SwiftData
import SwiftUI

/// The ⌥C clipboard history panel: search, keyboard navigation, preview, paste into the previous app.
struct ClipboardPanelView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]
    @State private var query = ""
    @State private var filter: ClipFilter = .all
    @State private var selectedID: UUID?
    @State private var keyMonitor = PanelKeyMonitor()
    @State private var status: String?
    @State private var showAccessibilityHelp = false
    @FocusState private var searchFocused: Bool
    private let monitor = ClipboardMonitor.shared

    /// Pinned first, then by recency, filtered and fuzzy-ranked.
    private var visible: [ClipboardItem] { rank(items) }

    /// The key handler is created once, so it reads live data instead of this view's captured @Query.
    private var liveVisible: [ClipboardItem] {
        let all = (try? Persistence.container.mainContext.fetch(
            FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        return rank(all)
    }

    private func rank(_ items: [ClipboardItem]) -> [ClipboardItem] {
        let filtered = items.filter(filter.matches)
        let ordered = filtered.filter(\.isPinned) + filtered.filter { !$0.isPinned }
        return FuzzyMatcher.rank(ordered, query: query) { item in
            "\(item.title) \(item.text.prefix(2000)) \(item.sourceAppName) \(item.folder)"
        }
    }

    private var selected: ClipboardItem? {
        let list = visible
        return list.first { $0.uid == selectedID } ?? list.first
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 320)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(VisualEffectBackground(material: .hudWindow))
        .tint(DS.accent)
        .onAppear {
            searchFocused = true
            keyMonitor.install(window: { WindowManager.shared.clipboardPanel }, handler: handle)
        }
        .onChange(of: appState.panelSession) { _, _ in reset() }
        .onChange(of: query) { _, _ in selectedID = visible.first?.uid }
        .onChange(of: filter) { _, _ in selectedID = visible.first?.uid }
    }

    // MARK: Pieces

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            TextField("Search clipboard history…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
            Picker("Filter", selection: $filter) {
                ForEach(ClipFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .help("Tab cycles filters")
        }
        .padding(12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedID) {
                let rows = visible
                if rows.isEmpty {
                    Text(items.isEmpty ? (monitor.isPaused ? "Clipboard capture is paused." : "Copy something and it shows up here.") : "No matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(rows.prefix(300).enumerated()), id: \.element.uid) { index, item in
                    ClipRow(item: item, shortcut: index < 9 ? index + 1 : nil)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                .fill(item.uid == (selectedID ?? rows.first?.uid) ? DS.accent.opacity(0.22) : Color.clear)
                                .padding(.horizontal, 6)
                        )
                        .tag(item.uid)
                        .id(item.uid)
                        .onTapGesture(count: 2) { paste(item, plain: false) }
                        .onTapGesture { selectedID = item.uid }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let item = selected {
            VStack(alignment: .leading, spacing: 10) {
                ClipPreview(item: item)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    detail("Type", item.kind.label + (item.looksLikeCode ? " · code" : ""))
                    if !item.sourceAppName.isEmpty { detail("From", item.sourceAppName) }
                    detail("Copied", item.createdAt.formatted(.relative(presentation: .named)))
                    if item.kind != .image { detail("Characters", "\(item.text.count)") }
                    if item.useCount > 0 { detail("Pasted", "\(item.useCount)×") }
                    if !item.folder.isEmpty { detail("Folder", item.folder) }
                }
                .font(.caption)
            }
            .padding(14)
        } else {
            Text("Nothing selected").foregroundStyle(.secondary)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).lineLimit(1)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let status {
                Text(status).font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else if !PasteService.isTrusted {
                Button("Allow pasting into apps…") { showAccessibilityHelp = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer()
            KeyHint("↩", "Paste")
            KeyHint("⇧↩", "Plain")
            KeyHint("⌘↩", "Copy")
            KeyHint("⌘P", "Pin")
            KeyHint("⌘F", "Favorite")
            KeyHint("⌘⌫", "Delete")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .popover(isPresented: $showAccessibilityHelp) { AccessibilityExplainer() }
    }

    // MARK: Keyboard

    private func handle(_ event: PanelKey.Event) -> Bool {
        let list = liveVisible
        let index = list.firstIndex { $0.uid == selectedID } ?? 0
        let current = list.indices.contains(index) ? list[index] : nil
        switch event.key {
        case .down:
            if !list.isEmpty { selectedID = list[min(index + 1, list.count - 1)].uid }
        case .up:
            if !list.isEmpty { selectedID = list[max(index - 1, 0)].uid }
        case .enter:
            guard let item = current else { return true }
            if event.command { copy(item) } else { paste(item, plain: event.shift) }
        case .tab:
            let all = ClipFilter.allCases
            let current = all.firstIndex(of: filter) ?? 0
            filter = all[(current + (event.shift ? all.count - 1 : 1)) % all.count]
        case .escape:
            WindowManager.shared.hidePanels()
        case .commandDelete:
            if let item = current {
                let next = list.indices.contains(index + 1) ? list[index + 1].uid : (index > 0 ? list[index - 1].uid : nil)
                monitor.delete(item)
                selectedID = next
            }
        case .commandDigit(let number):
            if list.indices.contains(number - 1) { paste(list[number - 1], plain: event.shift) }
        case .command(let character):
            guard let item = current else { return false }
            switch character {
            case "p": item.isPinned.toggle()
            case "f": item.isFavorite.toggle()
            default: return false
            }
            try? Persistence.container.mainContext.save()
        }
        return true
    }

    // MARK: Actions

    private func reset() {
        query = ""
        filter = .all
        status = nil
        selectedID = liveVisible.first?.uid
        searchFocused = true
    }

    private func paste(_ item: ClipboardItem, plain: Bool) {
        let target = WindowManager.shared.previousApp
        WindowManager.shared.hidePanels()
        if !PasteService.paste(item, into: target, plainText: plain) {
            // Copied only: no Accessibility permission yet.
            if !UserDefaults.standard.bool(forKey: "clipboard.accessibilityExplained") {
                UserDefaults.standard.set(true, forKey: "clipboard.accessibilityExplained")
                PasteService.requestTrust()
            }
            target?.activate()
        }
    }

    private func copy(_ item: ClipboardItem) {
        PasteService.write(item)
        WindowManager.shared.hidePanels()
        WindowManager.shared.previousApp?.activate()
    }
}

struct ClipRow: View {
    let item: ClipboardItem
    var shortcut: Int?

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? " " : item.title)
                    .lineLimit(1)
                    .font(item.looksLikeCode ? .callout.monospaced() : .callout)
                HStack(spacing: 4) {
                    if item.isPinned { Image(systemName: "pin.fill") }
                    if item.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if !item.sourceAppName.isEmpty { Text(item.sourceAppName) }
                    Text(item.createdAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let shortcut {
                Text("⌘\(shortcut)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .color:
            RoundedRectangle(cornerRadius: 4)
                .fill(RGBColor(hex: item.text)?.color ?? .gray)
                .frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        case .image:
            if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
            }
        default:
            IconTile(systemImage: item.looksLikeCode ? "chevron.left.forwardslash.chevron.right" : item.kind.systemImage,
                     color: item.looksLikeCode ? .gray : (item.kind == .link ? .blue : (item.kind == .file ? .orange : AppSection.clipboard.tint)),
                     size: 20)
        }
    }
}

/// Large preview of a clip: text/code, image, color swatch, link or files.
struct ClipPreview: View {
    let item: ClipboardItem

    var body: some View {
        switch item.kind {
        case .image:
            if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Image file is missing.").foregroundStyle(.secondary)
            }
        case .color:
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(RGBColor(hex: item.text)?.color ?? .gray)
                    .frame(height: 120)
                Text(item.text).font(.title2.monospaced()).textSelection(.enabled)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                Label("Link", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                Text(item.text).textSelection(.enabled)
                if let url = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Button("Open in browser") { NSWorkspace.shared.open(url) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.text.split(separator: "\n").map(String.init), id: \.self) { path in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                            Text(path).font(.caption).lineLimit(2).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text, .richText:
            ScrollView {
                Text(String(item.text.prefix(20_000)))
                    .font(item.looksLikeCode ? .callout.monospaced() : .callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct AccessibilityExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste straight into apps").font(.headline)
            Text("To paste with Return, macOS needs to let MacPilot send ⌘V. Turn MacPilot on in System Settings → Privacy & Security → Accessibility. Until then, Return copies the item and you press ⌘V yourself.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Accessibility Settings") {
                    PasteService.requestTrust()
                    PasteService.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
