import AppKit
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import Intents
import Observation

/// Why MacPilot thinks you should not be disturbed.
enum FocusReason: Codable, Equatable {
    case manual(until: Date)
    case screenSharing(app: String)
    case recording
    case meeting(title: String, until: Date)
    case micInUse(app: String)
    case deepWork(app: String)

    /// Higher wins when several apply.
    var priority: Int {
        switch self {
        case .manual: return 6
        case .screenSharing: return 5
        case .recording: return 4
        case .meeting: return 3
        case .micInUse: return 2
        case .deepWork: return 1
        }
    }

    var label: String {
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        switch self {
        case .manual(let until): return "Focus until \(time(until))"
        case .screenSharing(let app): return "Sharing your screen (\(app))"
        case .recording: return "Recording a meeting"
        case let .meeting(title, until): return "In “\(title)” until \(time(until))"
        case .micInUse(let app): return "On a call (\(app))"
        case .deepWork(let app): return "Deep work in \(app)"
        }
    }

    var kind: String {
        switch self {
        case .manual: return "manual"
        case .screenSharing: return "screenSharing"
        case .recording: return "recording"
        case .meeting: return "meeting"
        case .micInUse: return "mic"
        case .deepWork: return "deepWork"
        }
    }
}

struct FocusSettings: Equatable {
    var meetings = true
    var microphone = true
    var screenSharing = true
    var deepWork = false
    var deepWorkApps: [String] = ["com.apple.dt.Xcode"]
    var deepWorkMinutes = 5
    var deepWorkOnlyWhileTyping = false
    /// Turn on macOS Focus through the two MacPilot shortcuts (otherwise only MacPilot's own alerts are held).
    var useSystemFocus = true
    var graceSeconds: TimeInterval = 120

    private enum Keys {
        static let prefix = "focus."
    }

    static func load(_ defaults: UserDefaults = .standard) -> FocusSettings {
        var s = FocusSettings()
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: Keys.prefix + key) as? Bool ?? fallback }
        s.meetings = bool("meetings", s.meetings)
        s.microphone = bool("microphone", s.microphone)
        s.screenSharing = bool("screenSharing", s.screenSharing)
        s.deepWork = bool("deepWork", s.deepWork)
        s.deepWorkApps = defaults.stringArray(forKey: Keys.prefix + "deepWorkApps") ?? s.deepWorkApps
        if defaults.object(forKey: Keys.prefix + "deepWorkMinutes") != nil { s.deepWorkMinutes = max(1, defaults.integer(forKey: Keys.prefix + "deepWorkMinutes")) }
        s.deepWorkOnlyWhileTyping = bool("deepWorkTyping", s.deepWorkOnlyWhileTyping)
        s.useSystemFocus = bool("useSystemFocus", s.useSystemFocus)
        if defaults.object(forKey: Keys.prefix + "grace") != nil { s.graceSeconds = max(0, defaults.double(forKey: Keys.prefix + "grace")) }
        return s
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(meetings, forKey: Keys.prefix + "meetings")
        defaults.set(microphone, forKey: Keys.prefix + "microphone")
        defaults.set(screenSharing, forKey: Keys.prefix + "screenSharing")
        defaults.set(deepWork, forKey: Keys.prefix + "deepWork")
        defaults.set(deepWorkApps, forKey: Keys.prefix + "deepWorkApps")
        defaults.set(deepWorkMinutes, forKey: Keys.prefix + "deepWorkMinutes")
        defaults.set(deepWorkOnlyWhileTyping, forKey: Keys.prefix + "deepWorkTyping")
        defaults.set(useSystemFocus, forKey: Keys.prefix + "useSystemFocus")
        defaults.set(graceSeconds, forKey: Keys.prefix + "grace")
    }
}

/// A snapshot of what's happening on the Mac (gathered by `FocusSensors`, faked in tests).
struct FocusInputs: Equatable {
    var now: Date
    var currentMeeting: (title: String, end: Date)?
    var micInUseBy: String?
    var recording = false
    var sharingApp: String?
    var frontmostBundleID = ""
    var frontmostName = ""
    var frontmostSince: Date?
    var secondsSinceTyping: TimeInterval = .infinity
    var manualUntil: Date?
    /// "Not now": ignore automatic triggers until then.
    var snoozedUntil: Date?

    static func == (lhs: FocusInputs, rhs: FocusInputs) -> Bool {
        lhs.now == rhs.now && lhs.currentMeeting?.title == rhs.currentMeeting?.title && lhs.currentMeeting?.end == rhs.currentMeeting?.end
            && lhs.micInUseBy == rhs.micInUseBy && lhs.recording == rhs.recording && lhs.sharingApp == rhs.sharingApp
            && lhs.frontmostBundleID == rhs.frontmostBundleID && lhs.manualUntil == rhs.manualUntil && lhs.snoozedUntil == rhs.snoozedUntil
    }
}

/// Pure trigger evaluation (unit-tested).
enum FocusEvaluator {
    static func reasons(_ inputs: FocusInputs, settings: FocusSettings) -> [FocusReason] {
        var found: [FocusReason] = []
        if let until = inputs.manualUntil, until > inputs.now { found.append(.manual(until: until)) }
        let automaticAllowed = inputs.snoozedUntil.map { $0 <= inputs.now } ?? true
        if automaticAllowed {
            if settings.screenSharing, let app = inputs.sharingApp { found.append(.screenSharing(app: app)) }
            if settings.meetings, inputs.recording { found.append(.recording) }
            if settings.meetings, let meeting = inputs.currentMeeting, meeting.end > inputs.now { found.append(.meeting(title: meeting.title, until: meeting.end)) }
            if settings.microphone, let app = inputs.micInUseBy { found.append(.micInUse(app: app)) }
            if settings.deepWork, settings.deepWorkApps.contains(where: { $0.caseInsensitiveCompare(inputs.frontmostBundleID) == .orderedSame }),
               let since = inputs.frontmostSince, inputs.now.timeIntervalSince(since) >= Double(settings.deepWorkMinutes) * 60,
               !settings.deepWorkOnlyWhileTyping || inputs.secondsSinceTyping < 60 {
                found.append(.deepWork(app: inputs.frontmostName.isEmpty ? inputs.frontmostBundleID : inputs.frontmostName))
            }
        }
        return found.sorted { $0.priority > $1.priority }
    }

    static func reason(_ inputs: FocusInputs, settings: FocusSettings) -> FocusReason? {
        reasons(inputs, settings: settings).first
    }
}

/// On/off with a grace period so back-to-back meetings don't flap.
struct FocusStateMachine: Equatable {
    enum Change: Equatable { case none, turnOn(FocusReason), update(FocusReason), turnOff }

    private(set) var active: FocusReason?
    private(set) var clearSince: Date?

    mutating func step(reason: FocusReason?, now: Date, grace: TimeInterval) -> Change {
        if let reason {
            clearSince = nil
            if active == nil { active = reason; return .turnOn(reason) }
            if active != reason { active = reason; return .update(reason) }
            return .none
        }
        guard active != nil else { return .none }
        // Manual focus ends exactly when asked; automatic ones wait out the grace period.
        if case .manual? = active { active = nil; clearSince = nil; return .turnOff }
        if clearSince == nil { clearSince = now }
        if let since = clearSince, now.timeIntervalSince(since) >= grace {
            active = nil
            clearSince = nil
            return .turnOff
        }
        return .none
    }

    mutating func forceOff() {
        active = nil
        clearSince = nil
    }
}

/// Runs the two Shortcuts that switch macOS Focus (there's no public API to set Focus directly).
protocol ShortcutsRunning {
    func list() async -> [String]?
    func run(_ name: String) async -> Bool
}

struct SystemShortcutsRunner: ShortcutsRunning {
    func list() async -> [String]? {
        let result = await Shell.run("/usr/bin/shortcuts", ["list"], timeout: 15)
        guard result.ok else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func run(_ name: String) async -> Bool {
        await Shell.run("/usr/bin/shortcuts", ["run", name], timeout: 20).ok
    }
}

enum FocusShortcuts {
    static let onName = "MacPilot Focus On"
    static let offName = "MacPilot Focus Off"

    static func missing(in names: [String]) -> [String] {
        [onName, offName].filter { wanted in !names.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
    }

    /// A one-action shortcut using Shortcuts' “Set Focus” action (Do Not Disturb on or off).
    static func workflow(enabled: Bool) -> [String: Any] {
        [
            "WFWorkflowClientVersion": "2302.0.4", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": enabled ? 4_282_601_983 : 2_846_468_607, "WFWorkflowIconGlyphNumber": 59_511],
            "WFWorkflowImportQuestions": [], "WFWorkflowInputContentItemClasses": [], "WFWorkflowOutputContentItemClasses": [],
            "WFWorkflowTypes": [], "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                "WFWorkflowActionParameters": [
                    "Enabled": enabled ? 1 : 0,
                    "FocusModes": ["Identifier": "com.apple.donotdisturb.mode.default", "DisplayString": "Do Not Disturb"]
                ]
            ]]
        ]
    }

    /// Writes, signs (`shortcuts sign`) and opens both shortcuts so Shortcuts shows its import screen.
    static func installWithImport() async -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacPilotShortcuts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var opened = 0
        for (name, enabled) in [(onName, true), (offName, false)] {
            let raw = folder.appendingPathComponent("raw-\(enabled).shortcut")
            let signed = folder.appendingPathComponent("\(name).shortcut")
            guard let data = try? PropertyListSerialization.data(fromPropertyList: workflow(enabled: enabled), format: .binary, options: 0),
                  (try? data.write(to: raw)) != nil else { continue }
            let result = await Shell.run("/usr/bin/shortcuts", ["sign", "--mode", "anyone", "--input", raw.path, "--output", signed.path], timeout: 60)
            if result.ok, FileManager.default.fileExists(atPath: signed.path) {
                NSWorkspace.shared.open(signed)
                opened += 1
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        return opened == 2
            ? "Shortcuts opened both shortcuts — click “Add Shortcut” for each. You can change which Focus they set."
            : "Couldn't prepare the shortcuts automatically. Create them by hand (see below)."
    }

    static let manualSteps = """
    1. Open Shortcuts and create a shortcut named “MacPilot Focus On” with one action: Set Focus → Do Not Disturb (or any Focus) → Turn On.
    2. Create “MacPilot Focus Off” with Set Focus → Turn Off.
    MacPilot runs them with the `shortcuts` command when Focus should start or end.
    """
}

/// Live sensors for the triggers (public APIs only).
@MainActor
enum FocusSensors {
    static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams", "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack", "com.cisco.webexmeetingsapp": "Webex", "com.google.Chrome": "Google Meet",
        "com.apple.Safari": "Google Meet", "company.thebrowser.Browser": "Google Meet", "org.mozilla.firefox": "Google Meet", "com.hnc.Discord": "Discord"
    ]

    /// Whether any process uses the default input device (CoreAudio). Attribution is by which call app is running.
    static func microphoneRunning() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    static func micInUseBy() -> String? {
        guard microphoneRunning(), !RecordingManager.shared.isActive, !DictationController.shared.phase.isActive else { return nil }
        let running = NSWorkspace.shared.runningApplications
        // Prefer the frontmost call app, then any running dedicated call app.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, let name = callApps[front] { return name }
        let dedicated = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.cisco.webexmeetingsapp", "com.tinyspeck.slackmacgap"]
        return running.compactMap(\.bundleIdentifier).first { dedicated.contains($0) }.flatMap { callApps[$0] }
    }

    /// What's detectable with public APIs: call apps' sharing windows (window titles need Screen Recording permission),
    /// macOS Screen Sharing / Remote Management sessions (screensharingd), and AirPlay or display mirroring.
    static func sharingApp() -> String? {
        if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for window in windows {
                let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
                let title = (window[kCGWindowName as String] as? String ?? "").lowercased()
                if owner.contains("zoom"), title.contains("screen share") || title.contains("sharing") || title == "zoom share toolbar window" { return "Zoom" }
                if owner.contains("teams"), title.contains("sharing control bar") || title.contains("you're sharing") || title.contains("presenting") { return "Teams" }
                if title.contains("is sharing your screen") || title.contains("meet.google.com is sharing") { return "Google Meet" }
                if owner.contains("webex"), title.contains("sharing") { return "Webex" }
                if owner.contains("slack"), title.contains("screen share") || title.contains("sharing your screen") { return "Slack" }
            }
        }
        if processRunning("screensharingd") { return "macOS Screen Sharing" }
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &displays, &count)
        if displays.prefix(Int(count)).contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) { return "Display mirroring / AirPlay" }
        return nil
    }

    static func processRunning(_ name: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 4_096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == name { return true }
        }
        return false
    }

    static func currentMeeting(now: Date) -> (title: String, end: Date)? {
        CalendarService.shared.events(on: now).first { !$0.isAllDay && $0.start <= now && $0.end > now && MeetingAutoRecord.looksLikeMeeting($0) }
            .map { ($0.title, $0.end) }
    }

    static var secondsSinceTyping: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    /// The system Focus state, when the user lets MacPilot see it (INFocusStatusCenter).
    static var systemFocusOn: Bool? {
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .authorized else { return nil }
        return center.focusStatus.isFocused
    }
}

struct FocusSession: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date?
    var reason: String
}

/// Smart Do Not Disturb: watches the triggers, switches macOS Focus through Shortcuts, holds MacPilot's own
/// alerts while focused and summarizes them afterwards.
@Observable
@MainActor
final class FocusController {
    static let shared = FocusController()

    private(set) var machine = FocusStateMachine()
    var active: FocusReason? { machine.active }
    var isActive: Bool { machine.active != nil }
    private(set) var manualUntil: Date?
    private(set) var snoozedUntil: Date?
    private(set) var missingShortcuts: [String] = []
    private(set) var history: [FocusSession] = []
    /// MacPilot alerts held while focused.
    private(set) var held: [String] = []
    private(set) var lastShortcutError: String?

    var settingsProvider: () -> FocusSettings = { FocusSettings.load() }
    var inputsProvider: (FocusController) -> FocusInputs = { FocusController.liveInputs($0) }
    var shortcuts: ShortcutsRunning = SystemShortcutsRunner()
    var systemFocusOn: () -> Bool? = { FocusSensors.systemFocusOn }
    var now: () -> Date = Date.init
    /// Delivers the summary of held alerts when focus ends.
    var deliverSummary: ([String]) -> Void = { FocusController.defaultSummary($0) }
    /// Whether macOS Focus was already on before MacPilot turned it on (then it's left on afterwards).
    private(set) var focusWasAlreadyOn = false
    private(set) var turnedSystemFocusOn = false
    private var frontmost: (bundle: String, since: Date)?
    private var timer: Timer?
    private let historyKey = "focus.history"

    init() {
        history = (UserDefaults.standard.data(forKey: historyKey)).flatMap { try? JSONDecoder().decode([FocusSession].self, from: $0) } ?? []
    }

    func start() {
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            _ = MainActor.assumeIsolated { Task { await FocusController.shared.evaluate() } }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await checkShortcuts() }
    }

    static func liveInputs(_ controller: FocusController) -> FocusInputs {
        let now = controller.now()
        let front = NSWorkspace.shared.frontmostApplication
        let bundle = front?.bundleIdentifier ?? ""
        if controller.frontmost?.bundle != bundle { controller.frontmost = (bundle, now) }
        let settings = controller.settingsProvider()
        return FocusInputs(now: now,
                           currentMeeting: settings.meetings ? FocusSensors.currentMeeting(now: now) : nil,
                           micInUseBy: settings.microphone ? FocusSensors.micInUseBy() : nil,
                           recording: RecordingManager.shared.isActive && RecordingManager.shared.current?.kind == .meeting,
                           sharingApp: settings.screenSharing ? FocusSensors.sharingApp() : nil,
                           frontmostBundleID: bundle, frontmostName: front?.localizedName ?? "", frontmostSince: controller.frontmost?.since,
                           secondsSinceTyping: FocusSensors.secondsSinceTyping,
                           manualUntil: controller.manualUntil, snoozedUntil: controller.snoozedUntil)
    }

    func checkShortcuts() async {
        guard let names = await shortcuts.list() else {
            missingShortcuts = [FocusShortcuts.onName, FocusShortcuts.offName]
            return
        }
        missingShortcuts = FocusShortcuts.missing(in: names)
    }

    @discardableResult
    func evaluate() async -> FocusStateMachine.Change {
        let settings = settingsProvider()
        let inputs = inputsProvider(self)
        if let until = manualUntil, until <= inputs.now { manualUntil = nil }
        let reason = FocusEvaluator.reason(inputs, settings: settings)
        let change = machine.step(reason: reason, now: inputs.now, grace: settings.graceSeconds)
        switch change {
        case .turnOn(let reason): await turnOn(reason, settings: settings)
        case .update(let reason):
            if !history.isEmpty, history[0].end == nil { history[0].reason = reason.label; saveHistory() }
        case .turnOff: await turnOff(settings: settings)
        case .none: break
        }
        return change
    }

    private func turnOn(_ reason: FocusReason, settings: FocusSettings) async {
        history.insert(FocusSession(start: now(), reason: reason.label), at: 0)
        history = Array(history.prefix(50))
        saveHistory()
        focusWasAlreadyOn = systemFocusOn() ?? false
        turnedSystemFocusOn = false
        guard settings.useSystemFocus, !focusWasAlreadyOn else { return }
        if missingShortcuts.contains(FocusShortcuts.onName) { await checkShortcuts() }
        guard !missingShortcuts.contains(FocusShortcuts.onName) else {
            lastShortcutError = "The “\(FocusShortcuts.onName)” shortcut is missing — set it up in Settings → Focus."
            return
        }
        if await shortcuts.run(FocusShortcuts.onName) {
            turnedSystemFocusOn = true
            lastShortcutError = nil
        } else {
            lastShortcutError = "Running “\(FocusShortcuts.onName)” failed."
        }
    }

    /// Restores the previous state: macOS Focus goes off only if MacPilot turned it on.
    private func turnOff(settings: FocusSettings) async {
        if !history.isEmpty, history[0].end == nil { history[0].end = now(); saveHistory() }
        if turnedSystemFocusOn, !focusWasAlreadyOn {
            if missingShortcuts.contains(FocusShortcuts.offName) {
                lastShortcutError = "The “\(FocusShortcuts.offName)” shortcut is missing, so macOS Focus is still on."
            } else if !(await shortcuts.run(FocusShortcuts.offName)) {
                lastShortcutError = "Running “\(FocusShortcuts.offName)” failed."
            }
        }
        turnedSystemFocusOn = false
        focusWasAlreadyOn = false
        let summary = held
        held = []
        if !summary.isEmpty { deliverSummary(summary) }
    }

    // MARK: Controls

    func focus(minutes: Int) async {
        manualUntil = now().addingTimeInterval(Double(minutes) * 60)
        snoozedUntil = nil
        await evaluate()
    }

    func end() async {
        manualUntil = nil
        // Ending also says "not now" to automatic triggers for a while.
        snoozedUntil = now().addingTimeInterval(30 * 60)
        if isActive {
            machine.forceOff()
            await turnOff(settings: settingsProvider())
        }
    }

    /// One-tap "Not now": ends this focus and ignores automatic triggers for an hour.
    func notNow() async {
        snoozedUntil = now().addingTimeInterval(3_600)
        manualUntil = nil
        if isActive {
            machine.forceOff()
            await turnOff(settings: settingsProvider())
        }
    }

    // MARK: Holding alerts

    /// Returns true when the alert should be shown now; otherwise it's held for the summary.
    func allow(_ title: String, urgent: Bool) -> Bool {
        guard isActive, !urgent else { return true }
        held.append(title)
        return false
    }

    static func defaultSummary(_ items: [String]) {
        let title = "While you were focused: \(items.count) alert\(items.count == 1 ? "" : "s")"
        let body = items.prefix(6).joined(separator: "\n") + (items.count > 6 ? "\n…and \(items.count - 6) more" : "")
        NotchController.shared.peek(NotchPeek(systemImage: "moon.fill", tint: .blue, title: title, subtitle: items.first ?? "", duration: 10, urgent: true))
        NotificationService.alert(id: "focus-summary-\(UUID().uuidString)", heading: title, body: body, after: 1)
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: historyKey) }
    }

    var statusText: String {
        if let active { return active.label }
        if let snoozed = snoozedUntil, snoozed > now() { return "Off (Not now until \(snoozed.formatted(date: .omitted, time: .shortened)))" }
        return "Off"
    }
}
