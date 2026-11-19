import AppKit
import ApplicationServices
import Foundation
import Observation
import SwiftData

/// Watches the general pasteboard and saves new items to clipboard history.
@Observable
@MainActor
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    /// Shown in the menu bar and the manager; persisted.
    var isPaused: Bool = UserDefaults.standard.bool(forKey: PrefKey.clipboardPaused) {
        didSet { UserDefaults.standard.set(isPaused, forKey: PrefKey.clipboardPaused) }
    }
    private(set) var lastSkipReason: String?

    private var timer: Timer?
    private var retentionTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ignoredChangeCount: Int?
    private let maxImageBytes = 15 * 1024 * 1024

    private var context: ModelContext { Persistence.container.mainContext }

    private init() {}

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.3 // lets macOS coalesce wake-ups for low idle CPU
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let retention = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }
        retention.tolerance = 300
        RunLoop.main.add(retention, forMode: .common)
        retentionTimer = retention
        applyRetention()
    }

    /// Called right after MacPilot writes to the pasteboard so its own copies are not re-captured.
    func ignoreCurrentChange() {
        ignoredChangeCount = NSPasteboard.general.changeCount
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard count != ignoredChangeCount else { return }
        guard Prefs.clipboardEnabled, !isPaused else { return }
        capture(pasteboard)
    }

    // MARK: Capture

    private func capture(_ pasteboard: NSPasteboard) {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard !types.isEmpty else { return }
        if SensitiveContent.hasSkipMarker(types) {
            lastSkipReason = "Skipped an item marked private by the app that copied it."
            return
        }
        let source = NSWorkspace.shared.frontmostApplication
        let bundleID = source?.bundleIdentifier ?? ""
        if !bundleID.isEmpty && Prefs.clipboardExcludedApps.contains(bundleID) {
            lastSkipReason = "Skipped a copy from \(source?.localizedName ?? bundleID) (excluded app)."
            return
        }

        guard let item = makeItem(from: pasteboard, types: types) else { return }
        if Prefs.clipboardSkipSensitive, item.kind != .image, SensitiveContent.looksSensitive(item.text) {
            lastSkipReason = "Skipped something that looked like a password, key or card number."
            ClipboardStorage.deleteImage(named: item.imageFileName)
            return
        }
        lastSkipReason = nil
        item.sourceAppName = source?.localizedName ?? ""
        item.sourceBundleID = bundleID
        save(item)
    }

    private func makeItem(from pasteboard: NSPasteboard, types: [String]) -> ClipboardItem? {
        // Files from Finder.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let text = urls.map(\.path).joined(separator: "\n")
            return ClipboardItem(kind: .file, text: text, contentHash: ClipboardStorage.hash(Data(("file:" + text).utf8)))
        }

        if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kind = Self.classify(string)
            let item = ClipboardItem(kind: kind, text: string, contentHash: ClipboardStorage.hash(Data(string.utf8)))
            if kind == .text, let rtf = pasteboard.data(forType: .rtf), rtf.count < 2_000_000 {
                item.kind = .richText
                item.rtfData = rtf
            }
            if kind == .color { item.text = Self.normalizedHex(string) }
            return item
        }

        if let color = NSColor(from: pasteboard)?.usingColorSpace(.sRGB) {
            let hex = String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            return ClipboardItem(kind: .color, text: hex, contentHash: ClipboardStorage.hash(Data(hex.utf8)))
        }

        guard Prefs.clipboardCaptureImages,
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= maxImageBytes else { return nil }
        let hash = ClipboardStorage.hash(png)
        let name = "\(hash.prefix(24)).png"
        let url = ClipboardStorage.directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try png.write(to: url, options: .atomic) } catch { return nil }
        }
        let item = ClipboardItem(kind: .image, text: "", contentHash: hash)
        item.imageFileName = name
        item.imageWidth = bitmap.pixelsWide
        item.imageHeight = bitmap.pixelsHigh
        return item
    }

    nonisolated static func classify(_ string: String) -> ClipKind {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^#?([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$"#, options: .regularExpression) != nil,
           trimmed.hasPrefix("#") || trimmed.contains(where: \.isLetter) {
            return .color
        }
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp", "ssh", "file"].contains(scheme) {
            return .link
        }
        return .text
    }

    nonisolated static func normalizedHex(_ string: String) -> String {
        var hex = string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        return "#" + hex
    }

    private func save(_ item: ClipboardItem) {
        let hash = item.contentHash
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentHash == hash })
        if let existing = try? context.fetch(descriptor).first {
            // Same content again: move it to the top instead of storing a duplicate.
            existing.createdAt = Date()
            existing.lastUsedAt = Date()
            if !item.sourceAppName.isEmpty {
                existing.sourceAppName = item.sourceAppName
                existing.sourceBundleID = item.sourceBundleID
            }
        } else {
            context.insert(item)
        }
        try? context.save()
        applyRetention()
    }

    func applyRetention() {
        guard let items = try? context.fetch(FetchDescriptor<ClipboardItem>()) else { return }
        let expired = ClipboardRetention.expired(
            items.map { ClipboardRetention.Entry(id: $0.uid, date: $0.createdAt, isKept: $0.isKept) },
            now: Date(),
            maxAgeDays: Prefs.clipboardRetentionDays,
            maxItems: Prefs.clipboardMaxItems
        )
        guard !expired.isEmpty else { return }
        for item in items where expired.contains(item.uid) {
            delete(item, save: false)
        }
        try? context.save()
    }

    func delete(_ item: ClipboardItem, save: Bool = true) {
        let imageName = item.imageFileName
        let hash = item.contentHash
        context.delete(item)
        // Images are shared by hash; remove the file only if nothing else uses it.
        if let imageName {
            let others = (try? context.fetchCount(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentHash == hash }))) ?? 0
            if others <= 1 { ClipboardStorage.deleteImage(named: imageName) }
        }
        if save { try? context.save() }
    }

    /// Removes everything except pinned and favorite items (or everything when `includeKept`).
    func clearHistory(includeKept: Bool) {
        guard let items = try? context.fetch(FetchDescriptor<ClipboardItem>()) else { return }
        for item in items where includeKept || !item.isKept {
            delete(item, save: false)
        }
        try? context.save()
    }
}

// MARK: - Writing and pasting

@MainActor
enum PasteService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS prompt that adds MacPilot to Accessibility.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Puts the item on the pasteboard without re-capturing it.
    static func write(_ item: ClipboardItem, plainText: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .image:
            if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            }
        case .file:
            let urls = item.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            if plainText { pasteboard.setString(item.text, forType: .string) } else { pasteboard.writeObjects(urls) }
        case .richText:
            if !plainText, let rtf = item.rtfData { pasteboard.setData(rtf, forType: .rtf) }
            pasteboard.setString(item.text, forType: .string)
        default:
            pasteboard.setString(item.text, forType: .string)
        }
        ClipboardMonitor.shared.ignoreCurrentChange()
        item.lastUsedAt = Date()
        item.useCount += 1
        try? Persistence.container.mainContext.save()
    }

    static func write(text: String) {
        Clipboard.copy(text)
        ClipboardMonitor.shared.ignoreCurrentChange()
    }

    /// Writes the item, returns focus to `app` and sends ⌘V. Without Accessibility permission it only copies.
    /// Returns false when it could only copy.
    @discardableResult
    static func paste(_ item: ClipboardItem, into app: NSRunningApplication?, plainText: Bool = false) -> Bool {
        write(item, plainText: plainText)
        return sendPaste(to: app)
    }

    @discardableResult
    static func paste(text: String, into app: NSRunningApplication?) -> Bool {
        write(text: text)
        return sendPaste(to: app)
    }

    private static func sendPaste(to app: NSRunningApplication?) -> Bool {
        guard isTrusted else { return false }
        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyV: CGKeyCode = 9
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        return true
    }
}
