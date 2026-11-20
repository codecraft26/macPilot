import Foundation
import Observation
import ServiceManagement

/// Observable copy of the login-item state, so menus and Settings show the current value.
@Observable
@MainActor
final class LoginItemState {
    static let shared = LoginItemState()
    private(set) var enabled = LaunchAtLogin.isEnabled
    func refresh() { enabled = LaunchAtLogin.isEnabled }
}

/// Open MacPilot automatically when you log in (System Settings → General → Login Items shows it too).
@MainActor
enum LaunchAtLogin {
    private static let setUpKey = "loginItem.setUp"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS needs your OK in System Settings → Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Only an installed app can be a login item (not a build run from Xcode or the terminal).
    static var isInstalledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isInstalledApp else { return "Install MacPilot in Applications first." }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            LoginItemState.shared.refresh()
            return nil
        } catch {
            LoginItemState.shared.refresh()
            return error.localizedDescription
        }
    }

    /// Turns it on once, the first time this version runs from Applications. After that the user's choice stands.
    static func setUpOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: setUpKey), isInstalledApp,
              Bundle.main.bundleURL.path.hasPrefix("/Applications") else { return }
        defaults.set(true, forKey: setUpKey)
        if SMAppService.mainApp.status == .notRegistered { set(true) }
    }
}
