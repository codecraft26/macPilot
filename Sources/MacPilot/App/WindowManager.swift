import AppKit
import SwiftData
import SwiftUI

/// Owns the dashboard window and the floating assistant panel so they can be
/// opened from global shortcuts, the menu bar, or anywhere else.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var dashboardWindow: NSWindow?
    private var assistantPanel: FloatingPanel?

    func showDashboard(section: AppSection? = nil) {
        if let section {
            AppState.shared.selectedSection = section
        }
        if dashboardWindow == nil {
            let root = RootView()
                .environment(AppState.shared)
                .modelContainer(Persistence.container)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "MacPilot"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.minSize = NSSize(width: 900, height: 560)
            window.center()
            window.setFrameAutosaveName("MacPilotDashboard")
            dashboardWindow = window
        }
        // Show in the Dock / Cmd-Tab while the dashboard is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    func toggleQuickAssistant() {
        if let panel = assistantPanel, panel.isVisible, panel.isKeyWindow {
            panel.orderOut(nil)
            return
        }
        if assistantPanel == nil {
            let view = QuickAssistantView()
                .environment(AppState.shared)
                .modelContainer(Persistence.container)
            assistantPanel = FloatingPanel(rootView: view, size: NSSize(width: 680, height: 460))
        }
        guard let panel = assistantPanel else { return }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideQuickAssistant() {
        assistantPanel?.orderOut(nil)
    }

    func open(_ section: AppSection, action: PendingAction? = nil) {
        AppState.shared.pendingAction = action
        showDashboard(section: section)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboardWindow else { return }
        // Back to a pure menu bar app.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// A Spotlight-style floating panel that can take keyboard focus.
final class FloatingPanel: NSPanel {
    init<Content: View>(rootView: Content, size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentViewController = NSHostingController(rootView: rootView)
        setContentSize(size)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Escape closes the panel.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
