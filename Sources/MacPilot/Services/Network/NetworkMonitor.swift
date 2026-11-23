import Darwin
import Foundation
import Observation
import SystemConfiguration

/// Byte counters for one network interface, read from `getifaddrs` (AF_LINK entries carry `if_data`).
struct InterfaceCounters: Equatable {
    var name: String
    var received: UInt64
    var sent: UInt64
}

/// One second of traffic: bytes per second down and up.
struct NetworkSample: Equatable {
    var date: Date
    var down: Double
    var up: Double
}

/// Pure maths and formatting for the network readouts (unit-tested).
enum NetworkMath {
    /// `if_data` counters are 32-bit on macOS and wrap at 4 GiB.
    static let counterLimit: UInt64 = 1 << 32

    /// Bytes moved between two readings of a counter, allowing for a single wrap-around.
    static func delta(_ previous: UInt64, _ current: UInt64, limit: UInt64 = counterLimit) -> UInt64 {
        if current >= previous { return current - previous }
        // Wrapped (or the interface was reset): count from the wrap point.
        guard previous < limit else { return current }
        return (limit - previous) + current
    }

    /// Down/up rates in bytes per second between two snapshots. Interfaces that appear or disappear are ignored.
    static func rates(previous: [InterfaceCounters], current: [InterfaceCounters], interval: TimeInterval) -> (down: Double, up: Double) {
        guard interval > 0 else { return (0, 0) }
        let old = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var down: UInt64 = 0, up: UInt64 = 0
        for counters in current {
            guard let before = old[counters.name] else { continue }
            down += delta(before.received, counters.received)
            up += delta(before.sent, counters.sent)
        }
        return (Double(down) / interval, Double(up) / interval)
    }

    /// Interfaces that carry real traffic: no loopback, tunnels, AirDrop or bridges (they'd double-count).
    static func isCountable(_ name: String) -> Bool {
        let skipped = ["lo", "utun", "ipsec", "gif", "stf", "awdl", "llw", "anpi", "bridge", "ap", "XHC", "vmenet"]
        return !skipped.contains { name.hasPrefix($0) }
    }

    /// "1.2 MB/s", "640 KB/s", "0 KB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_000_000_000 { return String(format: "%.1f GB/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: value >= 100_000_000 ? "%.0f MB/s" : "%.1f MB/s", value / 1_000_000) }
        return String(format: "%.0f KB/s", value / 1_000)
    }

    /// Short form for the notch and menu bar: "1.2M", "640K", "0K".
    static func compact(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_000_000_000 { return String(format: "%.1fG", value / 1_000_000_000) }
        if value >= 10_000_000 { return String(format: "%.0fM", value / 1_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        return String(format: "%.0fK", value / 1_000)
    }

    /// Speed test numbers are in bits per second: "245 Mbps", "8.4 Mbps", "1.2 Gbps".
    static func mbps(_ bitsPerSecond: Double) -> String {
        let mbps = max(0, bitsPerSecond) / 1_000_000
        if mbps >= 1_000 { return String(format: "%.1f Gbps", mbps / 1_000) }
        if mbps >= 100 { return String(format: "%.0f Mbps", mbps) }
        return String(format: "%.1f Mbps", mbps)
    }

    /// Keeps the newest `limit` samples.
    static func appending(_ sample: NetworkSample, to history: [NetworkSample], limit: Int = 60) -> [NetworkSample] {
        Array((history + [sample]).suffix(limit))
    }
}

/// Live download/upload throughput, sampled once a second from the interface byte counters (very low CPU).
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var down: Double = 0
    private(set) var up: Double = 0
    /// Last 60 seconds.
    private(set) var history: [NetworkSample] = []
    /// The interface with an IPv4 address that moves the most traffic (e.g. "en0").
    private(set) var interfaceName = ""
    private(set) var interfaceDisplayName = ""
    private(set) var localIP = ""

    private var previous: [InterfaceCounters] = []
    private var previousDate = Date()
    private var timer: Timer?
    private var totals: [String: UInt64] = [:]
    private var displayNames: [String: String] = [:]

    private init() {}

    func start() {
        guard timer == nil else { return }
        previous = Self.readCounters().counters
        previousDate = Date()
        refreshDisplayNames()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { NetworkMonitor.shared.sample() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let now = Date()
        let reading = Self.readCounters()
        let rates = NetworkMath.rates(previous: previous, current: reading.counters, interval: now.timeIntervalSince(previousDate))
        let old = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for counters in reading.counters {
            if let before = old[counters.name] {
                totals[counters.name, default: 0] += NetworkMath.delta(before.received, counters.received) + NetworkMath.delta(before.sent, counters.sent)
            }
        }
        previous = reading.counters
        previousDate = now
        down = rates.down
        up = rates.up
        history = NetworkMath.appending(NetworkSample(date: now, down: rates.down, up: rates.up), to: history)

        // Primary interface: has an IPv4 address; prefer the busiest, then the lowest-numbered (en0 before en1).
        let candidates = reading.addresses.keys.sorted()
        let primary = candidates.max { (totals[$0] ?? 0, $1) < (totals[$1] ?? 0, $0) } ?? ""
        if primary != interfaceName {
            interfaceName = primary
            if displayNames[primary] == nil { refreshDisplayNames() }
            interfaceDisplayName = displayNames[primary] ?? primary
        }
        localIP = reading.addresses[primary] ?? ""
    }

    private func refreshDisplayNames() {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        for interface in interfaces {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                displayNames[bsd] = name
            }
        }
    }

    /// Counters for every up, running, countable interface, plus their IPv4 addresses.
    nonisolated static func readCounters() -> (counters: [InterfaceCounters], addresses: [String: String]) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return ([], [:]) }
        defer { freeifaddrs(head) }
        var counters: [InterfaceCounters] = []
        var addresses: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard NetworkMath.isCountable(name) else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                guard let raw = entry.pointee.ifa_data else { continue }
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                counters.append(InterfaceCounters(name: name, received: UInt64(data.ifi_ibytes), sent: UInt64(data.ifi_obytes)))
            case AF_INET:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = String(cString: host)
                }
            default:
                break
            }
        }
        return (counters, addresses)
    }
}
