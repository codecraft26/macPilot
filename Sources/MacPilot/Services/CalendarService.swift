import AppKit
import EventKit
import Foundation
import Observation
import SwiftUI

enum CalendarSource: String, Hashable {
    case apple, google
}

struct RGBColor: Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    init(cgColor: CGColor?) {
        let converted = cgColor.flatMap { $0.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) }
        let components = converted?.components ?? [0.5, 0.5, 0.5]
        red = Double(components.count > 0 ? components[0] : 0.5)
        green = Double(components.count > 1 ? components[1] : 0.5)
        blue = Double(components.count > 2 ? components[2] : 0.5)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// A calendar from either Apple Calendar (EventKit) or Google Calendar.
struct CalendarInfo: Identifiable, Hashable {
    /// The source's own identifier.
    var rawID: String
    var source: CalendarSource
    var title: String
    var color: RGBColor
    var isWritable: Bool

    /// Unique across sources, e.g. "apple:<id>" or "google:<id>".
    var id: String { "\(source.rawValue):\(rawID)" }
}

/// An event from either source. Apple ids are EventKit `calendarItemIdentifier`s;
/// Google ids are "google:<calendar id>|<event id>".
struct CalendarEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String
    var notes: String
    var attendees: [String]
    var calendar: CalendarInfo
    var alarmMinutes: Int?

    var isEditable: Bool { calendar.isWritable }
    var attendeeNames: String { attendees.joined(separator: ", ") }
    var source: CalendarSource { calendar.source }
}

/// Apple Calendar (EventKit) and, optionally, Google Calendar behind one interface.
/// MacPilot never writes to a calendar without the user confirming in the event editor.
@Observable
@MainActor
final class CalendarService {
    static let shared = CalendarService()

    let store = EKEventStore()
    let google = GoogleCalendarService.shared
    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    /// Bumped whenever calendar data changes, so views reload.
    private(set) var revision = 0
    private(set) var hiddenCalendarIDs: Set<String> = Prefs.hiddenCalendarIDs
    var lastError: String?

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.revision += 1 }
        }
        google.onChange = { [weak self] in self?.revision += 1 }
    }

    /// Apple Calendar access.
    var isAuthorized: Bool { status == .fullAccess }
    var isDenied: Bool { status == .denied || status == .restricted }
    /// True when at least one source is available.
    var isConnected: Bool { isAuthorized || google.isConnected }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            lastError = error.localizedDescription
        }
        status = EKEventStore.authorizationStatus(for: .event)
        revision += 1
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Calendars

    private var appleCalendars: [EKCalendar] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
    }

    private static func info(_ calendar: EKCalendar) -> CalendarInfo {
        CalendarInfo(
            rawID: calendar.calendarIdentifier,
            source: .apple,
            title: calendar.title,
            color: RGBColor(cgColor: calendar.cgColor),
            isWritable: calendar.allowsContentModifications
        )
    }

    var calendars: [CalendarInfo] {
        let apple = appleCalendars.map(Self.info)
        return (apple + google.calendars).sorted {
            if $0.source != $1.source { return $0.source == .apple }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    var writableCalendars: [CalendarInfo] { calendars.filter(\.isWritable) }

    var defaultCalendarID: String? {
        if let apple = store.defaultCalendarForNewEvents, isAuthorized { return Self.info(apple).id }
        return writableCalendars.first?.id
    }

    func isVisible(_ calendar: CalendarInfo) -> Bool {
        // Apple calendars were stored by raw id before Google support; accept both.
        !hiddenCalendarIDs.contains(calendar.id) && !hiddenCalendarIDs.contains(calendar.rawID)
    }

    func setVisible(_ visible: Bool, _ calendar: CalendarInfo) {
        if visible {
            hiddenCalendarIDs.remove(calendar.id)
            hiddenCalendarIDs.remove(calendar.rawID)
        } else {
            hiddenCalendarIDs.insert(calendar.id)
        }
        Prefs.hiddenCalendarIDs = hiddenCalendarIDs
        revision += 1
        if visible && calendar.source == .google {
            let start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
            let end = Calendar.current.date(byAdding: .month, value: 2, to: Date()) ?? Date()
            Task { await refresh(from: start, to: end) }
        }
    }

    // MARK: Events

    private static func event(_ event: EKEvent) -> CalendarEvent {
        var alarm: Int?
        if let offset = event.alarms?.first?.relativeOffset, offset <= 0 { alarm = Int(-offset / 60) }
        return CalendarEvent(
            id: event.calendarItemIdentifier,
            title: event.title ?? "Event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location ?? "",
            notes: event.notes ?? "",
            attendees: (event.attendees ?? []).compactMap(\.name),
            calendar: info(event.calendar),
            alarmMinutes: alarm
        )
    }

    /// Fetches Google events for the range (Apple events are read live from EventKit).
    func refresh(from start: Date, to end: Date) async {
        await google.load(from: start, to: end, visible: isVisible)
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        let visibleApple = appleCalendars.filter { isVisible(Self.info($0)) }
        if !visibleApple.isEmpty {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: visibleApple)
            result += store.events(matching: predicate).map(Self.event)
        }
        result += google.events(from: start, to: end).filter { isVisible($0.calendar) }
        return result.sorted { $0.start < $1.start }
    }

    func events(on day: Date) -> [CalendarEvent] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        return events(from: start, to: end)
    }

    /// Timed (not all-day) events that have not ended, soonest first.
    func upcoming(limit: Int = 5, withinDays days: Int = 7) -> [CalendarEvent] {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        return Array(events(from: now, to: end).filter { !$0.isAllDay && $0.end > now }.prefix(limit))
    }

    /// An event in progress or starting within 10 minutes, used to name a new meeting recording.
    func currentOrImminentEvent() -> CalendarEvent? {
        let now = Date()
        return upcoming(limit: 10, withinDays: 1).first { $0.start <= now.addingTimeInterval(600) }
    }

    func event(withID id: String) -> CalendarEvent? {
        if id.hasPrefix(GoogleMapping.idPrefix) { return google.event(withID: id) }
        guard isAuthorized, let event = store.calendarItem(withIdentifier: id) as? EKEvent else { return nil }
        return Self.event(event)
    }

    /// Other events overlapping the given time range.
    func conflicts(start: Date, end: Date, excluding id: String? = nil) -> [CalendarEvent] {
        let candidates = events(from: start.addingTimeInterval(-86_400), to: end.addingTimeInterval(86_400))
            .filter { !$0.isAllDay && $0.id != id }
        let spans = candidates.map { EventSpan(id: $0.id, start: $0.start, end: $0.end) }
        let ids = Set(EventSpan.overlapping(EventSpan(id: id ?? "", start: start, end: end), in: spans).map(\.id))
        return candidates.filter { ids.contains($0.id) }
    }

    /// IDs of events that overlap another event in the list.
    func conflictingIDs(in events: [CalendarEvent]) -> Set<String> {
        EventSpan.conflictingIDs(events.filter { !$0.isAllDay }.map { EventSpan(id: $0.id, start: $0.start, end: $0.end) })
    }

    func save(_ draft: EventDraft) async throws {
        guard let target = draft.calendarID.flatMap({ id in calendars.first { $0.id == id } })
                ?? defaultCalendarID.flatMap({ id in calendars.first { $0.id == id } }) else {
            throw GoogleCalendarError.notConnected
        }
        let existing = draft.eventID.flatMap(event(withID:))
        switch target.source {
        case .apple:
            if let existing, existing.source == .google { try await google.delete(existing) }
            let ekEvent = (existing?.source == .apple ? draft.eventID.flatMap { store.calendarItem(withIdentifier: $0) as? EKEvent } : nil)
                ?? EKEvent(eventStore: store)
            draft.apply(to: ekEvent, calendar: store.calendar(withIdentifier: target.rawID) ?? store.defaultCalendarForNewEvents)
            try store.save(ekEvent, span: .thisEvent, commit: true)
        case .google:
            if let existing, existing.source == .apple, let ekEvent = store.calendarItem(withIdentifier: existing.id) as? EKEvent {
                var copy = draft
                copy.eventID = nil
                try await google.save(copy, calendarRawID: target.rawID)
                try store.remove(ekEvent, span: .thisEvent, commit: true)
            } else {
                try await google.save(draft, calendarRawID: target.rawID)
            }
            await refresh(from: draft.start.addingTimeInterval(-86_400), to: draft.end.addingTimeInterval(86_400))
        }
        revision += 1
    }

    func delete(_ event: CalendarEvent) async throws {
        switch event.source {
        case .apple:
            guard let ekEvent = store.calendarItem(withIdentifier: event.id) as? EKEvent else { return }
            try store.remove(ekEvent, span: .thisEvent, commit: true)
        case .google:
            try await google.delete(event)
        }
        revision += 1
    }
}

/// A plain time range used for overlap checks (testable without EventKit).
struct EventSpan: Equatable {
    var id: String
    var start: Date
    var end: Date

    func overlaps(_ other: EventSpan) -> Bool {
        start < other.end && other.start < end
    }

    static func overlapping(_ span: EventSpan, in spans: [EventSpan]) -> [EventSpan] {
        spans.filter { $0.id != span.id && span.overlaps($0) }
    }

    static func conflictingIDs(_ spans: [EventSpan]) -> Set<String> {
        let sorted = spans.sorted { $0.start < $1.start }
        var result: Set<String> = []
        for (index, span) in sorted.enumerated() {
            for other in sorted[(index + 1)...] {
                if other.start >= span.end { break }
                if span.overlaps(other) {
                    result.insert(span.id)
                    result.insert(other.id)
                }
            }
        }
        return result
    }
}

/// Editable values for a new or existing event. Nothing is saved until the user confirms.
struct EventDraft: Equatable {
    var eventID: String?
    var title = ""
    var start = Date()
    var end = Date().addingTimeInterval(3600)
    var isAllDay = false
    var location = ""
    var notes = ""
    /// `CalendarInfo.id` of the target calendar; nil means the default calendar.
    var calendarID: String?
    /// Minutes before the start; nil means no alert.
    var alarmMinutes: Int?

    static func new(at start: Date) -> EventDraft {
        var draft = EventDraft()
        draft.start = start
        draft.end = start.addingTimeInterval(3600)
        let minutes = Prefs.defaultEventAlarmMinutes
        draft.alarmMinutes = minutes > 0 ? minutes : nil
        return draft
    }

    init() {}

    init(_ event: CalendarEvent) {
        eventID = event.id
        title = event.title
        start = event.start
        end = event.end
        isAllDay = event.isAllDay
        location = event.location
        notes = event.notes
        calendarID = event.calendar.id
        alarmMinutes = event.alarmMinutes
    }

    func apply(to event: EKEvent, calendar: EKCalendar?) {
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New event" : title
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(isAllDay ? 0 : 300))
        event.isAllDay = isAllDay
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        if let calendar { event.calendar = calendar }
        event.alarms = alarmMinutes.map { [EKAlarm(relativeOffset: TimeInterval(-$0 * 60))] }
    }
}

/// Natural-language quick add ("Lunch with Sam tomorrow at 1 for an hour").
enum EventQuickAdd {
    static func prompt(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return """
        Current date and time: \(formatter.string(from: now)) (\(timeZone.identifier)), \(now.formatted(.dateTime.weekday(.wide))).
        Turn this request into a calendar event. Reply with one JSON object only:
        {"title": "...", "start": "ISO 8601 with offset", "end": "ISO 8601 with offset", "all_day": false, "location": "", "notes": ""}
        If no duration is given use 30 minutes; if no time is given for a meeting pick 09:00.

        Request: \(text)
        """
    }

    static func parse(_ reply: String, fallbackStart: Date = Date()) -> EventDraft? {
        guard let data = JSONExtraction.object(in: reply),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let start = (object["start"] as? String).flatMap(date) else { return nil }
        var draft = EventDraft.new(at: start)
        draft.title = (object["title"] as? String) ?? ""
        draft.end = (object["end"] as? String).flatMap(date) ?? start.addingTimeInterval(1800)
        if draft.end <= start { draft.end = start.addingTimeInterval(1800) }
        draft.isAllDay = object["all_day"] as? Bool ?? false
        draft.location = object["location"] as? String ?? ""
        draft.notes = object["notes"] as? String ?? ""
        return draft
    }

    /// Local fallback when no AI provider is available: NSDataDetector for the date, the rest becomes the title.
    static func localParse(_ text: String) -> EventDraft? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let start = match.date else { return nil }
        var draft = EventDraft.new(at: start)
        draft.end = start.addingTimeInterval(match.duration > 0 ? match.duration : 1800)
        var title = text
        if let range = Range(match.range, in: text) { title.removeSubrange(range) }
        draft.title = title
            .replacingOccurrences(of: #"\s+(at|on|from)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return draft
    }

    static func draft(from text: String) async -> (EventDraft?, String?) {
        do {
            let reply = try await AIRouter.complete(
                provider: Prefs.analysisProvider,
                system: "You convert requests into calendar events. Reply with JSON only.",
                prompt: prompt(text)
            )
            if let draft = parse(reply) { return (draft, nil) }
        } catch {
            if let local = localParse(text) {
                return (local, "AI was unavailable (\(AIError.describe(error))), so the date was read on this Mac. Check the details.")
            }
            return (nil, AIError.describe(error))
        }
        if let local = localParse(text) { return (local, "Check the details before saving.") }
        return (nil, "MacPilot could not find a date in that request.")
    }

    static func date(_ string: String) -> Date? {
        let withOffset = ISO8601DateFormatter()
        withOffset.formatOptions = [.withInternetDateTime]
        if let date = withOffset.date(from: string) { return date }
        withOffset.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withOffset.date(from: string) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: string) { return date }
        }
        return nil
    }
}
