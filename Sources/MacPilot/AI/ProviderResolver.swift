import Foundation

/// One place that decides which AI provider a feature runs on, from the credentials actually saved.
/// It never switches away from a provider the user explicitly picked; it offers the alternative instead.
enum ProviderResolver {
    /// Which providers can run right now (checked without reading secrets, so no Keychain prompt).
    struct Availability: Equatable {
        var anthropic = false
        var openAI = false
        var bedrock = false
        var ollama = false

        func has(_ provider: AIProviderID) -> Bool {
            switch provider {
            case .anthropic: return anthropic
            case .openAI: return openAI
            case .bedrock: return bedrock
            case .ollama: return ollama
            }
        }

        /// Saved credentials; Ollama counts when it's turned on in Settings → Providers (no network check here).
        static var current: Availability {
            Availability(anthropic: AIProviderID.anthropic.hasCredentials, openAI: AIProviderID.openAI.hasCredentials,
                         bedrock: AIProviderID.bedrock.hasCredentials, ollama: Prefs.isEnabled(.ollama))
        }
    }

    enum Decision: Equatable {
        /// Run on this provider.
        case use(AIProviderID)
        /// The explicitly chosen provider has no credentials; offer `alternative` (never switch silently).
        case offer(chosen: AIProviderID, alternative: AIProviderID)
        /// Nothing is configured: ask for credentials for this provider.
        case setUp(AIProviderID)
    }

    /// Fallback order after the user's default provider: Bedrock, Anthropic, OpenAI, Ollama.
    static let order: [AIProviderID] = [.bedrock, .anthropic, .openAI, .ollama]

    static func firstConfigured(preferred: AIProviderID?, _ availability: Availability) -> AIProviderID? {
        let candidates = (preferred.map { [$0] } ?? []) + order
        return candidates.first(where: availability.has)
    }

    /// `explicit`: what the user picked for this feature (nil = never picked). `preferred`: their default chat provider.
    static func resolve(explicit: AIProviderID?, preferred: AIProviderID?, _ availability: Availability) -> Decision {
        if let explicit {
            if availability.has(explicit) { return .use(explicit) }
            if let alternative = firstConfigured(preferred: preferred, availability), alternative != explicit {
                return .offer(chosen: explicit, alternative: alternative)
            }
            return .setUp(explicit)
        }
        if let provider = firstConfigured(preferred: preferred, availability) { return .use(provider) }
        return .setUp(preferred ?? .anthropic)
    }

    /// "Bedrock isn't set up — use Claude (Anthropic API) instead?"
    static func offerText(chosen: AIProviderID, alternative: AIProviderID) -> String {
        "\(chosen.shortName) isn't set up — use \(alternative.displayName) instead?"
    }
}
