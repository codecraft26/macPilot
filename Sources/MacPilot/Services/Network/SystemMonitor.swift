import AppKit
import Darwin
import Foundation
import Observation

/// Cumulative CPU ticks for one core (from `host_processor_info`).
struct CPUTicks: Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64
}

/// One process's CPU share, from `ps`.
struct ProcessUsage: Equatable, Identifiable {
    var pid: Int32
    var percent: Double
    var name: String
    var id: Int32 { pid }
}

/// Pure maths and formatting for the CPU readout (unit-tested).
enum CPUMath {
    /// Busy fraction (0…1) per core and in total between two readings. Counters are 32-bit and may wrap.
    static func usage(previous: [CPUTicks], current: [CPUTicks]) -> (total: Double, perCore: [Double]) {
        guard previous.count == current.count, !current.isEmpty else { return (0, []) }
        var busyAll: UInt64 = 0, totalAll: UInt64 = 0
        var perCore: [Double] = []
        for (before, now) in zip(previous, current) {
            let user = NetworkMath.delta(before.user, now.user), system = NetworkMath.delta(before.system, now.system)
            let nice = NetworkMath.delta(before.nice, now.nice), idle = NetworkMath.delta(before.idle, now.idle)
            let busy = user + system + nice
            let total = busy + idle
            perCore.append(total == 0 ? 0 : Double(busy) / Double(total))
            busyAll += busy
            totalAll += total
        }
        return (totalAll == 0 ? 0 : Double(busyAll) / Double(totalAll), perCore)
    }

    /// Exponential smoothing so the number doesn't jump around every second.
    static func smooth(_ previous: Double?, _ next: Double, alpha: Double = 0.5) -> Double {
        guard let previous else { return next }
        return previous + alpha * (next - previous)
    }

    /// "23%" (0…100, rounded).
    static func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded()))%" }

    /// Above 80% the readout turns orange.
    static func isHot(_ fraction: Double) -> Bool { fraction >= 0.8 }

    /// `ps -Aceo pid=,pcpu=,comm= -r` → the busiest processes (MacPilot's own `ps` is left out).
    static func parseTop(_ output: String, limit: Int = 5) -> [ProcessUsage] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> ProcessUsage? in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let percent = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
            let name = String(parts[2]).trimmingCharacters(in: .whitespaces)
            return name == "ps" ? nil : ProcessUsage(pid: pid, percent: percent, name: name)
        }
        .sorted { $0.percent > $1.percent }
        .prefix(limit).map { $0 }
    }
}

/// How network rates are written: auto (KB/s or MB/s), always MB/s, or Mbps.
enum RateUnit: String, CaseIterable, Identifiable {
    case auto, megabytes, megabits
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .megabytes: return "MB/s"
        case .megabits: return "Mbps"
        }
    }

    /// Readout text for bytes per second.
    func format(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        switch self {
        case .auto: return NetworkMath.rate(value)
        case .megabytes: return String(format: value >= 10_000_000 ? "%.1f MB/s" : "%.2f MB/s", value / 1_000_000)
        case .megabits:
            let mbps = value * 8 / 1_000_000
            return String(format: mbps >= 100 ? "%.0f Mbps" : "%.1f Mbps", mbps)
        }
    }
}

/// What the live readout shows and where.
enum StatsDisplay {
    /// Menu bar readout: auto (only on Macs without a notch, or with MacPilot's notch off), off, network, cpu or both.
    enum MenuBarMode: String, CaseIterable, Identifiable {
        case auto, off, network, cpu, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Automatic (when there's no notch)"
            case .off: return "Off"
            case .network: return "Network"
            case .cpu: return "CPU"
            case .both: return "Network and CPU"
            }
        }
    }

    struct Parts: Equatable { var network: Bool; var cpu: Bool; var any: Bool { network || cpu } }

    /// Beside the notch: only on a real notch, with MacPilot's notch on.
    static func notch(networkOn: Bool, cpuOn: Bool, notchEnabled: Bool, hasHardwareNotch: Bool) -> Parts {
        guard notchEnabled, hasHardwareNotch else { return Parts(network: false, cpu: false) }
        return Parts(network: networkOn, cpu: cpuOn)
    }

    static func menuBar(mode: MenuBarMode, networkOn: Bool, cpuOn: Bool, notchEnabled: Bool, hasHardwareNotch: Bool) -> Parts {
        switch mode {
        case .off: return Parts(network: false, cpu: false)
        case .network: return Parts(network: true, cpu: false)
        case .cpu: return Parts(network: false, cpu: true)
        case .both: return Parts(network: true, cpu: true)
        case .auto:
            // Same choices as the notch readout, moved to the menu bar when there's no notch to sit beside.
            guard !(notchEnabled && hasHardwareNotch) else { return Parts(network: false, cpu: false) }
            return Parts(network: networkOn, cpu: cpuOn)
        }
    }

    @MainActor static var screenHasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }

    @MainActor static var menuBarMode: MenuBarMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: PrefKey.menuBarStats), let mode = MenuBarMode(rawValue: raw) { return mode }
        // Earlier versions had a single "network in the menu bar" switch.
        return defaults.bool(forKey: PrefKey.menuBarNetwork) ? .network : .auto
    }

    @MainActor static var unit: RateUnit { RateUnit(rawValue: UserDefaults.standard.string(forKey: PrefKey.statsUnit) ?? "") ?? .auto }

    @MainActor static var interval: TimeInterval { UserDefaults.standard.double(forKey: PrefKey.statsInterval) >= 2 ? 2 : 1 }

    /// Snapshots only: what the notch readout shows regardless of this Mac's screen.
    @MainActor static var previewParts: Parts?

    @MainActor static var notchParts: Parts {
        if let previewParts { return previewParts }
        let defaults = UserDefaults.standard
        return notch(networkOn: defaults.bool(forKey: PrefKey.notchNetworkReadout), cpuOn: defaults.bool(forKey: PrefKey.notchCPUReadout),
                     notchEnabled: defaults.bool(forKey: PrefKey.notchEnabled), hasHardwareNotch: screenHasNotch)
    }

    @MainActor static var menuBarParts: Parts {
        let defaults = UserDefaults.standard
        return menuBar(mode: menuBarMode, networkOn: defaults.bool(forKey: PrefKey.notchNetworkReadout), cpuOn: defaults.bool(forKey: PrefKey.notchCPUReadout),
                       notchEnabled: defaults.bool(forKey: PrefKey.notchEnabled), hasHardwareNotch: screenHasNotch)
    }
}

/// Sampling stops while the screen is locked, the displays sleep or the Mac sleeps.
struct SamplingGate: Equatable {
    var locked = false
    var displaysAsleep = false
    var systemAsleep = false
    var isPaused: Bool { locked || displaysAsleep || systemAsleep }
}

/// Live CPU usage (total and per core), memory in use, and the busiest processes on demand.
/// Reading `host_processor_info` once a second costs a few microseconds.
@Observable
@MainActor
final class SystemMonitor {
    static let shared = SystemMonitor()

    /// Smoothed busy fraction across all cores (0…1).
    private(set) var cpu: Double = 0
    private(set) var perCore: [Double] = []
    /// Last 60 samples of `cpu`.
    private(set) var history: [Double] = []
    /// Memory in use (app + wired + compressed) as a fraction of RAM.
    private(set) var memory: Double = 0
    private(set) var topProcesses: [ProcessUsage] = []
    private(set) var gate = SamplingGate()
    private(set) var isRunning = false

    private var previous: [CPUTicks] = []
    private var timer: Timer?
    private var smoothed: Double?
    private var observers: [NSObjectProtocol] = []
    /// Open monitor panels; the process list is only gathered while one is showing.
    private var viewers = 0
    private var lastTop = Date.distantPast

    private init() {}

    /// Called at launch and when settings change: runs only if a readout needs it (or the panel is open).
    func refreshDemand() {
        observeSleepAndLock()
        let needed = StatsDisplay.notchParts.cpu || StatsDisplay.menuBarParts.cpu || viewers > 0
        if needed && !gate.isPaused { start() } else { stop() }
        NetworkMonitor.shared.setPaused(gate.isPaused)
    }

    func start() {
        let interval = StatsDisplay.interval
        if let timer, timer.timeInterval == interval { return }
        timer?.invalidate()
        previous = Self.readTicks()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { SystemMonitor.shared.sample() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        isRunning = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// Previews and snapshots only.
    func setPreview(cpu: Double, perCore: [Double], history: [Double], memory: Double, top: [ProcessUsage]) {
        self.cpu = cpu
        self.perCore = perCore
        self.history = history
        self.memory = memory
        topProcesses = top
        isPreview = true
    }
    private var isPreview = false

    func addViewer() { viewers += 1; refreshDemand(); Task { await refreshTop(force: true) } }
    func removeViewer() { viewers = max(0, viewers - 1); refreshDemand() }

    func sample() {
        let current = Self.readTicks()
        let usage = CPUMath.usage(previous: previous, current: current)
        previous = current
        let value = CPUMath.smooth(smoothed, usage.total)
        smoothed = value
        cpu = value
        perCore = usage.perCore
        history = Array((history + [value]).suffix(60))
        memory = Self.readMemory()
        if viewers > 0 { Task { await refreshTop() } }
    }

    private func refreshTop(force: Bool = false) async {
        guard !isPreview, force || Date().timeIntervalSince(lastTop) >= 2 else { return }
        lastTop = Date()
        let result = await Shell.run("/bin/ps", ["-Aceo", "pid=,pcpu=,comm=", "-r"], timeout: 5)
        if result.ok { topProcesses = CPUMath.parseTop(result.stdout) }
    }

    // MARK: Lock and sleep

    func apply(_ gate: SamplingGate) {
        self.gate = gate
        refreshDemand()
    }

    private func observeSleepAndLock() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, NotificationCenter, (inout SamplingGate) -> Void)] = [
            (NSWorkspace.willSleepNotification, workspace, { $0.systemAsleep = true }),
            (NSWorkspace.didWakeNotification, workspace, { $0.systemAsleep = false }),
            (NSWorkspace.screensDidSleepNotification, workspace, { $0.displaysAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, workspace, { $0.displaysAsleep = false }),
            (Notification.Name("com.apple.screenIsLocked"), DistributedNotificationCenter.default(), { $0.locked = true }),
            (Notification.Name("com.apple.screenIsUnlocked"), DistributedNotificationCenter.default(), { $0.locked = false })
        ]
        for (name, center, change) in pairs {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    var gate = SystemMonitor.shared.gate
                    change(&gate)
                    SystemMonitor.shared.apply(gate)
                }
            })
        }
    }

    // MARK: Reading

    /// Per-core cumulative ticks.
    nonisolated static func readTicks() -> [CPUTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * states + Int(state)])) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    /// Memory in use (active + wired + compressed) / physical RAM.
    nonisolated static func readMemory() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        let used = Double(UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return min(1, used / Double(ProcessInfo.processInfo.physicalMemory))
    }
}
