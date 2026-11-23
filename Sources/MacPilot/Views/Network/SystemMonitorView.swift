import AppKit
import SwiftUI

/// The live readout's text, shared by the notch and the menu bar.
enum StatsText {
    @MainActor static var down: String { "↓ " + StatsDisplay.unit.format(NetworkMonitor.shared.down) }
    @MainActor static var up: String { "↑ " + StatsDisplay.unit.format(NetworkMonitor.shared.up) }
    @MainActor static var cpu: String { "CPU " + CPUMath.percent(SystemMonitor.shared.cpu) }
}

/// One line of CPU history (0…100%) over the last minute.
struct CPUSparkline: View {
    let samples: [Double]
    var color: Color = .orange
    var capacity = 60

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let step = size.width / CGFloat(max(1, capacity - 1))
            let offset = CGFloat(capacity - samples.count) * step
            var line = Path()
            for (index, value) in samples.enumerated() {
                let point = CGPoint(x: offset + CGFloat(index) * step, y: size.height - CGFloat(min(1, max(0, value))) * (size.height - 2) - 1)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: offset, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.18)))
            context.stroke(line, with: .color(color), lineWidth: 1.5)
        }
        .accessibilityLabel("CPU usage, last minute")
    }
}

/// A mini bar per core.
struct CoreBars: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, value in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 1.5).fill(CPUMath.isHot(value) ? Color.orange : Color.green)
                        .frame(height: max(1, CGFloat(value) * 26))
                }
                .frame(width: 6, height: 26)
            }
        }
        .accessibilityLabel("Per-core usage")
    }
}

/// Click the readout: 60-second graphs for network and CPU, memory, the busiest processes and a speed test.
struct SystemMonitorView: View {
    private let system = SystemMonitor.shared
    private let network = NetworkMonitor.shared
    private let speedTest = SpeedTest.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("System", systemImage: "gauge.with.dots.needle.33percent").font(.headline)
                Spacer()
                Text(system.gate.isPaused ? "Paused while locked" : "Every \(Int(StatsDisplay.interval)) s").font(.caption).foregroundStyle(.secondary)
            }
            // CPU
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("CPU").font(.subheadline.weight(.semibold))
                    Text(CPUMath.percent(system.cpu)).font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(CPUMath.isHot(system.cpu) ? .orange : .primary)
                    Spacer()
                    Text("Memory \(CPUMath.percent(system.memory))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    CPUSparkline(samples: system.history).frame(height: 40)
                    CoreBars(cores: system.perCore).help("\(system.perCore.count) cores")
                }
            }
            Divider()
            // Network
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Network").font(.subheadline.weight(.semibold))
                    Text(StatsText.down).foregroundStyle(.green)
                    Text(StatsText.up).foregroundStyle(.cyan)
                    Spacer()
                    Text([network.interfaceDisplayName, network.localIP].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.callout.monospacedDigit())
                NetworkSparkline(samples: network.history).frame(height: 40)
            }
            Divider()
            // Top processes
            VStack(alignment: .leading, spacing: 4) {
                Text("Top processes").font(.subheadline.weight(.semibold))
                if system.topProcesses.isEmpty {
                    Text("Reading…").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(system.topProcesses) { process in
                    HStack {
                        Text(process.name).lineLimit(1)
                        Text(verbatim: String(process.pid)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", process.percent)).monospacedDigit()
                            .foregroundStyle(process.percent >= 80 ? .orange : .primary)
                    }
                    .font(.callout)
                }
            }
            Divider()
            HStack {
                if speedTest.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Speed test running…").font(.callout)
                } else if let latest = speedTest.latest {
                    Text(latest.summary).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Speed Test") { Task { await speedTest.run() } }
                    .disabled(speedTest.isRunning || !SpeedTest.isAvailable)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { system.addViewer() }
        .onDisappear { system.removeViewer() }
    }
}

/// A small floating panel under the notch or menu bar; closes on Escape or a click elsewhere.
@MainActor
final class SystemMonitorPanel {
    static let shared = SystemMonitorPanel()
    private var panel: NSPanel?
    private var clickMonitor: Any?

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? close() : show() }

    func show() {
        if panel == nil {
            let panel = MonitorPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 480),
                                     styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.onClose = { [weak self] in self?.close() }
            self.panel = panel
        }
        guard let panel else { return }
        let hosting = NSHostingView(rootView: SystemMonitorView())
        panel.contentView = hosting
        let size = hosting.fittingSize
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main {
            let top = screen.visibleFrame.maxY - 6
            panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated {
                let panel = SystemMonitorPanel.shared.panel
                if let panel, !panel.frame.contains(NSEvent.mouseLocation) { SystemMonitorPanel.shared.close() }
            }
        }
    }

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.orderOut(nil)
        // Drop the view so its onDisappear stops the process sampling.
        panel?.contentView = nil
    }
}

private final class MonitorPanel: NSPanel {
    var onClose: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose() }
    override func performClose(_ sender: Any?) { onClose() }
    override func close() { super.close(); onClose() }
}
