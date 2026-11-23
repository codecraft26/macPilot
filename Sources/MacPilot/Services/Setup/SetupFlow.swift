import AppKit
import ApplicationServices
import AVFoundation
import CoreLocation
import EventKit
import Foundation
import Speech
@preconcurrency import UserNotifications

/// The steps of first-run setup, in order.
enum SetupStep: String, CaseIterable, Codable, Identifiable {
    case welcome, provider, permissions, calendar, features, telegram, updates, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .provider: return "AI provider"
        case .permissions: return "Permissions"
        case .calendar: return "Calendar"
        case .features: return "Features"
        case .telegram: return "Telegram"
        case .updates: return "Updates"
        case .done: return "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: return "hand.wave"
        case .provider: return "sparkles"
        case .permissions: return "lock.shield"
        case .calendar: return "calendar"
        case .features: return "switch.2"
        case .telegram: return "paperplane"
        case .updates: return "arrow.down.circle"
        case .done: return "checkmark.seal"
        }
    }

    /// Optional steps don't count against "setup done".
    var isRequired: Bool {
        switch self {
        case .telegram, .calendar: return false
        default: return true
        }
    }

    /// The setup version that introduced this step (a newer version reshows setup at the new steps only).
    var introducedIn: Int { 1 }

    /// Where "Set up later" leads.
    var settingsTab: String {
        switch self {
        case .provider: return "Providers"
        case .permissions: return "Agent"
        case .calendar: return "Recording & Calendar"
        case .features: return "Focus"
        case .telegram: return "Agent"
        case .updates: return "General"
        default: return "General"
        }
    }
}

/// Saved per step, so quitting mid-way resumes at the same place.
struct SetupProgress: Codable, Equatable {
    static let currentVersion = 1

    var current: SetupStep = .welcome
    var completed: Set<SetupStep> = []
    var skipped: Set<SetupStep> = []
    /// The setup version the user last finished (0 = never).
    var finishedVersion = 0

    // MARK: State machine

    mutating func complete() {
        completed.insert(current)
        skipped.remove(current)
        advance()
    }

    mutating func skip() {
        if !completed.contains(current) { skipped.insert(current) }
        advance()
    }

    mutating func back() {
        guard let index = SetupStep.allCases.firstIndex(of: current), index > 0 else { return }
        current = SetupStep.allCases[index - 1]
    }

    mutating func go(to step: SetupStep) { current = step }

    private mutating func advance() {
        guard let index = SetupStep.allCases.firstIndex(of: current) else { return }
        if index + 1 < SetupStep.allCases.count {
            current = SetupStep.allCases[index + 1]
        }
        if current == .done { completed.insert(.done) }
    }

    mutating func finish(version: Int = SetupProgress.currentVersion) {
        completed.insert(.done)
        finishedVersion = max(finishedVersion, version)
    }

    // MARK: Counts

    static var requiredSteps: [SetupStep] { SetupStep.allCases.filter { $0.isRequired && $0 != .welcome && $0 != .done } }
    var requiredDone: Int { Self.requiredSteps.filter(completed.contains).count }
    var allRequiredDone: Bool { requiredDone == Self.requiredSteps.count }
    /// "5/8 done" on the dashboard: every step but the final summary.
    var doneCount: Int { SetupStep.allCases.filter { $0 != .done && completed.contains($0) }.count }
    static var totalCount: Int { SetupStep.allCases.count - 1 }

    // MARK: When to show

    /// Show on first launch, or when a newer setup version added steps the user hasn't seen.
    func shouldShow(currentVersion: Int = SetupProgress.currentVersion) -> Bool {
        finishedVersion < currentVersion
    }

    /// Where a reshow starts: the first step added since the user last finished (or where they left off).
    func resumeStep(currentVersion: Int = SetupProgress.currentVersion, introducedIn: (SetupStep) -> Int = { $0.introducedIn }) -> SetupStep {
        guard finishedVersion > 0 else { return current }
        return SetupStep.allCases.first { introducedIn($0) > finishedVersion && !completed.contains($0) } ?? current
    }

    // MARK: Storage

    static let key = "setup.progress"

    static func load(_ defaults: UserDefaults = .standard) -> SetupProgress {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SetupProgress.self, from: $0) } ?? SetupProgress()
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: - Permissions

enum PermissionState: Equatable {
    case granted, needed, denied, unknown

    var symbol: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .needed: return "exclamationmark.triangle.fill"
        case .denied: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .needed: return "Needed"
        case .denied: return "Denied — allow it in System Settings"
        case .unknown: return "Not checked"
        }
    }
}

enum SetupPermission: String, CaseIterable, Identifiable {
    case accessibility, screenRecording, microphone, speech, calendars, reminders, notifications, location, mailAutomation, fullDiskAccess
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen & System Audio Recording"
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .calendars: return "Calendars"
        case .reminders: return "Reminders"
        case .notifications: return "Notifications"
        case .location: return "Location"
        case .mailAutomation: return "Automation → Mail"
        case .fullDiskAccess: return "Full Disk Access"
        }
    }

    var why: String {
        switch self {
        case .accessibility: return "Paste dictation and snippets into apps, read selected text, control apps you allow, and (if you turn it on) Memory."
        case .screenRecording: return "Record meeting audio from other apps, screenshots and OCR, and the agent's screenshots. macOS may need MacPilot relaunched after you allow it."
        case .microphone: return "Dictation, voice notes, meeting recording and talking to Pilot."
        case .speech: return "Understand what you say to Pilot on this Mac."
        case .calendars: return "Show meetings, prep notes, auto-record and Focus during meetings."
        case .reminders: return "Two-way sync between Tasks and Apple Reminders."
        case .notifications: return "Reminders, timers, task due alerts and finished summaries."
        case .location: return "Optional: reminders for arriving/leaving places and Wi-Fi networks (macOS needs Location to share the Wi-Fi name). Never leaves the Mac."
        case .mailAutomation: return "Optional: let scheduled jobs send email through the Mail app."
        case .fullDiskAccess: return "Optional: lets universal search find messages in the Mail app."
        }
    }

    var isOptional: Bool { [.location, .mailAutomation, .fullDiskAccess, .reminders, .speech].contains(self) }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        case .speech: pane = "Privacy_SpeechRecognition"
        case .calendars: pane = "Privacy_Calendars"
        case .reminders: pane = "Privacy_Reminders"
        case .location: pane = "Privacy_LocationServices"
        case .mailAutomation: pane = "Privacy_Automation"
        case .fullDiskAccess: pane = "Privacy_AllFiles"
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// Maps the different system status types onto one state (pure, unit-tested).
enum PermissionMapping {
    static func av(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .needed
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    static func speech(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .needed
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    static func eventKit(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess, .authorized: return .granted
        case .writeOnly, .notDetermined: return .needed
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    static func notifications(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .needed
        case .denied: return .denied
        @unknown default: return .unknown
        }
    }

    static func location(_ status: CLAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorizedAlways, .authorized: return .granted
        case .notDetermined: return .needed
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    static func trusted(_ granted: Bool) -> PermissionState { granted ? .granted : .needed }

    /// AEDeterminePermissionToAutomateTarget result.
    static func automation(_ status: OSStatus) -> PermissionState {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .needed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .unknown
        default: return .unknown
        }
    }
}

/// Live status of each permission (checked without prompting) and the request actions.
@MainActor
enum PermissionChecker {
    static func status(_ permission: SetupPermission) async -> PermissionState {
        switch permission {
        case .accessibility: return PermissionMapping.trusted(AXIsProcessTrusted())
        case .screenRecording: return PermissionMapping.trusted(CGPreflightScreenCaptureAccess())
        case .microphone: return PermissionMapping.av(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speech: return PermissionMapping.speech(SFSpeechRecognizer.authorizationStatus())
        case .calendars: return PermissionMapping.eventKit(EKEventStore.authorizationStatus(for: .event))
        case .reminders: return PermissionMapping.eventKit(EKEventStore.authorizationStatus(for: .reminder))
        case .notifications:
            guard NotificationService.isAvailable else { return .unknown }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return PermissionMapping.notifications(settings.authorizationStatus)
        case .location: return PermissionMapping.location(CLLocationManager().authorizationStatus)
        case .mailAutomation:
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first != nil else { return .unknown }
            var target = AEAddressDesc()
            let bundle = "com.apple.mail"
            _ = bundle.withCString { AECreateDesc(typeApplicationBundleID, $0, bundle.utf8.count, &target) }
            defer { AEDisposeDesc(&target) }
            return PermissionMapping.automation(AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false))
        case .fullDiskAccess:
            // A protected file only readable with Full Disk Access.
            let probe = NSHomeDirectory() + "/Library/Mail"
            return PermissionMapping.trusted((try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil)
        }
    }

    static func request(_ permission: SetupPermission) async {
        switch permission {
        case .accessibility: ComputerPermissions.requestAccessibility()
        case .screenRecording: ComputerPermissions.requestScreenRecording()
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech: _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        case .calendars: await CalendarService.shared.requestAccess()
        case .reminders: _ = await ReminderSync.shared.requestAccess()
        case .notifications:
            guard NotificationService.isAvailable else { return }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case .location: ReminderEngine.shared.requestLocationPermission()
        case .mailAutomation:
            var target = AEAddressDesc()
            let bundle = "com.apple.mail"
            _ = bundle.withCString { AECreateDesc(typeApplicationBundleID, $0, bundle.utf8.count, &target) }
            _ = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
            AEDisposeDesc(&target)
        case .fullDiskAccess:
            NSWorkspace.shared.open(permission.settingsURL)
        }
    }
}

/// Stores a provider key from setup: Keychain only (never UserDefaults or logs).
enum SetupKeyStore {
    static func save(_ key: String, for provider: AIProviderID, writer: (String, String) throws -> Void = { try KeychainStore.save($0, account: $1) }) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.missingKey(provider) }
        try writer(trimmed, provider.rawValue)
        UserDefaults.standard.set(true, forKey: PrefKey.enabled(provider))
    }

    /// Relaunches MacPilot (after Screen Recording is granted); setup resumes at the saved step.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
