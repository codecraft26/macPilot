import Foundation

/// UserDefaults keys. Views use the same keys through @AppStorage.
/// Nothing secret is stored here.
enum PrefKey {
    static let hasLaunchedBefore = "app.hasLaunchedBefore"
    static let chatProvider = "routing.chatProvider"
    static let analysisProvider = "routing.analysisProvider"
    static let transcriptionProvider = "routing.transcriptionProvider"
    static let transcriptionModel = "routing.transcriptionModel"
    static let whisperExecutable = "transcription.whisperExecutable"
    static let whisperModel = "transcription.whisperModel"
    static let ollamaBaseURL = "ollama.baseURL"
    static let defaultSystemPrompt = "assistant.systemPrompt"
    static let microphoneID = "recording.microphoneID"
    static let includeSystemAudio = "recording.includeSystemAudio"
    static let autoProcessRecordings = "recording.autoProcess"
    static let audioRetentionDays = "privacy.audioRetentionDays"
    static let hiddenCalendarIDs = "calendar.hiddenCalendarIDs"
    static let defaultEventAlarmMinutes = "calendar.defaultAlarmMinutes"
    static let clipboardEnabled = "clipboard.enabled"
    static let clipboardPaused = "clipboard.paused"
    static let clipboardRetentionDays = "clipboard.retentionDays"
    static let clipboardMaxItems = "clipboard.maxItems"
    static let clipboardCaptureImages = "clipboard.captureImages"
    static let clipboardSkipSensitive = "clipboard.skipSensitive"
    static let clipboardExcludedApps = "clipboard.excludedApps"
    static let developerRepos = "developer.repositories"
    static let snippetsEnabled = "snippets.enabled"
    static let iCloudSyncEnabled = "sync.iCloudEnabled"
    static let hideFromScreenCapture = "privacy.hideFromScreenCapture"
    static let autoBriefing = "briefing.auto"
    static let buddyEnabled = "buddy.enabled"
    static let notchShelfEnabled = "notch.shelfEnabled"
    static let pilotWakeWord = "buddy.wakeWord"
    static let pilotSpeaks = "buddy.speaks"
    static let notchEnabled = "notch.enabled"
    static let notchExpandOnHover = "notch.expandOnHover"
    static let notchMeetingCountdown = "notch.meetingCountdown"
    static let notchNetworkReadout = "notch.networkReadout"
    static let notchNetworkCard = "notch.networkCard"
    static let menuBarNetwork = "menuBar.networkReadout"
    static let notchCPUReadout = "notch.cpuReadout"
    static let menuBarStats = "menuBar.stats"
    static let statsUnit = "stats.unit"
    static let statsInterval = "stats.interval"
    static let recordScreen = "recording.recordScreen"
    static let screenDisplayID = "recording.screenDisplayID"
    static let screenFPS = "recording.screenFPS"
    static let screenMaxDimension = "recording.screenMaxDimension"
    static let screenHideMacPilot = "recording.screenHideMacPilot"
    static let remindersSync = "reminders.sync"
    static let remindersListName = "reminders.listName"
    static let remindersListID = "reminders.listID"
    static let dictationPushToTalk = "dictation.pushToTalk"
    static let dictationCleanup = "dictation.cleanup"
    static let dictationMode = "dictation.mode"
    static let dictationVocabulary = "dictation.vocabulary"
    static let dictationLanguage = "dictation.translateLanguage"
    static let dictationSounds = "dictation.sounds"
    static let dictationAutoPaste = "dictation.autoPaste"
    static let dictationKeepClipboard = "dictation.keepClipboard"
    static let dictationSaveNote = "dictation.saveAsNote"
    static let transcribeRegion = "transcribe.region"
    static let transcribeBucket = "transcribe.bucket"
    static let transcribePrefix = "transcribe.prefix"
    static let transcribeLanguage = "transcribe.language"
    static let transcribeIdentifySpeakers = "transcribe.identifySpeakers"
    static let transcribeMaxSpeakers = "transcribe.maxSpeakers"
    static let transcribeDeleteAfter = "transcribe.deleteAfter"
    static let transcribeLive = "transcribe.live"
    static let transcribeUseLive = "transcribe.useLive"
    static let bedrockDataProfile = "transcribe.bedrockDataProfile"
    static let bedrockDataProject = "transcribe.bedrockDataProject"
    static let bedrockRegion = "bedrock.region"
    static let bedrockAuthMethod = "bedrock.authMethod"
    static let googleClientID = "google.clientID"
    static let googleAccountEmail = "google.accountEmail"

    static func enabled(_ provider: AIProviderID) -> String { "provider.\(provider.rawValue).enabled" }
    static func model(_ provider: AIProviderID) -> String { "provider.\(provider.rawValue).model" }
    static func cachedModels(_ provider: AIProviderID) -> String { "provider.\(provider.rawValue).models" }
    static func tokenLimit(_ provider: AIProviderID) -> String { "provider.\(provider.rawValue).monthlyTokenLimit" }
}

/// Transcription is configured independently from chat (PRD section 5).
enum TranscriptionProviderID: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case amazonTranscribe = "aws"
    case bedrock = "bedrock"
    case localWhisper = "whisper"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .amazonTranscribe: return "Amazon Transcribe (AWS)"
        case .bedrock: return "Amazon Bedrock Data Automation"
        case .localWhisper: return "Local Whisper (on device)"
        }
    }
}

enum Prefs {
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        var values: [String: Any] = [
            PrefKey.chatProvider: AIProviderID.anthropic.rawValue,
            PrefKey.analysisProvider: AIProviderID.anthropic.rawValue,
            PrefKey.transcriptionProvider: TranscriptionProviderID.openAI.rawValue,
            PrefKey.transcriptionModel: "gpt-4o-transcribe",
            PrefKey.ollamaBaseURL: "http://localhost:11434",
            PrefKey.microphoneID: "",
            PrefKey.includeSystemAudio: true,
            PrefKey.autoProcessRecordings: true,
            PrefKey.audioRetentionDays: 0,
            PrefKey.defaultEventAlarmMinutes: 10,
            PrefKey.bedrockRegion: BedrockConfig.defaultRegion,
            PrefKey.snippetsEnabled: true,
            PrefKey.hideFromScreenCapture: true,
            PrefKey.autoBriefing: true,
            PrefKey.buddyEnabled: true,
            PrefKey.notchShelfEnabled: true,
            PrefKey.pilotWakeWord: false,
            PrefKey.pilotSpeaks: true,
            PrefKey.notchEnabled: true,
            PrefKey.notchExpandOnHover: true,
            PrefKey.notchMeetingCountdown: true,
            PrefKey.notchNetworkReadout: true,
            PrefKey.notchCPUReadout: true,
            PrefKey.statsInterval: 1.0,
            PrefKey.notchNetworkCard: true,
            PrefKey.menuBarNetwork: false,
            PrefKey.recordScreen: false,
            PrefKey.screenDisplayID: 0,
            PrefKey.screenFPS: 15,
            PrefKey.screenMaxDimension: 1920,
            PrefKey.screenHideMacPilot: true,
            PrefKey.remindersSync: false,
            PrefKey.remindersListName: "MacPilot",
            PrefKey.dictationPushToTalk: true,
            PrefKey.dictationCleanup: true,
            PrefKey.dictationMode: DictationMode.plain.rawValue,
            PrefKey.dictationVocabulary: "",
            PrefKey.dictationLanguage: "English",
            PrefKey.dictationSounds: true,
            PrefKey.dictationAutoPaste: true,
            PrefKey.dictationKeepClipboard: true,
            PrefKey.dictationSaveNote: false,
            PrefKey.transcribeRegion: "",
            PrefKey.transcribeBucket: "",
            PrefKey.transcribePrefix: "macpilot/",
            PrefKey.transcribeLanguage: "auto",
            PrefKey.transcribeIdentifySpeakers: true,
            PrefKey.transcribeMaxSpeakers: 4,
            PrefKey.transcribeDeleteAfter: true,
            PrefKey.transcribeLive: false,
            PrefKey.transcribeUseLive: false,
            PrefKey.bedrockAuthMethod: BedrockAuthMethod.accessKeys.rawValue,
            PrefKey.clipboardEnabled: true,
            PrefKey.clipboardRetentionDays: 30,
            PrefKey.clipboardMaxItems: 1000,
            PrefKey.clipboardCaptureImages: false,
            PrefKey.clipboardSkipSensitive: true,
            PrefKey.clipboardExcludedApps: SensitiveContent.defaultExcludedBundleIDs,
            PrefKey.defaultSystemPrompt: "You are MacPilot, a concise and practical assistant for a professional working on a Mac. Prefer short, direct answers and use Markdown code blocks for code."
        ]
        for provider in AIProviderID.allCases {
            values[PrefKey.enabled(provider)] = provider == .anthropic || provider == .openAI
            values[PrefKey.model(provider)] = provider.defaultModel
            values[PrefKey.tokenLimit(provider)] = 0
        }
        defaults.register(defaults: values)
    }

    static var chatProvider: AIProviderID {
        AIProviderID(rawValue: defaults.string(forKey: PrefKey.chatProvider) ?? "") ?? .anthropic
    }

    static var analysisProvider: AIProviderID {
        AIProviderID(rawValue: defaults.string(forKey: PrefKey.analysisProvider) ?? "") ?? .anthropic
    }

    static var transcriptionProvider: TranscriptionProviderID {
        TranscriptionProviderID(rawValue: defaults.string(forKey: PrefKey.transcriptionProvider) ?? "") ?? .openAI
    }

    static var transcriptionModel: String {
        let value = defaults.string(forKey: PrefKey.transcriptionModel) ?? ""
        return value.isEmpty ? "gpt-4o-transcribe" : value
    }

    static var microphoneID: String? {
        let value = defaults.string(forKey: PrefKey.microphoneID) ?? ""
        return value.isEmpty ? nil : value
    }

    static var includeSystemAudio: Bool { defaults.bool(forKey: PrefKey.includeSystemAudio) }
    static var recordScreen: Bool { defaults.bool(forKey: PrefKey.recordScreen) }
    static var autoProcessRecordings: Bool { defaults.bool(forKey: PrefKey.autoProcessRecordings) }
    static var audioRetentionDays: Int { defaults.integer(forKey: PrefKey.audioRetentionDays) }
    static var defaultEventAlarmMinutes: Int { defaults.integer(forKey: PrefKey.defaultEventAlarmMinutes) }

    static var clipboardEnabled: Bool { defaults.bool(forKey: PrefKey.clipboardEnabled) }
    static var clipboardRetentionDays: Int { defaults.integer(forKey: PrefKey.clipboardRetentionDays) }
    static var clipboardMaxItems: Int { defaults.integer(forKey: PrefKey.clipboardMaxItems) }
    static var clipboardCaptureImages: Bool { defaults.bool(forKey: PrefKey.clipboardCaptureImages) }
    static var clipboardSkipSensitive: Bool { defaults.bool(forKey: PrefKey.clipboardSkipSensitive) }

    static var clipboardExcludedApps: [String] {
        get { defaults.stringArray(forKey: PrefKey.clipboardExcludedApps) ?? SensitiveContent.defaultExcludedBundleIDs }
        set { defaults.set(newValue, forKey: PrefKey.clipboardExcludedApps) }
    }

    static var dictationDefaultMode: DictationMode {
        DictationMode(rawValue: defaults.string(forKey: PrefKey.dictationMode) ?? "") ?? .plain
    }

    /// Names, product terms and identifiers, one per line or comma separated.
    static var dictationVocabulary: [String] {
        (defaults.string(forKey: PrefKey.dictationVocabulary) ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static var hiddenCalendarIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: PrefKey.hiddenCalendarIDs) ?? []) }
        set { defaults.set(Array(newValue), forKey: PrefKey.hiddenCalendarIDs) }
    }

    static var defaultSystemPrompt: String {
        defaults.string(forKey: PrefKey.defaultSystemPrompt) ?? ""
    }

    static func isEnabled(_ provider: AIProviderID) -> Bool {
        defaults.bool(forKey: PrefKey.enabled(provider))
    }

    static func model(for provider: AIProviderID) -> String {
        let value = defaults.string(forKey: PrefKey.model(provider)) ?? ""
        return value.isEmpty ? provider.defaultModel : value
    }

    static func cachedModels(for provider: AIProviderID) -> [String] {
        let stored = defaults.stringArray(forKey: PrefKey.cachedModels(provider)) ?? []
        return stored.isEmpty ? provider.suggestedModels : stored
    }

    static func setCachedModels(_ models: [String], for provider: AIProviderID) {
        defaults.set(models, forKey: PrefKey.cachedModels(provider))
    }

    static var ollamaBaseURL: URL {
        let raw = defaults.string(forKey: PrefKey.ollamaBaseURL) ?? ""
        return URL(string: raw) ?? URL(string: "http://localhost:11434")!
    }

    /// First enabled provider, preferring the configured chat provider.
    static var preferredChatProvider: AIProviderID {
        let preferred = chatProvider
        if isEnabled(preferred) { return preferred }
        return AIProviderID.allCases.first(where: isEnabled) ?? preferred
    }
}
