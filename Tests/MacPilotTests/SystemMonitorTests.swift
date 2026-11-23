import Darwin
import XCTest
@testable import MacPilot

final class SystemMonitorTests: XCTestCase {
    // MARK: CPU maths

    func testCPUPercentFromTickDeltas() {
        let before = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0), CPUTicks(user: 0, system: 0, idle: 1_000, nice: 0)]
        // Core 0: 60 busy of 100 → 60%. Core 1: 20 busy (10 user + 10 nice) of 100 → 20%.
        let after = [CPUTicks(user: 140, system: 70, idle: 890, nice: 0), CPUTicks(user: 10, system: 0, idle: 1_080, nice: 10)]
        let usage = CPUMath.usage(previous: before, current: after)
        XCTAssertEqual(usage.perCore[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(usage.perCore[1], 0.2, accuracy: 0.0001)
        XCTAssertEqual(usage.total, 0.4, accuracy: 0.0001, "total weights cores by their ticks")
    }

    func testCPUTicksWrapAndMismatchedCores() {
        let limit = UInt64(UInt32.max) + 1
        let before = [CPUTicks(user: limit - 10, system: 0, idle: 0, nice: 0)]
        let after = [CPUTicks(user: 30, system: 0, idle: 60, nice: 0)]
        XCTAssertEqual(CPUMath.usage(previous: before, current: after).total, 0.4, accuracy: 0.0001, "a 32-bit wrap counts the ticks across it")
        XCTAssertEqual(CPUMath.usage(previous: before, current: after + after).total, 0, "core count changed: no reading")
        XCTAssertEqual(CPUMath.usage(previous: after, current: after).total, 0, "no ticks: 0%, not NaN")
    }

    func testSmoothingAndFormatting() {
        XCTAssertEqual(CPUMath.smooth(nil, 0.8), 0.8)
        XCTAssertEqual(CPUMath.smooth(0.2, 0.8), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CPUMath.percent(0.234), "23%")
        XCTAssertEqual(CPUMath.percent(1.4), "100%")
        XCTAssertEqual(CPUMath.percent(-0.1), "0%")
        XCTAssertFalse(CPUMath.isHot(0.79))
        XCTAssertTrue(CPUMath.isHot(0.8), "orange from 80%")
    }

    func testParsesTopProcesses() {
        let output = """
          512 98.5 WindowServer
          88  12,0 Google Chrome Helper (Renderer)
          999  0.4 ps
          7    3.1 kernel_task
          bad line
        """
        let top = CPUMath.parseTop(output, limit: 5)
        XCTAssertEqual(top.map(\.name), ["WindowServer", "Google Chrome Helper (Renderer)", "kernel_task"])
        XCTAssertEqual(top[1].percent, 12.0)
        XCTAssertEqual(CPUMath.parseTop(output, limit: 1).count, 1)
    }

    // MARK: Units

    func testRateUnits() {
        XCTAssertEqual(RateUnit.auto.format(2_400_000), "2.4 MB/s")
        XCTAssertEqual(RateUnit.auto.format(120_000), "120 KB/s")
        XCTAssertEqual(RateUnit.megabytes.format(120_000), "0.12 MB/s")
        XCTAssertEqual(RateUnit.megabytes.format(24_000_000), "24.0 MB/s")
        XCTAssertEqual(RateUnit.megabits.format(2_400_000), "19.2 Mbps")
        XCTAssertEqual(RateUnit.megabits.format(25_000_000), "200 Mbps")
        XCTAssertEqual(RateUnit.megabits.format(-5), "0.0 Mbps")
    }

    // MARK: Where the readout shows

    func testNotchTogglesAndPlacement() {
        XCTAssertEqual(StatsDisplay.notch(networkOn: true, cpuOn: true, notchEnabled: true, hasHardwareNotch: true), .init(network: true, cpu: true))
        XCTAssertEqual(StatsDisplay.notch(networkOn: false, cpuOn: true, notchEnabled: true, hasHardwareNotch: true), .init(network: false, cpu: true))
        XCTAssertEqual(StatsDisplay.notch(networkOn: true, cpuOn: false, notchEnabled: true, hasHardwareNotch: true), .init(network: true, cpu: false))
        XCTAssertFalse(StatsDisplay.notch(networkOn: true, cpuOn: true, notchEnabled: false, hasHardwareNotch: true).any, "notch off: nothing beside it")
        XCTAssertFalse(StatsDisplay.notch(networkOn: true, cpuOn: true, notchEnabled: true, hasHardwareNotch: false).any, "no notch: nothing at the top centre")
    }

    func testMenuBarModes() {
        func parts(_ mode: StatsDisplay.MenuBarMode, notch: Bool, enabled: Bool = true, network: Bool = true, cpu: Bool = true) -> StatsDisplay.Parts {
            StatsDisplay.menuBar(mode: mode, networkOn: network, cpuOn: cpu, notchEnabled: enabled, hasHardwareNotch: notch)
        }
        XCTAssertEqual(parts(.auto, notch: false), .init(network: true, cpu: true), "no notch: the readout moves to the menu bar")
        XCTAssertFalse(parts(.auto, notch: true).any, "with a notch it stays beside the notch")
        XCTAssertTrue(parts(.auto, notch: true, enabled: false).any, "MacPilot's notch turned off: menu bar")
        XCTAssertEqual(parts(.auto, notch: false, cpu: false), .init(network: true, cpu: false), "the notch toggles carry over")
        XCTAssertEqual(parts(.network, notch: true), .init(network: true, cpu: false))
        XCTAssertEqual(parts(.cpu, notch: true), .init(network: false, cpu: true))
        XCTAssertEqual(parts(.both, notch: true, network: false, cpu: false), .init(network: true, cpu: true), "explicit choices ignore the notch toggles")
        XCTAssertFalse(parts(.off, notch: false).any)
    }

    @MainActor
    func testLegacyMenuBarSwitchMigrates() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: PrefKey.menuBarStats), defaults.object(forKey: PrefKey.menuBarNetwork))
        defer {
            defaults.set(saved.0, forKey: PrefKey.menuBarStats)
            defaults.set(saved.1, forKey: PrefKey.menuBarNetwork)
        }
        defaults.removeObject(forKey: PrefKey.menuBarStats)
        defaults.set(true, forKey: PrefKey.menuBarNetwork)
        XCTAssertEqual(StatsDisplay.menuBarMode, .network)
        defaults.set(false, forKey: PrefKey.menuBarNetwork)
        XCTAssertEqual(StatsDisplay.menuBarMode, .auto)
        defaults.set("cpu", forKey: PrefKey.menuBarStats)
        XCTAssertEqual(StatsDisplay.menuBarMode, .cpu)
    }

    // MARK: Pausing

    func testGatePausesOnLockAndSleep() {
        var gate = SamplingGate()
        XCTAssertFalse(gate.isPaused)
        gate.locked = true
        XCTAssertTrue(gate.isPaused)
        gate.locked = false
        gate.displaysAsleep = true
        XCTAssertTrue(gate.isPaused)
        gate.displaysAsleep = false
        gate.systemAsleep = true
        XCTAssertTrue(gate.isPaused)
        gate.systemAsleep = false
        XCTAssertFalse(gate.isPaused)
    }

    @MainActor
    func testLockStopsSamplersAndUnlockResumes() {
        let system = SystemMonitor.shared
        let network = NetworkMonitor.shared
        system.addViewer()
        defer { system.removeViewer(); system.apply(SamplingGate()) }
        XCTAssertTrue(system.isRunning, "an open System panel needs CPU samples")
        system.apply(SamplingGate(locked: true))
        XCTAssertFalse(system.isRunning, "locked: CPU sampling stops")
        XCTAssertTrue(network.isPaused, "locked: network sampling stops")
        XCTAssertEqual(network.down, 0)
        system.apply(SamplingGate())
        XCTAssertTrue(system.isRunning)
        XCTAssertFalse(network.isPaused)
    }

    // MARK: Cost

    /// One sample (CPU ticks + memory + network counters) must cost well under 1% of a 1-second interval.
    func testSamplerCostsUnderOnePercentCPU() {
        func threadCPU() -> Double {
            var spec = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
            return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
        }
        var previous = SystemMonitor.readTicks()
        XCTAssertFalse(previous.isEmpty, "host_processor_info returns cores")
        let samples = 200
        let start = threadCPU()
        for _ in 0..<samples {
            let ticks = SystemMonitor.readTicks()
            _ = CPUMath.usage(previous: previous, current: ticks)
            previous = ticks
            _ = SystemMonitor.readMemory()
            _ = NetworkMonitor.readCounters()
        }
        let perSample = (threadCPU() - start) / Double(samples)
        print("sampler cost per sample: \(String(format: "%.1f", perSample * 1e6)) µs")
        XCTAssertLessThan(perSample, 0.01, "under 10 ms of CPU per 1 s sample = under 1%")
    }

    func testRealReadingsAreSane() {
        let memory = SystemMonitor.readMemory()
        XCTAssertGreaterThan(memory, 0)
        XCTAssertLessThanOrEqual(memory, 1)
        let first = SystemMonitor.readTicks()
        usleep(50_000)
        let usage = CPUMath.usage(previous: first, current: SystemMonitor.readTicks())
        XCTAssertEqual(usage.perCore.count, ProcessInfo.processInfo.processorCount)
        XCTAssertTrue((0...1).contains(usage.total))
    }
}
