import AppKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettingsView()
                .tabItem { Label("Providers", systemImage: "key") }
            RoutingSettingsView()
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
            RecordingSettingsView()
                .tabItem { Label("Recording & Calendar", systemImage: "waveform") }
            ClipboardSettingsView()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            UsageSettingsView()
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            PrivacySettingsView()
                .tabItem { Label("Privacy & Data", systemImage: "lock.shield") }
        }
        .padding(16)
        .navigationTitle("Settings")
    }
}

// MARK: - Providers and API keys

struct ProvidersSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("API keys are stored in your macOS Keychain and are never written to logs, settings files or the database.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(AIProviderID.allCases) { provider in
                    ProviderCard(provider: provider)
                }
            }
            .padding(8)
        }
    }
}

private struct ProviderCard: View {
    let provider: AIProviderID

    @AppStorage private var isEnabled: Bool
    @AppStorage private var model: String
    @AppStorage(PrefKey.ollamaBaseURL) private var ollamaURL = "http://localhost:11434"

    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var models: [String] = []

    init(provider: AIProviderID) {
        self.provider = provider
        _isEnabled = AppStorage(wrappedValue: provider != .ollama, PrefKey.enabled(provider))
        _model = AppStorage(wrappedValue: provider.defaultModel, PrefKey.model(provider))
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(provider.displayName).font(.headline)
                    Spacer()
                    Toggle("Enabled", isOn: $isEnabled).toggleStyle(.switch)
                }
                Text(provider.dataNotice).font(.caption).foregroundStyle(.secondary)

                if provider.requiresAPIKey {
                    keyRow
                } else {
                    HStack {
                        Text("Server URL").frame(width: 90, alignment: .leading)
                        TextField("http://localhost:11434", text: $ollamaURL)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Text("Model").frame(width: 90, alignment: .leading)
                    Picker("", selection: $model) {
                        ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    TextField("or type a model id", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }

                HStack {
                    Button(action: testConnection) {
                        if isTesting { ProgressView().controlSize(.small) } else { Text("Test connection") }
                    }
                    .disabled(isTesting || (provider.requiresAPIKey && !hasKey))
                    if let status {
                        Label(status, systemImage: statusIsError ? "xmark.octagon" : "checkmark.circle")
                            .foregroundStyle(statusIsError ? .red : .green)
                            .font(.callout)
                            .lineLimit(3)
                    }
                }
            }
            .padding(8)
        }
        .onAppear {
            hasKey = provider.requiresAPIKey ? KeychainStore.exists(account: provider.rawValue) : true
            models = Prefs.cachedModels(for: provider)
        }
    }

    private var keyRow: some View {
        HStack {
            Text("API key").frame(width: 90, alignment: .leading)
            SecureField(hasKey ? "Saved in Keychain — paste to replace" : "Paste your API key", text: $keyInput)
                .textFieldStyle(.roundedBorder)
            Button("Save") { saveKey() }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Delete", role: .destructive) { deleteKey() }
                .disabled(!hasKey)
        }
    }

    private var modelOptions: [String] {
        var options = models
        if !model.isEmpty, !options.contains(model) { options.insert(model, at: 0) }
        return options
    }

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.save(key, account: provider.rawValue)
            keyInput = ""
            hasKey = true
            setStatus("Key saved to Keychain.", error: false)
            testConnection()
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func deleteKey() {
        do {
            try KeychainStore.delete(account: provider.rawValue)
            hasKey = false
            setStatus("Key deleted.", error: false)
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func testConnection() {
        isTesting = true
        status = nil
        let provider = provider
        Task {
            do {
                let fetched = try await AIRouter.client(for: provider).listModels()
                if !fetched.isEmpty {
                    Prefs.setCachedModels(fetched, for: provider)
                    models = fetched
                }
                setStatus("Connected. \(fetched.count) models available.", error: false)
            } catch {
                setStatus(AIError.describe(error), error: true)
            }
            isTesting = false
        }
    }

    private func setStatus(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }
}

// MARK: - Provider routing (PRD section 5)

struct RoutingSettingsView: View {
    @AppStorage(PrefKey.chatProvider) private var chatProvider = AIProviderID.anthropic.rawValue
    @AppStorage(PrefKey.analysisProvider) private var analysisProvider = AIProviderID.anthropic.rawValue
    @AppStorage(PrefKey.transcriptionProvider) private var transcriptionProvider = TranscriptionProviderID.openAI.rawValue
    @AppStorage(PrefKey.transcriptionModel) private var transcriptionModel = "gpt-4o-transcribe"
    @AppStorage(PrefKey.liveTranscriptionModel) private var liveTranscriptionModel = "gpt-4o-transcribe"
    @AppStorage(PrefKey.defaultSystemPrompt) private var systemPrompt = ""

    var body: some View {
        Form {
            Section("AI conversations") {
                Picker("Default provider for new chats", selection: $chatProvider) {
                    ForEach(AIProviderID.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                VStack(alignment: .leading) {
                    Text("Default system prompt")
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 70)
                        .font(.body)
                }
            }
            Section("Transcript analysis (summaries, action items)") {
                Picker("Provider", selection: $analysisProvider) {
                    ForEach(AIProviderID.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            Section {
                Picker("Provider", selection: $transcriptionProvider) {
                    ForEach(TranscriptionProviderID.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                TextField("File transcription model", text: $transcriptionModel)
                TextField("Live transcription model", text: $liveTranscriptionModel)
            } header: {
                Text("Audio transcription")
            } footer: {
                Text("Claude is used for analysis, not speech-to-text. OpenAI models: gpt-4o-transcribe, gpt-4o-mini-transcribe or whisper-1 (whisper-1 returns exact segment timestamps). Long audio is uploaded in 2-minute pieces. Local Whisper arrives in Phase 7; live transcription is not available yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    private let manager = ShortcutManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(action.title)
                            Spacer()
                            ShortcutRecorder(action: action)
                        }
                        if let failure = manager.failures[action] {
                            Text(failure).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the new key combination. Esc cancels, Delete clears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Restore defaults") { manager.resetAll() }
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: View {
    let action: ShortcutAction
    @State private var isRecording = false
    @State private var monitor: Any?
    private let manager = ShortcutManager.shared

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Press keys…" : (manager.hotKey(for: action)?.displayString ?? "None"))
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? Color.accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        manager.suspend()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 { // Escape
            stop()
            return
        }
        if event.keyCode == 51 && flags.isEmpty { // Delete clears
            manager.set(nil, for: action)
            stop()
            return
        }
        guard !flags.isEmpty, flags != .shift else { NSSound.beep(); return }
        let hotKey = HotKey(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: HotKey.carbonModifiers(from: flags),
            keyLabel: HotKey.label(for: event)
        )
        stop()
        manager.set(hotKey, for: action)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            manager.resume()
        }
    }
}

// MARK: - Usage and limits

struct UsageSettingsView: View {
    @State private var usage: [AIProviderID: UsageTracker.Usage] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(AIProviderID.allCases) { provider in
                    UsageRow(provider: provider, usage: usage[provider] ?? .init()) {
                        UsageTracker.reset(provider)
                        refresh()
                    }
                }
            } header: {
                Text("This month (\(UsageTracker.monthKey()))")
            } footer: {
                Text("Counts come from token usage reported by each provider. Check your provider dashboard for billing. A limit of 0 means no limit; when a limit is reached, MacPilot stops sending requests to that provider until next month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        for provider in AIProviderID.allCases {
            usage[provider] = UsageTracker.current(provider)
        }
    }
}

private struct UsageRow: View {
    let provider: AIProviderID
    let usage: UsageTracker.Usage
    var onReset: () -> Void
    @AppStorage private var limit: Int

    init(provider: AIProviderID, usage: UsageTracker.Usage, onReset: @escaping () -> Void) {
        self.provider = provider
        self.usage = usage
        self.onReset = onReset
        _limit = AppStorage(wrappedValue: 0, PrefKey.tokenLimit(provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.displayName).font(.headline)
                Spacer()
                Button("Reset", action: onReset).buttonStyle(.borderless)
            }
            Text("\(usage.requests) requests · \(usage.inputTokens.formatted()) input · \(usage.outputTokens.formatted()) output tokens")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text("Monthly token limit")
                TextField("0", value: $limit, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                if limit > 0 {
                    ProgressView(value: min(Double(usage.totalTokens) / Double(limit), 1))
                        .frame(width: 140)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Privacy and data

struct PrivacySettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var confirmDeleteChats = false
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteKeys = false
    @State private var message: String?
    @AppStorage(PrefKey.audioRetentionDays) private var retentionDays = 0

    var body: some View {
        Form {
            Section("Where your data goes") {
                ForEach(AIProviderID.allCases) { provider in
                    HStack(alignment: .top) {
                        Image(systemName: provider.isExternal ? "arrow.up.right.circle" : "desktopcomputer")
                        VStack(alignment: .leading) {
                            Text(provider.displayName)
                            Text(provider.dataNotice).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Everything else (chats, notes, tasks, prompts) stays on this Mac in \(Persistence.storeDirectory.path). There is no MacPilot account or server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("Recording") {
                Text("MacPilot never records in the background. A red indicator shows in the menu bar whenever audio is captured. You are responsible for getting consent from people you record.")
                    .font(.callout)
                Picker("Keep audio files", selection: $retentionDays) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("Older audio is deleted when MacPilot starts. Transcripts and summaries are kept. Recordings are stored in \(RecordingStorage.root.path).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("Your data") {
                Button("Export all data as JSON…", action: exportAll)
                Button("Reveal data folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Persistence.storeDirectory])
                }
                Button("Delete all conversations…", role: .destructive) { confirmDeleteChats = true }
                Button("Delete all API keys…", role: .destructive) { confirmDeleteKeys = true }
                Button("Delete all local data…", role: .destructive) { confirmDeleteAll = true }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all conversations?", isPresented: $confirmDeleteChats) {
            Button("Delete conversations", role: .destructive) {
                run { try DataManager.deleteAllConversations(context: context) }
            }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog("Delete all API keys from the Keychain?", isPresented: $confirmDeleteKeys) {
            Button("Delete keys", role: .destructive) {
                DataManager.deleteAllAPIKeys()
                message = "API keys deleted."
            }
        }
        .confirmationDialog("Delete all local MacPilot data?", isPresented: $confirmDeleteAll) {
            Button("Delete everything", role: .destructive) {
                run { try DataManager.deleteAllLocalData(context: context) }
            }
        } message: {
            Text("Conversations, notes, tasks, prompts, recordings (with audio), clipboard history and usage stats will be removed. API keys are kept unless you delete them separately. This cannot be undone.")
        }
    }

    private func exportAll() {
        do {
            let json = try DataManager.exportAllJSON(context: context)
            Exporter.save(text: json, suggestedName: "MacPilot-export.json", fileExtension: "json")
        } catch {
            message = error.localizedDescription
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            message = "Done."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Recording and calendar

struct RecordingSettingsView: View {
    @AppStorage(PrefKey.microphoneID) private var microphoneID = ""
    @AppStorage(PrefKey.includeSystemAudio) private var includeSystemAudio = true
    @AppStorage(PrefKey.autoProcessRecordings) private var autoProcess = true
    @AppStorage(PrefKey.defaultEventAlarmMinutes) private var alarmMinutes = 10
    @State private var devices: [AudioInputDevice] = []
    @State private var hasScreenPermission = SystemAudioRecorder.hasPermission
    private let calendar = CalendarService.shared

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Input", selection: $microphoneID) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                Button("Refresh devices") { devices = MicRecorder.availableDevices() }
            }
            Section {
                Toggle("Record system audio in meetings", isOn: $includeSystemAudio)
                HStack {
                    Image(systemName: hasScreenPermission ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(hasScreenPermission ? .green : .orange)
                    Text(hasScreenPermission
                         ? "Screen & System Audio Recording permission granted."
                         : "Needs Screen & System Audio Recording permission. Without it, meetings record the microphone only.")
                    Spacer()
                    if !hasScreenPermission {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .font(.callout)
            } header: {
                Text("Meetings")
            } footer: {
                Text("System audio is what other apps play, such as the other side of a call. It is saved as a separate track labelled “Others”; your microphone is “Me”. Rename speakers in the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("After recording") {
                Toggle("Transcribe and summarize automatically", isOn: $autoProcess)
                Text("Uses the transcription and analysis providers from the Routing tab. Turn this off to start each step yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Calendar") {
                HStack {
                    Text("Apple Calendar")
                    Spacer()
                    if calendar.isAuthorized {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if calendar.isDenied {
                        Button("Open Privacy Settings") { calendar.openPrivacySettings() }
                    } else {
                        Button("Connect") { Task { await calendar.requestAccess() } }
                    }
                }
                Picker("Default alert for new events", selection: $alarmMinutes) {
                    Text("None").tag(0)
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                }
                Text("Quick add uses the analysis provider to read your request; you always review the event before it is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GoogleCalendarSettingsSection()
        }
        .formStyle(.grouped)
        .onAppear {
            devices = MicRecorder.availableDevices()
            hasScreenPermission = SystemAudioRecorder.hasPermission
        }
    }
}

// MARK: - Google Calendar

private struct GoogleCalendarSettingsSection: View {
    private let google = GoogleCalendarService.shared
    private let calendar = CalendarService.shared
    @State private var clientID = GoogleCalendarService.shared.clientID
    @State private var clientSecret = ""
    @State private var hasSecret = KeychainStore.exists(account: GoogleCalendarService.clientSecretAccount)
    @State private var showHelp = false
    @State private var message: String?

    var body: some View {
        Section {
            if google.isConnected {
                HStack {
                    Label(google.accountEmail.isEmpty ? "Connected" : "Connected as \(google.accountEmail)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Refresh calendars") { Task { await google.refreshCalendars() } }
                    Button("Disconnect", role: .destructive) { google.disconnect() }
                }
                let calendars = calendar.calendars.filter { $0.source == .google }
                if calendars.isEmpty {
                    Text("No calendars loaded yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(calendars) { item in
                    Toggle(isOn: Binding(get: { calendar.isVisible(item) }, set: { calendar.setVisible($0, item) })) {
                        HStack(spacing: 6) {
                            Circle().fill(item.color.color).frame(width: 9, height: 9)
                            Text(item.title)
                            if !item.isWritable { Text("read only").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } else {
                TextField("OAuth client ID", text: $clientID, prompt: Text("1234-abc.apps.googleusercontent.com"))
                    .onChange(of: clientID) { _, value in google.clientID = value }
                HStack {
                    SecureField("Client secret", text: $clientSecret, prompt: Text(hasSecret ? "Saved in Keychain" : "GOCSPX-…"))
                    Button("Save") { saveSecret() }
                        .disabled(clientSecret.isEmpty)
                }
                HStack {
                    Button {
                        Task { await google.connect() }
                    } label: {
                        if google.isSigningIn {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for Google in your browser…") }
                        } else {
                            Text("Connect Google Calendar")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || google.isSigningIn)
                    Spacer()
                    Button(showHelp ? "Hide setup steps" : "How do I get these?") { showHelp.toggle() }
                        .buttonStyle(.link)
                }
                if showHelp {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Open console.cloud.google.com and create (or pick) a project.")
                        Text("2. APIs & Services → Library → enable “Google Calendar API”.")
                        Text("3. APIs & Services → OAuth consent screen: choose External, fill in the app name and your email, and add yourself as a test user.")
                        Text("4. APIs & Services → Credentials → Create credentials → OAuth client ID → Application type “Desktop app”.")
                        Text("5. Copy the client ID and client secret here, then press Connect and approve access in your browser.")
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                }
            }
            if let error = google.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Google Calendar (optional)")
        } footer: {
            Text("MacPilot talks to Google directly with your own OAuth client; the refresh token and client secret are kept in your Keychain. Simpler alternative: add your Google account under System Settings → Internet Accounts and turn on Calendars — it then shows up through Apple Calendar with no setup here (don't use both, or events appear twice).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveSecret() {
        do {
            try KeychainStore.save(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines), account: GoogleCalendarService.clientSecretAccount)
            clientSecret = ""
            hasSecret = true
            message = "Client secret saved in Keychain."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Clipboard

struct ClipboardSettingsView: View {
    @AppStorage(PrefKey.clipboardEnabled) private var enabled = true
    @AppStorage(PrefKey.clipboardRetentionDays) private var retentionDays = 30
    @AppStorage(PrefKey.clipboardMaxItems) private var maxItems = 1000
    @AppStorage(PrefKey.clipboardCaptureImages) private var captureImages = false
    @AppStorage(PrefKey.clipboardSkipSensitive) private var skipSensitive = true
    @State private var excluded = Prefs.clipboardExcludedApps
    @State private var isTrusted = PasteService.isTrusted
    @State private var confirmClear = false
    private let monitor = ClipboardMonitor.shared

    var body: some View {
        Form {
            Section("History") {
                Toggle("Save clipboard history", isOn: $enabled)
                Toggle("Paused", isOn: Binding(get: { monitor.isPaused }, set: { monitor.isPaused = $0 }))
                Picker("Keep items for", selection: $retentionDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Unlimited").tag(0)
                }
                Picker("Maximum items", selection: $maxItems) {
                    Text("200").tag(200)
                    Text("1,000").tag(1000)
                    Text("5,000").tag(5000)
                    Text("Unlimited").tag(0)
                }
                Toggle("Save images (stored as PNG, up to 15 MB each)", isOn: $captureImages)
                Text("Pinned and favorite items never expire. History is stored only on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear history…", role: .destructive) { confirmClear = true }
            }
            .onChange(of: retentionDays) { _, _ in monitor.applyRetention() }
            .onChange(of: maxItems) { _, _ in monitor.applyRetention() }

            Section {
                Toggle("Skip passwords, API keys, tokens and card numbers", isOn: $skipSensitive)
                ForEach(excluded, id: \.self) { bundleID in
                    HStack {
                        Text(appName(bundleID))
                        Text(bundleID).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { remove(bundleID) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Menu("Exclude a running app") {
                    ForEach(runningApps, id: \.self) { bundleID in
                        Button(appName(bundleID)) { add(bundleID) }
                    }
                }
                .fixedSize()
                Button("Restore default exclusions") {
                    excluded = SensitiveContent.defaultExcludedBundleIDs
                    Prefs.clipboardExcludedApps = excluded
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Copies from excluded apps are never saved. Items that password managers mark as concealed or transient are always skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Paste into apps") {
                HStack {
                    Image(systemName: isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(isTrusted ? .green : .orange)
                    Text(isTrusted
                         ? "Accessibility permission granted: Return in the clipboard panel pastes into the app you were using."
                         : "Without Accessibility permission, Return copies the item and you press ⌘V yourself.")
                    Spacer()
                    if !isTrusted {
                        Button("Open Settings") {
                            PasteService.requestTrust()
                            PasteService.openAccessibilitySettings()
                        }
                    }
                }
                .font(.callout)
                Text("Shortcuts: \(ShortcutManager.shared.hotKey(for: .clipboard)?.displayString ?? "—") clipboard panel, \(ShortcutManager.shared.hotKey(for: .launcher)?.displayString ?? "—") command launcher (change them in Shortcuts).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { isTrusted = PasteService.isTrusted }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear (keep pinned & favorites)", role: .destructive) { monitor.clearHistory(includeKept: false) }
            Button("Clear everything", role: .destructive) { monitor.clearHistory(includeKept: true) }
        }
    }

    private var runningApps: [String] {
        Array(Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !excluded.contains($0) && $0 != Bundle.main.bundleIdentifier }))
            .sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private func add(_ bundleID: String) {
        excluded.append(bundleID)
        Prefs.clipboardExcludedApps = excluded
    }

    private func remove(_ bundleID: String) {
        excluded.removeAll { $0 == bundleID }
        Prefs.clipboardExcludedApps = excluded
    }
}
