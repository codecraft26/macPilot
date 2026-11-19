import EventKit
import Foundation
import Observation
import SwiftData

/// The fields both sides share, normalized so the same task always produces the same fingerprint.
struct ReminderFields: Equatable {
    var title: String
    var notes: String
    var due: Date?
    var priority: TaskPriority
    var completed: Bool

    var fingerprint: String {
        let dueMinutes = due.map { String(Int(($0.timeIntervalSince1970 / 60).rounded())) } ?? "-"
        return [title.trimmingCharacters(in: .whitespacesAndNewlines), notes.trimmingCharacters(in: .whitespacesAndNewlines),
                dueMinutes, String(priority.rawValue), completed ? "1" : "0"].joined(separator: "\u{1f}")
    }

    /// EventKit priority: 1 high … 5 medium … 9 low, 0 none.
    static func ekPriority(_ priority: TaskPriority) -> Int {
        switch priority {
        case .none: return 0
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }

    static func taskPriority(_ value: Int) -> TaskPriority {
        switch value {
        case 1...4: return .high
        case 5: return .medium
        case 6...9: return .low
        default: return .none
        }
    }
}

/// What a sync should do for a linked task/reminder pair.
enum ReminderMergeDecision: Equatable {
    case none, pushToReminder, pullFromReminder, merge
    case reminderDeleted, recreateReminder

    /// `stored` is the fingerprint saved at the last sync; `remote` is nil when the reminder no longer exists.
    static func decide(local: String, remote: String?, stored: String?) -> ReminderMergeDecision {
        guard let remote else {
            // Deleted in Reminders: follow that unless the task changed here since the last sync.
            return local == stored ? .reminderDeleted : .recreateReminder
        }
        let localChanged = local != stored
        let remoteChanged = remote != stored
        switch (localChanged, remoteChanged) {
        case (false, false): return local == remote ? .none : .pullFromReminder
        case (true, false): return .pushToReminder
        case (false, true): return .pullFromReminder
        case (true, true): return local == remote ? .none : .merge
        }
    }
}

/// Two-way sync between MacPilot tasks and one Apple Reminders list (default "MacPilot").
@Observable
@MainActor
final class ReminderSync {
    static let shared = ReminderSync()

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastSummary: String?
    private(set) var lastError: String?

    private var store: EKEventStore { CalendarService.shared.store }
    private var pending: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var saveObserver: NSObjectProtocol?
    private var timer: Timer?
    private static let deletedKey = "reminders.deletedIDs"

    private init() {}

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.remindersSync) }

    static var listName: String {
        let value = (UserDefaults.standard.string(forKey: PrefKey.remindersListName) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "MacPilot" : value
    }

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Starts listening for changes (call at launch); syncs right away when enabled.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in ReminderSync.shared.scheduleSync(after: 3) }
        }
        // Any task saved anywhere in MacPilot (editor, dictation, meetings, launcher) triggers a sync.
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard !ReminderSync.shared.isSyncing else { return }
                ReminderSync.shared.scheduleSync(after: 2)
            }
        }
        let timer = Timer(timeInterval: 300, repeats: true) { _ in
            Task { @MainActor in ReminderSync.shared.scheduleSync(after: 0) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduleSync(after: 2)
    }

    /// Coalesces bursts of edits into one sync.
    func scheduleSync(after seconds: Double = 2) {
        guard Self.isEnabled, isAuthorized else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            lastError = error.localizedDescription
        }
        return isAuthorized
    }

    /// Remember a deleted task so its reminder is removed at the next sync.
    static func noteDeleted(_ task: TaskItem) {
        guard let id = task.reminderID else { return }
        var ids = UserDefaults.standard.stringArray(forKey: deletedKey) ?? []
        ids.append(id)
        UserDefaults.standard.set(ids, forKey: deletedKey)
        shared.scheduleSync()
    }

    // MARK: Sync

    func sync() async {
        guard Self.isEnabled, !isSyncing else { return }
        guard await requestAccess() else {
            lastError = "MacPilot has no access to Reminders. Allow it in System Settings → Privacy & Security → Reminders."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let list = try reminderList()
            let reminders = await fetchReminders(in: list)
            let summary = try apply(reminders: reminders, list: list)
            lastSummary = summary
            lastError = nil
            lastSync = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reminderList() throws -> EKCalendar {
        let name = Self.listName
        if let id = UserDefaults.standard.string(forKey: PrefKey.remindersListID),
           let list = store.calendar(withIdentifier: id), list.title == name {
            return list
        }
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == name }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: PrefKey.remindersListID)
            return existing
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = name
        list.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .calDAV || $0.sourceType == .local }
        try store.saveCalendar(list, commit: true)
        UserDefaults.standard.set(list.calendarIdentifier, forKey: PrefKey.remindersListID)
        return list
    }

    private func fetchReminders(in list: EKCalendar) async -> [EKReminder] {
        let predicate = store.predicateForReminders(in: [list])
        let box = await withCheckedContinuation { (continuation: CheckedContinuation<ReminderBox, Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: ReminderBox(reminders ?? []))
            }
        }
        return box.reminders
    }

    private func apply(reminders: [EKReminder], list: EKCalendar) throws -> String {
        let context = Persistence.container.mainContext
        var byID = Dictionary(reminders.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var pushed = 0, pulled = 0, created = 0, imported = 0, removed = 0

        // Reminders for tasks deleted in MacPilot.
        let deleted = UserDefaults.standard.stringArray(forKey: Self.deletedKey) ?? []
        for id in deleted {
            if let reminder = byID.removeValue(forKey: id) {
                try store.remove(reminder, commit: false)
                removed += 1
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.deletedKey)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        // Tasks that arrived from another Mac through iCloud sync carry the reminder's cross-device id:
        // link them to the same reminder here instead of creating a second one.
        var byExternalID: [String: EKReminder] = [:]
        for reminder in byID.values {
            if let external = reminder.calendarItemExternalIdentifier { byExternalID[external] = reminder }
        }
        for task in tasks where task.reminderID == nil {
            guard let external = task.reminderExternalID else { continue }
            if let reminder = byExternalID[external] {
                task.reminderID = reminder.calendarItemIdentifier
                task.reminderFingerprint = fields(of: reminder).fingerprint
            }
        }
        let linkedExternalIDs = Set(tasks.compactMap(\.reminderExternalID))
        for task in tasks {
            if let id = task.reminderID {
                let reminder = byID.removeValue(forKey: id)
                let decision = ReminderMergeDecision.decide(local: fields(of: task).fingerprint,
                                                            remote: reminder.map { fields(of: $0).fingerprint },
                                                            stored: task.reminderFingerprint)
                switch decision {
                case .none:
                    break
                case .pushToReminder:
                    if let reminder { write(task, to: reminder); try store.save(reminder, commit: false); pushed += 1 }
                case .pullFromReminder:
                    if let reminder { read(reminder, into: task, context: context); pulled += 1 }
                case .merge:
                    if let reminder {
                        // Both changed: keep this Mac's edits, but a completion on either side wins.
                        let completed = task.isCompleted || reminder.isCompleted
                        if completed && !task.isCompleted { TaskActions.toggle(task, context: context, sync: false) }
                        write(task, to: reminder)
                        try store.save(reminder, commit: false)
                        pushed += 1
                    }
                case .reminderDeleted:
                    NotificationService.cancel(id: task.notificationID)
                    context.delete(task)
                    removed += 1
                    continue
                case .recreateReminder:
                    try create(for: task, in: list)
                    created += 1
                    continue
                }
                if let reminder {
                    task.reminderFingerprint = fields(of: reminder).fingerprint
                    task.reminderExternalID = reminder.calendarItemExternalIdentifier
                }
            } else if task.reminderExternalID != nil {
                // Synced from another Mac; its reminder hasn't reached this Mac yet. Link it on a later sync.
                continue
            } else if !task.isCompleted {
                try create(for: task, in: list)
                created += 1
            }
        }

        // New reminders made in the Reminders app.
        for reminder in byID.values where !reminder.isCompleted
            && !(reminder.calendarItemExternalIdentifier.map(linkedExternalIDs.contains) ?? false) {
            let fields = fields(of: reminder)
            let task = TaskItem(title: fields.title, dueDate: fields.due, priority: fields.priority, category: "Reminders")
            task.notes = fields.notes
            task.reminderID = reminder.calendarItemIdentifier
            task.reminderExternalID = reminder.calendarItemExternalIdentifier
            task.reminderFingerprint = fields.fingerprint
            context.insert(task)
            NotificationService.schedule(id: task.notificationID, title: task.title, at: task.dueDate)
            imported += 1
        }

        // Only write when something changed, so our own saves don't trigger endless follow-up syncs.
        if pushed + created + removed > 0 || !deleted.isEmpty { try store.commit() }
        if context.hasChanges { try context.save() }
        let parts = [(created, "added to Reminders"), (pushed, "updated in Reminders"), (pulled, "updated from Reminders"),
                     (imported, "imported"), (removed, "removed")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "Everything is in sync." : parts.joined(separator: ", ")
    }

    // MARK: Mapping

    func fields(of task: TaskItem) -> ReminderFields {
        ReminderFields(title: task.title, notes: task.notes, due: task.dueDate, priority: task.priority, completed: task.isCompleted)
    }

    func fields(of reminder: EKReminder) -> ReminderFields {
        let due = reminder.dueDateComponents.flatMap { components -> Date? in
            var components = components
            if components.calendar == nil { components.calendar = Calendar.current }
            return components.date
        }
        return ReminderFields(title: reminder.title ?? "", notes: reminder.notes ?? "", due: due,
                              priority: ReminderFields.taskPriority(reminder.priority), completed: reminder.isCompleted)
    }

    private func create(for task: TaskItem, in list: EKCalendar) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        write(task, to: reminder)
        try store.save(reminder, commit: false)
        task.reminderID = reminder.calendarItemIdentifier
        task.reminderExternalID = reminder.calendarItemExternalIdentifier
        task.reminderFingerprint = fields(of: task).fingerprint
    }

    private func write(_ task: TaskItem, to reminder: EKReminder) {
        reminder.title = task.title
        reminder.notes = task.notes.isEmpty ? nil : task.notes
        reminder.priority = ReminderFields.ekPriority(task.priority)
        if let due = task.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        } else {
            reminder.dueDateComponents = nil
        }
        reminder.isCompleted = task.isCompleted
    }

    private func read(_ reminder: EKReminder, into task: TaskItem, context: ModelContext) {
        let remote = fields(of: reminder)
        task.title = remote.title
        task.notes = remote.notes
        task.priority = remote.priority
        if task.dueDate != remote.due {
            task.dueDate = remote.due
            NotificationService.schedule(id: task.notificationID, title: task.title, at: task.isCompleted ? nil : remote.due)
        }
        if remote.completed != task.isCompleted {
            TaskActions.toggle(task, context: context, sync: false)
        }
    }
}

/// Carries EventKit objects out of the fetch callback.
private struct ReminderBox: @unchecked Sendable {
    let reminders: [EKReminder]
    init(_ reminders: [EKReminder]) { self.reminders = reminders }
}
