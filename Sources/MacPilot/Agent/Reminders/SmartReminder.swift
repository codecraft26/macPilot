import Foundation
import SwiftData

/// What makes a smart reminder fire.
enum ReminderTrigger: Codable, Equatable {
    /// A moment; with `repeating` it recurs on that schedule.
    case time(at: Date, repeating: JobSchedule?)
    case appOpened(app: String)
    case appQuit(app: String)
    case wifiJoined(ssid: String)
    case wifiLeft(ssid: String)
    case wake
    case unlock
    case arrive(place: String)
    case leave(place: String)
    case beforeMeeting(minutes: Int)

    var summary: String {
        switch self {
        case let .time(at, repeating):
            return repeating.map { "\($0.summary)" } ?? "At \(at.formatted(date: .abbreviated, time: .shortened))"
        case .appOpened(let app): return "When you open \(app)"
        case .appQuit(let app): return "When you quit \(app)"
        case .wifiJoined(let ssid): return "When you join the Wi-Fi “\(ssid)”"
        case .wifiLeft(let ssid): return "When you leave the Wi-Fi “\(ssid)”"
        case .wake: return "When your Mac wakes"
        case .unlock: return "When you unlock your Mac"
        case .arrive(let place): return "When you arrive at \(place)"
        case .leave(let place): return "When you leave \(place)"
        case .beforeMeeting(let minutes): return "\(minutes) min before your next meeting"
        }
    }

    var systemImage: String {
        switch self {
        case .time: return "clock"
        case .appOpened, .appQuit: return "app.badge"
        case .wifiJoined, .wifiLeft: return "wifi"
        case .wake, .unlock: return "lock.open"
        case .arrive, .leave: return "location"
        case .beforeMeeting: return "calendar"
        }
    }

    /// Context triggers (not time) can be snoozed "until next time".
    var isContext: Bool {
        if case .time = self { return false }
        return true
    }
}

/// Optional limits on when a reminder may fire.
struct ReminderConditions: Codable, Equatable {
    var weekdaysOnly = false
    /// Minutes after midnight, e.g. 9:00 → 540. Both nil = any time.
    var windowStart: Int?
    var windowEnd: Int?

    var summary: String {
        var parts: [String] = []
        if weekdaysOnly { parts.append("on weekdays") }
        if let start = windowStart, let end = windowEnd {
            parts.append(String(format: "between %02d:%02d and %02d:%02d", start / 60, start % 60, end / 60, end % 60))
        }
        return parts.joined(separator: ", ")
    }

    func allows(_ date: Date, calendar: Calendar = .current) -> Bool {
        if weekdaysOnly {
            let weekday = calendar.component(.weekday, from: date)
            if weekday == 1 || weekday == 7 { return false }
        }
        if let start = windowStart, let end = windowEnd {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            // A window can wrap past midnight (22:00–06:00).
            let inside = start <= end ? (minute >= start && minute < end) : (minute >= start || minute < end)
            if !inside { return false }
        }
        return true
    }
}

enum ReminderRepeat: String, Codable, CaseIterable, Identifiable {
    case once, everyTime
    var id: String { rawValue }
    var label: String { self == .once ? "Once" : "Every time" }
}

@Model
final class SmartReminder {
    var uid: UUID = UUID()
    /// What to remind about ("check PR reviews").
    var text: String = ""
    /// The words the user typed (shown in the confirmation; never includes location data).
    var sourceText: String = ""
    var triggerData: Data?
    var conditionsData: Data?
    var repeatRaw: String = ReminderRepeat.once.rawValue
    var cooldownMinutes: Int = 30
    var enabled: Bool = true
    var isDone: Bool = false
    var createdAt: Date = Date()
    var lastFired: Date?
    var firedCount: Int = 0
    var snoozedUntil: Date?
    /// For time triggers: the next moment it fires.
    var nextFire: Date?
    /// Meeting already reminded about (so each meeting fires once).
    var lastMeetingKey: String = ""
    /// Mirror as a task (and through it, Apple Reminders) when on.
    var syncToReminders: Bool = false
    var taskUID: UUID?

    init(text: String, trigger: ReminderTrigger, conditions: ReminderConditions = ReminderConditions(), repeatMode: ReminderRepeat = .once,
         cooldownMinutes: Int = 30, sourceText: String = "") {
        self.text = text
        self.sourceText = sourceText
        self.trigger = trigger
        self.conditions = conditions
        self.repeatRaw = repeatMode.rawValue
        self.cooldownMinutes = cooldownMinutes
    }

    var trigger: ReminderTrigger {
        get { triggerData.flatMap { try? JSONDecoder().decode(ReminderTrigger.self, from: $0) } ?? .wake }
        set { triggerData = try? JSONEncoder().encode(newValue) }
    }

    var conditions: ReminderConditions {
        get { conditionsData.flatMap { try? JSONDecoder().decode(ReminderConditions.self, from: $0) } ?? ReminderConditions() }
        set { conditionsData = try? JSONEncoder().encode(newValue) }
    }

    var repeatMode: ReminderRepeat {
        get { ReminderRepeat(rawValue: repeatRaw) ?? .once }
        set { repeatRaw = newValue.rawValue }
    }

    var shortID: String { String(uid.uuidString.prefix(8)).lowercased() }

    /// "When you open Xcode → “check PR reviews”"
    var confirmation: String { ReminderDraft(text: text, trigger: trigger, conditions: conditions, repeatMode: repeatMode, cooldownMinutes: cooldownMinutes).confirmation }
}

/// A parsed reminder before it's saved (shown for confirmation).
struct ReminderDraft: Equatable, Codable {
    var text: String
    var trigger: ReminderTrigger
    var conditions = ReminderConditions()
    var repeatMode: ReminderRepeat = .once
    var cooldownMinutes = 30

    var confirmation: String {
        var line = "\(trigger.summary)"
        let extra = conditions.summary
        if !extra.isEmpty { line += " (\(extra))" }
        line += " → “\(text)”"
        if trigger.isContext { line += repeatMode == .everyTime ? " · every time, at most every \(cooldownMinutes) min" : " · once" }
        return line
    }
}

/// Something that happened on the Mac. Location stays here: it's never sent to a model.
enum ReminderEvent: Equatable {
    case appOpened(name: String, bundleID: String)
    case appQuit(name: String, bundleID: String)
    case wifiChanged(from: String?, to: String?)
    case wake
    case unlock
    case entered(place: String)
    case exited(place: String)
}

/// Pure matching and firing rules.
enum ReminderRules {
    static func matches(_ trigger: ReminderTrigger, _ event: ReminderEvent) -> Bool {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        func app(_ wanted: String, _ name: String, _ bundle: String) -> Bool {
            same(wanted, name) || same(wanted, bundle) || same(wanted.replacingOccurrences(of: ".app", with: ""), name)
        }
        switch (trigger, event) {
        case let (.appOpened(wanted), .appOpened(name, bundle)): return app(wanted, name, bundle)
        case let (.appQuit(wanted), .appQuit(name, bundle)): return app(wanted, name, bundle)
        case let (.wifiJoined(ssid), .wifiChanged(from, to)): return to.map { same($0, ssid) } == true && from.map { same($0, ssid) } != true
        case let (.wifiLeft(ssid), .wifiChanged(from, to)): return from.map { same($0, ssid) } == true && to.map { same($0, ssid) } != true
        case (.wake, .wake), (.unlock, .unlock): return true
        case let (.arrive(place), .entered(name)): return same(place, name)
        case let (.leave(place), .exited(name)): return same(place, name)
        default: return false
        }
    }

    enum Verdict: Equatable { case fire, skip(String) }

    /// Conditions, snooze, cooldown and once-only. Call when the trigger matched.
    static func verdict(enabled: Bool, done: Bool, repeatMode: ReminderRepeat, firedCount: Int, lastFired: Date?, cooldownMinutes: Int,
                        snoozedUntil: Date?, conditions: ReminderConditions, now: Date, calendar: Calendar = .current) -> Verdict {
        if !enabled { return .skip("off") }
        if done { return .skip("done") }
        if repeatMode == .once && firedCount > 0 && snoozedUntil == nil { return .skip("already reminded once") }
        if let snoozedUntil, now < snoozedUntil { return .skip("snoozed") }
        if snoozedUntil == nil, let lastFired, now.timeIntervalSince(lastFired) < Double(max(0, cooldownMinutes)) * 60 { return .skip("cooldown") }
        if !conditions.allows(now, calendar: calendar) { return .skip("outside its days or hours") }
        return .fire
    }

    static func verdict(_ reminder: SmartReminder, now: Date, calendar: Calendar = .current) -> Verdict {
        verdict(enabled: reminder.enabled, done: reminder.isDone, repeatMode: reminder.repeatMode, firedCount: reminder.firedCount,
                lastFired: reminder.lastFired, cooldownMinutes: reminder.cooldownMinutes, snoozedUntil: reminder.snoozedUntil,
                conditions: reminder.conditions, now: now, calendar: calendar)
    }

    /// Time trigger due now?
    static func timeDue(nextFire: Date?, now: Date) -> Bool {
        guard let nextFire else { return false }
        return nextFire <= now
    }

    /// The first meeting starting within `minutes` that hasn't been reminded about.
    static func meetingDue(events: [CalendarEvent], minutes: Int, lastKey: String, now: Date) -> (key: String, event: CalendarEvent)? {
        events.filter { !$0.isAllDay && $0.start > now && $0.start.timeIntervalSince(now) <= Double(minutes) * 60 }
            .sorted { $0.start < $1.start }
            .map { ("\($0.id)@\(Int($0.start.timeIntervalSince1970))", $0) }
            .first { $0.0 != lastKey }
    }
}

/// Common phrasings, understood without a model (and in local-only mode).
enum ReminderParser {
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> ReminderDraft? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for prefix in ["hey pilot", "pilot", "/remind", "please"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        }
        if text.lowercased().hasPrefix("remind "), !text.lowercased().hasPrefix("remind me") { text = String(text.dropFirst(7)) }
        let lower = text.lowercased()
        var conditions = ReminderConditions()
        var working = lower

        // Conditions first, so they don't end up in the reminder text.
        if let range = working.range(of: #"\s*(only\s+)?on weekdays|\s*(only\s+)?during the week"#, options: .regularExpression) {
            conditions.weekdaysOnly = true
            working.removeSubrange(range)
        }
        if let range = working.range(of: #"\s*(only\s+)?between\s+\d{1,2}(:\d{2})?\s*(am|pm)?\s+and\s+\d{1,2}(:\d{2})?\s*(am|pm)?"#, options: .regularExpression) {
            let times = timesIn(String(working[range]))
            if times.count == 2 { conditions.windowStart = times[0]; conditions.windowEnd = times[1] }
            working.removeSubrange(range)
        }
        var repeatMode: ReminderRepeat = .once
        if working.contains("whenever") || working.contains("every time") || working.contains("each time") {
            repeatMode = .everyTime
            working = working.replacingOccurrences(of: "every time", with: "when").replacingOccurrences(of: "each time", with: "when")
                .replacingOccurrences(of: "whenever", with: "when")
        }

        // Trigger clause: "when I open Xcode", "when I join the Office wifi", "before my next meeting", …
        let clauses: [(String, ([String]) -> ReminderTrigger?)] = [
            (#"when (?:i )?(?:open|launch|start|switch to) ([a-z0-9 .\-]+?)(?=$| remind| to |,)"#, { .appOpened(app: titled($0[0])) }),
            (#"when ([a-z0-9 .\-]+?) (?:opens|launches|starts)(?=$| remind| to |,)"#, { .appOpened(app: titled($0[0])) }),
            (#"when (?:i )?(?:quit|close|exit) ([a-z0-9 .\-]+?)(?=$| remind| to |,)"#, { .appQuit(app: titled($0[0])) }),
            (#"when (?:i )?(?:join|connect to|get on|am on|'m on)(?: the)? ([a-z0-9 _.\-']+?) (?:wi-?fi|network)"#, { .wifiJoined(ssid: $0[0]) }),
            (#"when (?:i )?(?:join|connect to)(?: the)? (?:wi-?fi|network) ([a-z0-9 _.\-']+?)(?=$| remind| to |,)"#, { .wifiJoined(ssid: $0[0]) }),
            (#"when (?:i )?(?:leave|disconnect from|drop off)(?: the)? ([a-z0-9 _.\-']+?) (?:wi-?fi|network)"#, { .wifiLeft(ssid: $0[0]) }),
            (#"when (?:i )?(?:get|arrive|am|'m) (?:at |to )?(home|work|the office|office|[a-z0-9 \-']+?)(?=$| remind| to |,)"#, { .arrive(place: placeName($0[0])) }),
            (#"when (?:i )?leave (home|work|the office|office|[a-z0-9 \-']+?)(?=$| remind| to |,)"#, { .leave(place: placeName($0[0])) }),
            (#"when (?:i )?unlock(?: my)?(?: mac| computer)?"#, { _ in .unlock }),
            (#"when (?:my )?(?:mac|computer) (?:wakes(?: up)?|is unlocked)|when i wake (?:up )?(?:my )?(?:mac|computer)"#, { _ in .wake }),
            (#"(\d{1,3}) ?(?:min(?:ute)?s?) before (?:my )?next meeting"#, { .beforeMeeting(minutes: Int($0[0]) ?? 5) }),
            (#"before (?:my )?next meeting"#, { _ in .beforeMeeting(minutes: 5) })
        ]
        var trigger: ReminderTrigger?
        for (pattern, build) in clauses {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)) else { continue }
            // Names keep the user's capitalization (SSIDs are case-sensitive).
            let groups = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: working).map { String(working[$0]).trimmingCharacters(in: .whitespaces) } }
                .map { piece in text.range(of: piece, options: .caseInsensitive).map { String(text[$0]) } ?? piece }
            guard let built = build(groups) else { continue }
            trigger = built
            if let range = Range(match.range, in: working) { working.replaceSubrange(range, with: " ") }
            break
        }
        if trigger == nil, let time = timeTrigger(working, now: now, calendar: calendar) {
            trigger = time.trigger
            working = time.rest
        }
        guard let trigger else { return nil }

        // What to remind about: "remind me to X", or whatever is left.
        var what = working
        if let range = what.range(of: #"remind me (?:to |about |that )?"#, options: .regularExpression) {
            what = String(what[range.upperBound...])
        }
        what = what.replacingOccurrences(of: #"\b(remind me|to remind me|please)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(to|about|that)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:")))
        // Keep the user's capitalization for the reminder text.
        if let range = text.range(of: what, options: .caseInsensitive) { what = String(text[range]) }
        guard !what.isEmpty else { return nil }
        let cooldown = repeatMode == .everyTime ? (isApp(trigger) ? 60 : 30) : 0
        return ReminderDraft(text: what.prefix(1).uppercased() + what.dropFirst(), trigger: trigger, conditions: conditions,
                             repeatMode: trigger.isContext ? repeatMode : (timeRepeats(trigger) ? .everyTime : .once), cooldownMinutes: cooldown)
    }

    private static func isApp(_ trigger: ReminderTrigger) -> Bool {
        if case .appOpened = trigger { return true }
        return false
    }

    private static func timeRepeats(_ trigger: ReminderTrigger) -> Bool {
        if case .time(_, let repeating) = trigger { return repeating != nil }
        return false
    }

    static func titled(_ name: String) -> String {
        let known = ["xcode": "Xcode", "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "slack": "Slack", "mail": "Mail",
                     "safari": "Safari", "chrome": "Google Chrome", "zoom": "zoom.us", "figma": "Figma", "notion": "Notion", "terminal": "Terminal"]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return known[trimmed.lowercased()] ?? trimmed.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func placeName(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: #"(?i)^the "#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased() == "office" ? "Work" : trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    /// "9", "9am", "17:30", "5:15 pm" → minutes after midnight.
    static func timesIn(_ text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let h = Range(match.range(at: 1), in: text), var hour = Int(text[h]) else { return nil }
            let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
            if let r = Range(match.range(at: 3), in: text) {
                if text[r] == "pm", hour < 12 { hour += 12 }
                if text[r] == "am", hour == 12 { hour = 0 }
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return hour * 60 + minute
        }
    }

    /// "in 20 minutes", "at 5pm", "tomorrow at 9", "every weekday at 8:30".
    static func timeTrigger(_ text: String, now: Date, calendar: Calendar) -> (trigger: ReminderTrigger, rest: String)? {
        var rest = text
        if let range = rest.range(of: #"in (\d{1,4}) ?(minutes?|mins?|hours?|hrs?|h|m)\b"#, options: .regularExpression) {
            let part = String(rest[range])
            let amount = Double(part.filter(\.isNumber)) ?? 0
            let seconds = part.contains("h") && !part.contains("m") ? amount * 3_600 : amount * 60
            rest.removeSubrange(range)
            return (.time(at: now.addingTimeInterval(seconds), repeating: nil), rest)
        }
        if rest.range(of: #"\bevery\b|\bdaily\b|\bweekdays?\b"#, options: .regularExpression) != nil,
           let schedule = ScheduleParser.parse(rest, timeZone: calendar.timeZone), schedule.kind != .everyHours || rest.contains("hour") {
            rest = rest.replacingOccurrences(of: #"every (?:day|weekday|monday|tuesday|wednesday|thursday|friday|saturday|sunday|morning)s?|every \d+ hours?|daily|on weekdays"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\bat \d{1,2}(?:[:.]\d{2})?\s*(?:am|pm)?"#, with: " ", options: .regularExpression)
            return (.time(at: schedule.next(after: now) ?? now, repeating: schedule), rest)
        }
        guard let regex = try? NSRegularExpression(pattern: #"(tomorrow |today )?at (\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?"#),
              let match = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let whole = Range(match.range, in: rest) else { return nil }
        let minutes = timesIn(String(rest[whole]).replacingOccurrences(of: #"tomorrow |today |at "#, with: "", options: .regularExpression)).first ?? 540
        let tomorrow = Range(match.range(at: 1), in: rest).map { rest[$0].hasPrefix("tomorrow") } ?? false
        var day = calendar.startOfDay(for: now)
        if tomorrow { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day }
        guard var date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) else { return nil }
        if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        rest.removeSubrange(whole)
        return (.time(at: date, repeating: nil), rest)
    }
}

/// Model-based parsing for phrasings the rules don't cover. Only the reminder text is sent — never location or Wi-Fi.
enum ReminderLLMParser {
    static let schema = """
    {"text": string (what to remind, short), "trigger": {"type": one of "time"|"appOpened"|"appQuit"|"wifiJoined"|"wifiLeft"|"wake"|"unlock"|"arrive"|"leave"|"beforeMeeting", \
    "at": ISO-8601 date-time (time only), "app": string, "ssid": string, "place": string, "minutes": integer}, \
    "weekdaysOnly": boolean, "windowStart": "HH:MM" or null, "windowEnd": "HH:MM" or null, "everyTime": boolean}
    """

    static func prompt(now: Date, timeZone: TimeZone) -> String {
        """
        Convert the user's reminder request into JSON matching this schema, and reply with only the JSON:
        \(schema)
        Now is \(ISO8601DateFormatter.string(from: now, timeZone: timeZone, formatOptions: [.withInternetDateTime])) in time zone \(timeZone.identifier).
        If the request has no trigger you can express, reply {"error": "unsupported"}.
        """
    }

    /// Validates the model's JSON against the schema; nil if anything is missing or the wrong type.
    static func decode(_ json: String, now: Date) -> ReminderDraft? {
        guard let data = AgentEngine.firstJSON(in: json)?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 300,
              let trigger = object["trigger"] as? [String: Any], let type = trigger["type"] as? String else { return nil }
        func string(_ key: String) -> String? {
            (trigger[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.count > 100 ? nil : $0 }
        }
        let built: ReminderTrigger?
        switch type {
        case "time":
            let formatter = ISO8601DateFormatter()
            built = string("at").flatMap { formatter.date(from: $0) }.flatMap { $0 > now.addingTimeInterval(-60) ? ReminderTrigger.time(at: $0, repeating: nil) : nil }
        case "appOpened": built = string("app").map { .appOpened(app: $0) }
        case "appQuit": built = string("app").map { .appQuit(app: $0) }
        case "wifiJoined": built = string("ssid").map { .wifiJoined(ssid: $0) }
        case "wifiLeft": built = string("ssid").map { .wifiLeft(ssid: $0) }
        case "wake": built = .wake
        case "unlock": built = .unlock
        case "arrive": built = string("place").map { .arrive(place: $0) }
        case "leave": built = string("place").map { .leave(place: $0) }
        case "beforeMeeting":
            let minutes = (trigger["minutes"] as? Int) ?? 5
            built = (1...240).contains(minutes) ? .beforeMeeting(minutes: minutes) : nil
        default: built = nil
        }
        guard let built else { return nil }
        var conditions = ReminderConditions()
        if let weekdays = object["weekdaysOnly"] as? Bool { conditions.weekdaysOnly = weekdays }
        if let start = object["windowStart"] as? String, let end = object["windowEnd"] as? String,
           let s = ReminderParser.timesIn(start).first, let e = ReminderParser.timesIn(end).first {
            conditions.windowStart = s
            conditions.windowEnd = e
        }
        let every = object["everyTime"] as? Bool ?? false
        return ReminderDraft(text: text, trigger: built, conditions: conditions, repeatMode: every && built.isContext ? .everyTime : .once,
                             cooldownMinutes: every ? 30 : 0)
    }
}

/// A named place: by coordinates (region monitoring) or by a Wi-Fi network as a proxy. Stored only on this Mac.
struct SavedPlace: Codable, Equatable, Identifiable {
    var name: String
    var latitude: Double?
    var longitude: Double?
    var radius: Double = 150
    var ssid: String?
    var id: String { name.lowercased() }
}
