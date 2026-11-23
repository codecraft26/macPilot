import Charts
import SwiftUI

/// Two thin lines (down and up) over the last minute, scaled to the busiest second.
struct NetworkSparkline: View {
    let samples: [NetworkSample]
    var downColor: Color = .green
    var upColor: Color = .cyan
    var capacity = 60

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let peak = max(samples.map { max($0.down, $0.up) }.max() ?? 0, 50_000)
            let step = size.width / CGFloat(max(1, capacity - 1))
            let offset = CGFloat(capacity - samples.count) * step
            func path(_ value: (NetworkSample) -> Double) -> Path {
                var path = Path()
                for (index, sample) in samples.enumerated() {
                    let point = CGPoint(x: offset + CGFloat(index) * step,
                                        y: size.height - CGFloat(value(sample) / peak) * (size.height - 2) - 1)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }
            var area = path(\.down)
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: offset, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(downColor.opacity(0.18)))
            context.stroke(path(\.down), with: .color(downColor), lineWidth: 1.5)
            context.stroke(path(\.up), with: .color(upColor), lineWidth: 1.2)
        }
        .accessibilityLabel("Network activity, last minute")
    }
}

/// Dashboard: live throughput graph, interface and IP, and the speed test.
struct NetworkDashboardCard: View {
    private let network = NetworkMonitor.shared
    private let speedTest = SpeedTest.shared
    @State private var showingHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "Network", systemImage: "network", color: .cyan) {
                Button {
                    showingHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(speedTest.history.isEmpty)
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) { SpeedTestHistoryList().frame(width: 380, height: 360) }
            }
            HStack(alignment: .top, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    readout("arrow.down.circle.fill", NetworkMath.rate(network.down), color: .green, label: "Download")
                    readout("arrow.up.circle.fill", NetworkMath.rate(network.up), color: .cyan, label: "Upload")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(network.interfaceDisplayName.isEmpty ? "Not connected" : "\(network.interfaceDisplayName) (\(network.interfaceName))")
                            .font(.caption)
                        if !network.localIP.isEmpty {
                            Text(network.localIP).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(width: 170, alignment: .leading)
                chart.frame(height: 110)
                speedTestPanel.frame(width: 220, alignment: .leading)
            }
        }
        .card()
    }

    private func readout(_ systemImage: String, _ value: String, color: Color, label: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }

    private var chart: some View {
        let samples = network.history
        let start = samples.first?.date ?? Date()
        return Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                AreaMark(x: .value("Seconds", sample.date.timeIntervalSince(start)), y: .value("MB/s", sample.down / 1_000_000),
                         series: .value("Direction", "Download"))
                    .foregroundStyle(Color.green.opacity(0.25))
                LineMark(x: .value("Seconds", sample.date.timeIntervalSince(start)), y: .value("MB/s", sample.down / 1_000_000),
                         series: .value("Direction", "Download"))
                    .foregroundStyle(Color.green)
                LineMark(x: .value("Seconds", sample.date.timeIntervalSince(start)), y: .value("MB/s", sample.up / 1_000_000),
                         series: .value("Direction", "Upload"))
                    .foregroundStyle(Color.cyan)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let mb = value.as(Double.self) { Text(String(format: "%.1f", mb)) } }
            }
        }
        .chartXScale(domain: 0...60)
        .chartYAxisLabel("MB/s")
    }

    @ViewBuilder
    private var speedTestPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Speed test").font(.headline)
            if speedTest.isRunning {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let elapsed = context.date.timeIntervalSince(speedTest.startedAt ?? context.date)
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: SpeedTest.progress(elapsed: elapsed))
                        Text(SpeedTest.phase(elapsed: elapsed)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let latest = speedTest.latest {
                SpeedTestNumbers(result: latest)
                Text(latest.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Download, upload and latency, measured with macOS's networkQuality.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = speedTest.lastError, !speedTest.isRunning {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            Button {
                Task { await speedTest.run() }
            } label: {
                Label(speedTest.isRunning ? "Testing…" : "Run speed test", systemImage: "speedometer")
            }
            .disabled(speedTest.isRunning)
        }
    }
}

struct SpeedTestNumbers: View {
    let result: SpeedTestResult

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                Image(systemName: "arrow.down").foregroundStyle(.green)
                Text(NetworkMath.mbps(result.download)).monospacedDigit()
            }
            GridRow {
                Image(systemName: "arrow.up").foregroundStyle(.cyan)
                Text(NetworkMath.mbps(result.upload)).monospacedDigit()
            }
            GridRow {
                Image(systemName: "timer").foregroundStyle(.secondary)
                Text("\(Int(result.latency.rounded())) ms latency").monospacedDigit()
            }
        }
        .font(.callout)
    }
}

/// The last 20 speed tests, stored on this Mac.
struct SpeedTestHistoryList: View {
    private let speedTest = SpeedTest.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("Speed test history").font(.headline)
                Spacer()
                Button("Clear", role: .destructive) { speedTest.clearHistory() }
                    .buttonStyle(.borderless)
                    .disabled(speedTest.history.isEmpty)
            }
            Table(speedTest.history) {
                TableColumn("When") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                TableColumn("Down") { Text(NetworkMath.mbps($0.download)).monospacedDigit() }
                TableColumn("Up") { Text(NetworkMath.mbps($0.upload)).monospacedDigit() }
                TableColumn("Latency") { Text("\(Int($0.latency.rounded())) ms").monospacedDigit() }
            }
        }
        .padding(DS.Space.m)
    }
}
