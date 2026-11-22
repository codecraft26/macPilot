import AppKit
import Darwin
import Foundation
import Observation

/// One listening socket and the process that owns it.
struct ListeningPort: Identifiable, Equatable, Hashable {
    var port: Int
    var proto: String
    var address: String
    var pid: Int32
    var process: String
    var uid: Int32
    var user: String
    var command = ""
    var cwd = ""
    var executablePath = ""

    var id: String { "\(proto):\(address):\(port):\(pid)" }
    var isLocalOnly: Bool { address.hasPrefix("127.") || address == "[::1]" || address == "localhost" }
    /// The folder a dev server was started in (not "/" or your home folder, which most apps use).
    var projectName: String { cwd.isEmpty || cwd == "/" || cwd == NSHomeDirectory() ? "" : URL(fileURLWithPath: cwd).lastPathComponent }
}

/// Parses `lsof -nP -iTCP -sTCP:LISTEN -iUDP -F pcuLPn` (field output, one field per line).
enum LsofParser {
    static func parse(_ output: String) -> [ListeningPort] {
        var results: [ListeningPort] = []
        var pid: Int32 = 0, command = "", uid: Int32 = -1, login = "", proto = ""
        for raw in output.split(whereSeparator: \.isNewline) {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0; command = ""; uid = -1; login = ""; proto = ""
            case "c": command = value
            case "u": uid = Int32(value) ?? -1
            case "L": login = value
            case "P": proto = value
            case "n":
                guard let (address, port) = endpoint(value) else { continue }
                let item = ListeningPort(port: port, proto: proto.isEmpty ? "TCP" : proto, address: address, pid: pid, process: command, uid: uid, user: login)
                if !results.contains(where: { $0.port == item.port && $0.pid == item.pid && $0.proto == item.proto && $0.address == item.address }) {
                    results.append(item)
                }
            default: continue
            }
        }
        return results.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
    }

    /// "*:3000", "127.0.0.1:5432", "[::1]:8080", "10.0.0.2:5353->1.2.3.4:5353" → (address, port); "*:*" → nil.
    static func endpoint(_ name: String) -> (String, Int)? {
        let local = name.components(separatedBy: "->").first ?? name
        guard let colon = local.lastIndex(of: ":"), let port = Int(local[local.index(after: colon)...]), port > 0 else { return nil }
        return (String(local[..<colon]), port)
    }
}

/// Which processes may never be killed, and why (shown in the UI).
enum PortProtection {
    static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/Library/Apple/"]
    static let systemNames: Set<String> = ["launchd", "kernel_task", "mDNSResponder", "rapportd", "sharingd", "ControlCenter", "identityservicesd",
                                           "AirPlayXPCHelper", "remoted", "netbiosd", "configd", "syslogd", "WindowServer", "loginwindow",
                                           "screensharingd", "cupsd", "bluetoothd", "airportd", "apsd", "UserEventAgent", "symptomsd"]

    static func reason(_ port: ListeningPort, currentUID: Int32 = Int32(getuid()), currentPID: Int32 = getpid()) -> String? {
        if port.pid == currentPID || port.process == "MacPilot" { return "This is MacPilot itself." }
        if port.pid <= 1 { return "This is a core system process." }
        if port.uid != currentUID {
            return port.uid == 0 ? "Owned by the system (root). MacPilot never uses sudo." : "Owned by another user (\(port.user.isEmpty ? String(port.uid) : port.user)). MacPilot only stops your own processes."
        }
        if systemNames.contains(port.process) { return "\(port.process) is part of macOS." }
        if systemPathPrefixes.contains(where: port.executablePath.hasPrefix) { return "\(port.process) is part of macOS (\(port.executablePath))." }
        return nil
    }
}

/// Signals and liveness, swappable in tests.
protocol ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool
    func isAlive(_ pid: Int32) -> Bool
}

struct SystemProcessSignaling: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { kill(pid, signal) == 0 }
    func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

enum KillOutcome: Equatable {
    case stopped
    /// Still running after SIGTERM and the wait: offer Force kill.
    case stillRunning
    case forceKilled
    case refused(String)
    case failed(String)

    var message: String {
        switch self {
        case .stopped: return "Stopped."
        case .stillRunning: return "Still running after 3 seconds. Force kill?"
        case .forceKilled: return "Force-killed."
        case .refused(let reason): return "Not stopped: \(reason)"
        case .failed(let reason): return "Couldn't stop it: \(reason)"
        }
    }
}

/// Lists listening ports and stops processes politely (SIGTERM, then SIGKILL only when asked).
@Observable
@MainActor
final class PortKiller {
    static let shared = PortKiller()

    private(set) var ports: [ListeningPort] = []
    private(set) var lastRefresh: Date?
    private(set) var error: String?
    var signaling: ProcessSignaling = SystemProcessSignaling()
    var lister: () async -> String? = {
        let result = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-F", "pcuLPn"], timeout: 15)
        // lsof exits 1 when nothing matches; output is still valid.
        return result.timedOut ? nil : result.stdout
    }
    var graceSeconds: TimeInterval = 3
    /// Adds command line, executable and folder (replaced in tests so fixture PIDs aren't looked up on the real system).
    var enricher: (inout ListeningPort) -> Void = { PortKiller.enrich(&$0) }
    var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    static let commonPorts = [3000, 5173, 8080, 5432, 6379]
    private var timer: Timer?
    private var watchers = 0

    func refresh() async {
        guard let output = await lister() else { error = "lsof didn't answer in time."; return }
        var found = LsofParser.parse(output)
        for index in found.indices { enricher(&found[index]) }
        ports = found
        lastRefresh = Date()
        error = nil
    }

    /// Live refresh every 3 s while a Ports view is visible.
    func watch() {
        watchers += 1
        guard timer == nil else { return }
        Task { await refresh() }
        let timer = Timer(timeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { Task { await PortKiller.shared.refresh() } } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    func filtered(_ text: String) -> [ListeningPort] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return ports }
        if let number = Int(query.replacingOccurrences(of: ":", with: "")) { return ports.filter { String($0.port).hasPrefix(String(number)) } }
        return ports.filter { "\($0.process) \($0.command) \($0.projectName) \($0.user)".lowercased().contains(query) }
    }

    func owners(of port: Int) -> [ListeningPort] { ports.filter { $0.port == port } }

    /// Command line, executable and working folder (readable for your own processes only).
    static func enrich(_ port: inout ListeningPort) {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(port.pid, &path, UInt32(path.count)) > 0 { port.executablePath = String(cString: path) }
        var vnode = proc_vnodepathinfo()
        if proc_pidinfo(port.pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            port.cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        port.command = commandLine(port.pid) ?? port.process
    }

    static func commandLine(_ pid: Int32) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var parts: [String] = []
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        while index < size, parts.count < argc {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            parts.append(String(decoding: buffer[start..<index].map { UInt8(bitPattern: $0) }, as: UTF8.self))
            index += 1
        }
        return parts.isEmpty ? nil : AgentRedactor.redact(parts.joined(separator: " "))
    }

    // MARK: Stopping

    /// SIGTERM, then wait up to 3 s. Never sends SIGKILL by itself.
    func terminate(_ port: ListeningPort) async -> KillOutcome {
        if let reason = PortProtection.reason(port) { return .refused(reason) }
        guard signaling.send(SIGTERM, to: port.pid) else { return .failed(String(cString: strerror(errno))) }
        let steps = max(1, Int(graceSeconds / 0.25))
        for _ in 0..<steps {
            await sleep(0.25)
            if !signaling.isAlive(port.pid) {
                await refresh()
                return .stopped
            }
        }
        return .stillRunning
    }

    /// Only after `terminate` returned `.stillRunning` and the user confirmed Force kill.
    func forceKill(_ port: ListeningPort) async -> KillOutcome {
        if let reason = PortProtection.reason(port) { return .refused(reason) }
        guard signaling.send(SIGKILL, to: port.pid) else { return .failed(String(cString: strerror(errno))) }
        await sleep(0.3)
        await refresh()
        return signaling.isAlive(port.pid) ? .failed("it's still running") : .forceKilled
    }

    func icon(for port: ListeningPort) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: port.pid), let icon = app.icon { return icon }
        if !port.executablePath.isEmpty, let range = port.executablePath.range(of: ".app/") {
            return NSWorkspace.shared.icon(forFile: String(port.executablePath[..<range.lowerBound]) + ".app")
        }
        return NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
    }

    /// "kill port 3000" / "what's on port 5432" in ⌥K or voice.
    enum Command: Equatable { case kill(Int), show(Int) }

    static func command(_ text: String) -> Command? {
        let lower = text.lowercased()
        guard let match = lower.range(of: #"\bport\s*:?\s*(\d{1,5})\b|:(\d{1,5})\b"#, options: .regularExpression),
              let port = Int(lower[match].filter(\.isNumber)), (1...65_535).contains(port) else { return nil }
        if lower.range(of: #"\b(kill|stop|free|close|end)\b"#, options: .regularExpression) != nil { return .kill(port) }
        if lower.range(of: #"what('s| is)|who('s| is)|which|show|using|on port"#, options: .regularExpression) != nil { return .show(port) }
        return nil
    }
}

/// Confirm-first stop from ⌥K and voice: shows the process, SIGTERM, then offers Force kill.
@MainActor
enum PortActions {
    static func confirmAndStop(port number: Int) async {
        let killer = PortKiller.shared
        await killer.refresh()
        guard let port = killer.owners(of: number).first(where: { PortProtection.reason($0) == nil }) ?? killer.owners(of: number).first else {
            alert("Nothing is listening on port \(number).")
            return
        }
        if let reason = PortProtection.reason(port) {
            alert("\(port.process) (PID \(port.pid)) on port \(number) can't be stopped.", info: reason)
            return
        }
        guard confirm("Stop \(port.process) on port \(number)?", info: "PID \(port.pid) · \(port.command)" + (port.cwd.isEmpty ? "" : "\nin \(port.cwd)"),
                      button: "Stop") else { return }
        let outcome = await killer.terminate(port)
        if outcome == .stillRunning {
            guard confirm("\(port.process) is still running. Force kill?", info: "Unsaved work in that process will be lost.", button: "Force Kill") else { return }
            alert((await killer.forceKill(port)).message)
        } else if outcome != .stopped {
            alert(outcome.message)
        }
    }

    private static func confirm(_ message: String, info: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func alert(_ message: String, info: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
