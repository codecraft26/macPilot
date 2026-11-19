import SwiftUI

/// Result of ⌥⇧S: the capture, its text, and what to do with it.
struct ScreenshotView: View {
    @State private var keyMonitor = PanelKeyMonitor()
    @State private var question = ""
    private let tool = ScreenCaptureTool.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconTile(systemImage: "camera.viewfinder", color: .teal, size: 22)
                Text("Screenshot").font(.headline)
                if let image = tool.image {
                    Text("\(Int(image.size.width))×\(Int(image.size.height))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { tool.captureArea() } label: { Label("New", systemImage: "plus.viewfinder") }.buttonStyle(.borderless)
            }
            .padding(12)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                if let image = tool.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 300, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.hairline))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Text in image").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if tool.isReading { ProgressView().controlSize(.mini) }
                    }
                    ScrollView {
                        Text(tool.text.isEmpty ? (tool.isReading ? "Reading…" : "No text found.") : tool.text)
                            .font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DS.subtleFill))
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                TextField("Ask AI about it… (Return)", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { tool.ask(question) }
                Button("Ask") { tool.ask(question) }.disabled(tool.isReading)
            }
            .padding(.horizontal, 12).padding(.top, 8)
            HStack(spacing: 8) {
                Button("Copy text") { tool.copyText() }.disabled(tool.text.isEmpty)
                Button("Copy image") { tool.copyImage() }
                Button("Pin on screen") { tool.pin() }
                Button("Save to Desktop") { tool.saveToDesktop() }
                Spacer()
                if let message = tool.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .controlSize(.small)
            .padding(12)
        }
        .background(VisualEffectBackground(material: .hudWindow))
        .tint(DS.accent)
        .onAppear { keyMonitor.install(window: { WindowManager.shared.screenshotPanel }, handler: handle) }
    }

    private func handle(_ event: PanelKey.Event) -> Bool {
        guard event.key == .escape else { return false }
        WindowManager.shared.hideScreenshot()
        return true
    }
}
