import Foundation

/// Picks the configured client for a provider and enforces on/off switches and usage limits.
enum AIRouter {
    static func client(for provider: AIProviderID) -> any ChatProvider {
        switch provider {
        case .anthropic: return AnthropicClient()
        case .openAI: return OpenAIClient()
        case .ollama: return OllamaClient(baseURL: Prefs.ollamaBaseURL)
        }
    }

    static func stream(
        provider: AIProviderID,
        model: String,
        system: String?,
        turns: [ChatTurn]
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        if !Prefs.isEnabled(provider) {
            return failing(AIError.providerDisabled(provider))
        }
        if UsageTracker.isOverLimit(provider) {
            return failing(AIError.limitReached(provider))
        }
        UsageTracker.recordRequest(provider)
        return client(for: provider).stream(model: model, system: system, turns: turns)
    }

    private static func failing(_ error: Error) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

/// Token usage per provider per calendar month, kept in UserDefaults (no prompt content).
enum UsageTracker {
    struct Usage: Codable, Equatable {
        var inputTokens = 0
        var outputTokens = 0
        var requests = 0
        var totalTokens: Int { inputTokens + outputTokens }
    }

    static func monthKey(for date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private static func key(_ provider: AIProviderID) -> String {
        "usage.\(provider.rawValue).\(monthKey())"
    }

    static func current(_ provider: AIProviderID) -> Usage {
        guard let data = UserDefaults.standard.data(forKey: key(provider)),
              let usage = try? JSONDecoder().decode(Usage.self, from: data) else { return Usage() }
        return usage
    }

    private static func store(_ usage: Usage, for provider: AIProviderID) {
        if let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: key(provider))
        }
    }

    static func recordRequest(_ provider: AIProviderID) {
        var usage = current(provider)
        usage.requests += 1
        store(usage, for: provider)
    }

    static func record(_ provider: AIProviderID, input: Int, output: Int) {
        var usage = current(provider)
        usage.inputTokens += input
        usage.outputTokens += output
        store(usage, for: provider)
    }

    static func reset(_ provider: AIProviderID) {
        UserDefaults.standard.removeObject(forKey: key(provider))
    }

    /// Monthly token cap; 0 means no limit.
    static func limit(_ provider: AIProviderID) -> Int {
        UserDefaults.standard.integer(forKey: PrefKey.tokenLimit(provider))
    }

    static func isOverLimit(_ provider: AIProviderID) -> Bool {
        let cap = limit(provider)
        return cap > 0 && current(provider).totalTokens >= cap
    }
}
