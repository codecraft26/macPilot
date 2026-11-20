import AppKit
import Foundation
import Observation
import PDFKit
import UniformTypeIdentifiers

/// Files parked on the notch: drop them on it, drag them out to any app later, AirDrop them or ask AI about them.
/// Only references are kept (the files stay where they are); missing files drop off automatically.
@Observable
@MainActor
final class NotchShelf {
    static let shared = NotchShelf()

    private(set) var items: [URL] = []
    /// True while a file drag is near the notch, so it opens as a drop zone.
    var isDropTargeted = false
    private let key = "notch.shelf"
    static let limit = 12

    private init() {
        items = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        var updated = items
        for url in urls where url.isFileURL && !updated.contains(url) {
            updated.append(url)
        }
        items = Array(updated.suffix(Self.limit))
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// Drops files that were moved or deleted since they were parked.
    func prune() {
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing != items { items = existing; save() }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }

    #if DEBUG
    func setPreview(_ urls: [URL]) { items = urls }
    #endif

    // MARK: Actions

    func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        service.perform(withItems: urls)
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Reads what it can from the files (text, PDF text, OCR for images) and asks the quick assistant about them.
    func askAI(_ urls: [URL]) {
        Task {
            var parts: [String] = []
            for url in urls.prefix(5) {
                let text = await Self.readableText(url)
                parts.append("File: \(url.lastPathComponent)\n" + (text.isEmpty ? "(no readable text)" : String(text.prefix(12_000))))
            }
            let prompt = """
            Summarize \(urls.count == 1 ? "this file" : "these files") and point out anything important or that needs action.

            \(parts.joined(separator: "\n\n---\n\n"))
            """
            WindowManager.shared.askQuickAssistant(prompt)
        }
    }

    static func readableText(_ url: URL) async -> String {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true {
            return PDFDocument(url: url)?.string ?? ""
        }
        if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
            return await ScreenCaptureTool.readText(image)
        }
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true || ["md", "json", "csv", "log", "yaml", "yml"].contains(url.pathExtension.lowercased()) {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return attributed.string
        }
        return ""
    }

    /// File URLs currently being dragged anywhere on screen (read from the system drag pasteboard).
    static func draggedFileURLs() -> [URL] {
        let pasteboard = NSPasteboard(name: .drag)
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
