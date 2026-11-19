import AppKit
import EventKit
import Foundation
import Observation

/// Apple Calendar through EventKit. MacPilot never writes to the calendar without the user confirming in the event editor.
@Observable
@MainActor
final class CalendarService {
    static let shared = CalendarService()

    let store = EKEventStore()
    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    /// Bumped whenever the calendar database changes, so views reload.
    private(set) var revision = 0
    private(set) var hiddenCalendarIDs: Set<String> = Prefs.hiddenCalendarIDs
    var lastError: String?

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.revision += 1 }
        }
    }

    var isAuthorized: Bool { status == .fullAccess }

    var isDenied: Bool { status == .denied || status == .restricted }

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

    var calendars: [EKCalendar] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var writableCalendars: [EKCalendar] { calendars.filter(\.allowsContentModifications) }

    func isVisible(_ calendar: EKCalendar) -> Bool { !hiddenCalendarIDs.contains(calendar.calendarIdentifier) }

    func setVisible(_ visible: Bool, _ calendar: EKCalendar) {
        if visible { hiddenCalendarIDs.remove(calendar.calendarIdentifier) } else { hiddenCalendarIDs.insert(calendar.calendarIdentifier) }
        Prefs.hiddenCalendarIDs = hiddenCalendarIDs
        revision += 1
    }

    // MARK: Events

    func events(from start: Date, to end: Date) -> [EKEvent] {
        guard isAuthorized else { return [] }
        let visible = calendars.filter(isVisible)
        guard !visible.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: visible)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func events(on day: Date) -> [EKEvent] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        return events(from: start, to: end)
    }

    /// Timed (not all-day) events that have not ended, soonest first.
    func upcoming(limit: Int = 5, withinDays days: Int = 7) -> [EKEvent] {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        return events(from: now, to: end).filter { !$0.isAllDay && $0.endDate > now }.prefix(limit).map { $0 }
    }

    /// An event in progress or starting within 10 minutes, used to name a new meeting recording.
    func currentOrImminentEvent() -> EKEvent? {
        let now = Date()
        return upcoming(limit: 10, withinDays: 1).first { $0.startDate <= now.addingTimeInterval(600) }
    }

    func event(withID id: String) -> EKEvent? {
        guard isAuthorized else { return nil }
        return store.calendarItem(withIdentifier: id) as? EKEvent
    }

    /// Other events overlapping the given time range.
    func conflicts(start: Date, end: Date, excluding id: String? = nil) -> [EKEvent] {
        let candidates = events(from: start.addingTimeInterval(-86_400), to: end.addingTimeInterval(86_400))
            .filter { !$0.isAllDay && $0.calendarItemIdentifier != id }
        let spans = candidates.map { EventSpan(id: $0.calendarItemIdentifier, start: $0.startDate, end: $0.endDate) }
        let ids = Set(EventSpan.overlapping(EventSpan(id: id ?? "", start: start, end: end), in: spans).map(\.id))
        return candidates.filter { ids.contains($0.calendarItemIdentifier) }
    }

    /// IDs of events that overlap another event in the list.
    func conflictingIDs(in events: [EKEvent]) -> Set<String> {
        EventSpan.conflictingIDs(events.filter { !$0.isAllDay }.map {
            EventSpan(id: $0.calendarItemIdentifier, start: $0.startDate, end: $0.endDate)
        })
    }

    func save(_ draft: EventDraft) throws {
        let event = draft.eventID.flatMap(event(withID:)) ?? EKEvent(eventStore: store)
        draft.apply(to: event, store: store)
        try store.save(event, span: .thisEvent, commit: true)
        revision += 1
    }

    func delete(_ event: EKEvent) throws {
        try store.remove(event, span: .thisEvent, commit: true)
        revision += 1
    }

    static func attendeeNames(_ event: EKEvent) -> String {
        (event.attendees ?? []).compactMap(\.name).joined(separator: ", ")
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

    init(_ event: EKEvent) {
        eventID = event.calendarItemIdentifier
        title = event.title ?? ""
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        location = event.location ?? ""
        notes = event.notes ?? ""
        calendarID = event.calendar?.calendarIdentifier
        if let offset = event.alarms?.first?.relativeOffset, offset <= 0 {
            alarmMinutes = Int(-offset / 60)
        }
    }

    func apply(to event: EKEvent, store: EKEventStore) {
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New event" : title
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(isAllDay ? 0 : 300))
        event.isAllDay = isAllDay
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        if let calendarID, let calendar = store.calendar(withIdentifier: calendarID) {
            event.calendar = calendar
        } else if event.calendar == nil {
            event.calendar = store.defaultCalendarForNewEvents
        }
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
