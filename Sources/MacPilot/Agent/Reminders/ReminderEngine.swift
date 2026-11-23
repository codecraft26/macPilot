import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import Observation
import SwiftData
@preconcurrency import UserNotifications

/// Watches for reminder triggers (apps, Wi-Fi, wake/unlock, places, meetings, time) and delivers
/// reminders by notification, notch and Telegram. Location and Wi-Fi names stay on this Mac.
@Observable
@MainActor
final class ReminderEngine: NSObject {
    static let shared = ReminderEngine(context: Persistence.container.mainContext)

    let context: ModelContext
    var now: () -> Date = Date.init
    /// Delivery hooks (replaced in tests).
    var deliver: (SmartReminder, String) -> Void = { reminder, context in ReminderEngine.defaultDeliver(reminder, context: context) }
    var upcomingEvents: () -> [CalendarEvent] = { CalendarService.shared.upcoming(limit: 5, withinDays: 1) }
    private(set) var currentSSID: String?
    private(set) var wifiNeedsLocation = false
    private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    private var timer: Timer?
    private var wifiTimer: Timer?
    private var started = false
    private let location = CLLocationManager()
    private var insidePlaces: Set<String> = []
    private let placesKey = "reminders.places"
    private(set) var revision = 0

    static let categoryID = "SMART_REMINDER"
    static let snoozeAction = "SNOOZE_10", nextAction = "SNOOZE_NEXT", doneAction = "DONE"

    init(context: ModelContext) {
        self.context = context
        super.init()
    }

    // MARK: Store

    var reminders: [SmartReminder] {
        (try? context.fetch(FetchDescriptor<SmartReminder>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    @discardableResult
    func add(_ draft: ReminderDraft, source: String, syncToReminders: Bool = false) -> SmartReminder {
        let reminder = SmartReminder(text: draft.text, trigger: draft.trigger, conditions: draft.conditions, repeatMode: draft.repeatMode,
                                     cooldownMinutes: draft.cooldownMinutes, sourceText: String(source.prefix(300)))
        if case let .time(at, _) = draft.trigger { reminder.nextFire = at }
        reminder.syncToReminders = syncToReminders
        context.insert(reminder)
        if syncToReminders { mirrorAsTask(reminder) }
        save()
        return reminder
    }

    func delete(_ reminder: SmartReminder) {
        context.delete(reminder)
        save()
    }

    func find(_ shortID: String) -> SmartReminder? {
        let id = shortID.lowercased()
        return reminders.first { $0.shortID.hasPrefix(id) || $0.uid.uuidString.lowercased() == id }
    }

    private func save() {
        try? context.save()
        revision += 1
    }

    /// The existing Reminders sync picks up tasks; a smart reminder can mirror itself as one.
    private func mirrorAsTask(_ reminder: SmartReminder) {
        var due: Date?
        if case let .time(at, _) = reminder.trigger { due = at }
        let task = TaskItem(title: reminder.text, dueDate: due)
        task.notes = "Smart reminder: \(reminder.trigger.summary)"
        context.insert(task)
        reminder.taskUID = task.uid
        ReminderSync.shared.scheduleSync()
    }

    // MARK: Places (local only)

    var places: [SavedPlace] {
        get { (UserDefaults.standard.data(forKey: placesKey)).flatMap { try? JSONDecoder().decode([SavedPlace].self, from: $0) } ?? [] }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: placesKey)
            revision += 1
            monitorPlaces()
        }
    }

    /// Saves the Mac's current location as a place (asks for Location permission if needed).
    func saveCurrentLocation(as name: String) {
        pendingPlaceName = name
        location.requestLocation()
    }
    private var pendingPlaceName: String?

    // MARK: Monitoring

    func start() {
        guard !started else { return }
        started = true
        location.delegate = self
        locationStatus = location.authorizationStatus
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { ReminderEngine.shared.handle(.appOpened(name: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "")) }
        }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { ReminderEngine.shared.handle(.appOpened(name: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "")) }
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { ReminderEngine.shared.handle(.appQuit(name: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "")) }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ReminderEngine.shared.handle(.wake) }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ReminderEngine.shared.handle(.unlock) }
        }
        currentSSID = Self.readSSID()
        let wifiTimer = Timer(timeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { ReminderEngine.shared.pollWiFi() }
        }
        wifiTimer.tolerance = 5
        RunLoop.main.add(wifiTimer, forMode: .common)
        self.wifiTimer = wifiTimer
        let timer = Timer(timeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { ReminderEngine.shared.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        setUpNotificationActions()
        monitorPlaces()
        tick()
    }

    /// Wi-Fi names need Location permission on recent macOS; without it the SSID reads as nil.
    nonisolated static func readSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    func requestLocationPermission() {
        location.requestWhenInUseAuthorization()
    }

    private func pollWiFi() {
        let ssid = Self.readSSID()
        wifiNeedsLocation = ssid == nil && CWWiFiClient.shared().interface()?.powerOn() == true && location.authorizationStatus != .authorizedAlways
        guard ssid != currentSSID else { return }
        let old = currentSSID
        currentSSID = ssid
        handle(.wifiChanged(from: old, to: ssid))
        // Places defined by a Wi-Fi network.
        for place in places {
            guard let wanted = place.ssid else { continue }
            if ssid == wanted, old != wanted { handle(.entered(place: place.name)) }
            if old == wanted, ssid != wanted { handle(.exited(place: place.name)) }
        }
    }

    private func monitorPlaces() {
        for region in location.monitoredRegions { location.stopMonitoring(for: region) }
        let geo = places.filter { $0.latitude != nil && $0.longitude != nil }
        guard !geo.isEmpty else { return }
        if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            for place in geo {
                let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: place.latitude!, longitude: place.longitude!),
                                              radius: max(100, place.radius), identifier: place.name)
                region.notifyOnEntry = true
                region.notifyOnExit = true
                location.startMonitoring(for: region)
            }
        } else {
            location.startMonitoringSignificantLocationChanges()
        }
    }

    /// Feeds a location fix (significant-change fallback): entering/leaving each saved place.
    func locationChanged(_ coordinate: CLLocationCoordinate2D) {
        for place in places {
            guard let lat = place.latitude, let lon = place.longitude else { continue }
            let distance = CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            let inside = distance <= max(100, place.radius)
            if inside, insidePlaces.insert(place.name).inserted { handle(.entered(place: place.name)) }
            if !inside, insidePlaces.remove(place.name) != nil { handle(.exited(place: place.name)) }
        }
    }

    // MARK: Firing

    /// An event happened: fire every matching reminder that its rules allow.
    func handle(_ event: ReminderEvent) {
        let current = now()
        for reminder in reminders where ReminderRules.matches(reminder.trigger, event) {
            if ReminderRules.verdict(reminder, now: current) == .fire { fire(reminder, context: reminder.trigger.summary) }
        }
    }

    /// Time and meeting triggers.
    func tick() {
        let current = now()
        for reminder in reminders where reminder.enabled && !reminder.isDone {
            switch reminder.trigger {
            case let .time(_, repeating):
                if let snoozed = reminder.snoozedUntil, snoozed <= current {
                    fire(reminder, context: "Snoozed reminder")
                    continue
                }
                guard ReminderRules.timeDue(nextFire: reminder.nextFire, now: current) else { continue }
                if reminder.conditions.allows(current) { fire(reminder, context: reminder.trigger.summary) }
                if let repeating {
                    reminder.nextFire = repeating.next(after: current)
                } else {
                    reminder.nextFire = nil
                }
                save()
            case .beforeMeeting(let minutes):
                if let (key, event) = ReminderRules.meetingDue(events: upcomingEvents(), minutes: minutes, lastKey: reminder.lastMeetingKey, now: current),
                   ReminderRules.verdict(reminder, now: current) == .fire || reminder.repeatMode == .once && reminder.firedCount == 0 {
                    reminder.lastMeetingKey = key
                    fire(reminder, context: "Before “\(event.title)” at \(event.start.formatted(date: .omitted, time: .shortened))")
                }
            default:
                if let snoozed = reminder.snoozedUntil, snoozed <= current {
                    fire(reminder, context: "Snoozed reminder")
                }
            }
        }
    }

    func fire(_ reminder: SmartReminder, context: String) {
        reminder.lastFired = now()
        reminder.firedCount += 1
        reminder.snoozedUntil = nil
        save()
        deliver(reminder, context)
    }

    // MARK: Snooze / Done

    func snooze(_ reminder: SmartReminder, minutes: Int) {
        reminder.snoozedUntil = now().addingTimeInterval(Double(minutes) * 60)
        save()
    }

    /// Context triggers: wait for the trigger to happen again (cooldown doesn't block it).
    func snoozeUntilNextTrigger(_ reminder: SmartReminder) {
        reminder.snoozedUntil = nil
        reminder.firedCount = 0
        reminder.lastFired = nil
        save()
    }

    func done(_ reminder: SmartReminder) {
        reminder.isDone = true
        reminder.snoozedUntil = nil
        if let taskID = reminder.taskUID,
           let task = try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.uid == taskID })).first {
            task.isCompleted = true
            ReminderSync.shared.scheduleSync()
        }
        save()
    }

    // MARK: Delivery

    static func defaultDeliver(_ reminder: SmartReminder, context: String) {
        // During Focus, reminders are held and summarized when it ends.
        guard FocusController.shared.allow("Reminder: \(reminder.text)", urgent: false) else { return }
        NotchController.shared.peek(NotchPeek(systemImage: reminder.trigger.systemImage, tint: .blue, title: reminder.text, subtitle: context,
                                              duration: 10, buttonTitle: "Done", buttonAction: .reminderDone(reminder.uid)))
        if NotificationService.isAvailable {
            let content = UNMutableNotificationContent()
            content.title = reminder.text
            content.body = context
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.userInfo = ["reminder": reminder.uid.uuidString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "smart-\(reminder.uid.uuidString)-\(reminder.firedCount)",
                                                                       content: content, trigger: nil))
        }
        TelegramBot.shared.sendReminder(reminder, context: context)
    }

    private func setUpNotificationActions() {
        guard NotificationService.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let actions = [UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 10 min"),
                       UNNotificationAction(identifier: Self.nextAction, title: "Until next time"),
                       UNNotificationAction(identifier: Self.doneAction, title: "Done")]
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryID, actions: actions, intentIdentifiers: [])])
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Notification buttons.
    func respond(action: String, reminderID: UUID) {
        guard let reminder = reminders.first(where: { $0.uid == reminderID }) else { return }
        switch action {
        case Self.snoozeAction: snooze(reminder, minutes: 10)
        case Self.nextAction: reminder.trigger.isContext ? snoozeUntilNextTrigger(reminder) : snooze(reminder, minutes: 60)
        case Self.doneAction: done(reminder)
        default: break
        }
    }
}

extension ReminderEngine: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["reminder"] as? String, let id = UUID(uuidString: raw) else { return }
        let action = response.actionIdentifier
        await MainActor.run { ReminderEngine.shared.respond(action: action, reminderID: id) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension ReminderEngine: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in ReminderEngine.shared.locationStatus = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let name = region.identifier
        Task { @MainActor in ReminderEngine.shared.handle(.entered(place: name)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let name = region.identifier
        Task { @MainActor in ReminderEngine.shared.handle(.exited(place: name)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            let engine = ReminderEngine.shared
            if let name = engine.pendingPlaceName {
                engine.pendingPlaceName = nil
                var places = engine.places.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
                places.append(SavedPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude))
                engine.places = places
            }
            engine.locationChanged(coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
