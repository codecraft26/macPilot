import SwiftUI

/// Settings → General: version and updates.
struct GeneralSettingsView: View {
    private let updates = UpdateManager.shared
    @State private var checks = UpdateManager.shared.automaticallyChecks
    @State private var installs = UpdateManager.shared.automaticallyInstalls

    var body: some View {
        Form {
            Section("MacPilot") {
                LabeledContent("Version", value: "\(updates.currentVersion) (build \(updates.currentBuild))")
                HStack {
                    Text("Setup: \(SetupController.shared.progress.doneCount)/\(SetupProgress.totalCount) steps done")
                    Spacer()
                    Button("Run setup again") { SetupController.shared.show(restart: true) }
                }
            }
            Section {
                Toggle("Automatically check for updates (daily)", isOn: $checks)
                    .onChange(of: checks) { _, on in updates.automaticallyChecks = on }
                Toggle("Automatically download and install updates", isOn: $installs)
                    .onChange(of: installs) { _, on in updates.automaticallyInstalls = on }
                    .disabled(!checks)
                HStack {
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.isAvailable)
                    if let last = updates.lastCheck {
                        Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !updates.isAvailable {
                    Text("Auto-updates aren't set up in this build (it has no update signing key yet).").font(.caption).foregroundStyle(.orange)
                }
                Text("Updates come from MacPilot's GitHub repository and are checked against MacPilot's own signing key before anything is installed. Until MacPilot is signed with an Apple Developer ID, macOS may ask again for Accessibility and Screen Recording after an update.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Updates") }
        }
        .formStyle(.grouped)
    }
}
