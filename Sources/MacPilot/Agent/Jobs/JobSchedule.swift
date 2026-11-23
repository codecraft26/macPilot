import Foundation

/// When a job runs, always in a named time zone (so 9:00 stays 9:00 across daylight-saving changes).
struct JobSchedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case daily, weekly, everyHours, cron
        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: return "Every day"
            case .weekly: return "Weekly"
            case .everyHours: return "Every N hours"
            case .cron: return "Cron"
            }
        }
    }

    var kind: Kind = .daily
    var hour = 9
    var minute = 0
    /// 1 = Sunday … 7 = Saturday (Calendar's numbering).
    var weekdays: Set<Int> = [2]
    var intervalHours = 6
    /// "m h dom mon dow", e.g. "0 9 * * 1-5".
    var cron = "0 9 * * 1-5"
    var timeZoneID = TimeZone.current.identifier

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .daily: return "Every day at \(time)"
        case .weekly:
            let names = calendar.shortWeekdaySymbols
            let days = weekdays.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: ", ")
            return "Every \(days.isEmpty ? "week" : days) at \(time)"
        case .everyHours: return "Every \(intervalHours) hour\(intervalHours == 1 ? "" : "s")"
        case .cron: return "Cron “\(cron)”"
        }
    }

    /// The first run strictly after `date`. Wall-clock times that don't exist on a spring-forward day move to the
    /// next valid time; times that happen twice on a fall-back day run once.
    func next(after date: Date) -> Date? {
        let cal = calendar
        switch kind {
        case .daily:
            return cal.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        case .weekly:
            let days = weekdays.filter { (1...7).contains($0) }
            guard !days.isEmpty else { return nil }
            return days.compactMap {
                cal.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: $0),
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            }.min()
        case .everyHours:
            // Real elapsed hours (not wall clock), on the hour boundary in the job's time zone.
            let step = TimeInterval(max(1, intervalHours) * 3_600)
            let base = cal.dateInterval(of: .day, for: date)?.start ?? date
            let elapsed = date.timeIntervalSince(base)
            let candidate = base.addingTimeInterval((floor(elapsed / step) + 1) * step)
            return candidate
        case .cron:
            return CronExpression(cron)?.next(after: date, calendar: cal)
        }
    }
}

/// A small cron: minute hour day-of-month month day-of-week, with *, lists, ranges and */step.
struct CronExpression: Equatable {
    var minutes: Set<Int>
    var hours: Set<Int>
    var days: Set<Int>
    var months: Set<Int>
    /// 0 = Sunday … 6 = Saturday (7 also means Sunday).
    var weekdays: Set<Int>
    var anyDay: Bool
    var anyWeekday: Bool

    init?(_ text: String) {
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5,
              let m = Self.field(fields[0], 0...59), let h = Self.field(fields[1], 0...23), let d = Self.field(fields[2], 1...31),
              let mo = Self.field(fields[3], 1...12), var w = Self.field(fields[4], 0...7) else { return nil }
        if w.contains(7) { w.remove(7); w.insert(0) }
        minutes = m; hours = h; days = d; months = mo; weekdays = w
        anyDay = fields[2] == "*"
        anyWeekday = fields[4] == "*"
    }

    static func field(_ text: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var values = Set<Int>()
        for part in text.split(separator: ",") {
            var body = String(part)
            var step = 1
            if let slash = body.firstIndex(of: "/") {
                guard let s = Int(body[body.index(after: slash)...]), s > 0 else { return nil }
                step = s
                body = String(body[..<slash])
            }
            var low = range.lowerBound, high = range.upperBound
            if body != "*" {
                let bounds = body.split(separator: "-").map { Int($0) }
                guard let first = bounds.first, let a = first, bounds.count <= 2 else { return nil }
                low = a
                high = bounds.count == 2 ? (bounds[1] ?? -1) : (step > 1 ? range.upperBound : a)
            }
            guard range.contains(low), range.contains(high), low <= high else { return nil }
            values.formUnion(stride(from: low, through: high, by: step))
        }
        return values.isEmpty ? nil : values
    }

    func next(after date: Date, calendar: Calendar) -> Date? {
        var day = calendar.startOfDay(for: date)
        for _ in 0..<(366 * 5) {
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            let dom = days.contains(parts.day ?? 0), dow = weekdays.contains((parts.weekday ?? 1) - 1)
            // Like cron: when both day fields are restricted, either may match.
            let dayMatches = anyDay && anyWeekday ? true : anyDay ? dow : anyWeekday ? dom : (dom || dow)
            if months.contains(parts.month ?? 0), dayMatches {
                for hour in hours.sorted() {
                    for minute in minutes.sorted() {
                        var wanted = parts
                        wanted.hour = hour
                        wanted.minute = minute
                        wanted.second = 0
                        wanted.weekday = nil
                        guard let candidate = calendar.date(from: wanted), candidate > date else { continue }
                        // Skip wall-clock times that don't exist that day (spring forward).
                        let back = calendar.dateComponents([.hour, .minute], from: candidate)
                        if back.hour == hour && back.minute == minute { return candidate }
                    }
                }
            }
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = tomorrow
        }
        return nil
    }
}

/// Decides what the scheduler does: run due jobs, and after a launch catch each missed job up once.
enum JobTiming {
    struct Plan: Equatable {
        var run: Bool
        var nextRun: Date?
    }

    /// For a job whose `nextRun` has passed: run it once and schedule the next occurrence after now
    /// (not after the missed time), so a Mac that slept for days doesn't fire a burst of runs.
    static func plan(nextRun: Date?, schedule: JobSchedule, enabled: Bool, now: Date) -> Plan {
        guard enabled else { return Plan(run: false, nextRun: nextRun) }
        guard let nextRun else { return Plan(run: false, nextRun: schedule.next(after: now)) }
        if nextRun <= now { return Plan(run: true, nextRun: schedule.next(after: now)) }
        return Plan(run: false, nextRun: nextRun)
    }
}

/// "every day at 9am", "weekdays at 8:30", "every 6 hours", "every monday at 10" → a schedule.
enum ScheduleParser {
    static func parse(_ text: String, timeZone: TimeZone = .current) -> JobSchedule? {
        let lower = text.lowercased()
        var schedule = JobSchedule()
        schedule.timeZoneID = timeZone.identifier
        if let match = lower.range(of: #"every\s+(\d{1,2})\s*(hours|hour|h)\b"#, options: .regularExpression) {
            let digits = lower[match].filter(\.isNumber)
            schedule.kind = .everyHours
            schedule.intervalHours = max(1, min(24, Int(digits) ?? 6))
            return schedule
        }
        if lower.contains("every hour") || lower.contains("hourly") { schedule.kind = .everyHours; schedule.intervalHours = 1; return schedule }
        let time = parseTime(lower) ?? (9, 0)
        schedule.hour = time.0
        schedule.minute = time.1
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let days = names.enumerated().filter { lower.contains($0.element) || lower.contains(String($0.element.prefix(3)) + " ") }.map { $0.offset + 1 }
        if lower.contains("weekday") {
            schedule.kind = .weekly
            schedule.weekdays = [2, 3, 4, 5, 6]
        } else if !days.isEmpty {
            schedule.kind = .weekly
            schedule.weekdays = Set(days)
        } else if lower.contains("every day") || lower.contains("daily") || lower.contains("each day") || lower.contains("every morning") || parseTime(lower) != nil {
            schedule.kind = .daily
        } else {
            return nil
        }
        return schedule
    }

    /// "9", "9am", "9:30", "21:15", "8.30 pm".
    static func parseTime(_ text: String) -> (Int, Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"\bat\s+(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(match.range(at: 1), in: text), var hour = Int(text[hourRange]) else { return nil }
        var minute = 0
        if let r = Range(match.range(at: 2), in: text) { minute = Int(text[r]) ?? 0 }
        if let r = Range(match.range(at: 3), in: text) {
            let suffix = text[r]
            if suffix == "pm", hour < 12 { hour += 12 }
            if suffix == "am", hour == 12 { hour = 0 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }
}
