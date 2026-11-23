import Foundation
import Observation
import SwiftData

/// Which calendar meetings MacPilot records by itself: ones you mark, every meeting in chosen calendars,
/// or all meetings (with per-meeting opt-out). Starts when the meeting begins and stops when it ends.
@Observable
@MainActor
final class MeetingAutoRecord {
    static let shared = MeetingAutoRecord()

    /// The general rule; individual meetings can still be switched on or off.
    enum Mode: String, CaseIterable, Identifiable {
        case off, all, videoLink, calendars
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off (only meetings I mark)"
            case .all: return "All meetings"
            case .videoLink: return "Meetings with a video link"
            case .calendars: return "Meetings in selected calendars"
            }
        }
    }

    struct Rules: Equatable {
        var mode: Mode = .off
        var calendars: Set<String> = []
        var marked: Set<String> = []
        var skipped: Set<String> = []
        /// With "all"/calendar rules, only events that look like meetings (attendees or a video link).
        var onlyRealMeetings = true

        var isActive: Bool { mode != .off || !marked.isEmpty }
    }

    private(set) var rules: Rules
    /// Event ids that already have a recording (to show a "recorded" badge).
    private(set) var recordedEventIDs: Set<String> = []
    var stopAtEnd: Bool {
        get { _ = revision; return UserDefaults.standard.object(forKey: Keys.stopAtEnd) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.stopAtEnd); bump() }
    }
    /// Show a reminder to tell attendees they're being recorded (on by default; it's often required).
    var remindToTell: Bool {
        get { _ = revision; return UserDefaults.standard.object(forKey: Keys.remindToTell) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.remindToTell); bump() }
    }

    private var timer: Timer?
    /// "eventID@start" of meetings already started automatically, so a manual stop isn't undone.
    private var started: Set<String> = []
    private var autoStarted: (eventID: String, end: Date)?
    private var tick = 0

    private enum Keys {
        static let all = "autoRecord.all"
        static let mode = "autoRecord.mode"
        static let remindToTell = "autoRecord.remindToTell"
        static let calendars = "autoRecord.calendars"
        static let marked = "autoRecord.marked"
        static let skipped = "autoRecord.skipped"
        static let onlyMeetings = "autoRecord.onlyMeetings"
        static let stopAtEnd = "autoRecord.stopAtEnd"
    }

    private init() {
        let defaults = UserDefaults.standard
        rules = Rules(mode: Self.storedMode(defaults),
                      calendars: Set(defaults.stringArray(forKey: Keys.calendars) ?? []),
                      marked: Set(defaults.stringArray(forKey: Keys.marked) ?? []),
                      skipped: Set(defaults.stringArray(forKey: Keys.skipped) ?? []),
                      onlyRealMeetings: defaults.object(forKey: Keys.onlyMeetings) as? Bool ?? true)
    }

    /// The mode, migrating 0.20's "record all" flag and calendar list.
    private static func storedMode(_ defaults: UserDefaults) -> Mode {
        if let raw = defaults.string(forKey: Keys.mode), let mode = Mode(rawValue: raw) { return mode }
        if defaults.bool(forKey: Keys.all) { return .all }
        return (defaults.stringArray(forKey: Keys.calendars) ?? []).isEmpty ? .off : .calendars
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(rules.mode.rawValue, forKey: Keys.mode)
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
        switch rules.mode {
        case .off: return false
        case .videoLink: return MeetingLink.find(in: [event.location, event.notes]) != nil
        case .all: return !rules.onlyRealMeetings || looksLikeMeeting(event)
        case .calendars: return rules.calendars.contains(event.calendar.id) && (!rules.onlyRealMeetings || looksLikeMeeting(event))
        }
    }

    /// Context-menu toggle: record this meeting (or not), whatever the general rules say.
    func setRecord(_ record: Bool, for event: CalendarEvent) {
        let byRule = Self.shouldRecord(event, rules: Rules(mode: rules.mode, calendars: rules.calendars,
                                                           onlyRealMeetings: rules.onlyRealMeetings))
        rules.marked.remove(event.id)
        rules.skipped.remove(event.id)
        if record && !byRule { rules.marked.insert(event.id) }
        if !record && byRule { rules.skipped.insert(event.id) }
        save()
    }

    func setMode(_ mode: Mode) { rules.mode = mode; save() }
    func setOnlyRealMeetings(_ on: Bool) { rules.onlyRealMeetings = on; save() }

    func setCalendar(_ calendarID: String, record: Bool) {
        if record { rules.calendars.insert(calendarID) } else { rules.calendars.remove(calendarID) }
        if record { rules.mode = .calendars }
        save()
    }

    func records(calendarID: String) -> Bool { rules.calendars.contains(calendarID) }

    func wasRecorded(_ event: CalendarEvent) -> Bool { recordedEventIDs.contains(event.id) }

    /// The most recent recording made for this event, for the Recording / Transcript / Summary links.
    func recording(for event: CalendarEvent) -> Recording? {
        let id: String? = event.id
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.calendarEventID == id },
                                                    sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? Persistence.container.mainContext.fetch(descriptor).first
    }

    /// Opens the event's recording in Calendar & Meetings, on the given tab ("Summary", "Transcript").
    func openRecording(for event: CalendarEvent, tab: String? = nil) {
        guard let recording = recording(for: event) else { return }
        AppState.shared.pendingRecordingTab = tab
        WindowManager.shared.open(.calendar, action: .openRecording(recording.uid))
    }

    /// Filters to events that have a recording (the "Recorded" filter).
    func recordedOnly(_ events: [CalendarEvent]) -> [CalendarEvent] {
        Self.recorded(events, ids: recordedEventIDs)
    }

    nonisolated static func recorded(_ events: [CalendarEvent], ids: Set<String>) -> [CalendarEvent] {
        events.filter { ids.contains($0.id) }
    }

    /// Text for the "recording started" alert.
    nonisolated static func startMessage(for event: CalendarEvent, remindToTell: Bool, stopAtEnd: Bool) -> String {
        if remindToTell && !event.attendees.isEmpty { return "Let attendees know this meeting is being recorded" }
        if remindToTell { return "Remember to tell others in the call it's recorded" }
        return stopAtEnd ? "Stops when the meeting ends" : "Started automatically"
    }

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
            let message = Self.startMessage(for: meeting, remindToTell: remindToTell, stopAtEnd: stopAtEnd)
            NotchController.shared.peek(NotchPeek(systemImage: "record.circle", tint: .red, title: "Recording “\(meeting.title)”",
                                                  subtitle: message, duration: 12,
                                                  buttonTitle: "Stop", buttonAction: .stopRecording))
            NotificationService.alert(id: "autorecord-\(meeting.id)", heading: "Recording “\(meeting.title)”",
                                      body: (remindToTell ? message + ". " : "") + "Started automatically from your calendar. Stop it from the notch, the menu bar or ⌥R.", after: 1)
            refreshRecorded()
        }
    }
}
