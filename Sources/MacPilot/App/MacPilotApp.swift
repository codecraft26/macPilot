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
        RecordingStorage.applyRetention(days: Prefs.audioRetentionDays, context: Persistence.container.mainContext)
        RecordingRecovery.markInterrupted(context: Persistence.container.mainContext)
        Task {
            // Prime Google Calendar (if connected) so the menu bar can show the next meeting.
            await CalendarService.shared.refresh(from: Date(), to: Date().addingTimeInterval(7 * 86_400))
        }
        ShortcutManager.shared.registerAll()
        ProviderAutoSetup.reconcile()
        ClipboardMonitor.shared.start()
        ReminderSync.shared.start()
        NotchController.shared.start()
        NowPlaying.shared.start()
        SnippetExpander.shared.start()
        ICloudSync.shared.start()
        ScreenPrivacy.start()
        FloatingBuddy.shared.start()
        LaunchAtLogin.setUpOnce()
        MeetingAutoRecord.shared.start()
        NetworkMonitor.shared.start()
        AgentEngine.shared.recoverAfterLaunch()
        TelegramBot.shared.startIfEnabled()
        JobScheduler.shared.onRunFinished = { job, run in TelegramBot.shared.jobFinished(job, run: run) }
        JobScheduler.shared.start()
        // Finder → right-click → Quick Actions / Services → "Convert with MacPilot".
        NSApp.servicesProvider = FinderServiceProvider.shared
        NSUpdateDynamicServices()
        AutomationEngine.shared.start()

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
