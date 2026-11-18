import Foundation

/// UserDefaults keys. Views use the same keys through @AppStorage.
/// Nothing secret is stored here.
enum PrefKey {
    static let hasLaunchedBefore = "app.hasLaunchedBefore"
    static let chatProvider = "routing.chatProvider"
    static let analysisProvider = "routing.analysisProvider"
    static let transcriptionProvider = "routing.transcriptionProvider"
    static let transcriptionModel = "routing.transcriptionModel"
    static let liveTranscriptionModel = "routing.liveTranscriptionModel"
    static let ollamaBaseURL = "ollama.baseURL"
    static let defaultSystemPrompt = "assistant.systemPrompt"

    static func enabled(_ provider: AIProviderID) -> String { "provider.\(provider.rawValue).enabled" }
    static func model(_ provider: AIProviderID) -> String { "provider.\(provider.rawValue).model" }
    static func cachedModels(_ provider: AIProviderID) -> String { "provider.\(provider.rawValue).models" }
    static func tokenLimit(_ provider: AIProviderID) -> String { "provider.\(provider.rawValue).monthlyTokenLimit" }
}

/// Transcription is configured independently from chat (PRD section 5).
enum TranscriptionProviderID: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case localWhisper = "whisper"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
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
            PrefKey.liveTranscriptionModel: "gpt-4o-transcribe",
            PrefKey.ollamaBaseURL: "http://localhost:11434",
            PrefKey.defaultSystemPrompt: "You are MacPilot, a concise and practical assistant for a professional working on a Mac. Prefer short, direct answers and use Markdown code blocks for code."
        ]
        for provider in AIProviderID.allCases {
            values[PrefKey.enabled(provider)] = provider != .ollama
            values[PrefKey.model(provider)] = provider.defaultModel
            values[PrefKey.tokenLimit(provider)] = 0
        }
        defaults.register(defaults: values)
    }

    static var chatProvider: AIProviderID {
        AIProviderID(rawValue: defaults.string(forKey: PrefKey.chatProvider) ?? "") ?? .anthropic
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
