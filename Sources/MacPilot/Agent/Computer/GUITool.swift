import AppKit
import ApplicationServices
import Foundation
@preconcurrency import ScreenCaptureKit

struct GUIApp: Codable, Equatable {
    var name: String
    var bundleID: String
    var pid: Int32
}

/// Desktop control through the Accessibility API (mocked in tests).
@MainActor
protocol GUIDriving: AnyObject {
    var hasAccessibility: Bool { get }
    func apps() -> [GUIApp]
    func windows(of app: GUIApp) -> [String]
    func tree(of app: GUIApp, depth: Int) throws -> String
    func click(app: GUIApp, path: String) throws
    func type(app: GUIApp, text: String) throws
    func press(app: GUIApp, keys: String) throws
    func clickAt(app: GUIApp, x: Double, y: Double) throws
    func screenshot(app: GUIApp?) async throws -> Data
}

enum GUIError: LocalizedError, Equatable {
    case noAccessibility, appNotFound(String), noElement(String), badKeys(String), actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAccessibility: return "MacPilot needs control permission: turn it on in \(ComputerPermissions.accessibilityPath()) (Settings → Agent → Permissions → Request)."
        case .appNotFound(let name): return "“\(name)” isn't running."
        case .noElement(let path): return "No UI element at \(path). Read the app's UI tree first."
        case .badKeys(let keys): return "Couldn't understand the keys “\(keys)” (try cmd+s, return, tab, escape)."
        case .actionFailed(let detail): return "The action failed: \(detail)"
        }
    }
}

/// Which apps the agent may touch. Some are never touched, whatever the allowlist or an approval says.
enum GUIPolicy {
    static let forbiddenBundleIDs: Set<String> = [
        "com.apple.systempreferences", "com.apple.Settings", "com.apple.settings.PrivacySecurity.extension",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.loginwindow", "com.apple.SecurityAgent",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.coreservices.uiagent", "com.apple.ScreenSaver.Engine",
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.dashlane.Dashlane", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
        "com.macpilot.app"
    ]
    static let forbiddenNames = ["system settings", "system preferences", "keychain access", "passwords", "1password", "bitwarden",
                                 "lastpass", "dashlane", "keepassxc", "loginwindow", "securityagent"]

    static func isForbidden(_ app: GUIApp) -> Bool {
        forbiddenBundleIDs.contains(app.bundleID) || forbiddenNames.contains(app.name.lowercased())
    }

    static let readActions: Set<String> = ["list_apps", "list_windows", "read_tree", "screenshot"]
    static let allActions: Set<String> = readActions.union(["click", "type", "press_key", "click_at"])

    struct Assessment: Equatable {
        var risk: AgentRisk
        var reason: String
        var denied: String?
    }

    static func assess(action: String, app: GUIApp?, allowlist: [String], visionModel: Bool, readOnly: Bool) -> Assessment {
        guard allActions.contains(action) else { return Assessment(risk: .high, reason: "", denied: "Unknown GUI action “\(action)”.") }
        if readOnly { return Assessment(risk: .high, reason: "", denied: "Scheduled jobs can't control apps.") }
        if action == "list_apps" { return Assessment(risk: .low, reason: "List running apps") }
        if action == "screenshot", app == nil { return Assessment(risk: .medium, reason: "Screenshot of the whole screen (MacPilot hidden)") }
        guard let app else { return Assessment(risk: .high, reason: "", denied: "Name the app (use list_apps).") }
        if isForbidden(app) {
            return Assessment(risk: .high, reason: "", denied: "MacPilot never controls \(app.name): security settings, passwords and the login window are off-limits.")
        }
        if action == "click_at", !visionModel {
            return Assessment(risk: .high, reason: "", denied: "Clicking by coordinates needs a model that can see screenshots. Use click with an AX path.")
        }
        let allowed = allowlist.contains { $0.caseInsensitiveCompare(app.bundleID) == .orderedSame }
        let verb: String
        switch action {
        case "list_windows": verb = "List \(app.name)'s windows"
        case "read_tree": verb = "Read \(app.name)'s UI"
        case "screenshot": verb = "Screenshot \(app.name)"
        case "click": verb = "Click in \(app.name)"
        case "type": verb = "Type in \(app.name)"
        case "press_key": verb = "Press keys in \(app.name)"
        default: verb = "Click at a position in \(app.name)"
        }
        if readActions.contains(action) {
            return Assessment(risk: allowed ? .low : .high, reason: verb + (allowed ? "" : " (not on the app allowlist)"))
        }
        return Assessment(risk: allowed ? .medium : .high, reason: verb + (allowed ? "" : " (not on the app allowlist)"))
    }

    /// "cmd+shift+s", "return", "tab" → key code and flags.
    static func parseKeys(_ text: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last else { return nil }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            default: return nil
            }
        }
        let named: [String: CGKeyCode] = ["return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
                                          "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121]
        let letters: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
                                               "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
                                               "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
                                               "n": 45, "m": 46, ",": 43, ".": 47, "/": 44]
        if let code = named[key] { return (code, flags) }
        if key.count == 1, let code = letters[key.first!] { return (code, flags) }
        return nil
    }
}

/// Real driver: AXUIElement for reading and pressing, CGEvent for typing and keys, ScreenCaptureKit for screenshots.
@MainActor
final class AXGUIDriver: GUIDriving {
    static let shared = AXGUIDriver()

    var hasAccessibility: Bool { AXIsProcessTrusted() }

    func apps() -> [GUIApp] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            GUIApp(name: $0.localizedName ?? "?", bundleID: $0.bundleIdentifier ?? "", pid: $0.processIdentifier)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    func windows(of app: GUIApp) -> [String] {
        let root = AXUIElementCreateApplication(app.pid)
        return (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { attribute($0, kAXTitleAttribute) as? String ?? "(untitled)" }
    }

    /// Trimmed tree: "path role "title" [value]" lines, at most 400 nodes.
    func tree(of app: GUIApp, depth: Int) throws -> String {
        guard hasAccessibility else { throw GUIError.noAccessibility }
        let root = AXUIElementCreateApplication(app.pid)
        var lines: [String] = []
        func walk(_ element: AXUIElement, path: String, level: Int) {
            guard lines.count < 400 else { return }
            let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
            let title = (attribute(element, kAXTitleAttribute) as? String) ?? (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
            let value = attribute(element, kAXValueAttribute).map { "\($0)" } ?? ""
            // Secure text fields never show their value.
            let shown = role == "AXSecureTextField" ? "•••" : String(value.prefix(60))
            lines.append(String(repeating: "  ", count: level) + "\(path) \(role)" + (title.isEmpty ? "" : " “\(title.prefix(60))”") + (shown.isEmpty ? "" : " [\(shown)]"))
            guard level < depth else { return }
            for (index, child) in children(element).enumerated() { walk(child, path: path + "/" + String(index), level: level + 1) }
        }
        walk(root, path: "0", level: 0)
        return lines.joined(separator: "\n")
    }

    private func resolve(app: GUIApp, path: String) throws -> AXUIElement {
        var element = AXUIElementCreateApplication(app.pid)
        let indices = path.split(separator: "/").dropFirst().map { Int($0) }
        for index in indices {
            guard let index, case let kids = children(element), kids.indices.contains(index) else { throw GUIError.noElement(path) }
            element = kids[index]
        }
        return element
    }

    private func activate(_ app: GUIApp) {
        NSRunningApplication(processIdentifier: app.pid)?.activate()
    }

    func click(app: GUIApp, path: String) throws {
        guard hasAccessibility else { throw GUIError.noAccessibility }
        let element = try resolve(app: app, path: path)
        if (attribute(element, kAXRoleAttribute) as? String) == "AXSecureTextField" { throw GUIError.actionFailed("password fields are off-limits") }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw GUIError.actionFailed("AX press returned \(result.rawValue)") }
    }

    func type(app: GUIApp, text: String) throws {
        guard hasAccessibility else { throw GUIError.noAccessibility }
        activate(app)
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in Array(text).chunked(16) {
            let utf16 = Array(String(chunk).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event?.postToPid(app.pid)
            }
        }
    }

    func press(app: GUIApp, keys: String) throws {
        guard hasAccessibility else { throw GUIError.noAccessibility }
        guard let (code, flags) = GUIPolicy.parseKeys(keys) else { throw GUIError.badKeys(keys) }
        activate(app)
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.postToPid(app.pid)
        }
    }

    func clickAt(app: GUIApp, x: Double, y: Double) throws {
        guard hasAccessibility else { throw GUIError.noAccessibility }
        activate(app)
        let point = CGPoint(x: x, y: y)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    func screenshot(app: GUIApp?) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let filter: SCContentFilter
        if let app, let window = content.windows.first(where: { $0.owningApplication?.processID == app.pid && $0.isOnScreen && $0.frame.width > 50 }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            let size = SystemScreenSource.fit(width: Int(window.frame.width * 2), height: Int(window.frame.height * 2), maxDimension: 1_600)
            configuration.width = size.width
            configuration.height = size.height
        } else {
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw ScreenshotError.noDisplay }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ownPID }, exceptingWindows: [])
            let size = SystemScreenSource.fit(width: display.width * 2, height: display.height * 2, maxDimension: 1_600)
            configuration.width = size.width
            configuration.height = size.height
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try SystemScreenSource.jpeg(image, maxBytes: 4_000_000)
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// The permission checklist in Settings → Agent.
enum ComputerPermissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows macOS's prompt (which adds MacPilot to the list, switched off) and opens the right pane.
    static func requestAccessibility() {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !trusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSWorkspace.shared.open(accessibilitySettings) }
        }
    }

    /// What System Settings calls the Accessibility (control your computer) list on this macOS.
    /// macOS 27 renamed it "Device Control and Data Access"; the Accessibility *settings* section only lists assistive apps.
    static func accessibilityPaneName(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    /// "System Settings → Privacy & Security → Device Control and Data Access"
    static func accessibilityPath(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        "System Settings → Privacy & Security → \(accessibilityPaneName(majorVersion: majorVersion))"
    }

    /// Short instruction for any view that needs the permission.
    static var accessibilityHelp: String {
        "Turn on MacPilot in \(accessibilityPath()), then quit and reopen MacPilot. (Not System Settings → Accessibility: that only lists assistive apps.)"
    }

    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenRecordingSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
