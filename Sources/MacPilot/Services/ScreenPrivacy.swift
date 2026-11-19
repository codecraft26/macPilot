import AppKit

/// Keeps MacPilot's windows (main window, ⌥K / ⌥C / ⌥⇧E / ⌥⇧A panels, the notch, assistant)
/// out of screenshots, screen recordings and screen sharing by marking them non-shareable.
@MainActor
enum ScreenPrivacy {
    private static var observers: [NSObjectProtocol] = []

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.hideFromScreenCapture) }

    static func start() {
        guard observers.isEmpty else { applyAll(); return }
        let center = NotificationCenter.default
        // New windows and panels are created lazily; re-apply whenever the app updates its windows.
        for name in [NSApplication.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ScreenPrivacy.applyAll() }
            })
        }
        applyAll()
    }

    static func applyAll() {
        let type: NSWindow.SharingType = isEnabled ? .none : .readOnly
        for window in NSApp.windows where window.sharingType != type {
            window.sharingType = type
        }
    }
}
