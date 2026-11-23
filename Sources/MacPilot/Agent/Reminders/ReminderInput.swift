import Foundation

/// Turns typed or spoken words into a reminder draft: rules first (no model, works in local-only mode),
/// then the agent's model for anything else. Only the words are sent — never location or Wi-Fi.
@MainActor
enum ReminderInput {
    static func looksLikeReminder(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("remind me") || lower.hasPrefix("/remind") || (lower.contains("remind me") && lower.contains("when "))
    }

    enum Source: Equatable { case rules, model }

    static func parse(_ text: String) async -> ReminderDraft? {
        await parse(text, settings: AgentSettings.load(), adapterFactory: { AgentAdapters.make(provider: $0, model: $1) }).draft
    }

    static func parse(_ text: String, settings: AgentSettings, now: Date = Date(),
                      adapterFactory: (AIProviderID, String) -> any AgentModelAdapter) async -> (draft: ReminderDraft?, source: Source?) {
        if let draft = ReminderParser.parse(text, now: now) { return (draft, .rules) }
        // Local-only mode (or a cloud provider that's blocked): rules only.
        if settings.localOnly { return (nil, nil) }
        guard (try? AgentPolicy.checkProvider(settings.provider, settings: settings)) != nil else { return (nil, nil) }
        let adapter = adapterFactory(settings.provider, settings.model)
        guard let response = try? await adapter.generate(system: ReminderLLMParser.prompt(now: now, timeZone: .current),
                                                         messages: [.user(String(text.prefix(500)))], tools: []) else { return (nil, nil) }
        UsageTracker.record(settings.provider, input: response.inputTokens, output: response.outputTokens)
        return (ReminderLLMParser.decode(response.text, now: now), .model)
    }
}
