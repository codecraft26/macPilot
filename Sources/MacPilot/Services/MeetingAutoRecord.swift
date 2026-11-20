import Foundation
import Observation
import SwiftData

/// Which calendar meetings MacPilot records by itself: ones you mark, every meeting in chosen calendars,
/// or all meetings (with per-meeting opt-out). Starts when the meeting begins and stops when it ends.
@Observable
@MainActor
final class MeetingAutoRecord {
    static let shared = MeetingAutoRecord()

    struct Rules: Equatable {
        var recordAll = false
        var calendars: Set<String> = []
        var marked: Set<String> = []
        var skipped: Set<String> = []
        /// With "all"/calendar rules, only events that look like meetings (attendees or a video link).
        var onlyRealMeetings = true
    }

    private(set) var rules: Rules
    /// Event ids that already have a recording (to show a "recorded" badge).
    private(set) var recordedEventIDs: Set<String> = []
    var stopAtEnd: Bool {
        get { UserDefaults.standard.object(forKey: Keys.stopAtEnd) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.stopAtEnd); bump() }
    }

    private var timer: Timer?
    /// "eventID@start" of meetings already started automatically, so a manual stop isn't undone.
    private var started: Set<String> = []
    private var autoStarted: (eventID: String, end: Date)?
    private var tick = 0

    private enum Keys {
        static let all = "autoRecord.all"
        static let calendars = "autoRecord.calendars"
        static let marked = "autoRecord.marked"
        static let skipped = "autoRecord.skipped"
        static let onlyMeetings = "autoRecord.onlyMeetings"
        static let stopAtEnd = "autoRecord.stopAtEnd"
    }

    private init() {
        let defaults = UserDefaults.standard
        rules = Rules(recordAll: defaults.bool(forKey: Keys.all),
                      calendars: Set(defaults.stringArray(forKey: Keys.calendars) ?? []),
                      marked: Set(defaults.stringArray(forKey: Keys.marked) ?? []),
                      skipped: Set(defaults.stringArray(forKey: Keys.skipped) ?? []),
                      onlyRealMeetings: defaults.object(forKey: Keys.onlyMeetings) as? Bool ?? true)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(rules.recordAll, forKey: Keys.all)
        defaults.set(Array(rules.calendars), forKey: Keys.calendars)
        defaults.set(Array(rules.marked), forKey: Keys.marked)
        defaults.set(Array(rules.skipped), forKey: Keys.skipped)
        defaults.set(rules.onlyRealMeetings, forKey: Keys.onlyMeetings)
    }

    private var revision = 0
    private func bump() { revision += 1 }

    // MARK: Rules

    func willRecord(_ event: CalendarEvent) -> Bool {
        _ = revision
        return Self.shouldRecord(event, rules: rules)
    }

    nonisolated static func looksLikeMeeting(_ event: CalendarEvent) -> Bool {
        !event.attendees.isEmpty || MeetingLink.find(in: [event.location, event.notes]) != nil
    }

    nonisolated static func shouldRecord(_ event: CalendarEvent, rules: Rules) -> Bool {
        guard !event.isAllDay else { return false }
        if rules.skipped.contains(event.id) { return false }
        if rules.marked.contains(event.id) { return true }
        let byRule = rules.recordAll || rules.calendars.contains(event.calendar.id)
        return byRule && (!rules.onlyRealMeetings || looksLikeMeeting(event))
    }

    /// Context-menu toggle: record this meeting (or not), whatever the general rules say.
    func setRecord(_ record: Bool, for event: CalendarEvent) {
        let byRule = Self.shouldRecord(event, rules: Rules(recordAll: rules.recordAll, calendars: rules.calendars,
                                                           onlyRealMeetings: rules.onlyRealMeetings))
        rules.marked.remove(event.id)
        rules.skipped.remove(event.id)
        if record && !byRule { rules.marked.insert(event.id) }
        if !record && byRule { rules.skipped.insert(event.id) }
        save()
    }

    func setRecordAll(_ on: Bool) { rules.recordAll = on; save() }
    func setOnlyRealMeetings(_ on: Bool) { rules.onlyRealMeetings = on; save() }

    func setCalendar(_ calendarID: String, record: Bool) {
        if record { rules.calendars.insert(calendarID) } else { rules.calendars.remove(calendarID) }
        save()
    }

    func records(calendarID: String) -> Bool { rules.calendars.contains(calendarID) }

    func wasRecorded(_ event: CalendarEvent) -> Bool { recordedEventIDs.contains(event.id) }

    // MARK: Engine

    func start() {
        timer?.invalidate()
        refreshRecorded()
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingAutoRecord.shared.check() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func refreshRecorded() {
        let recordings = (try? Persistence.container.mainContext.fetch(FetchDescriptor<Recording>())) ?? []
        recordedEventIDs = Set(recordings.compactMap(\.calendarEventID))
    }

    /// The meeting that should be recorded now, if any (from a minute before it starts until a minute before it ends).
    nonisolated static func meetingToStart(_ events: [CalendarEvent], rules: Rules, started: Set<String>, now: Date) -> CalendarEvent? {
        events
            .filter { $0.start.addingTimeInterval(-60) <= now && $0.end.addingTimeInterval(-60) > now }
            .filter { shouldRecord($0, rules: rules) && !started.contains(occurrence($0)) }
            .min { $0.start < $1.start }
    }

    nonisolated static func occurrence(_ event: CalendarEvent) -> String { "\(event.id)@\(Int(event.start.timeIntervalSince1970))" }

    private func check() {
        tick += 1
        if tick % 4 == 0 { refreshRecorded() }
        let now = Date()
        let recorder = RecordingManager.shared

        // Stop an automatic recording when its meeting ends.
        if let auto = autoStarted {
            if !recorder.isActive || recorder.current?.calendarEventID != auto.eventID {
                autoStarted = nil
            } else if stopAtEnd, now > auto.end.addingTimeInterval(60) {
                autoStarted = nil
                Task {
                    await recorder.stop()
                    NotchController.shared.peek(NotchPeek(systemImage: "stop.circle.fill", tint: .green,
                                                          title: "Meeting ended — recording saved", subtitle: "Transcribing now", duration: 6))
                }
                return
            }
        }

        guard !recorder.isActive else { return }
        let events = CalendarService.shared.events(on: now)
        guard let meeting = Self.meetingToStart(events, rules: rules, started: started, now: now) else { return }
        started.insert(Self.occurrence(meeting))
        autoStarted = (meeting.id, meeting.end)
        Task {
            await recorder.start(kind: .meeting, title: meeting.title, eventID: meeting.id, attendees: meeting.attendeeNames)
            NotchController.shared.peek(NotchPeek(systemImage: "record.circle", tint: .red, title: "Recording “\(meeting.title)”",
                                                  subtitle: stopAtEnd ? "Stops when the meeting ends" : "Started automatically", duration: 7))
            NotificationService.alert(id: "autorecord-\(meeting.id)", heading: "Recording “\(meeting.title)”",
                                      body: "Started automatically from your calendar. Stop it from the menu bar or ⌥R.", after: 1)
            refreshRecorded()
        }
    }
}
