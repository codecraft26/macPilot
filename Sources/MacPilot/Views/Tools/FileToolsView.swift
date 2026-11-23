import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File Tools: a grid of converters; each opens a drop-zone workspace with options and results.
struct FileToolsView: View {
    @Environment(AppState.self) private var appState
    @State private var search = ""
    @State private var selected: ConversionTool?
    @State private var editingPages = false

    private var visibleTools: [ConversionTool] {
        ConversionTool.allCases.filter { search.isEmpty || "\($0.title) \($0.subtitle)".localizedCaseInsensitiveContains(search) }
    }

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: DS.Space.m)]

    var body: some View {
        Group {
            if editingPages {
                PDFPageEditorView { editingPages = false }
            } else if let tool = selected {
                ToolWorkspace(tool: tool) { selected = nil }
                    .id(tool)
            } else {
                grid
            }
        }
        .navigationTitle("File Tools")
        .onAppear(perform: takePending)
        .onChange(of: appState.pendingAction) { _, _ in takePending() }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("File Tools").font(.largeTitle.weight(.bold))
                        Text("Convert, combine and compress files. Everything runs on this Mac — nothing is uploaded.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("Search tools", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                if search.isEmpty || "edit pdf pages rotate reorder delete page numbers watermark".contains(search.lowercased()) {
                    pageEditorBanner
                }
                ForEach(ConversionTool.Category.allCases, id: \.self) { category in
                    let tools = visibleTools.filter { $0.category == category }
                    if !tools.isEmpty {
                        Text(category.rawValue).font(.title3.weight(.semibold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                            ForEach(tools) { tool in
                                ToolCard(tool: tool) { selected = tool }
                            }
                        }
                    }
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var pageEditorBanner: some View {
        Button { editingPages = true } label: {
            HStack(spacing: DS.Space.m) {
                IconTile(systemImage: "doc.on.doc", color: .red, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit PDF pages").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text("See every page: rotate, drag to reorder, delete, extract, add page numbers or a watermark.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill").font(.title2).foregroundStyle(.red)
            }
            .padding(DS.Space.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .fill(LinearGradient(colors: [Color.red.opacity(0.12), Color.orange.opacity(0.06)], startPoint: .leading, endPoint: .trailing)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).strokeBorder(Color.red.opacity(0.25)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func takePending() {
        guard case .openTool(let raw)? = appState.pendingAction else { return }
        appState.pendingAction = nil
        if raw == "pageEditor" {
            selected = nil
            editingPages = true
        } else {
            editingPages = false
            selected = ConversionTool(rawValue: raw)
        }
    }
}

extension ConversionTool {
    var tint: Color {
        switch category {
        case .pdf: return .red
        case .documents: return .blue
        case .images: return .orange
        case .media: return .purple
        }
    }
}

private struct ToolCard: View {
    let tool: ConversionTool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                IconTile(systemImage: tool.systemImage, color: tool.tint, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title).font(.headline).foregroundStyle(.primary)
                    Text(tool.subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .padding(DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).fill(DS.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(hovering ? tool.tint.opacity(0.6) : DS.hairline, lineWidth: hovering ? 1.5 : 1))
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Workspace

private struct ToolWorkspace: View {
    let tool: ConversionTool
    var onBack: () -> Void

    @State private var files: [URL] = []
    @State private var options = ConversionOptions()
    @State private var results: [ConversionResult] = []
    @State private var error: String?
    @State private var progress: Double = 0
    @State private var isRunning = false
    @State private var isTargeted = false
    @State private var showingImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Button(action: onBack) { Label("All tools", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                IconTile(systemImage: tool.systemImage, color: tool.tint, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.title).font(.title2.weight(.bold))
                    Text(tool.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    dropZone
                    if !files.isEmpty { fileList }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    optionsCard
                    convertButton
                    if isRunning { ProgressView(value: progress).progressViewStyle(.linear) }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                    if !results.isEmpty { resultsCard }
                }
                .frame(width: 330)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.l)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: tool.inputTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "arrow.down.doc").font(.system(size: 34, weight: .light)).foregroundStyle(isTargeted ? tool.tint : .secondary)
            Text(isTargeted ? "Drop to add" : "Drop files here").font(.headline)
            Text(tool.combinesInputs ? "Add files in the order you want them combined." : "You can add several files at once.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Choose files…") { showingImporter = true }
        }
        .frame(maxWidth: .infinity, minHeight: files.isEmpty ? 220 : 140)
        .background(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
            .fill(isTargeted ? tool.tint.opacity(0.08) : DS.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
            .strokeBorder(isTargeted ? tool.tint : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            }
            return true
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(files.count) file\(files.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                Button("Clear") { files = []; results = []; error = nil }.buttonStyle(.borderless)
            }
            ForEach(Array(files.enumerated()), id: \.element) { index, url in
                HStack(spacing: DS.Space.xs) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ConversionNaming.sizeString(url)).font(.caption).foregroundStyle(.secondary)
                    if tool.combinesInputs {
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Move up")
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(index == files.count - 1).accessibilityLabel("Move down")
                    }
                    Button { files.remove(at: index) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(url.lastPathComponent)")
                }
                .padding(.vertical, 3)
                .padding(.horizontal, DS.Space.xs)
                .hoverHighlight()
            }
        }
        .card(padding: DS.Space.s)
    }

    @ViewBuilder
    private var optionsCard: some View {
        if ConversionOptionFields.hasFields(tool) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Options").font(.headline)
                ConversionOptionFields(tool: tool, options: $options)
            }
            .card(padding: DS.Space.s)
        }
    }

    private var convertButton: some View {
        Button(action: run) {
            HStack {
                if isRunning { ProgressView().controlSize(.small) }
                Text(isRunning ? "Converting…" : buttonTitle).frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(tool.tint)
        .controlSize(.large)
        .disabled(files.isEmpty || isRunning)
        .keyboardShortcut(.defaultAction)
    }

    private var buttonTitle: String {
        switch tool {
        case .mergePDF: return "Merge \(files.count) PDFs"
        case .imagesToPDF: return "Make PDF"
        case .splitPDF: return "Split"
        case .compressPDF: return "Compress"
        case .protectPDF: return "Protect"
        case .ocrToText: return "Extract text"
        default: return files.count > 1 ? "Convert \(files.count) files" : "Convert"
        }
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(results.map(\.url)) }
                    .buttonStyle(.borderless)
            }
            ForEach(results.prefix(12)) { result in
                HStack(spacing: DS.Space.xs) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(result.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(result.note).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(result.url) }.buttonStyle(.borderless).font(.caption)
                }
            }
            if results.count > 12 { Text("+\(results.count - 12) more").font(.caption).foregroundStyle(.secondary) }
        }
        .card(padding: DS.Space.s)
    }

    // MARK: Actions

    private func add(_ urls: [URL]) {
        let accepted = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return tool.inputTypes.contains { type.conforms(to: $0) }
        }
        let rejected = urls.count - accepted.count
        files += accepted.filter { !files.contains($0) }
        results = []
        error = rejected > 0 ? "\(rejected) file\(rejected == 1 ? " isn't" : "s aren't") supported by \(tool.title)." : nil
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    private func run() {
        isRunning = true
        error = nil
        results = []
        progress = 0
        let inputs = files
        let options = options
        Task {
            do {
                results = try await FileConverter.run(tool, inputs: inputs, options: options) { value in progress = value }
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
        }
    }
}

/// Options for a conversion (format, quality, pages, password…), shared by File Tools and the Convert picker.
struct ConversionOptionFields: View {
    let tool: ConversionTool
    @Binding var options: ConversionOptions

    static func hasFields(_ tool: ConversionTool) -> Bool {
        switch tool {
        case .convertImages, .resizeImages, .pdfToImages, .splitPDF, .protectPDF, .documentConvert, .markdownExport, .videoToMP4: return true
        default: return false
        }
    }

    var body: some View {
        if let fields { fields }
    }

    private var fields: AnyView? {
        switch tool {
        case .convertImages, .resizeImages, .pdfToImages:
            return AnyView(VStack(alignment: .leading, spacing: DS.Space.s) {
                Picker("Format", selection: $options.imageFormat) {
                    ForEach(tool == .pdfToImages ? [.png, .jpeg] : ConversionOptions.ImageFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                if options.imageFormat == .jpeg || options.imageFormat == .heic {
                    HStack {
                        Text("Quality")
                        Slider(value: $options.quality, in: 0.4...1)
                        Text("\(Int(options.quality * 100))%").monospacedDigit().frame(width: 40)
                    }
                }
                if tool == .resizeImages {
                    Picker("Fit within", selection: $options.maxPixels) {
                        ForEach([640, 1024, 1280, 1920, 2560, 3840], id: \.self) { Text("\($0) px").tag($0) }
                    }
                }
            })
        case .splitPDF:
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                TextField("Pages, e.g. 1-3, 5, 8-", text: $options.pageRanges).textFieldStyle(.roundedBorder)
                Text("Leave empty to save every page as its own PDF.").font(.caption).foregroundStyle(.secondary)
            })
        case .protectPDF:
            return AnyView(SecureField("Password (at least 4 characters)", text: $options.password).textFieldStyle(.roundedBorder))
        case .documentConvert:
            return AnyView(Picker("Convert to", selection: $options.documentFormat) {
                ForEach(ConversionOptions.DocumentFormat.allCases) { Text($0.rawValue).tag($0) }
            })
        case .markdownExport:
            return AnyView(Picker("Convert to", selection: $options.documentFormat) {
                Text("Word (.docx)").tag(ConversionOptions.DocumentFormat.docx)
                Text("PDF").tag(ConversionOptions.DocumentFormat.pdf)
            })
        case .videoToMP4:
            return AnyView(Picker("Size", selection: $options.videoQuality) {
                ForEach(ConversionOptions.VideoQuality.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented))
        default:
            return nil
        }
    }
}
