import AppKit
import CryptoKit
import Foundation
import SwiftData

enum ClipKind: String, Codable, CaseIterable {
    case text, richText, link, file, color, image

    var label: String {
        switch self {
        case .text: return "Text"
        case .richText: return "Rich text"
        case .link: return "Link"
        case .file: return "File"
        case .color: return "Color"
        case .image: return "Image"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .link: return "link"
        case .file: return "doc"
        case .color: return "paintpalette"
        case .image: return "photo"
        }
    }
}

/// Filters offered in the clipboard panel (Tab cycles) and manager.
enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All", text = "Text", links = "Links", images = "Images", code = "Code", files = "Files", favorites = "Favorites", pinned = "Pinned"
    var id: String { rawValue }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return item.kind == .text || item.kind == .richText
        case .links: return item.kind == .link
        case .images: return item.kind == .image
        case .code: return item.looksLikeCode
        case .files: return item.kind == .file
        case .favorites: return item.isFavorite
        case .pinned: return item.isPinned
        }
    }
}

@Model
final class ClipboardItem {
    var uid: UUID = UUID()
    var kindRaw: String = ClipKind.text.rawValue
    /// Plain text, URL, file paths (one per line) or "#RRGGBB" for colors. Empty for images.
    var text: String = ""
    var rtfData: Data?
    var imageFileName: String?
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var sourceAppName: String = ""
    var sourceBundleID: String = ""
    var createdAt: Date = Date()
    var lastUsedAt: Date = Date()
    var isFavorite: Bool = false
    var isPinned: Bool = false
    var folder: String = ""
    var useCount: Int = 0
    var contentHash: String = ""

    init(kind: ClipKind, text: String, contentHash: String) {
        self.kindRaw = kind.rawValue
        self.text = text
        self.contentHash = contentHash
    }

    var kind: ClipKind {
        get { ClipKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    var imageURL: URL? { imageFileName.map { ClipboardStorage.directory.appendingPathComponent($0) } }

    /// One-line title for lists.
    var title: String {
        switch kind {
        case .image: return "Image \(imageWidth)×\(imageHeight)"
        case .file:
            let paths = text.split(separator: "\n")
            let first = paths.first.map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? "File"
            return paths.count > 1 ? "\(first) +\(paths.count - 1) more" : first
        default:
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return String(line.trimmingCharacters(in: .whitespaces).prefix(140))
        }
    }

    var looksLikeCode: Bool {
        guard kind == .text || kind == .richText else { return false }
        return CodeDetector.looksLikeCode(text)
    }

    /// Kept forever regardless of retention.
    var isKept: Bool { isPinned || isFavorite }
}

enum ClipboardStorage {
    static var directory: URL {
        let dir = Persistence.storeDirectory.appendingPathComponent("Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func deleteImage(named name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum CodeDetector {
    static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return true }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return true }
        let signals = ["func ", "let ", "const ", "var ", "def ", "class ", "import ", "return ", "=> ", "->", "#include",
                       "public ", "private ", "SELECT ", "</", "();", "){", ") {", "};", "$ ", "git ", "npm ", "fn "]
        let hits = signals.filter { trimmed.contains($0) }.count
        let lines = trimmed.split(whereSeparator: \.isNewline)
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        let symbolRatio = Double(trimmed.filter { "{}[]();=<>".contains($0) }.count) / Double(trimmed.count)
        return hits >= 2 || (hits >= 1 && (indented >= 1 || symbolRatio > 0.04)) || (lines.count > 2 && indented * 2 >= lines.count)
    }
}

/// Which clipboard items have expired. Pinned and favorite items never expire.
enum ClipboardRetention {
    struct Entry {
        var id: UUID
        var date: Date
        var isKept: Bool
    }

    /// `maxAgeDays` 0 = unlimited; `maxItems` 0 = unlimited (kept items do not count toward the cap).
    static func expired(_ entries: [Entry], now: Date, maxAgeDays: Int, maxItems: Int) -> Set<UUID> {
        var result: Set<UUID> = []
        let candidates = entries.filter { !$0.isKept }.sorted { $0.date > $1.date }
        if maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
            for entry in candidates where entry.date < cutoff { result.insert(entry.id) }
        }
        if maxItems > 0 && candidates.count > maxItems {
            for entry in candidates[maxItems...] { result.insert(entry.id) }
        }
        return result
    }
}
