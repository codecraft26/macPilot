import AppKit
import ApplicationServices
import Foundation
import Observation

/// Memory settings (off by default). Nothing here is secret.
struct MemorySettings: Equatable {
    var enabled = false
    var paused = false
    var allowlist: [String] = []
    var retentionDays = 30
    var feedReminders = true
    var autoClose = false
    var autoCloseThreshold = 0.9
    var extractEveryMinutes = 10

    /// Suggested apps for the allowlist (none are on until the user ticks them).
    static let suggestions: [(name: String, bundleID: String)] = [
        ("Mail", "com.apple.mail"), ("Messages", "com.apple.MobileSMS"), ("WhatsApp", "net.whatsapp.WhatsApp"),
        ("Slack", "com.tinyspeck.slackmacgap"), ("Calendar", "com.apple.iCal"), ("Notes", "com.apple.Notes"),
        ("Microsoft Teams", "com.microsoft.teams2"), ("Microsoft Outlook", "com.microsoft.Outlook"), ("Reminders", "com.apple.reminders"),
        ("Safari", "com.apple.Safari"), ("Google Chrome", "com.google.Chrome")
    ]

    private enum Keys {
        static let enabled = "memory.enabled", paused = "memory.paused", allowlist = "memory.allowlist", retention = "memory.retentionDays"
        static let feed = "memory.feedReminders", autoClose = "memory.autoClose", threshold = "memory.autoCloseThreshold"
    }

    static func load(_ defaults: UserDefaults = .standard) -> MemorySettings {
        var settings = MemorySettings()
        settings.enabled = defaults.bool(forKey: Keys.enabled)
        settings.paused = defaults.bool(forKey: Keys.paused)
        settings.allowlist = defaults.stringArray(forKey: Keys.allowlist) ?? []
        if defaults.object(forKey: Keys.retention) != nil { settings.retentionDays = max(1, defaults.integer(forKey: Keys.retention)) }
        if defaults.object(forKey: Keys.feed) != nil { settings.feedReminders = defaults.bool(forKey: Keys.feed) }
        settings.autoClose = defaults.bool(forKey: Keys.autoClose)
        if defaults.object(forKey: Keys.threshold) != nil { settings.autoCloseThreshold = min(1, max(0.5, defaults.double(forKey: Keys.threshold))) }
        return settings
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(paused, forKey: Keys.paused)
        defaults.set(allowlist, forKey: Keys.allowlist)
        defaults.set(retentionDays, forKey: Keys.retention)
        defaults.set(feedReminders, forKey: Keys.feed)
        defaults.set(autoClose, forKey: Keys.autoClose)
        defaults.set(autoCloseThreshold, forKey: Keys.threshold)
    }
}

/// A node of an app's accessibility tree (the real AXUIElement or a test double).
protocol AXTextNode {
    var role: String { get }
    var title: String { get }
    var value: String { get }
    var subrole: String { get }
    var children: [AXTextNode] { get }
}

/// Visible text from an accessibility tree. Secure (password) fields are never read.
enum AXTextFlattener {
    static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell", "AXButton", "AXMenuItem"]

    static func flatten(_ root: AXTextNode, maxCharacters: Int = 20_000, maxNodes: Int = 3_000) -> String {
        var lines: [String] = []
        var total = 0, visited = 0
        func walk(_ node: AXTextNode, depth: Int) {
            guard total < maxCharacters, visited < maxNodes, depth < 40 else { return }
            visited += 1
            if node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField" { return }
            if textRoles.contains(node.role) {
                let piece = (node.value.isEmpty ? node.title : node.value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty, lines.last != piece {
                    lines.append(piece)
                    total += piece.count
                }
            }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return String(lines.joined(separator: "\n").prefix(maxCharacters))
    }
}

/// Reads the focused window of an app (real: Accessibility; tests: a mock).
@MainActor
protocol FocusedWindowReader {
    func focusedWindow(pid: pid_t) -> (title: String, root: AXTextNode)?
}

/// The capture rules, independent of the Accessibility API (unit-tested).
struct CapturePolicy {
    static let privateWindowMarkers = ["private browsing", "incognito", "inprivate", "private window"]

    enum Decision: Equatable { case read, skip(String) }

    static func decide(bundleID: String, appName: String, windowTitle: String?, settings: MemorySettings) -> Decision {
        guard settings.enabled else { return .skip("memory is off") }
        guard !settings.paused else { return .skip("paused") }
        if GUIPolicy.isForbidden(GUIApp(name: appName, bundleID: bundleID, pid: 0)) { return .skip("blocked app") }
        guard settings.allowlist.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return .skip("not on the allowlist") }
        if let title = windowTitle?.lowercased(), privateWindowMarkers.contains(where: title.contains) { return .skip("private window") }
        return .read
    }
}

/// Per-window throttle (≥30 s between reads) and change detection by hash.
struct CaptureThrottle {
    var interval: TimeInterval = 30
    private var lastRead: [String: Date] = [:]
    private var lastHash: [String: String] = [:]

    mutating func mayRead(_ key: String, now: Date) -> Bool {
        if let last = lastRead[key], now.timeIntervalSince(last) < interval { return false }
        lastRead[key] = now
        return true
    }

    /// True when the text differs from the last one seen in this window.
    mutating func changed(_ key: String, text: String) -> Bool {
        let hash = MemoryStore.hash(text)
        if lastHash[key] == hash { return false }
        lastHash[key] = hash
        return true
    }
}

/// Opt-in capture of visible text from allowlisted apps, on focus and on content change (polled, throttled).
@Observable
@MainActor
final class MemoryCapture {
    static let shared = MemoryCapture(store: .shared)

    let store: MemoryStore
    var settingsProvider: () -> MemorySettings = { MemorySettings.load() }
    var reader: FocusedWindowReader = AXFocusedWindowReader()
    var frontmost: () -> (name: String, bundleID: String, pid: pid_t)? = {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.localizedName ?? "", app.bundleIdentifier ?? "", app.processIdentifier)
    }
    var now: () -> Date = Date.init
    private(set) var lastCapture: Date?
    private(set) var capturedCount = 0
    private var throttle = CaptureThrottle()
    private var timer: Timer?

    init(store: MemoryStore) {
        self.store = store
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = MemoryCapture.shared.captureFocused() }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { _ = MemoryCapture.shared.captureFocused() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        store.purge(olderThan: settingsProvider().retentionDays)
    }

    var isPaused: Bool {
        get { settingsProvider().paused }
        set { var settings = MemorySettings.load(); settings.paused = newValue; settings.save() }
    }

    /// Reads the focused window if the rules allow it. Returns the stored snippet id (nil when skipped).
    @discardableResult
    func captureFocused() -> Int64? {
        let settings = settingsProvider()
        guard settings.enabled, !settings.paused, let app = frontmost() else { return nil }
        // Check app rules before touching the window at all.
        guard case .read = CapturePolicy.decide(bundleID: app.bundleID, appName: app.name, windowTitle: nil, settings: settings) else { return nil }
        guard let window = reader.focusedWindow(pid: app.pid) else { return nil }
        guard case .read = CapturePolicy.decide(bundleID: app.bundleID, appName: app.name, windowTitle: window.title, settings: settings) else { return nil }
        let key = app.bundleID + "|" + window.title
        guard throttle.mayRead(key, now: now()) else { return nil }
        let text = AXTextFlattener.flatten(window.root)
        guard text.count >= 20, throttle.changed(key, text: text) else { return nil }
        let inserted: Int64?? = try? store.insert(app: app.name, bundleID: app.bundleID, window: window.title, text: text, date: now())
        if let id = inserted ?? nil {
            lastCapture = now()
            capturedCount += 1
            return id
        }
        return nil
    }
}

/// AXUIElement-backed node.
struct AXElementNode: AXTextNode {
    let element: AXUIElement

    private func attribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    var role: String { attribute(kAXRoleAttribute) as? String ?? "" }
    var subrole: String { attribute(kAXSubroleAttribute) as? String ?? "" }
    var title: String { (attribute(kAXTitleAttribute) as? String) ?? (attribute(kAXDescriptionAttribute) as? String) ?? "" }
    var value: String {
        // Never read the value of a secure field (checked again here, not only in the flattener).
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return "" }
        return attribute(kAXValueAttribute) as? String ?? ""
    }
    var children: [AXTextNode] { (attribute(kAXChildrenAttribute) as? [AXUIElement] ?? []).map(AXElementNode.init) }
}

struct AXFocusedWindowReader: FocusedWindowReader {
    func focusedWindow(pid: pid_t) -> (title: String, root: AXTextNode)? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = window as! AXUIElement
        var title: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        return ((title as? String) ?? "", AXElementNode(element: element))
    }
}
