import AppKit
import Carbon.HIToolbox
import Observation

/// A global key combination, stored with Carbon modifier flags.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}

/// Actions reachable from global shortcuts (PRD section 8).
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case assistant, dictation, recording, clipboard, newNote, newTask, launcher, voiceTask, textActions, askMac, screenshot, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistant: return "AI assistant"
        case .dictation: return "Voice dictation"
        case .recording: return "Recording"
        case .clipboard: return "Clipboard"
        case .newNote: return "New note"
        case .newTask: return "New task"
        case .launcher: return "Command launcher"
        case .voiceTask: return "Voice to task"
        case .textActions: return "AI on selected text"
        case .askMac: return "Ask my Mac"
        case .screenshot: return "Screenshot & read text"
        case .search: return "Universal search"
        }
    }

    var hotKeyID: UInt32 {
        UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    var defaultHotKey: HotKey {
        let option = UInt32(optionKey)
        switch self {
        case .assistant: return HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: option, keyLabel: "Space")
        case .dictation: return HotKey(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: option, keyLabel: "D")
        case .recording: return HotKey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: option, keyLabel: "R")
        case .clipboard: return HotKey(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: option, keyLabel: "C")
        case .newNote: return HotKey(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: option, keyLabel: "N")
        case .newTask: return HotKey(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: option, keyLabel: "T")
        case .launcher: return HotKey(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: option, keyLabel: "K")
        case .voiceTask: return HotKey(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: option | UInt32(shiftKey), keyLabel: "T")
        case .textActions: return HotKey(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: option | UInt32(shiftKey), keyLabel: "E")
        case .askMac: return HotKey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: option | UInt32(shiftKey), keyLabel: "A")
        case .screenshot: return HotKey(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: option | UInt32(shiftKey), keyLabel: "S")
        // ⌥Space is MacPilot's AI assistant (and ⌘Space is Spotlight), so search defaults to ⌥F.
        case .search: return HotKey(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: option, keyLabel: "F")
        }
    }
}

// MARK: - Carbon hot key registration

private func hotKeyEventHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    Task { @MainActor in
        if released {
            HotKeyCenter.shared.fireRelease(id)
        } else {
            HotKeyCenter.shared.fire(id)
        }
    }
    return noErr
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var installed = false
    private let signature: OSType = 0x4D50_4C54 // "MPLT"

    private init() {}

    private func installIfNeeded() {
        guard !installed else { return }
        // Key-up events let push-to-talk know when the shortcut is released (no Accessibility needed).
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 2, &specs, nil, nil)
        installed = true
    }

    /// Returns false when macOS refuses the combination (already taken, or not allowed).
    func register(id: UInt32, hotKey: HotKey, handler: @escaping () -> Void, onRelease: (() -> Void)? = nil) -> Bool {
        installIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        releaseHandlers[id] = onRelease
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers[id] = nil
        releaseHandlers[id] = nil
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    func fire(_ id: UInt32) {
        handlers[id]?()
    }

    func fireRelease(_ id: UInt32) {
        releaseHandlers[id]?()
    }
}

// MARK: - User-configurable bindings

@Observable
@MainActor
final class ShortcutManager {
    static let shared = ShortcutManager()

    private(set) var bindings: [ShortcutAction: HotKey] = [:]
    private(set) var failures: [ShortcutAction: String] = [:]

    private let bindingsKey = "shortcuts.bindings.v1"
    private let disabledKey = "shortcuts.disabled.v1"

    private init() {
        load()
    }

    func hotKey(for action: ShortcutAction) -> HotKey? {
        bindings[action]
    }

    func registerAll() {
        failures = [:]
        for action in ShortcutAction.allCases {
            guard let hotKey = bindings[action] else {
                HotKeyCenter.shared.unregister(id: action.hotKeyID)
                continue
            }
            let ok = HotKeyCenter.shared.register(
                id: action.hotKeyID,
                hotKey: hotKey,
                handler: { ShortcutRouter.perform(action) },
                onRelease: { ShortcutRouter.release(action) }
            )
            if !ok {
                failures[action] = "macOS refused \(hotKey.displayString). It may be in use by another app, or macOS may not allow Option-only shortcuts; try adding ⌃ or ⌘."
            }
        }
    }

    /// Pauses global shortcuts while the user is recording a new one.
    func suspend() {
        HotKeyCenter.shared.unregisterAll()
    }

    func resume() {
        registerAll()
    }

    func set(_ hotKey: HotKey?, for action: ShortcutAction) {
        bindings[action] = hotKey
        save()
        registerAll()
    }

    func resetAll() {
        bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultHotKey) })
        save()
        registerAll()
    }

    private func load() {
        let defaults = UserDefaults.standard
        var stored: [String: HotKey] = [:]
        if let data = defaults.data(forKey: bindingsKey),
           let decoded = try? JSONDecoder().decode([String: HotKey].self, from: data) {
            stored = decoded
        }
        let disabled = Set(defaults.stringArray(forKey: disabledKey) ?? [])
        for action in ShortcutAction.allCases where !disabled.contains(action.rawValue) {
            bindings[action] = stored[action.rawValue] ?? action.defaultHotKey
        }
    }

    private func save() {
        var stored: [String: HotKey] = [:]
        var disabled: [String] = []
        for action in ShortcutAction.allCases {
            if let hotKey = bindings[action] {
                stored[action.rawValue] = hotKey
            } else {
                disabled.append(action.rawValue)
            }
        }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: bindingsKey)
        }
        UserDefaults.standard.set(disabled, forKey: disabledKey)
    }
}

/// What each global shortcut does.
@MainActor
enum ShortcutRouter {
    static func perform(_ action: ShortcutAction) {
        let windows = WindowManager.shared
        switch action {
        case .assistant:
            windows.toggleQuickAssistant()
        case .launcher:
            windows.toggleLauncher()
        case .newNote:
            windows.open(.notes, action: .newNote)
        case .newTask:
            windows.open(.tasks, action: .newTask)
        case .clipboard:
            windows.toggleClipboardPanel()
        case .recording:
            RecordingManager.shared.toggleMeeting()
        case .dictation:
            DictationController.shared.hotKeyDown(mode: Prefs.dictationDefaultMode)
        case .voiceTask:
            DictationController.shared.hotKeyDown(mode: .task)
        case .textActions:
            TextActionsController.shared.open()
        case .askMac:
            WindowManager.shared.toggleAskMac()
        case .screenshot:
            ScreenCaptureTool.shared.captureArea()
        case .search:
            UniversalSearchPanel.shared.toggle()
        }
    }

    /// Key-up for shortcuts that care about it (push-to-talk).
    static func release(_ action: ShortcutAction) {
        switch action {
        case .dictation, .voiceTask:
            DictationController.shared.hotKeyUp()
        default:
            break
        }
    }
}
