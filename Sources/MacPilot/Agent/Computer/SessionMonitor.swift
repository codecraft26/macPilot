import AppKit
import CoreGraphics
import Foundation
import Observation

/// Whether someone is at the Mac: screen unlocked and awake. GUI and browser steps pause while it isn't;
/// file and command steps continue.
@Observable
@MainActor
final class SessionMonitor {
    static let shared = SessionMonitor()

    private(set) var isLocked = false
    private(set) var isAsleep = false
    var isAvailable: Bool { !isLocked && !isAsleep }
    var statusText: String {
        isAvailable ? "available" : isLocked ? "unavailable (screen locked)" : "unavailable (display asleep)"
    }

    private var started = false

    init(startObserving: Bool = false) {
        if startObserving { start() }
    }

    func start() {
        guard !started else { return }
        started = true
        isLocked = Self.screenLockedNow()
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SessionMonitor.shared.isLocked = true }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SessionMonitor.shared.isLocked = false }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SessionMonitor.shared.isAsleep = true }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    SessionMonitor.shared.isAsleep = false
                    SessionMonitor.shared.isLocked = SessionMonitor.screenLockedNow()
                }
            }
        }
    }

    /// For tests and previews.
    func set(locked: Bool, asleep: Bool = false) {
        isLocked = locked
        isAsleep = asleep
    }

    nonisolated static func screenLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        return (session["CGSSessionScreenIsLocked"] as? Int ?? 0) == 1
    }
}
