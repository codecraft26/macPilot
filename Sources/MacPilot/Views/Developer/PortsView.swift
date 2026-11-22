import AppKit
import SwiftUI

/// Developer → Ports: what's listening, with a confirm-first Stop (SIGTERM) and Force kill (SIGKILL).
struct PortsView: View {
    private let ports = PortKiller.shared
    @State private var search = ""
    @State private var confirm: ListeningPort?
    @State private var force: ListeningPort?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Filter by port, process or project", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                ForEach(PortKiller.commonPorts, id: \.self) { port in
                    Button(":\(port)") { search = String(port) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(ports.ports.contains { $0.port == port } ? .orange : .secondary)
                }
                Spacer()
                Button { Task { await ports.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            .padding(12)
            if let message { Text(message).font(.caption).padding(.horizontal, 12).padding(.bottom, 6) }
            Table(ports.filtered(search)) {
                TableColumn("Port") { port in
                    Text("\(port.port)").monospacedDigit().fontWeight(.semibold)
                }.width(60)
                TableColumn("Proto") { Text($0.proto).font(.caption) }.width(44)
                TableColumn("Process") { port in
                    HStack(spacing: 6) {
                        Image(nsImage: ports.icon(for: port)).resizable().frame(width: 16, height: 16)
                        Text(port.process)
                        Text("\(port.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.width(min: 140, ideal: 180)
                TableColumn("User") { Text($0.user).font(.caption) }.width(70)
                TableColumn("Project / command") { port in
                    VStack(alignment: .leading, spacing: 1) {
                        if !port.projectName.isEmpty { Text(port.projectName).font(.caption.weight(.semibold)) }
                        Text(port.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .help(port.cwd.isEmpty ? port.command : "\(port.cwd)\n\(port.command)")
                }
                TableColumn("") { port in
                    if let reason = PortProtection.reason(port) {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary).help(reason)
                    } else {
                        Button("Stop…") { confirm = port }.controlSize(.small)
                    }
                }.width(64)
            }
        }
        .onAppear { ports.watch() }
        .onDisappear { ports.unwatch() }
        .confirmationDialog(confirm.map { "Stop \($0.process) on port \($0.port)?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Stop (SIGTERM)", role: .destructive) {
                guard let port = confirm else { return }
                Task {
                    let outcome = await ports.terminate(port)
                    message = "\(port.process) (\(port.pid)): \(outcome.message)"
                    if outcome == .stillRunning { force = port }
                }
            }
        } message: {
            Text(confirm.map { "PID \($0.pid) · \($0.command)\nIt gets a chance to shut down cleanly." } ?? "")
        }
        .confirmationDialog(force.map { "\($0.process) is still running. Force kill?" } ?? "", isPresented: Binding(get: { force != nil }, set: { if !$0 { force = nil } })) {
            Button("Force kill (SIGKILL)", role: .destructive) {
                guard let port = force else { return }
                Task { message = "\(port.process) (\(port.pid)): \((await ports.forceKill(port)).message)" }
            }
        } message: { Text("Unsaved work in that process will be lost.") }
    }
}

/// Dashboard: the dev ports that are in use, with a link to Developer → Ports.
struct PortsDashboardCard: View {
    private let ports = PortKiller.shared

    var body: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: "point.3.connected.trianglepath.dotted", color: .orange, size: 20)
            Text("Ports").font(.headline)
            let busy = ports.ports.filter { $0.proto == "TCP" && PortProtection.reason($0) == nil }
            if busy.isEmpty {
                Text("No dev servers listening").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(busy.prefix(5)) { port in
                    HStack(spacing: 4) {
                        Text(":\(port.port)").monospacedDigit().fontWeight(.semibold)
                        Text(port.projectName.isEmpty ? port.process : port.projectName).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            Spacer()
            Button("Manage") {
                DeveloperView.openPortsNext = true
                AppState.shared.selectedSection = .developer
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .card(padding: DS.Space.s)
        .onAppear { ports.watch() }
        .onDisappear { ports.unwatch() }
    }
}
