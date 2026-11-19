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
    private(set) var clipboardPanel: FloatingPanel?
    private(set) var launcherPanel: FloatingPanel?
    /// The app that was frontmost before a MacPilot panel opened; paste goes back to it.
    private(set) var previousApp: NSRunningApplication?

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

    /// Opens the quick assistant and asks `prompt` right away.
    func askQuickAssistant(_ prompt: String) {
        AppState.shared.pendingQuickPrompt = prompt
        if assistantPanel?.isVisible != true || assistantPanel?.isKeyWindow != true {
            toggleQuickAssistant()
        }
    }

    private func rememberFrontmostApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier || Bundle.main.bundleIdentifier == nil {
            previousApp = front
        }
    }

    /// Raycast-style clipboard history (⌥C). Non-activating, so the app you were in stays frontmost.
    func toggleClipboardPanel() {
        if let panel = clipboardPanel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        launcherPanel?.orderOut(nil)
        rememberFrontmostApp()
        if clipboardPanel == nil {
            let view = ClipboardPanelView()
                .environment(AppState.shared)
                .modelContainer(Persistence.container)
            clipboardPanel = FloatingPanel(rootView: view, size: NSSize(width: 780, height: 480), nonActivating: true)
        }
        guard let panel = clipboardPanel else { return }
        AppState.shared.panelSession += 1
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Command launcher (⌥K).
    func toggleLauncher() {
        if let panel = launcherPanel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        clipboardPanel?.orderOut(nil)
        rememberFrontmostApp()
        if launcherPanel == nil {
            let view = LauncherView()
                .environment(AppState.shared)
                .modelContainer(Persistence.container)
            launcherPanel = FloatingPanel(rootView: view, size: NSSize(width: 680, height: 440), nonActivating: true)
        }
        guard let panel = launcherPanel else { return }
        AppState.shared.panelSession += 1
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func hidePanels() {
        clipboardPanel?.orderOut(nil)
        launcherPanel?.orderOut(nil)
        textActionsPanel?.orderOut(nil)
    }

    private(set) var textActionsPanel: FloatingPanel?

    /// AI actions for the selected text, shown near the top of the screen without stealing the app's focus.
    func showTextActions() {
        clipboardPanel?.orderOut(nil)
        launcherPanel?.orderOut(nil)
        if textActionsPanel == nil {
            let view = TextActionsView().environment(AppState.shared)
            textActionsPanel = FloatingPanel(rootView: view, size: NSSize(width: 520, height: 470), nonActivating: true)
        }
        guard let panel = textActionsPanel else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 80))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hideTextActions() {
        textActionsPanel?.orderOut(nil)
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
    init<Content: View>(rootView: Content, size: NSSize, nonActivating: Bool = false) {
        var style: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        if nonActivating { style.insert(.nonactivatingPanel) }
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
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
        isOpaque = false
        backgroundColor = .clear
        // Spotlight/Raycast-style: no traffic-light buttons (Esc or the shortcut closes the panel).
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Escape closes the panel.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
