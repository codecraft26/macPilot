import AppKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.settingsTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("General")
            ProvidersSettingsView()
                .tabItem { Label("Providers", systemImage: "key") }
                .tag("Providers")
            RoutingSettingsView()
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
                .tag("Routing")
            AgentSettingsView()
                .tabItem { Label("Agent", systemImage: "cpu") }
                .tag("Agent")
            MemorySettingsView()
                .tabItem { Label("Memory", systemImage: "brain") }
                .tag("Memory")
            FocusSettingsView()
                .tabItem { Label("Focus", systemImage: "moon") }
                .tag("Focus")
            DictationSettingsView()
                .tabItem { Label("Dictation", systemImage: "mic.badge.plus") }
                .tag("Dictation")
            RecordingSettingsView()
                .tabItem { Label("Recording & Calendar", systemImage: "waveform") }
                .tag("Recording & Calendar")
            ClipboardSettingsView()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
                .tag("Clipboard")
            SnippetsSettingsView()
                .tabItem { Label("Snippets & Links", systemImage: "text.quote") }
                .tag("Snippets & Links")
            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "icloud") }
                .tag("Sync")
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag("Shortcuts")
            UsageSettingsView()
                .tabItem { Label("Usage", systemImage: "chart.bar") }
                .tag("Usage")
            PrivacySettingsView()
                .tabItem { Label("Privacy & Data", systemImage: "lock.shield") }
                .tag("Privacy & Data")
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
        _isEnabled = AppStorage(wrappedValue: provider == .anthropic || provider == .openAI, PrefKey.enabled(provider))
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

                if provider == .bedrock {
                    BedrockCredentialsSection(onChange: { saved in
                        hasKey = provider.hasCredentials
                        if saved { testConnection() }
                    })
                } else if provider.requiresAPIKey {
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
            hasKey = provider.hasCredentials
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
            ProviderAutoSetup.reconcile()
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
                setStatus(provider == .bedrock
                          ? "Connected to Bedrock in \(BedrockConfig.region); \(Prefs.model(for: .bedrock)) answered."
                          : "Connected. \(fetched.count) models available.", error: false)
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
                if selectedTranscriber == .openAI {
                    TextField("File transcription model", text: $transcriptionModel)
                    Text("Long audio is uploaded to OpenAI in two-minute pieces when MacPilot can decode it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Audio transcription") }
            if selectedTranscriber == .amazonTranscribe || selectedTranscriber == .bedrock {
                AWSTranscriptionSettingsView(provider: selectedTranscriber)
            }
            if selectedTranscriber == .localWhisper { LocalWhisperSettingsView() }
        }
        .formStyle(.grouped)
    }

    private var selectedTranscriber: TranscriptionProviderID {
        TranscriptionProviderID(rawValue: transcriptionProvider) ?? .openAI
    }
}

private struct AWSTranscriptionSettingsView: View {
    let provider: TranscriptionProviderID
    @AppStorage(PrefKey.transcribeRegion) private var region = ""
    @AppStorage(PrefKey.transcribeBucket) private var bucket = ""
    @AppStorage(PrefKey.transcribePrefix) private var prefix = "macpilot/"
    @AppStorage(PrefKey.transcribeLanguage) private var language = "auto"
    @AppStorage(PrefKey.transcribeIdentifySpeakers) private var speakers = true
    @AppStorage(PrefKey.transcribeMaxSpeakers) private var maxSpeakers = 4
    @AppStorage(PrefKey.transcribeDeleteAfter) private var cleanUp = true
    @AppStorage(PrefKey.transcribeLive) private var live = false
    @AppStorage(PrefKey.transcribeUseLive) private var reuseLive = false
    @AppStorage(PrefKey.bedrockDataProfile) private var profile = ""
    @AppStorage(PrefKey.bedrockDataProject) private var project = ""

    var body: some View {
        Section("AWS transcription") {
            Text("Save an AWS access key under Providers → Claude (Bedrock). Add the session token for temporary credentials.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("AWS region", text: $region, prompt: Text(BedrockConfig.region))
            TextField("S3 bucket", text: $bucket)
            BucketStatusRow(bucket: $bucket)
            Text(provider == .bedrock
                 ? "Bedrock uploads audio and writes transcripts to this bucket. Use a bucket in the AWS region above."
                 : "A bucket in this region enables batch jobs. Leave it blank to stream saved audio to Amazon Transcribe.")
                .font(.caption).foregroundStyle(.secondary)
            if provider == .bedrock || !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextField("S3 key prefix", text: $prefix)
                Toggle(provider == .bedrock ? "Delete uploaded audio after a job finishes" : "Delete uploaded audio and completed job", isOn: $cleanUp)
                S3CleanupRow()
            }
            if provider == .bedrock {
                TextField("Data Automation profile ARN", text: $profile)
                TextField("Data Automation project ARN (optional)", text: $project)
                Text("If you use a project, enable the full audio transcript in its standard output. Bedrock output files stay in S3.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Bedrock Data Automation profiles and IAM", destination: URL(string: "https://docs.aws.amazon.com/bedrock/latest/userguide/bda-cris.html")!)
            }
            if provider == .amazonTranscribe || live {
                Picker("Amazon Transcribe language", selection: $language) {
                    ForEach(TranscribeSettings.languages, id: \.code) { Text($0.label).tag($0.code) }
                }
                Toggle("Identify speakers with Amazon Transcribe", isOn: $speakers)
                if speakers && provider == .amazonTranscribe && !bucket.isEmpty {
                    Stepper("Maximum speakers per batch track: \(maxSpeakers)", value: $maxSpeakers, in: 2...10)
                }
            }
            Toggle("Live microphone captions via Amazon Transcribe", isOn: $live)
            if live {
                Text("While recording, microphone audio streams to Amazon Transcribe. System audio is processed after you stop.")
                    .font(.caption).foregroundStyle(.secondary)
                if provider == .amazonTranscribe {
                    Toggle("Reuse complete live captions for the microphone track", isOn: $reuseLive)
                }
            }
            if provider == .amazonTranscribe || live {
                Link("Amazon Transcribe WebSocket permission", destination: URL(string: "https://docs.aws.amazon.com/transcribe/latest/dg/streaming-setting-up.html")!)
            }
        }
    }
}

private struct LocalWhisperSettingsView: View {
    @AppStorage(PrefKey.whisperExecutable) private var executable = ""
    @AppStorage(PrefKey.whisperModel) private var model = ""

    var body: some View {
        Section("Local Whisper") {
            pathField("whisper-cli executable", path: $executable)
            pathField("whisper.cpp model file", path: $model)
            Text("Install whisper.cpp and select a local model file. MacPilot can find whisper-cli in the default Homebrew locations. Audio is transcribed on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Whisper.cpp setup", destination: URL(string: "https://github.com/ggml-org/whisper.cpp#quick-start")!)
        }
    }

    private func pathField(_ title: String, path: Binding<String>) -> some View {
        HStack {
            TextField(title, text: path)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.message = title
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
            .accessibilityLabel("Choose \(title)")
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    private let manager = ShortcutManager.shared
    @AppStorage(PrefKey.buddyEnabled) private var buddyEnabled = true
    @AppStorage(PrefKey.pilotWakeWord) private var wakeWord = false
    @AppStorage(PrefKey.pilotSpeaks) private var speaks = true
    @State private var openAtLogin = LoginItemState.shared.enabled
    @State private var loginMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open MacPilot when I log in", isOn: $openAtLogin)
                    .onChange(of: LoginItemState.shared.enabled) { _, on in openAtLogin = on }
                    .onChange(of: openAtLogin) { _, on in
                        guard on != LoginItemState.shared.enabled else { return }
                        loginMessage = LaunchAtLogin.set(on)
                        openAtLogin = LaunchAtLogin.isEnabled || (on && LaunchAtLogin.needsApproval)
                        if LaunchAtLogin.needsApproval {
                            loginMessage = "Allow MacPilot in System Settings → General → Login Items."
                        }
                    }
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.orange)
                }
                Text("Starts in the menu bar so your shortcuts, notch, buddy, clipboard history and sync are ready right away.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Startup")
            }
            Section {
                Toggle("Show the floating buddy on the desktop", isOn: $buddyEnabled)
                    .onChange(of: buddyEnabled) { _, on in FloatingBuddy.shared.setEnabled(on) }
                Text("A small always-on-top helper: click it and speak, use its buttons for a voice note, dictation or a new note, drag it anywhere, right-click for more.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Answer out loud", isOn: $speaks).disabled(!buddyEnabled)
                Toggle("Listen for “Hey Pilot”", isOn: $wakeWord)
                    .disabled(!buddyEnabled)
                    .onChange(of: wakeWord) { _, _ in WakeWordListener.shared.start() }
                Text("Try: “add a task call mom tomorrow at 5”, “what's next today?”, “start recording”, “set a timer for 25 minutes”, “new note …”, or any question. “Hey Pilot” keeps the microphone on and works only with on-device recognition — nothing is sent anywhere until you speak to it — and pauses during recordings and dictation.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Floating buddy")
            }
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
    @AppStorage(PrefKey.hideFromScreenCapture) private var hideFromCapture = true

    var body: some View {
        Form {
            Section("Screen sharing & recording") {
                Toggle("Hide MacPilot from screenshots, screen recordings and screen sharing", isOn: $hideFromCapture)
                    .onChange(of: hideFromCapture) { _, _ in ScreenPrivacy.applyAll() }
                Text("""
                Others in a Zoom, Meet or Teams share see what's behind MacPilot's windows, not MacPilot itself — you still                 see it normally. macOS decides whether each app honors this; if a capture still shows MacPilot, share a                 single window instead of the whole screen.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }
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
                Text("Cloud transcription sends audio to the provider selected in Routing. Bedrock and Amazon Transcribe batch mode also upload audio to your S3 bucket. Local Whisper processes audio on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Text("Conversations, notes, tasks, prompts, recordings (with audio), clipboard history, workflows, run history, and usage stats will be removed. API keys are kept unless you delete them separately. This cannot be undone.")
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
            NotchSettingsSection()
            Section("Microphone") {
                Picker("Input", selection: $microphoneID) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                Button("Refresh devices") { devices = MicRecorder.availableDevices() }
            }
            Section {
                Toggle("Record system audio in meetings", isOn: $includeSystemAudio)
                ScreenRecordingSettings()
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
            RemindersSettingsSection()
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

/// One connected Google account: its calendars with show/hide toggles, and Disconnect.
private struct GoogleAccountCalendars: View {
    let account: String
    private let google = GoogleCalendarService.shared
    private let calendar = CalendarService.shared
    @State private var confirmDisconnect = false

    var body: some View {
        let calendars = google.calendars(of: account)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                GoogleBadge()
                Text(account).font(.headline)
                Text("\(calendars.count) calendar\(calendars.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !calendars.isEmpty {
                    Button("Show all") { calendars.forEach { calendar.setVisible(true, $0) } }.buttonStyle(.link)
                    Button("Hide all") { calendars.forEach { calendar.setVisible(false, $0) } }.buttonStyle(.link)
                }
                Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
            }
            if calendars.isEmpty {
                Text("No calendars loaded yet — press Refresh calendars.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(calendars) { item in
                Toggle(isOn: Binding(get: { calendar.isVisible(item) }, set: { calendar.setVisible($0, item) })) {
                    HStack(spacing: 6) {
                        Circle().fill(item.color.color).frame(width: 9, height: 9)
                        Text(item.title)
                        if !item.isWritable { Text("read only").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Disconnect \(account)?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { google.disconnect(account) }
        } message: {
            Text("Its calendars disappear from MacPilot and its access is revoked. Your events stay in Google Calendar.")
        }
    }
}

struct GoogleCalendarSettingsSection: View {
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
                    Label("\(google.accounts.count) Google account\(google.accounts.count == 1 ? "" : "s") connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Refresh calendars") { Task { await google.refreshCalendars() } }
                    Button {
                        Task { await google.connect() }
                    } label: {
                        if google.isSigningIn {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for Google…") }
                        } else {
                            Label("Add another Google account", systemImage: "plus")
                        }
                    }
                    .disabled(google.isSigningIn)
                }
                ForEach(google.accounts, id: \.self) { account in
                    GoogleAccountCalendars(account: account)
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
            Text("Google Calendar (optional, any number of accounts)")
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

// MARK: - Amazon Bedrock credentials

private struct BedrockCredentialsSection: View {
    var onChange: (_ saved: Bool) -> Void

    @AppStorage(PrefKey.bedrockAuthMethod) private var authMethod = BedrockAuthMethod.accessKeys.rawValue
    @AppStorage(PrefKey.bedrockRegion) private var region = BedrockConfig.defaultRegion
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var sessionToken = ""
    @State private var apiKey = ""
    @State private var saved: [String: Bool] = [:]
    @State private var message: String?

    private var method: BedrockAuthMethod { BedrockAuthMethod(rawValue: authMethod) ?? .accessKeys }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sign in with").frame(width: 90, alignment: .leading)
                Picker("", selection: $authMethod) {
                    ForEach(BedrockAuthMethod.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .onChange(of: authMethod) { _, _ in onChange(false) }
            }
            HStack {
                Text("Region").frame(width: 90, alignment: .leading)
                Picker("", selection: $region) {
                    ForEach(regionOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                TextField("or type a region", text: $region)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            if method == .accessKeys {
                secretRow("Access key ID", account: BedrockConfig.Account.accessKeyID, text: $accessKeyID, placeholder: "AKIA…", secure: false)
                secretRow("Secret key", account: BedrockConfig.Account.secretAccessKey, text: $secretAccessKey, placeholder: "Secret access key", secure: true)
                secretRow("Session token", account: BedrockConfig.Account.sessionToken, text: $sessionToken, placeholder: "Optional, for temporary credentials", secure: true)
            } else {
                secretRow("API key", account: BedrockConfig.Account.apiKey, text: $apiKey, placeholder: "Amazon Bedrock API key", secure: true)
            }
            HStack {
                Button("Save") { save() }
                    .disabled(!hasInput)
                Button("Delete credentials", role: .destructive) {
                    BedrockConfig.deleteAll()
                    refresh()
                    message = "Bedrock credentials deleted."
                    onChange(false)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Link("Model access in AWS", destination: BedrockConfig.modelAccessURL).font(.caption)
            }
            Text(method == .accessKeys
                 ? "Requests are signed with AWS Signature V4 (service bedrock-mantle). The IAM identity needs bedrock-mantle:CreateInference on the models you use, and each model must be enabled in Amazon Bedrock model access."
                 : "The identity behind the API key needs bedrock-mantle:CallWithBearerToken and bedrock-mantle:CreateInference. Short-term keys work only in the region where they were created.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
    }

    private var regionOptions: [String] {
        var options = BedrockConfig.suggestedRegions
        if !region.isEmpty, !options.contains(region) { options.insert(region, at: 0) }
        return options
    }

    private var hasInput: Bool {
        [accessKeyID, secretAccessKey, sessionToken, apiKey].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func secretRow(_ label: String, account: String, text: Binding<String>, placeholder: String, secure: Bool) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Group {
                let prompt = saved[account] == true ? "Saved in Keychain — paste to replace" : placeholder
                if secure {
                    SecureField(prompt, text: text)
                } else {
                    TextField(prompt, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            if saved[account] == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Saved in Keychain")
            }
        }
    }

    private func refresh() {
        for account in BedrockConfig.Account.all {
            saved[account] = KeychainStore.exists(account: account)
        }
    }

    private func save() {
        let values: [(String, String)] = [
            (BedrockConfig.Account.accessKeyID, accessKeyID),
            (BedrockConfig.Account.secretAccessKey, secretAccessKey),
            (BedrockConfig.Account.sessionToken, sessionToken),
            (BedrockConfig.Account.apiKey, apiKey)
        ]
        do {
            for (account, value) in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { try KeychainStore.save(trimmed, account: account) }
            }
            accessKeyID = ""
            secretAccessKey = ""
            sessionToken = ""
            apiKey = ""
            refresh()
            message = "Saved to Keychain."
            ProviderAutoSetup.reconcile()
            onChange(BedrockConfig.isConfigured)
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Dictation

struct DictationSettingsView: View {
    @AppStorage(PrefKey.dictationPushToTalk) private var pushToTalk = true
    @AppStorage(PrefKey.dictationCleanup) private var cleanup = true
    @AppStorage(PrefKey.dictationMode) private var mode = DictationMode.plain.rawValue
    @AppStorage(PrefKey.dictationVocabulary) private var vocabulary = ""
    @AppStorage(PrefKey.dictationLanguage) private var language = "English"
    @AppStorage(PrefKey.dictationSounds) private var sounds = true
    @AppStorage(PrefKey.dictationAutoPaste) private var autoPaste = true
    @AppStorage(PrefKey.dictationKeepClipboard) private var keepClipboard = true
    @AppStorage(PrefKey.dictationSaveNote) private var saveNote = false
    @State private var isTrusted = PasteService.isTrusted
    private let shortcuts = ShortcutManager.shared

    var body: some View {
        Form {
            Section {
                Picker("Shortcut behaviour", selection: $pushToTalk) {
                    Text("Hold to talk, tap for hands-free").tag(true)
                    Text("Tap to start, tap to stop").tag(false)
                }
                LabeledContent("Dictate", value: shortcuts.hotKey(for: .dictation)?.displayString ?? "Off")
                LabeledContent("Voice to task", value: shortcuts.hotKey(for: .voiceTask)?.displayString ?? "Off")
                Toggle("Play sounds on start and stop", isOn: $sounds)
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Change the keys in Settings → Shortcuts. Esc cancels while listening (needs Accessibility), or use ✕ on the pill.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Speech to text", value: Prefs.transcriptionProvider.displayName)
                LabeledContent("Microphone", value: Prefs.microphoneID == nil ? "System default" : "Chosen in Recording & Calendar")
                Toggle("Clean up with AI (punctuation, fillers, grammar)", isOn: $cleanup)
                Picker("Default style", selection: $mode) {
                    ForEach(DictationMode.allCases.filter { $0 != .task }) { Label($0.label, systemImage: $0.systemImage).tag($0.rawValue) }
                }
                TextField("Translate into", text: $language)
            } header: {
                Text("Transcription")
            } footer: {
                Text("Speech to text uses the provider in Routing; with Amazon Transcribe you see words while you speak. Cleanup uses \(Prefs.analysisProvider.displayName) (Routing → Transcript analysis); a fast model such as Haiku keeps it quick. Styles other than Plain always use AI. Without AI, fillers like “um” are removed locally.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $vocabulary)
                    .font(.body.monospaced())
                    .frame(minHeight: 70)
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Names, product terms and code identifiers, separated by commas or new lines. They help transcription and cleanup spell them right.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Output") {
                Toggle("Paste into the app you're using", isOn: $autoPaste)
                Toggle("Keep my clipboard (restore it after pasting)", isOn: $keepClipboard)
                    .disabled(!autoPaste)
                Toggle("Also save each dictation as a note", isOn: $saveNote)
                HStack {
                    Image(systemName: isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(isTrusted ? .green : .orange)
                    Text(isTrusted ? "Accessibility granted: text is pasted at your cursor." : "Without Accessibility permission the text is copied and you press ⌘V.")
                    Spacer()
                    if !isTrusted {
                        Button("Open Settings") {
                            PasteService.requestTrust()
                            PasteService.openAccessibilitySettings()
                        }
                    }
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear { isTrusted = PasteService.isTrusted }
    }
}

// MARK: - Apple Reminders

private struct RemindersSettingsSection: View {
    @AppStorage(PrefKey.remindersSync) private var enabled = false
    @AppStorage(PrefKey.remindersListName) private var listName = "MacPilot"
    private let sync = ReminderSync.shared

    var body: some View {
        Section {
            Toggle("Sync tasks with Apple Reminders", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    if on { Task { await sync.sync() } }
                }
            TextField("Reminders list", text: $listName)
                .disabled(!enabled)
            HStack {
                Button(sync.isSyncing ? "Syncing…" : "Sync now") { Task { await sync.sync() } }
                    .disabled(!enabled || sync.isSyncing)
                if let error = sync.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if let date = sync.lastSync {
                    Text("\(sync.lastSummary ?? "") · \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Two-way: tasks go to the “\(listName.isEmpty ? "MacPilot" : listName)” list (created if needed) with title, notes, due date, priority and done state, and reminders you add or change there come back here. Syncs on every change and every 5 minutes; on iPhone the list syncs through iCloud.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - S3 cleanup

/// Deletes everything MacPilot stored under its key prefix in the transcription bucket.
private struct S3CleanupRow: View {
    @State private var confirm = false
    @State private var running = false
    @State private var message: String?

    var body: some View {
        HStack {
            Button(running ? "Cleaning up…" : "Clean up S3…") { confirm = true }
                .disabled(running || TranscribeSettings.bucket.isEmpty || TranscribeSettings.keyPrefix.isEmpty)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .confirmationDialog("Delete everything MacPilot stored in s3://\(TranscribeSettings.bucket)/\(TranscribeSettings.keyPrefix)?",
                            isPresented: $confirm) {
            Button("Delete from S3", role: .destructive, action: run)
        } message: {
            Text("Uploaded audio and transcription output under this prefix are deleted permanently. Recordings and transcripts on this Mac are not affected.")
        }
    }

    private func run() {
        running = true
        message = nil
        Task {
            do {
                let count = try await S3Client.deletePrefix(bucket: TranscribeSettings.bucket, prefix: TranscribeSettings.keyPrefix,
                                                            region: TranscribeSettings.region)
                message = count == 0 ? "Nothing to delete." : "Deleted \(count) file\(count == 1 ? "" : "s") from S3."
            } catch {
                message = AIError.describe(error)
            }
            running = false
        }
    }
}

// MARK: - S3 bucket status

/// Shows whether the bucket exists and offers to create it (or suggest a free name).
private struct BucketStatusRow: View {
    @Binding var bucket: String
    @State private var status: String?
    @State private var isError = false
    @State private var busy = false
    @State private var canCreate = false

    private var name: String { bucket.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 8) {
            if name.isEmpty {
                Button("Suggest a name") { bucket = S3Bucket.suggestedName(region: TranscribeSettings.region) }
            } else {
                Button(busy ? "Checking…" : "Check bucket") { check() }.disabled(busy)
                if canCreate {
                    Button("Create bucket") { create() }.disabled(busy).buttonStyle(.borderedProminent)
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(isError ? .red : .secondary).lineLimit(3)
            } else if !name.isEmpty, let problem = S3Bucket.nameProblem(name) {
                Text("Name: \(problem)").font(.caption).foregroundStyle(.red)
            } else if !name.isEmpty {
                Text("Created automatically on first use if it doesn't exist.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: bucket) { _, _ in
            status = nil
            canCreate = false
        }
    }

    private func check() {
        busy = true
        Task {
            defer { busy = false }
            do {
                switch try await S3Bucket.state(bucket: name, region: TranscribeSettings.region) {
                case .exists: set("✓ Bucket found in \(TranscribeSettings.region).", error: false)
                case .missing:
                    set("This bucket doesn't exist yet.", error: false)
                    canCreate = S3Bucket.nameProblem(name) == nil
                case .otherRegion(let region): set(S3Bucket.BucketError.otherRegion(bucket: name, region: region).localizedDescription, error: true)
                case .noAccess: set(S3Bucket.BucketError.noAccess(name).localizedDescription, error: true)
                }
            } catch {
                set(AIError.describe(error), error: true)
            }
        }
    }

    private func create() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let note = try await S3Bucket.create(bucket: name, region: TranscribeSettings.region, prefix: TranscribeSettings.keyPrefix)
                canCreate = false
                set(note ?? "✓ Created “\(name)” in \(TranscribeSettings.region) (private, encrypted; temporary files expire after 1 day).", error: false)
            } catch {
                set(AIError.describe(error), error: true)
            }
        }
    }

    private func set(_ text: String, error: Bool) {
        status = text
        isError = error
    }
}

// MARK: - Screen recording

private struct ScreenRecordingSettings: View {
    @AppStorage(PrefKey.recordScreen) private var recordScreen = false
    @AppStorage(PrefKey.screenDisplayID) private var displayID = 0
    @AppStorage(PrefKey.screenFPS) private var fps = 15
    @AppStorage(PrefKey.screenMaxDimension) private var maxDimension = 1920
    @AppStorage(PrefKey.screenHideMacPilot) private var hideMacPilot = true

    private var displays: [(id: Int, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (Int(number), screen.localizedName)
        }
    }

    /// Rough size per hour for the chosen settings (screen content compresses well).
    private var estimate: String {
        let size = ScreenVideoSettings.outputSize(width: maxDimension == 0 ? 3024 : maxDimension,
                                                  height: maxDimension == 0 ? 1964 : maxDimension * 1964 / 3024, maxDimension: maxDimension)
        let bytesPerHour = Double(ScreenVideoSettings.bitrate(width: size.width, height: size.height, fps: fps)) / 8 * 3600
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerHour), countStyle: .file)
    }

    var body: some View {
        Toggle("Also record the screen (video) in meetings", isOn: $recordScreen)
        if recordScreen {
            Picker("Display", selection: $displayID) {
                Text("Main display").tag(0)
                ForEach(displays, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Frame rate", selection: $fps) {
                Text("5 fps (slides, smallest files)").tag(5)
                Text("15 fps (recommended)").tag(15)
                Text("30 fps (smooth video)").tag(30)
            }
            Picker("Quality", selection: $maxDimension) {
                Text("Standard (up to 1280 px)").tag(1280)
                Text("High (up to 1920 px)").tag(1920)
                Text("Full resolution").tag(0)
            }
            Toggle("Hide MacPilot's own windows in the video", isOn: $hideMacPilot)
            Text("Saved as screen.mp4 next to the meeting audio, about \(estimate) per hour at these settings. Watch it in the meeting's Transcript tab (it follows the transcript) or export one MP4 with screen and sound from Export.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notch

private struct NotchSettingsSection: View {
    @AppStorage(PrefKey.notchEnabled) private var enabled = true
    @AppStorage(PrefKey.notchExpandOnHover) private var expandOnHover = true
    @AppStorage(PrefKey.notchMeetingCountdown) private var countdown = true
    @AppStorage(PrefKey.notchShelfEnabled) private var shelf = true
    @AppStorage(PrefKey.notchNetworkReadout) private var networkReadout = true
    @AppStorage(PrefKey.notchCPUReadout) private var cpuReadout = true
    @AppStorage(PrefKey.notchNetworkCard) private var networkCard = true
    @AppStorage(PrefKey.statsUnit) private var unit = RateUnit.auto.rawValue
    @AppStorage(PrefKey.statsInterval) private var interval = 1.0
    @State private var menuBarMode = StatsDisplay.menuBarMode

    var body: some View {
        Section {
            Toggle("Show MacPilot in the notch", isOn: $enabled)
                .onChange(of: enabled) { _, _ in NotchController.shared.start(); SystemMonitor.shared.refreshDemand() }
            Toggle("Expand when the pointer is on it", isOn: $expandOnHover).disabled(!enabled)
            Toggle("Count down to meetings starting in 15 minutes", isOn: $countdown).disabled(!enabled)
            Toggle("File shelf: drop files on the notch to park them", isOn: $shelf).disabled(!enabled)
            Toggle("Network speed beside the notch (↓/↑)", isOn: $networkReadout)
                .onChange(of: networkReadout) { _, _ in SystemMonitor.shared.refreshDemand() }
            Toggle("CPU usage beside the notch", isOn: $cpuReadout)
                .onChange(of: cpuReadout) { _, _ in SystemMonitor.shared.refreshDemand() }
            Picker("Network units", selection: $unit) {
                ForEach(RateUnit.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Update every", selection: $interval) {
                Text("1 second").tag(1.0)
                Text("2 seconds").tag(2.0)
            }
            .onChange(of: interval) { _, _ in NetworkMonitor.shared.start(); SystemMonitor.shared.stop(); SystemMonitor.shared.refreshDemand() }
            Picker("Menu bar readout", selection: $menuBarMode) {
                ForEach(StatsDisplay.MenuBarMode.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: menuBarMode) { _, mode in
                UserDefaults.standard.set(mode.rawValue, forKey: PrefKey.menuBarStats)
                SystemMonitor.shared.refreshDemand()
            }
            Toggle("Network card with a 1-minute graph when expanded", isOn: $networkCard).disabled(!enabled)
        } header: {
            Text("Notch")
        } footer: {
            Text("A Dynamic Island–style area around the camera: recording timer, dictation, next meeting with Join and Record, and quick actions. On Macs without a notch it sits at the top centre of the main screen and only appears when something is happening; the network and CPU readout goes in the menu bar instead. Click the readout for graphs, top processes and a speed test. Sampling pauses while the screen is locked or asleep.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Snippets and quick links

struct SnippetsSettingsView: View {
    @AppStorage(PrefKey.snippetsEnabled) private var expansionEnabled = true
    @State private var isTrusted = PasteService.isTrusted
    private let library = SnippetLibrary.shared

    var body: some View {
        Form {
            Section {
                Toggle("Expand snippets as you type", isOn: $expansionEnabled)
                    .onChange(of: expansionEnabled) { _, _ in SnippetExpander.shared.start() }
                if !isTrusted {
                    HStack {
                        Label("Needs Accessibility permission to watch typing.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") { PasteService.requestTrust(); PasteService.openAccessibilitySettings() }
                    }
                    .font(.callout)
                }
                ForEach(Bindable(library).snippets) { $snippet in
                    HStack(alignment: .top) {
                        TextField("Keyword", text: $snippet.keyword).frame(width: 90).font(.body.monospaced())
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name", text: $snippet.name)
                            TextField("Text", text: $snippet.text, axis: .vertical).lineLimit(1...6)
                        }
                        Button(role: .destructive) { library.snippets.removeAll { $0.id == snippet.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete snippet")
                    }
                }
                Button("Add snippet") { library.snippets.append(Snippet(keyword: ";new", name: "New snippet", text: "")) }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Type a keyword like ;sig in any app and it turns into the text. Use {date}, {time}, {datetime} and {clipboard} as placeholders. Snippets are also in ⌥K. Never active in password fields.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(Bindable(library).aiCommands) { $command in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name", text: $command.name).font(.body.weight(.medium))
                            TextField("What the AI should do with the selected text", text: $command.instruction, axis: .vertical).lineLimit(1...5)
                            Toggle("Result replaces the selection", isOn: $command.replacesSelection).controlSize(.small)
                        }
                        Button(role: .destructive) { library.aiCommands.removeAll { $0.id == command.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete AI command")
                    }
                }
                HStack {
                    Button("Add AI command") { library.aiCommands.append(AICommand(name: "New command", instruction: "")) }
                    Button("Restore defaults") { library.aiCommands = AICommand.defaults }
                }
            } header: {
                Text("AI commands")
            } footer: {
                Text("Your own prompts for selected text. They appear in ⌥⇧E under “Your commands” and as commands in ⌥K.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(Bindable(library).links) { $link in
                    HStack {
                        TextField("Keyword", text: $link.keyword).frame(width: 70).font(.body.monospaced())
                        TextField("Name", text: $link.name).frame(width: 130)
                        TextField("https://…{query}…", text: $link.template)
                        Button(role: .destructive) { library.links.removeAll { $0.id == link.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete quick link")
                    }
                }
                HStack {
                    Button("Add quick link") { library.links.append(QuickLink(keyword: "new", name: "New link", template: "https://example.com/search?q={query}")) }
                    Button("Restore defaults") { library.links = QuickLink.defaults }
                }
            } header: {
                Text("Quick links")
            } footer: {
                Text("In ⌥K, type the keyword, a space and your search: “yt lofi”, “gh macpilot”, “jira ABC-123”. {query} is replaced by what you type. Edit the Jira link to your company's address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { isTrusted = PasteService.isTrusted }
    }
}
