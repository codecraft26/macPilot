import Foundation

/// Picks sensible providers from the credentials you actually have, without overriding real choices.
/// Example: with only AWS keys saved, transcription uses Amazon Transcribe and chat uses Claude via Bedrock
/// instead of failing with "No OpenAI API key".
enum ProviderAutoSetup {
    struct Credentials: Equatable {
        var openAI: Bool
        var anthropic: Bool
        var awsAccessKeys: Bool
        var bedrock: Bool
    }

    struct Choices: Equatable {
        var transcription: String?
        var chat: String?
        var analysis: String?
    }

    /// Pure decision: `explicit*` are the values the user saved (nil when never chosen).
    static func decide(_ credentials: Credentials, explicitTranscription: String?, explicitChat: String?, explicitAnalysis: String?) -> Choices {
        var choices = Choices()
        let transcription = explicitTranscription ?? TranscriptionProviderID.openAI.rawValue
        if transcription == TranscriptionProviderID.openAI.rawValue, !credentials.openAI, credentials.awsAccessKeys {
            choices.transcription = TranscriptionProviderID.amazonTranscribe.rawValue
        }
        func claude(_ current: String?) -> String? {
            let value = current ?? AIProviderID.anthropic.rawValue
            guard value == AIProviderID.anthropic.rawValue, !credentials.anthropic, credentials.bedrock else { return nil }
            return AIProviderID.bedrock.rawValue
        }
        choices.chat = claude(explicitChat)
        choices.analysis = claude(explicitAnalysis)
        return choices
    }

    /// Shown once after launch when the agent's provider was switched.
    @MainActor static var agentProviderNotice: String?

    /// Applies the decision to preferences. Call at launch and after credentials change.
    @MainActor
    static func reconcile() {
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.macpilot.app") ?? [:]
        let credentials = Credentials(
            openAI: KeychainStore.exists(account: AIProviderID.openAI.rawValue),
            anthropic: KeychainStore.exists(account: AIProviderID.anthropic.rawValue),
            awsAccessKeys: BedrockConfig.authMethod == .accessKeys && BedrockConfig.isConfigured,
            bedrock: BedrockConfig.isConfigured
        )
        let choices = decide(credentials,
                             explicitTranscription: saved[PrefKey.transcriptionProvider] as? String,
                             explicitChat: saved[PrefKey.chatProvider] as? String,
                             explicitAnalysis: saved[PrefKey.analysisProvider] as? String)
        if let value = choices.transcription { defaults.set(value, forKey: PrefKey.transcriptionProvider) }
        if let value = choices.chat { defaults.set(value, forKey: PrefKey.chatProvider) }
        if let value = choices.analysis { defaults.set(value, forKey: PrefKey.analysisProvider) }
        if credentials.bedrock, saved[PrefKey.enabled(.bedrock)] == nil {
            defaults.set(true, forKey: PrefKey.enabled(.bedrock)) // saving AWS keys means you want to use them
        }
        // The agent (and memory, search Ask, smart reminders, which share its settings) used to stay on Anthropic.
        if let next = AgentSettings.migrateProvider(defaults, availability: .current, preferred: Prefs.chatProvider, modelFor: { Prefs.model(for: $0) }) {
            agentProviderNotice = "The agent now uses \(next.displayName), which is already set up. Change it in Settings → Agent."
        }
    }
}
