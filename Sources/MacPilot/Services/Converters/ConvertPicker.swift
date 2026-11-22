import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ConversionTool {
    /// Whether this tool can take `url` as input (by its file extension's type).
    func accepts(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return inputTypes.contains { type.conforms(to: $0) }
    }

    /// Tools that fit every selected file. Merge needs at least two PDFs; Markdown files get the Markdown export
    /// (not the generic plain-text document tools).
    static func matching(_ urls: [URL]) -> [ConversionTool] {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return [] }
        let markdown = Set(["md", "markdown"])
        let allMarkdown = files.allSatisfy { markdown.contains($0.pathExtension.lowercased()) }
        return allCases.filter { tool in
            guard files.allSatisfy(tool.accepts) else { return false }
            switch tool {
            case .mergePDF: return files.count >= 2
            case .markdownExport: return allMarkdown
            case .wordToPDF, .documentConvert: return !allMarkdown
            default: return true
            }
        }
    }
}

/// The small "Convert with MacPilot" window, opened from Finder's Services menu or the notch shelf.
@MainActor
final class ConvertPicker: NSObject, NSWindowDelegate {
    static let shared = ConvertPicker()
    private var panel: NSPanel?

    func show(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        panel?.close()
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 480),
                            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Convert with MacPilot"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ConvertPickerView(files: files) { [weak panel] in panel?.close() })
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

/// Receives Finder's Services menu item (declared as NSServices in Info.plist).
@MainActor
final class FinderServiceProvider: NSObject {
    static let shared = FinderServiceProvider()

    /// Selector name matches NSMessage "convertWithMacPilot" in Info.plist.
    @objc func convertWithMacPilot(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error?.pointee = "No files were selected." as NSString
            return
        }
        ConvertPicker.shared.show(urls)
    }

    /// File URLs from a service pasteboard (modern file URLs, or the legacy filenames list).
    nonisolated static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        return (pasteboard.propertyList(forType: legacy) as? [String] ?? []).map { URL(fileURLWithPath: $0) }
    }
}

struct ConvertPickerView: View {
    let files: [URL]
    var close: () -> Void

    @State private var tool: ConversionTool?
    @State private var options = ConversionOptions()
    @State private var isRunning = false
    @State private var progress: Double = 0
    @State private var results: [ConversionResult] = []
    @State private var error: String?

    private var tools: [ConversionTool] { ConversionTool.matching(files) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            fileSummary
            if tools.isEmpty {
                EmptyStateView(systemImage: "questionmark.folder", title: "Nothing to convert",
                               message: "File Tools work with PDFs, Word and text documents, Markdown, images and videos.", compact: true)
            } else if let tool {
                selected(tool)
            } else {
                Text("Choose a conversion").font(.headline)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(tools) { item in
                            Button { pick(item) } label: { row(item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .padding(.top, DS.Space.s)
        .frame(width: 440, height: 480, alignment: .topLeading)
        .onAppear { if tools.count == 1 { pick(tools[0]) } }
    }

    private var fileSummary: some View {
        HStack(spacing: DS.Space.xs) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: files[0].path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(files.count == 1 ? ConversionNaming.sizeString(files[0]) : files.map(\.lastPathComponent).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func row(_ item: ConversionTool) -> some View {
        HStack(spacing: DS.Space.s) {
            IconTile(systemImage: item.systemImage, color: item.tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).foregroundStyle(.primary)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, DS.Space.xs)
        .contentShape(Rectangle())
        .hoverHighlight()
    }

    @ViewBuilder
    private func selected(_ item: ConversionTool) -> some View {
        HStack {
            if tools.count > 1 {
                Button { tool = nil; results = []; error = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(isRunning)
                    .accessibilityLabel("Back to conversions")
            }
            IconTile(systemImage: item.systemImage, color: item.tint, size: 22)
            Text(item.title).font(.headline)
        }
        ConversionOptionFields(tool: item, options: $options)
        if isRunning {
            ProgressView(value: progress)
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Saved next to the original\(files.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.subheadline.weight(.semibold))
                ForEach(results.prefix(6)) { result in
                    HStack {
                        Text(result.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(result.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Button("Open") { NSWorkspace.shared.open(result.url) }.buttonStyle(.borderless).font(.caption)
                    }
                }
                if results.count > 6 { Text("+\(results.count - 6) more").font(.caption).foregroundStyle(.secondary) }
            }
        }
        HStack {
            if !results.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(results.map(\.url)) }
            }
            Spacer()
            Button(results.isEmpty ? "Cancel" : "Done", action: close)
                .keyboardShortcut(.cancelAction)
            if results.isEmpty {
                Button(isRunning ? "Converting…" : "Convert") { run(item) }
                    .buttonStyle(.borderedProminent)
                    .tint(item.tint)
                    .disabled(isRunning || (item == .protectPDF && options.password.count < 4))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func pick(_ item: ConversionTool) {
        tool = item
        results = []
        error = nil
        options = ConversionOptions()
        if item == .markdownExport { options.documentFormat = .docx }
        if item == .documentConvert, let ext = files.first?.pathExtension.lowercased() {
            options.documentFormat = ext == "docx" ? .pdf : .docx
        }
    }

    private func run(_ item: ConversionTool) {
        isRunning = true
        error = nil
        progress = 0
        let inputs = files
        let options = options
        Task {
            do {
                results = try await FileConverter.run(item, inputs: inputs, options: options) { progress = $0 }
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
        }
    }
}
