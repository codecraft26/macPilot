import AppKit
import SwiftUI

/// The first-run setup window. Progress is saved after every step, so quitting resumes where you were.
@Observable
@MainActor
final class SetupController {
    static let shared = SetupController()

    var progress = SetupProgress.load()
    private var window: NSWindow?

    var shouldShowAtLaunch: Bool { progress.shouldShow() }

    func show(restart: Bool = false) {
        if restart {
            progress.current = .welcome
        } else {
            progress.current = progress.resumeStep()
        }
        progress.save()
        if window == nil {
            let hosting = NSHostingController(rootView: SetupWizardView().environment(AppState.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Set up MacPilot"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 760, height: 560))
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        ScreenPrivacy.applyAll()
    }

    func close() {
        window?.orderOut(nil)
    }

    func next() { progress.complete(); progress.save() }
    func skip() { progress.skip(); progress.save() }
    func back() { progress.back(); progress.save() }
    func go(_ step: SetupStep) { progress.go(to: step); progress.save() }

    func finish() {
        progress.finish()
        progress.save()
        close()
    }

    /// "Set up later": opens the matching Settings tab.
    func openSettings(for step: SetupStep) {
        AppState.shared.settingsTab = step.settingsTab
        WindowManager.shared.showDashboard(section: .settings)
    }
}

struct SetupWizardView: View {
    private let setup = SetupController.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                }
                Divider()
                footer.padding(16)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("MacPilot", systemImage: "paperplane.fill").font(.headline).foregroundStyle(DS.brandGradient).padding(.bottom, 12)
            ForEach(SetupStep.allCases) { step in
                Button { setup.go(step) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: stateSymbol(step)).foregroundStyle(stateColor(step)).frame(width: 16)
                        Text(step.title)
                        Spacer()
                        if !step.isRequired && step != .done { Text("optional").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(setup.progress.current == step ? DS.accent.opacity(0.15) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(step.title), \(setup.progress.completed.contains(step) ? "done" : setup.progress.skipped.contains(step) ? "skipped" : "not done")")
            }
            Spacer()
            Text("\(setup.progress.doneCount)/\(SetupProgress.totalCount) done").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 200, alignment: .topLeading)
        .background(DS.subtleFill)
    }

    private func stateSymbol(_ step: SetupStep) -> String {
        if setup.progress.completed.contains(step) { return "checkmark.circle.fill" }
        if setup.progress.skipped.contains(step) { return "arrow.uturn.forward.circle" }
        return setup.progress.current == step ? "circle.inset.filled" : "circle"
    }

    private func stateColor(_ step: SetupStep) -> Color {
        setup.progress.completed.contains(step) ? .green : setup.progress.skipped.contains(step) ? .orange : .secondary
    }

    @ViewBuilder
    private var content: some View {
        switch setup.progress.current {
        case .welcome: WelcomeStep()
        case .provider: ProviderStep()
        case .permissions: PermissionsStep()
        case .calendar: CalendarStep()
        case .features: FeaturesStep()
        case .telegram: TelegramStep()
        case .updates: UpdatesStep()
        case .done: DoneStep()
        }
    }

    private var footer: some View {
        HStack {
            if setup.progress.current != .welcome {
                Button { setup.back() } label: { Label("Back", systemImage: "chevron.left") }
                    .keyboardShortcut("[", modifiers: .command)
            }
            Spacer()
            if setup.progress.current == .done {
                Button("Finish") { setup.finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                if setup.progress.current != .welcome {
                    Button("Skip") { setup.skip() }
                }
                Button(setup.progress.current == .welcome ? "Get started" : "Continue") { setup.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Steps

private struct StepHeader: View {
    let step: SetupStep
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(step.title, systemImage: step.systemImage).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct WhyLine: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            .accessibilityLabel("Why we need this: \(text)")
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(step: .welcome, subtitle: "Your AI copilot for the Mac: assistant, meetings, notes, tasks, clipboard, launcher, an agent that works for you, and more.")
            ForEach([
                ("lock.shield", "Local-first", "Your notes, recordings, memory and settings stay on this Mac. There's no MacPilot account or server."),
                ("key.fill", "Your keys, in the Keychain", "AI and service keys are stored only in the macOS Keychain — never in files or logs."),
                ("hand.raised", "You stay in control", "Cloud AI sees only what a feature needs. The agent asks before it writes, runs commands, deletes or sends.")
            ], id: \.1) { icon, title, text in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon).font(.title2).foregroundStyle(DS.accent).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(text).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("This takes about two minutes. Every step can be skipped and changed later in Settings.").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
}

private struct ProviderStep: View {
    @State private var provider: AIProviderID = Prefs.analysisProvider
    @State private var key = ""
    @State private var status: String?
    @State private var ok = false
    @State private var busy = false
    @State private var ollamaModels: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(step: .provider, subtitle: "Pick the AI MacPilot uses for chat, summaries and the agent.")
            WhyLine(text: "Without a provider, AI features (assistant, summaries, agent) can't run. Ollama keeps everything on this Mac.")
            Picker("Provider", selection: $provider) {
                ForEach(AIProviderID.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(provider.dataNotice).font(.caption).foregroundStyle(.secondary)
            switch provider {
            case .anthropic, .openAI:
                HStack {
                    SecureField(provider == .anthropic ? "Anthropic API key (sk-ant-…)" : "OpenAI API key (sk-…)", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(provider.shortName) API key")
                    Button("Save & test") { saveAndTest() }.disabled(key.isEmpty || busy)
                }
                if provider.hasCredentials && key.isEmpty {
                    Button("Test saved key") { test() }.disabled(busy)
                }
            case .bedrock:
                Text("Amazon Bedrock needs an AWS access key or Bedrock API key and a region.").font(.callout)
                Button("Open Settings → Providers") { SetupController.shared.openSettings(for: .provider) }
            case .ollama:
                HStack {
                    Button("Find Ollama on this Mac") { detectOllama() }.disabled(busy)
                    if !ollamaModels.isEmpty { Text("Models: \(ollamaModels.prefix(4).joined(separator: ", "))").font(.caption) }
                }
                Text("Install Ollama from ollama.com and pull a model (e.g. `ollama pull llama3.2`) if you haven't.").font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView().controlSize(.small) }
            if let status {
                Label(status, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange).font(.callout)
            }
        }
        .onChange(of: provider) { _, _ in status = nil; key = "" }
    }

    private func choose() {
        UserDefaults.standard.set(provider.rawValue, forKey: PrefKey.chatProvider)
        UserDefaults.standard.set(provider.rawValue, forKey: PrefKey.analysisProvider)
        UserDefaults.standard.set(true, forKey: PrefKey.enabled(provider))
    }

    private func saveAndTest() {
        do {
            try SetupKeyStore.save(key, for: provider)
            key = ""
            choose()
            test()
        } catch {
            ok = false
            status = AIError.describe(error)
        }
    }

    private func test() {
        busy = true
        Task {
            do {
                let models = try await AIRouter.client(for: provider).listModels()
                if !models.isEmpty { Prefs.setCachedModels(models, for: provider) }
                ok = true
                status = "Connected to \(provider.shortName)."
                choose()
            } catch {
                ok = false
                status = AIError.describe(error)
            }
            busy = false
        }
    }

    private func detectOllama() {
        busy = true
        Task {
            do {
                ollamaModels = try await OllamaClient(baseURL: Prefs.ollamaBaseURL).listModels()
                ok = !ollamaModels.isEmpty
                status = ok ? "Ollama is running with \(ollamaModels.count) model\(ollamaModels.count == 1 ? "" : "s")." : "Ollama is running but has no models yet."
                if ok {
                    choose()
                    if let first = ollamaModels.first { UserDefaults.standard.set(first, forKey: PrefKey.model(.ollama)) }
                }
            } catch {
                ok = false
                status = "Ollama isn't running at \(Prefs.ollamaBaseURL.absoluteString)."
            }
            busy = false
        }
    }
}

private struct PermissionsStep: View {
    @State private var states: [SetupPermission: PermissionState] = [:]
    @State private var needsRelaunch = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(step: .permissions, subtitle: "Allow what you want MacPilot to do. Status updates live as you grant them.")
            ForEach(SetupPermission.allCases) { permission in
                let state = states[permission] ?? .unknown
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: state.symbol)
                        .foregroundStyle(state == .granted ? .green : state == .denied ? .red : permission.isOptional ? .secondary : .orange)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(permission.title).font(.headline)
                            if permission.isOptional { Text("optional").font(.caption2).foregroundStyle(.secondary) }
                        }
                        WhyLine(text: permission.why)
                    }
                    Spacer()
                    if state != .granted {
                        Button("Request") {
                            Task {
                                await PermissionChecker.request(permission)
                                if permission == .screenRecording { needsRelaunch = true }
                                await refresh()
                            }
                        }
                        Button("Open Settings") { NSWorkspace.shared.open(permission.settingsURL) }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(permission.title): \(state.label)")
            }
            if needsRelaunch || (states[.screenRecording] != .granted && states[.screenRecording] != nil) {
                HStack {
                    Text("macOS often applies Screen Recording only after MacPilot restarts.").font(.caption).foregroundStyle(.secondary)
                    Button("Relaunch MacPilot") { SetupKeyStore.relaunch() }
                }
            }
        }
        .task { await refresh() }
        .onReceive(timer) { _ in Task { await refresh() } }
    }

    private func refresh() async {
        for permission in SetupPermission.allCases { states[permission] = await PermissionChecker.status(permission) }
    }
}

private struct CalendarStep: View {
    private let calendar = CalendarService.shared
    private let google = GoogleCalendarService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(step: .calendar, subtitle: "See meetings, join and record them, and let Focus and reminders know when you're busy.")
            WhyLine(text: "MacPilot only creates or changes events after you confirm them.")
            HStack {
                Image(systemName: calendar.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(calendar.isAuthorized ? .green : .orange)
                Text(calendar.isAuthorized ? "Apple Calendar connected" : "Apple Calendar not connected")
                Spacer()
                if !calendar.isAuthorized { Button("Allow Apple Calendar") { Task { await calendar.requestAccess() } } }
            }
            HStack {
                Image(systemName: google.isConnected ? "checkmark.circle.fill" : "circle").foregroundStyle(google.isConnected ? .green : .secondary)
                Text(google.isConnected ? "Google: \(google.accountEmail)" : "Google Calendar (optional)")
                Spacer()
                Button(google.isConnected ? "Add another account" : "Connect Google account") {
                    if google.clientID.isEmpty { SetupController.shared.openSettings(for: .calendar) } else { Task { await google.connect() } }
                }
            }
            if google.clientID.isEmpty {
                Text("Google needs your own OAuth client ID first (Settings → Recording & Calendar explains how). You can also add Google under System Settings → Internet Accounts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = google.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct FeaturesStep: View {
    @AppStorage(PrefKey.notchEnabled) private var notch = true
    @State private var buddy = FloatingBuddy.shared.isVisible
    @State private var memory = MemorySettings.load()
    @State private var focus = FocusSettings.load()
    @State private var login = LoginItemState.shared.enabled
    @State private var shortcutMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(step: .features, subtitle: "Turn on what you'd like. Everything can be changed later.")
            Toggle("Floating buddy (Pilot) on the desktop", isOn: $buddy)
                .onChange(of: buddy) { _, on in FloatingBuddy.shared.setEnabled(on) }
            Toggle("Live status in the notch", isOn: $notch)
                .onChange(of: notch) { _, _ in NotchController.shared.start() }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Smart Do Not Disturb in meetings and while sharing your screen", isOn: Binding(
                    get: { focus.meetings || focus.screenSharing },
                    set: { on in focus.meetings = on; focus.screenSharing = on; focus.microphone = on; focus.save() }))
                HStack {
                    Button("Set up the Focus shortcuts…") { Task { shortcutMessage = await FocusShortcuts.installWithImport() } }
                    if let shortcutMessage { Text(shortcutMessage).font(.caption) }
                }
                WhyLine(text: "macOS has no public API to switch Focus, so MacPilot uses two small Shortcuts you import once.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Memory and open loops (off by default)", isOn: $memory.enabled)
                    .onChange(of: memory) { _, value in value.save() }
                WhyLine(text: "Reads visible text only in apps you choose, keeps it on this Mac, never reads passwords. Choose apps in Settings → Memory.")
            }
            Toggle("Open MacPilot at login", isOn: $login)
                .onChange(of: login) { _, on in _ = LaunchAtLogin.set(on) }
        }
    }
}

private struct TelegramStep: View {
    private let bot = TelegramBot.shared
    @State private var token = ""
    @State private var hasToken = TelegramBot.hasToken
    @State private var message: String?
    @State private var code: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(step: .telegram, subtitle: "Optional: ask the agent from your phone, approve actions, get reminders.")
            Text("1. In Telegram, message @BotFather, send /newbot and follow the steps.\n2. Paste the token it gives you below.\n3. Press Pair a phone and send the code to your bot.")
                .font(.callout)
            if hasToken {
                Label("Token saved in the Keychain", systemImage: "key.fill").foregroundStyle(.green)
            } else {
                HStack {
                    SecureField("Bot token (123456789:AA…)", text: $token).textFieldStyle(.roundedBorder).accessibilityLabel("Telegram bot token")
                    Button("Save") {
                        do {
                            try TelegramBot.saveToken(token)
                            token = ""
                            hasToken = true
                            bot.isEnabled = true
                            Task { message = await bot.test() }
                        } catch { message = error.localizedDescription }
                    }
                    .disabled(token.isEmpty)
                }
            }
            if hasToken {
                HStack {
                    Button("Pair a phone") { code = bot.newPairingCode() }
                    if let code { Text("Send /pair \(code) to your bot (valid 5 minutes)").font(.body.monospaced()).textSelection(.enabled) }
                }
                if !bot.pairing.users.isEmpty { Label("\(bot.pairing.users.count) phone(s) paired", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            WhyLine(text: "Telegram is cloud messaging, not end-to-end encrypted. Only paired people can use the bot.")
        }
    }
}

private struct UpdatesStep: View {
    private let updates = UpdateManager.shared
    @State private var checks = UpdateManager.shared.automaticallyChecks

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(step: .updates, subtitle: "Get fixes and new features automatically.")
            Toggle("Check for updates automatically (daily)", isOn: $checks)
                .onChange(of: checks) { _, on in updates.automaticallyChecks = on }
            Button("Check now") { updates.checkForUpdates() }.disabled(!updates.isAvailable)
            Text("You're on MacPilot \(updates.currentVersion). Updates are signed and verified before they're installed, and you choose when to install.")
                .font(.callout).foregroundStyle(.secondary)
            if !updates.isAvailable { Text("This build doesn't have updates set up.").font(.caption).foregroundStyle(.orange) }
        }
    }
}

private struct DoneStep: View {
    private let setup = SetupController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(step: .done, subtitle: "You're ready. Here's what's set up.")
            ForEach(SetupStep.allCases.filter { $0 != .welcome && $0 != .done }) { step in
                HStack {
                    Image(systemName: setup.progress.completed.contains(step) ? "checkmark.circle.fill" : "arrow.uturn.forward.circle")
                        .foregroundStyle(setup.progress.completed.contains(step) ? .green : .orange)
                    Text(step.title)
                    Text(setup.progress.completed.contains(step) ? "done" : "skipped").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !setup.progress.completed.contains(step) {
                        Button("Set up later…") { setup.openSettings(for: step) }.buttonStyle(.link)
                    }
                }
            }
            Divider().padding(.vertical, 6)
            Text("Try these shortcuts").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("⌥K").font(.body.monospaced()); Text("Command launcher — apps, commands, “remind me…”, “kill port 3000”") }
                GridRow { Text("⌥F").font(.body.monospaced()); Text("Search everything") }
                GridRow { Text("⌥Space").font(.body.monospaced()); Text("Ask AI") }
                GridRow { Text("⌥D").font(.body.monospaced()); Text("Hold to dictate into any app") }
            }
        }
    }
}

/// Dashboard: "Setup: 5/8 done" until every required step is done.
struct SetupProgressCard: View {
    private let setup = SetupController.shared

    var body: some View {
        if !setup.progress.allRequiredDone {
            HStack(spacing: DS.Space.m) {
                IconTile(systemImage: "checklist", color: DS.accent, size: 20)
                Text("Setup: \(setup.progress.doneCount)/\(SetupProgress.totalCount) done").font(.headline)
                ProgressView(value: Double(setup.progress.doneCount), total: Double(SetupProgress.totalCount)).frame(width: 140)
                Spacer()
                Button("Continue setup") { setup.show() }
            }
            .card(padding: DS.Space.s)
        }
    }
}
