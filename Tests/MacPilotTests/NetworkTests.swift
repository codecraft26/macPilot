import XCTest
@testable import MacPilot

final class NetworkTests: XCTestCase {
    func testCounterDeltaHandlesWrap() {
        XCTAssertEqual(NetworkMath.delta(1_000, 5_000), 4_000)
        XCTAssertEqual(NetworkMath.delta(0, 0), 0)
        let limit = NetworkMath.counterLimit
        XCTAssertEqual(NetworkMath.delta(limit - 100, 50), 150, "32-bit counter wrapped")
        XCTAssertEqual(NetworkMath.delta(limit + 10, 5), 5, "a reset counter (not a wrap) counts from zero")
    }

    func testRatesAcrossInterfaces() {
        let before = [InterfaceCounters(name: "en0", received: 1_000, sent: 500),
                      InterfaceCounters(name: "en1", received: 0, sent: 0)]
        let after = [InterfaceCounters(name: "en0", received: 3_000, sent: 1_500),
                     InterfaceCounters(name: "en1", received: 2_000, sent: 0),
                     InterfaceCounters(name: "en5", received: 9_999_999, sent: 9_999_999)] // new: ignored
        let rates = NetworkMath.rates(previous: before, current: after, interval: 2)
        XCTAssertEqual(rates.down, 2_000) // (2000 + 2000) / 2s
        XCTAssertEqual(rates.up, 500)
        XCTAssertEqual(NetworkMath.rates(previous: before, current: after, interval: 0).down, 0)
    }

    func testCountableInterfaces() {
        XCTAssertTrue(NetworkMath.isCountable("en0"))
        XCTAssertTrue(NetworkMath.isCountable("pdp_ip0"))
        for skipped in ["lo0", "utun3", "awdl0", "llw0", "bridge0", "ipsec0", "anpi1"] {
            XCTAssertFalse(NetworkMath.isCountable(skipped), skipped)
        }
    }

    func testFormatting() {
        XCTAssertEqual(NetworkMath.rate(0), "0 KB/s")
        XCTAssertEqual(NetworkMath.rate(-5), "0 KB/s")
        XCTAssertEqual(NetworkMath.rate(640_000), "640 KB/s")
        XCTAssertEqual(NetworkMath.rate(1_234_000), "1.2 MB/s")
        XCTAssertEqual(NetworkMath.rate(250_000_000), "250 MB/s")
        XCTAssertEqual(NetworkMath.rate(1_500_000_000), "1.5 GB/s")
        XCTAssertEqual(NetworkMath.compact(640_000), "640K")
        XCTAssertEqual(NetworkMath.compact(1_234_000), "1.2M")
        XCTAssertEqual(NetworkMath.compact(45_000_000), "45M")
        XCTAssertEqual(NetworkMath.mbps(26_080_864), "26.1 Mbps")
        XCTAssertEqual(NetworkMath.mbps(345_000_000), "345 Mbps")
        XCTAssertEqual(NetworkMath.mbps(1_200_000_000), "1.2 Gbps")
    }

    func testHistoryKeepsLastMinute() {
        var history: [NetworkSample] = []
        for second in 0..<75 {
            history = NetworkMath.appending(NetworkSample(date: Date(timeIntervalSince1970: Double(second)), down: Double(second), up: 0), to: history)
        }
        XCTAssertEqual(history.count, 60)
        XCTAssertEqual(history.first?.down, 15)
        XCTAssertEqual(history.last?.down, 74)
    }

    func testReadsRealCounters() {
        let reading = NetworkMonitor.readCounters()
        XCTAssertFalse(reading.counters.contains { $0.name.hasPrefix("lo") }, "loopback is skipped")
    }

    // MARK: networkQuality

    func testParsesNetworkQualityJSON() throws {
        let json = """
        {
          "base_rtt" : 106.99416351318359,
          "cli_options" : [ "-c" ],
          "dl_throughput" : 26080864,
          "il_h2_req_resp" : [ 76.4, 163.0 ],
          "interface_name" : "en1",
          "responsiveness" : 149.88595581054688,
          "ul_throughput" : 34279864,
          "other" : { "interface-type" : { "wifi" : 893 } }
        }
        """
        let result = try SpeedTestResult.parse(Data(json.utf8), date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result.download, 26_080_864)
        XCTAssertEqual(result.upload, 34_279_864)
        XCTAssertEqual(result.latency, 106.99, accuracy: 0.01)
        XCTAssertEqual(result.responsiveness ?? 0, 149.89, accuracy: 0.01)
        XCTAssertEqual(result.interface, "en1")
        XCTAssertEqual(result.summary, "↓ 26.1 Mbps  ↑ 34.3 Mbps  · 107 ms")
        XCTAssertTrue(result.spoken.contains("26.1 megabits"))
    }

    func testParsesWithLeadingNoiseAndRPMOnly() throws {
        let text = "Warning: something\n{ \"dl_throughput\": 1000000, \"ul_throughput\": 500000, \"responsiveness\": 600 }"
        let result = try SpeedTestResult.parse(Data(text.utf8))
        XCTAssertEqual(result.latency, 100, accuracy: 0.001, "60000 / 600 RPM")
        XCTAssertEqual(result.interface, "")
    }

    func testParseErrors() {
        XCTAssertThrowsError(try SpeedTestResult.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try SpeedTestResult.parse(Data("{\"base_rtt\": 10}".utf8)), "no throughput")
        XCTAssertThrowsError(try SpeedTestResult.parse(Data("{\"error_code\": -1009, \"error_domain\": \"NSURLErrorDomain\"}".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("-1009"))
        }
    }

    func testSpeedTestHistoryAndProgress() {
        var history: [SpeedTestResult] = []
        for index in 0..<25 {
            history = SpeedTest.appending(SpeedTestResult(date: Date(timeIntervalSince1970: Double(index)), download: Double(index),
                                                          upload: 0, latency: 0, interface: "en0"), to: history)
        }
        XCTAssertEqual(history.count, SpeedTest.historyLimit)
        XCTAssertEqual(history.first?.download, 24, "newest first")
        XCTAssertEqual(SpeedTest.progress(elapsed: 0), 0)
        XCTAssertEqual(SpeedTest.progress(elapsed: SpeedTest.expectedDuration / 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(SpeedTest.progress(elapsed: 500), 0.95, "never shows done before the result")
        XCTAssertEqual(SpeedTest.phase(elapsed: 0.5), "Measuring latency…")
    }

    func testPilotUnderstandsSpeedTest() {
        for phrase in ["run a speed test", "Hey Pilot, run a speed test", "how fast is my internet", "do an internet speed test", "speedtest"] {
            XCTAssertEqual(PilotCommand.parse(phrase), .speedTest, phrase)
        }
        XCTAssertNotEqual(PilotCommand.parse("start recording"), .speedTest)
    }
}
