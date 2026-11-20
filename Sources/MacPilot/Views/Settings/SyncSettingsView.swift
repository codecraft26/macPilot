import SwiftUI

/// Settings → Sync: iCloud Drive sync between your Macs.
struct SyncSettingsView: View {
    @AppStorage(PrefKey.iCloudSyncEnabled) private var enabled = false
    private let sync = ICloudSync.shared

    var body: some View {
        Form {
            Section {
                Toggle("Sync with my other Macs through iCloud Drive", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on { sync.start() } else { sync.stop() }
                    }
                Text("Turn this on on each Mac signed in to the same Apple Account. Changes arrive within about a minute.")
                    .font(.caption).foregroundStyle(.secondary)
                if !ICloudSync.isICloudDriveAvailable {
                    Label("iCloud Drive is off on this Mac. Turn it on in System Settings → Apple Account → iCloud → iCloud Drive.",
                          systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
                }
            }

            if enabled {
                Section("Status") {
                    HStack {
                        if sync.isSyncing { ProgressView().controlSize(.small) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sync.lastSummary ?? "Not synced yet")
                            if let last = sync.lastSync {
                                Text("Last sync \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Sync now") { sync.syncNow() }.disabled(sync.isSyncing)
                    }
                    if let error = sync.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    LabeledContent("This Mac", value: ICloudSync.deviceName)
                    ForEach(sync.devices) { device in
                        LabeledContent(device.name,
                                       value: "\(device.itemCount) items · updated \(device.updatedAt.formatted(.relative(presentation: .named)))")
                    }
                    if sync.devices.isEmpty {
                        Text("No other Mac yet. Install this version on your other Mac and turn on sync there.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("What syncs") {
                ForEach(SyncKind.allCases, id: \.self) { kind in
                    Label(kind.label, systemImage: "checkmark.circle.fill").foregroundStyle(.primary)
                }
                Text("""
                Not synced: clipboard history (stays on each Mac), audio and screen video files (large — meetings arrive with \
                their transcript and summary), API keys and AWS credentials (Keychain, per Mac), and app settings.
                Tasks linked to Apple Reminders are matched to the same reminder on both Macs, so nothing is duplicated.
                """)
                .font(.caption).foregroundStyle(.secondary)
                Button("Show sync folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ICloudSync.folder])
                }
                .disabled(!ICloudSync.isICloudDriveAvailable)
            }

            Section("If something looks wrong") {
                Text("The newest edit of an item wins. Deleting something deletes it on your other Macs too.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Re-send everything from this Mac") { sync.resetState() }
            }
        }
        .formStyle(.grouped)
    }
}
