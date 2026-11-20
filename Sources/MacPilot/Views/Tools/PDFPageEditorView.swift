import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Visual page editor: rotate, reorder (drag), delete pages, add page numbers and a watermark.
struct PDFPageEditorView: View {
    var onBack: () -> Void
    /// Opens this PDF right away (used for previews).
    var initialURL: URL?

    @State private var url: URL?
    @State private var document: PDFDocument?
    @State private var pages: [PDFPageItem] = []
    @State private var history: [[PDFPageItem]] = []
    @State private var selection: Set<UUID> = []
    @State private var anchor: UUID?
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var stamp = PDFStamp()
    @State private var showingImporter = false
    @State private var isTargeted = false
    @State private var error: String?
    @State private var savedURL: URL?
    @State private var thumbnailSize: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if document == nil {
                dropZone.padding(DS.Space.l)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    pageGrid.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    sidebar.frame(width: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { load(url) }
        }
        .onDeleteCommand(perform: deleteSelected)
        .onAppear { if let initialURL, document == nil { load(initialURL) } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: DS.Space.s) {
            Button(action: onBack) { Label("All tools", systemImage: "chevron.left") }.buttonStyle(.borderless)
            IconTile(systemImage: "doc.on.doc", color: .red, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Edit PDF pages").font(.headline)
                Text(url.map { "\($0.lastPathComponent) · \(pages.count) page\(pages.count == 1 ? "" : "s")" } ?? "Rotate, reorder, delete, number and watermark")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if document != nil {
                Group {
                    Button { change { PDFPageEditor.rotate($0, ids: targets, clockwise: false) } } label: { Image(systemName: "rotate.left") }
                        .help("Rotate left (selected, or all)")
                    Button { change { PDFPageEditor.rotate($0, ids: targets, clockwise: true) } } label: { Image(systemName: "rotate.right") }
                        .help("Rotate right (selected, or all)")
                    Button { change { PDFPageEditor.shift($0, ids: selection, by: -1) } } label: { Image(systemName: "arrow.left") }
                        .help("Move earlier").disabled(selection.isEmpty)
                    Button { change { PDFPageEditor.shift($0, ids: selection, by: 1) } } label: { Image(systemName: "arrow.right") }
                        .help("Move later").disabled(selection.isEmpty)
                    Button(action: deleteSelected) { Image(systemName: "trash") }
                        .help("Delete selected pages").disabled(selection.isEmpty || selection.count == pages.count)
                    Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                        .help("Undo").disabled(history.isEmpty).keyboardShortcut("z", modifiers: .command)
                }
                .buttonStyle(.bordered)
                Slider(value: $thumbnailSize, in: 100...260).frame(width: 90).help("Thumbnail size")
                Button("Open other…") { showingImporter = true }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }

    private var targets: Set<UUID> { selection.isEmpty ? Set(pages.map(\.id)) : selection }

    // MARK: Pages

    private var pageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize + 20), spacing: DS.Space.m)], spacing: DS.Space.m) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    pageCell(page, index: index)
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity)
        }
        .background(DS.subtleFill)
        .contentShape(Rectangle())
        .onTapGesture { selection = [] }
    }

    private func pageCell(_ page: PDFPageItem, index: Int) -> some View {
        let isSelected = selection.contains(page.id)
        return VStack(spacing: 6) {
            ZStack {
                if let image = thumbnails[page.sourceIndex] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(page.rotation)))
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: thumbnailSize, height: thumbnailSize)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(isSelected ? DS.accent.opacity(0.18) : .clear))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium).strokeBorder(isSelected ? DS.accent : .clear, lineWidth: 2))
            HStack(spacing: 4) {
                Text("\(index + 1)").font(.caption.weight(.semibold).monospacedDigit())
                if page.sourceIndex != index { Text("(was \(page.sourceIndex + 1))").font(.caption2).foregroundStyle(.secondary) }
                if page.rotation != 0 { Image(systemName: "rotate.right").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(page.id) }
        .contextMenu {
            Button("Rotate left") { change { PDFPageEditor.rotate($0, ids: [page.id], clockwise: false) } }
            Button("Rotate right") { change { PDFPageEditor.rotate($0, ids: [page.id], clockwise: true) } }
            Button("Duplicate") { change { list in
                var copy = list
                copy.insert(PDFPageItem(sourceIndex: page.sourceIndex, rotation: page.rotation), at: index + 1)
                return copy
            } }
            Divider()
            Button("Delete", role: .destructive) { change { $0.filter { $0.id != page.id } } }.disabled(pages.count == 1)
        }
        .draggable(page.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            let dragged = ids.compactMap(UUID.init)
            let moving = dragged.count == 1 && selection.contains(dragged[0]) ? pages.map(\.id).filter(selection.contains) : dragged
            change { PDFPageEditor.move($0, ids: moving, before: page.id) }
            return true
        }
    }

    private func select(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor,
                  let from = pages.firstIndex(where: { $0.id == anchor }), let to = pages.firstIndex(where: { $0.id == id }) {
            selection = Set(pages[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Toggle("Page numbers", isOn: $stamp.pageNumbers).font(.headline)
                    if stamp.pageNumbers {
                        Picker("Position", selection: $stamp.numberPosition) {
                            ForEach(PDFStamp.NumberPosition.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Format", selection: $stamp.numberFormat) {
                            Text("1 / 10").tag("{n} / {total}")
                            Text("1").tag("{n}")
                            Text("Page 1").tag("Page {n}")
                            Text("Page 1 of 10").tag("Page {n} of {total}")
                        }
                        Stepper("Start at \(stamp.firstNumber)", value: $stamp.firstNumber, in: 0...9999)
                    }
                }
                .card(padding: DS.Space.s)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Watermark").font(.headline)
                    TextField("e.g. CONFIDENTIAL or DRAFT", text: $stamp.watermark).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Opacity").font(.caption)
                        Slider(value: $stamp.watermarkOpacity, in: 0.05...0.6)
                    }
                    .disabled(stamp.watermark.isEmpty)
                }
                .card(padding: DS.Space.s)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Selection").font(.headline)
                    Text(selection.isEmpty ? "Click a page to select it. ⌘-click or ⇧-click for more. Drag pages to reorder."
                         : "\(selection.count) page\(selection.count == 1 ? "" : "s") selected")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Select all") { selection = Set(pages.map(\.id)) }
                        Button("Odd") { selection = Set(pages.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.id)) }
                        Button("Even") { selection = Set(pages.enumerated().filter { $0.offset % 2 == 1 }.map(\.element.id)) }
                    }
                    .controlSize(.small)
                    Button("Reverse page order") { change { $0.reversed() } }.controlSize(.small)
                    Button("Extract selected to new PDF…") { save(only: selection) }
                        .controlSize(.small).disabled(selection.isEmpty)
                }
                .card(padding: DS.Space.s)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
                if let savedURL {
                    HStack {
                        Label("Saved \(savedURL.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
                        Spacer()
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }.controlSize(.small)
                    }
                    .font(.callout)
                }
                Button { save(only: nil) } label: {
                    Label("Save PDF…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(DS.Space.m)
        }
    }

    // MARK: Empty state

    private var dropZone: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "doc.viewfinder").font(.system(size: 40, weight: .light)).foregroundStyle(isTargeted ? .red : .secondary)
            Text(isTargeted ? "Drop to open" : "Drop a PDF here").font(.headline)
            Text("See every page, then rotate, drag to reorder, delete, add page numbers or a watermark.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Choose PDF…") { showingImporter = true }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).fill(isTargeted ? Color.red.opacity(0.08) : DS.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
            .strokeBorder(isTargeted ? Color.red : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in load(url) }
            }
            return true
        }
    }

    // MARK: Actions

    func load(_ newURL: URL) {
        let access = newURL.startAccessingSecurityScopedResource()
        defer { if access { newURL.stopAccessingSecurityScopedResource() } }
        guard newURL.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: newURL) else {
            error = "Couldn't open \(newURL.lastPathComponent) as a PDF."
            return
        }
        guard !doc.isLocked else {
            error = "\(newURL.lastPathComponent) is password protected. Unlock it in Preview first."
            return
        }
        url = newURL
        document = doc
        pages = (0..<doc.pageCount).map { PDFPageItem(sourceIndex: $0) }
        history = []
        selection = []
        thumbnails = [:]
        error = nil
        savedURL = nil
        renderThumbnails(doc)
    }

    private func renderThumbnails(_ doc: PDFDocument) {
        Task { @MainActor in
            for index in 0..<doc.pageCount {
                guard document === doc, let page = doc.page(at: index) else { return }
                thumbnails[index] = page.thumbnail(of: NSSize(width: 520, height: 520), for: .mediaBox)
                if index % 4 == 3 { await Task.yield() }
            }
        }
    }

    private func change(_ transform: ([PDFPageItem]) -> [PDFPageItem]) {
        let updated = transform(pages)
        guard updated != pages, !updated.isEmpty else { return }
        history.append(pages)
        if history.count > 50 { history.removeFirst() }
        withAnimation(.easeInOut(duration: 0.2)) { pages = updated }
        savedURL = nil
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        withAnimation(.easeInOut(duration: 0.2)) { pages = last }
    }

    private func deleteSelected() {
        guard !selection.isEmpty, selection.count < pages.count else { return }
        change { $0.filter { !selection.contains($0.id) } }
        selection = []
    }

    private func save(only ids: Set<UUID>?) {
        guard let document, let url else { return }
        let chosen = ids.map { set in pages.filter { set.contains($0.id) } } ?? pages
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = ConversionNaming.outputURL(for: url, extension: "pdf", suffix: ids == nil ? " edited" : " pages").lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let output = try PDFPageEditor.build(from: document, pages: chosen, stamp: stamp)
            guard output.write(to: destination) else { throw ConversionError.failed("Couldn't write \(destination.lastPathComponent).") }
            savedURL = destination
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
