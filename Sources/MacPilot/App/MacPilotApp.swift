import AppKit
import SwiftData
import SwiftUI

@main
struct MacPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(AppState.shared)
                .modelContainer(Persistence.container)
        } label: {
            MenuBarLabel()
                .environment(AppState.shared)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        // Menu bar app: no Dock icon until the dashboard is opened.
        NSApp.setActivationPolicy(.accessory)
        Seeder.seedIfNeeded(Persistence.container.mainContext)
        ShortcutManager.shared.registerAll()

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: PrefKey.hasLaunchedBefore) {
            defaults.set(true, forKey: PrefKey.hasLaunchedBefore)
            WindowManager.shared.showDashboard(section: .settings)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showDashboard()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
