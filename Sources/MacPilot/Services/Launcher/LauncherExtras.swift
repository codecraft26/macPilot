import AppKit
import ApplicationServices
import Foundation
import Observation

// MARK: - Calculator

/// A small, safe arithmetic evaluator: + - * / % ^, parentheses, decimals, unary minus, "x" for times.
enum Calculator {
    static func evaluate(_ input: String) -> Double? {
        let text = input.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "x", with: "*").replacingOccurrences(of: "X", with: "*")
            .replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty, text.contains(where: \.isNumber),
              text.contains(where: { "+-*/%^()".contains($0) }),
              text.allSatisfy({ $0.isNumber || ".+-*/%^()".contains($0) }) else { return nil }
        var parser = Parser(chars: Array(text))
        guard let value = parser.expression(), parser.index == parser.chars.count, value.isFinite else { return nil }
        return value
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        let chars: [Character]
        var index = 0

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while index < chars.count, chars[index] == "+" || chars[index] == "-" {
                let op = chars[index]; index += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while index < chars.count, "*/%".contains(chars[index]) {
                let op = chars[index]; index += 1
                guard let rhs = power() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": guard rhs != 0 else { return nil }; value /= rhs
                default: guard rhs != 0 else { return nil }; value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if index < chars.count, chars[index] == "^" {
                index += 1
                guard let exponent = power() else { return nil } // right-associative
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if index < chars.count, chars[index] == "-" { index += 1; return unary().map { -$0 } }
            if index < chars.count, chars[index] == "+" { index += 1; return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            guard index < chars.count else { return nil }
            if chars[index] == "(" {
                index += 1
                guard let value = expression(), index < chars.count, chars[index] == ")" else { return nil }
                index += 1
                return value
            }
            let start = index
            while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(chars[start..<index]))
        }
    }
}

// MARK: - Unit conversion

enum UnitConversion {
    private static let units: [String: Dimension] = [
        "mm": UnitLength.millimeters, "cm": UnitLength.centimeters, "m": UnitLength.meters, "km": UnitLength.kilometers,
        "in": UnitLength.inches, "inch": UnitLength.inches, "inches": UnitLength.inches, "ft": UnitLength.feet, "feet": UnitLength.feet,
        "foot": UnitLength.feet, "yd": UnitLength.yards, "mi": UnitLength.miles, "mile": UnitLength.miles, "miles": UnitLength.miles,
        "g": UnitMass.grams, "kg": UnitMass.kilograms, "lb": UnitMass.pounds, "lbs": UnitMass.pounds, "oz": UnitMass.ounces,
        "c": UnitTemperature.celsius, "°c": UnitTemperature.celsius, "celsius": UnitTemperature.celsius,
        "f": UnitTemperature.fahrenheit, "°f": UnitTemperature.fahrenheit, "fahrenheit": UnitTemperature.fahrenheit,
        "k": UnitTemperature.kelvin, "kelvin": UnitTemperature.kelvin,
        "ml": UnitVolume.milliliters, "l": UnitVolume.liters, "gal": UnitVolume.gallons, "cup": UnitVolume.cups, "cups": UnitVolume.cups,
        "kmh": UnitSpeed.kilometersPerHour, "km/h": UnitSpeed.kilometersPerHour, "mph": UnitSpeed.milesPerHour, "m/s": UnitSpeed.metersPerSecond,
        "s": UnitDuration.seconds, "sec": UnitDuration.seconds, "min": UnitDuration.minutes, "h": UnitDuration.hours, "hr": UnitDuration.hours, "hours": UnitDuration.hours,
        "kb": UnitInformationStorage.kilobytes, "mb": UnitInformationStorage.megabytes, "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes
    ]

    /// "10 km to mi", "72 f in c", "5.5kg -> lb".
    static func convert(_ input: String) -> (result: Double, text: String)? {
        let pattern = #"^\s*(-?[\d.,]+)\s*([a-z°/]+)\s+(?:to|in|->|as)\s+([a-z°/]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let valueRange = Range(match.range(at: 1), in: input),
              let fromRange = Range(match.range(at: 2), in: input),
              let toRange = Range(match.range(at: 3), in: input),
              let value = Double(input[valueRange].replacingOccurrences(of: ",", with: "")),
              let from = units[input[fromRange].lowercased()], let to = units[input[toRange].lowercased()],
              type(of: from) == type(of: to) else { return nil }
        let converted = Measurement(value: value, unit: from).converted(to: to).value
        return (converted, "\(Calculator.format((converted * 10_000).rounded() / 10_000)) \(input[toRange])")
    }
}

// MARK: - Web

enum WebLinks {
    /// A typed URL or bare domain ("apple.com", "https://x.dev/a").
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.contains(" "), text.contains(".") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            return url
        }
        guard text.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let tld = text.split(separator: "/").first?.split(separator: ".").last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return URL(string: "https://" + text)
    }

    static func search(_ engine: String, _ query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch engine {
        case "YouTube": return URL(string: "https://www.youtube.com/results?search_query=\(encoded)")
        case "GitHub": return URL(string: "https://github.com/search?q=\(encoded)")
        default: return URL(string: "https://www.google.com/search?q=\(encoded)")
        }
    }
}

// MARK: - File search (Spotlight)

/// Spotlight file search for the launcher; results arrive asynchronously and the view re-renders.
@Observable
@MainActor
final class FileSearch {
    static let shared = FileSearch()

    struct Result: Hashable {
        let path: String
        let name: String
    }

    private(set) var results: [Result] = []
    private(set) var query = ""
    private var metadataQuery: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != query else { return }
        query = trimmed
        metadataQuery?.stop()
        results = []
        guard trimmed.count >= 2 else { return }

        let search = NSMetadataQuery()
        search.searchScopes = [NSMetadataQueryUserHomeScope]
        search.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemDisplayNameKey, trimmed)
        search.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: search, queue: .main) { _ in
            MainActor.assumeIsolated { FileSearch.shared.collectCurrent(for: trimmed) }
        }
        metadataQuery = search
        search.start()
    }

    private func collectCurrent(for text: String) {
        if let metadataQuery { collect(metadataQuery, for: text) }
    }

    private func collect(_ search: NSMetadataQuery, for text: String) {
        search.disableUpdates()
        defer { search.stop() }
        guard text == query else { return }
        var found: [Result] = []
        for index in 0..<min(search.resultCount, 40) {
            guard let item = search.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.contains("/Library/"), !path.contains("/."), !path.hasSuffix(".app") else { continue }
            found.append(Result(path: path, name: (path as NSString).lastPathComponent))
            if found.count == 8 { break }
        }
        results = found
    }
}

// MARK: - Window management

enum WindowLayout: String, CaseIterable {
    case leftHalf = "Left half", rightHalf = "Right half", topHalf = "Top half", bottomHalf = "Bottom half"
    case maximize = "Maximize", center = "Center"
    case leftThird = "Left third", centerThird = "Center third", rightThird = "Right third"
    case leftTwoThirds = "Left two thirds", rightTwoThirds = "Right two thirds"

    var systemImage: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .maximize: return "rectangle.fill"
        case .center: return "rectangle.center.inset.filled"
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds: return "rectangle.split.3x1"
        }
    }

    /// Target frame inside `screen` (any coordinate space with the origin at a corner; only arithmetic).
    func frame(in screen: CGRect, current: CGRect) -> CGRect {
        let w = screen.width, h = screen.height, x = screen.minX, y = screen.minY
        switch self {
        case .leftHalf: return CGRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf: return CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .topHalf: return CGRect(x: x, y: y, width: w, height: h / 2)
        case .bottomHalf: return CGRect(x: x, y: y + h / 2, width: w, height: h / 2)
        case .maximize: return screen
        case .center:
            let size = CGSize(width: min(current.width, w), height: min(current.height, h))
            return CGRect(x: x + (w - size.width) / 2, y: y + (h - size.height) / 2, width: size.width, height: size.height)
        case .leftThird: return CGRect(x: x, y: y, width: w / 3, height: h)
        case .centerThird: return CGRect(x: x + w / 3, y: y, width: w / 3, height: h)
        case .rightThird: return CGRect(x: x + 2 * w / 3, y: y, width: w / 3, height: h)
        case .leftTwoThirds: return CGRect(x: x, y: y, width: 2 * w / 3, height: h)
        case .rightTwoThirds: return CGRect(x: x + w / 3, y: y, width: 2 * w / 3, height: h)
        }
    }

    /// Moves the focused window of `app` (needs Accessibility). Returns an error message on failure.
    @MainActor
    func apply(to app: NSRunningApplication?) -> String? {
        guard PasteService.isTrusted else {
            PasteService.requestTrust()
            return "Allow MacPilot in \(ComputerPermissions.accessibilityPath()) to move windows."
        }
        guard let app else { return "No app window to move." }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused, CFGetTypeID(window) == AXUIElementGetTypeID() else { return "\(app.localizedName ?? "That app") has no window to move." }
        let axWindow = window as! AXUIElement

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue) == .success, let positionValue {
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        }
        if AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue) == .success, let sizeValue {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        // AX uses top-left origin on the primary screen; NSScreen uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let current = CGRect(origin: position, size: size)
        let cocoaCenter = CGPoint(x: current.midX, y: primaryHeight - current.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(cocoaCenter) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return "No screen found." }
        let axScreen = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
        let target = frame(in: axScreen, current: current)

        var newPosition = target.origin
        var newSize = target.size
        if let value = AXValueCreate(.cgSize, &newSize) { AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &newPosition) { AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value) }
        // Some apps clamp the size until the window has moved; set it once more.
        if let value = AXValueCreate(.cgSize, &newSize) { AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value) }
        return nil
    }
}

// MARK: - System commands

@MainActor
enum SystemCommands {
    static func sleepDisplay() {
        Task { _ = await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
    }

    static func startScreenSaver() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }

    /// Locks the screen with the system shortcut ⌃⌘Q (needs Accessibility).
    static func lockScreen() {
        guard PasteService.isTrusted else {
            startScreenSaver()
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false)
        down?.flags = [.maskCommand, .maskControl]
        up?.flags = [.maskCommand, .maskControl]
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Toggles Light/Dark appearance (macOS asks once to let MacPilot control System Events).
    static func toggleDarkMode() {
        Task {
            _ = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
        }
    }

    /// Empties the Trash after the user confirms.
    static func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Items in the Trash are deleted permanently. This can't be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { _ = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"]) }
    }
}

// MARK: - Usage ranking

/// Remembers which launcher items you run so frequent and recent ones rank higher.
enum LauncherUsage {
    private static let key = "launcher.usage"

    struct Entry: Codable {
        var count: Int
        var last: Date
    }

    static var entries: [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func record(_ id: String, at date: Date = Date()) {
        // Typed-text items change with every query; group them by kind.
        let stable = stableID(id)
        var all = entries
        var entry = all[stable] ?? Entry(count: 0, last: date)
        entry.count += 1
        entry.last = date
        all[stable] = entry
        if all.count > 300 {
            all = Dictionary(uniqueKeysWithValues: all.sorted { $0.value.last > $1.value.last }.prefix(200).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func stableID(_ id: String) -> String {
        if id.hasPrefix("calc") || id.hasPrefix("web.") || id.hasPrefix("url") { return id.components(separatedBy: ":").first ?? id }
        return id
    }

    /// 0 for never used; grows with use and fades over about two weeks.
    static func boost(_ id: String, entries: [String: Entry], now: Date = Date()) -> Double {
        guard let entry = entries[stableID(id)] else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(entry.last) / 86_400)
        return log2(Double(entry.count) + 1) * exp(-ageDays / 14)
    }

    /// Keeps the matcher's order but lets frequently used items move up a few places.
    static func rerank(_ items: [LauncherItem], now: Date = Date()) -> [LauncherItem] {
        let usage = entries
        guard !usage.isEmpty else { return items }
        return items.enumerated()
            .map { (item: $0.element, score: Double($0.offset) - 3 * boost($0.element.id, entries: usage, now: now)) }
            .sorted { $0.score < $1.score }
            .map(\.item)
    }
}
