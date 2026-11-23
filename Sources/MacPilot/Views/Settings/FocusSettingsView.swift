import AppKit
import Intents
import SwiftUI

/// Settings → Focus: triggers, the two Shortcuts, what's detectable, and history.
struct FocusSettingsView: View {
    @State private var settings = FocusSettings.load()
    @State private var setupMessage: String?
    @State private var focusAccess = INFocusStatusCenter.default.authorizationStatus
    private let focus = FocusController.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: focus.isActive ? "moon.fill" : "moon").foregroundStyle(.indigo)
                    Text(focus.statusText)
                    Spacer()
                    if focus.isActive {
                        Button("Not now") { Task { await focus.notNow() } }
                    } else {
                        Button("Focus 25 min") { Task { await focus.focus(minutes: 25) } }
                        Button("Focus 50 min") { Task { await focus.focus(minutes: 50) } }
                    }
                }
                if let error = focus.lastShortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
            } header: { Text("Smart Do Not Disturb") }

            Section {
                Toggle("In a meeting: a calendar meeting is in progress or MacPilot is recording one", isOn: $settings.meetings)
                Toggle("On a call: the microphone is in use while Zoom, Teams, FaceTime, Webex, Slack or a browser is running", isOn: $settings.microphone)
                Toggle("Sharing my screen", isOn: $settings.screenSharing)
                Text("Detectable through public APIs: Zoom, Teams, Meet, Webex and Slack sharing windows (window titles need Screen Recording permission), macOS Screen Sharing / Remote Management sessions, and AirPlay or display mirroring. The orange/purple system recording indicator itself can't be read by apps, and other tools' sharing may be missed.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Deep work: a focus app stays in front", isOn: $settings.deepWork)
                if settings.deepWork {
                    Stepper("After \(settings.deepWorkMinutes) minutes", value: $settings.deepWorkMinutes, in: 1...60)
                    Toggle("Only while I'm typing", isOn: $settings.deepWorkOnlyWhileTyping)
                    ForEach(settings.deepWorkApps, id: \.self) { id in
                        HStack {
                            Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id)
                            Spacer()
                            Button(role: .destructive) { settings.deepWorkApps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    Menu("Add a focus app…") {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
                            .filter { !settings.deepWorkApps.contains($0) }, id: \.self) { id in
                            Button(NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id) { settings.deepWorkApps.append(id) }
                        }
                    }.fixedSize()
                }
                Stepper("Grace period: \(Int(settings.graceSeconds / 60)) min (stops back-to-back meetings from flapping)", value: $settings.graceSeconds, in: 0...900, step: 60)
            } header: { Text("Turn Focus on automatically when…") }

            Section {
                Toggle("Also turn on macOS Focus (Do Not Disturb)", isOn: $settings.useSystemFocus)
                if focus.missingShortcuts.isEmpty {
                    Label("“\(FocusShortcuts.onName)” and “\(FocusShortcuts.offName)” are installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Missing: \(focus.missingShortcuts.joined(separator: ", "))", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    HStack {
                        Button("Set up the shortcuts…") { Task { setupMessage = await FocusShortcuts.installWithImport() } }
                        Button("Check again") { Task { await focus.checkShortcuts() } }
                    }
                    if let setupMessage { Text(setupMessage).font(.caption) }
                    Text(FocusShortcuts.manualSteps).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Text(focusAccess == .authorized ? "MacPilot can see whether a Focus is already on, and leaves it as it was." : "Allow MacPilot to see your Focus status so it restores it exactly (otherwise it only turns off what it turned on).")
                        .font(.caption).foregroundStyle(.secondary)
                    if focusAccess != .authorized {
                        Button("Allow") { INFocusStatusCenter.default.requestAuthorization { status in Task { @MainActor in focusAccess = status } } }
                    }
                }
                Text("macOS has no public API to switch Focus, so MacPilot runs these two shortcuts with the `shortcuts` command. Either way, MacPilot's own notch alerts and smart reminders are held during Focus (except urgent ones like agent approvals) and shown as one summary afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("macOS Focus") }

            Section("History") {
                if focus.history.isEmpty { Text("No Focus sessions yet.").foregroundStyle(.secondary) }
                ForEach(focus.history.prefix(20)) { session in
                    HStack {
                        Text(session.reason)
                        Spacer()
                        Text(session.start.formatted(date: .abbreviated, time: .shortened) + (session.end.map { " – " + $0.formatted(date: .omitted, time: .shortened) } ?? " – now"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, value in value.save() }
        .task { await focus.checkShortcuts() }
    }
}
