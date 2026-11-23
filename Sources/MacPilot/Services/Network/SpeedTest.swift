import Foundation
import Observation

/// One run of macOS's built-in `networkQuality` test.
struct SpeedTestResult: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    /// Bits per second.
    var download: Double
    var upload: Double
    /// Idle round-trip time in milliseconds.
    var latency: Double
    /// Round trips per minute under load (Apple's "responsiveness"), if reported.
    var responsiveness: Double?
    var interface: String

    var summary: String {
        "↓ \(NetworkMath.mbps(download))  ↑ \(NetworkMath.mbps(upload))  · \(Int(latency.rounded())) ms"
    }

    /// Spoken by Pilot.
    var spoken: String {
        func spokenRate(_ bits: Double) -> String {
            NetworkMath.mbps(bits).replacingOccurrences(of: "Gbps", with: "gigabits").replacingOccurrences(of: "Mbps", with: "megabits")
        }
        return "Download \(spokenRate(download)), upload \(spokenRate(upload)), latency \(Int(latency.rounded())) milliseconds."
    }

    enum ParseError: LocalizedError {
        case notJSON, reported(String), missing

        var errorDescription: String? {
            switch self {
            case .notJSON: return "The speed test didn't return a result."
            case .reported(let message): return "Speed test failed: \(message)"
            case .missing: return "The speed test result was incomplete."
            }
        }
    }

    /// Parses `networkQuality -c` output (dl_throughput / ul_throughput in bits per second, base_rtt in ms).
    static func parse(_ data: Data, date: Date = Date()) throws -> SpeedTestResult {
        // The tool can print warnings before the JSON object.
        let start = data.firstIndex(of: UInt8(ascii: "{")) ?? data.startIndex
        guard let object = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any] else { throw ParseError.notJSON }
        if let error = object["error_code"] ?? object["error"] {
            throw ParseError.reported(object["error_domain"].map { "\($0) \(error)" } ?? "\(error)")
        }
        func number(_ key: String) -> Double? {
            if let value = object[key] as? NSNumber { return value.doubleValue }
            if let text = object[key] as? String { return Double(text) }
            return nil
        }
        let download = number("dl_throughput"), upload = number("ul_throughput")
        guard download != nil || upload != nil else { throw ParseError.missing }
        // Older macOS versions report latency only through responsiveness (RPM): 60000 / RPM ≈ ms per round trip.
        let rpm = number("responsiveness")
        let latency = number("base_rtt") ?? rpm.map { $0 > 0 ? 60_000 / $0 : 0 } ?? 0
        return SpeedTestResult(date: date, download: download ?? 0, upload: upload ?? 0, latency: latency,
                               responsiveness: rpm, interface: object["interface_name"] as? String ?? "")
    }
}

/// Runs `networkQuality -c`, shows progress and keeps the last 20 results on this Mac.
@Observable
@MainActor
final class SpeedTest {
    static let shared = SpeedTest()
    nonisolated static let historyLimit = 20
    /// Typical run length, for the progress bar (the tool itself doesn't report progress).
    nonisolated static let expectedDuration: TimeInterval = 22

    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private(set) var history: [SpeedTestResult] = []
    private(set) var lastError: String?
    private let key = "network.speedTests"

    var latest: SpeedTestResult? { history.first }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([SpeedTestResult].self, from: data) {
            history = saved
        }
    }

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/networkQuality") }

    /// 0…0.95 while running, based on elapsed time; the phase label follows the tool's order (latency, then load).
    nonisolated static func progress(elapsed: TimeInterval) -> Double {
        min(0.95, max(0, elapsed / expectedDuration))
    }

    nonisolated static func phase(elapsed: TimeInterval) -> String {
        elapsed < 2 ? "Measuring latency…" : elapsed < expectedDuration * 0.9 ? "Testing download and upload…" : "Finishing…"
    }

    func progress(at date: Date) -> Double {
        guard let startedAt else { return 0 }
        return Self.progress(elapsed: date.timeIntervalSince(startedAt))
    }

    nonisolated static func appending(_ result: SpeedTestResult, to history: [SpeedTestResult]) -> [SpeedTestResult] {
        Array(([result] + history).prefix(historyLimit))
    }

    /// Runs a test (or waits for the one already running) and returns the result.
    @discardableResult
    func run() async -> SpeedTestResult? {
        if isRunning {
            while isRunning { try? await Task.sleep(for: .milliseconds(300)) }
            return lastError == nil ? latest : nil
        }
        guard Self.isAvailable else {
            lastError = "networkQuality isn't available on this Mac (it needs macOS 12 or later)."
            return nil
        }
        isRunning = true
        startedAt = Date()
        lastError = nil
        defer { isRunning = false; startedAt = nil }

        let output = await Shell.run("/usr/bin/networkQuality", ["-c"], timeout: 120)
        if output.timedOut {
            lastError = "The speed test took too long. Check your connection and try again."
            return nil
        }
        let data = Data(output.stdout.utf8)
        do {
            let result = try SpeedTestResult.parse(data)
            history = Self.appending(result, to: history)
            save()
            NotchController.shared.peek(NotchPeek(systemImage: "speedometer", tint: .blue, title: "Speed test done",
                                                  subtitle: result.summary, duration: 8))
            return result
        } catch {
            let reason = output.stderr.split(separator: "\n").first.map(String.init) ?? ""
            lastError = output.stdout.isEmpty && !reason.isEmpty ? "Speed test failed: \(reason)" : error.localizedDescription
            return nil
        }
    }

    func clearHistory() {
        history = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: key) }
    }
}
