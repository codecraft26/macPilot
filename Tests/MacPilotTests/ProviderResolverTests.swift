import SwiftData
import XCTest
@testable import MacPilot

final class ProviderResolverTests: XCTestCase {
    private typealias Availability = ProviderResolver.Availability
    private let onlyBedrock = Availability(bedrock: true)

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "resolver-\(UUID().uuidString)")! }

    // MARK: Order

    func testResolverOrder() {
        let all = Availability(anthropic: true, openAI: true, bedrock: true, ollama: true)
        XCTAssertEqual(ProviderResolver.firstConfigured(preferred: .openAI, all), .openAI, "the user's default comes first")
        XCTAssertEqual(ProviderResolver.firstConfigured(preferred: nil, all), .bedrock, "then Bedrock")
        XCTAssertEqual(ProviderResolver.firstConfigured(preferred: .anthropic, Availability(openAI: true, bedrock: true)), .bedrock,
                       "a default without credentials is skipped")
        XCTAssertEqual(ProviderResolver.firstConfigured(preferred: nil, Availability(anthropic: true, openAI: true)), .anthropic)
        XCTAssertEqual(ProviderResolver.firstConfigured(preferred: nil, Availability(openAI: true, ollama: true)), .openAI)
        XCTAssertEqual(ProviderResolver.firstConfigured(preferred: nil, Availability(ollama: true)), .ollama)
        XCTAssertNil(ProviderResolver.firstConfigured(preferred: .anthropic, Availability()))
    }

    func testDecisions() {
        XCTAssertEqual(ProviderResolver.resolve(explicit: nil, preferred: .anthropic, onlyBedrock), .use(.bedrock))
        XCTAssertEqual(ProviderResolver.resolve(explicit: .bedrock, preferred: .anthropic, onlyBedrock), .use(.bedrock))
        XCTAssertEqual(ProviderResolver.resolve(explicit: .anthropic, preferred: .anthropic, onlyBedrock), .offer(chosen: .anthropic, alternative: .bedrock),
                       "an explicit pick is never switched silently")
        XCTAssertEqual(ProviderResolver.resolve(explicit: .anthropic, preferred: nil, Availability()), .setUp(.anthropic))
        XCTAssertEqual(ProviderResolver.resolve(explicit: nil, preferred: .anthropic, Availability()), .setUp(.anthropic))
        XCTAssertEqual(ProviderResolver.offerText(chosen: .bedrock, alternative: .anthropic), "Bedrock isn't set up — use Claude (Anthropic API) instead?")
    }

    func testLabelsSayWhichClaude() {
        XCTAssertEqual(AIProviderID.bedrock.displayName, "Claude (Bedrock)")
        XCTAssertEqual(AIProviderID.anthropic.displayName, "Claude (Anthropic API)")
        XCTAssertEqual(AIError.missingKey(.anthropic).errorDescription, "No Anthropic API key yet. Add one in Settings → Providers.")
    }

    // MARK: Agent settings

    func testOnlyBedrockConfiguredAgentUsesBedrock() {
        let store = defaults()
        // Fresh install: nothing saved.
        var settings = AgentSettings.load(store, availability: onlyBedrock, preferred: .anthropic, modelFor: { $0 == .bedrock ? "anthropic.claude-sonnet-5-5" : $0.defaultModel })
        XCTAssertEqual(settings.provider, .bedrock)
        XCTAssertEqual(settings.model, "anthropic.claude-sonnet-5-5", "the Bedrock model setting, not an Anthropic model ID")
        XCTAssertNil(settings.providerOffer, "no key prompt and no offer")
        // Settings saved before (e.g. a workspace was added) still follow the credentials when the provider wasn't picked.
        var old = AgentSettings()
        old.workspaceRoots = ["/tmp"]
        old.save(store)
        settings = AgentSettings.load(store, availability: onlyBedrock, preferred: .anthropic)
        XCTAssertEqual(settings.provider, .bedrock)
        XCTAssertEqual(settings.model, AIProviderID.bedrock.defaultModel, "the saved Anthropic model doesn't carry over")
        XCTAssertEqual(settings.workspaceRoots, ["/tmp"])
    }

    func testExplicitPickWithoutKeyIsOfferedNotSwitched() {
        let store = defaults()
        var picked = AgentSettings()
        picked.provider = .anthropic
        picked.model = "claude-sonnet-5-5"
        picked.providerExplicit = true
        picked.save(store)
        let settings = AgentSettings.load(store, availability: onlyBedrock, preferred: .anthropic)
        XCTAssertEqual(settings.provider, .anthropic, "kept")
        XCTAssertEqual(settings.model, "claude-sonnet-5-5")
        XCTAssertEqual(settings.providerOffer, .bedrock, "Bedrock is offered")
        // With the key it simply runs.
        XCTAssertNil(AgentSettings.load(store, availability: Availability(anthropic: true, bedrock: true), preferred: .anthropic).providerOffer)
    }

    func testMigrationSwitchesOnceAndRespectsExplicitPicks() {
        let store = defaults()
        store.set("anthropic", forKey: "agent.provider")
        store.set("claude-opus-5-5", forKey: "agent.model")
        XCTAssertEqual(AgentSettings.migrateProvider(store, availability: onlyBedrock, preferred: .anthropic, modelFor: { _ in "anthropic.claude-opus-5-5" }), .bedrock)
        XCTAssertEqual(store.string(forKey: "agent.provider"), "bedrock")
        XCTAssertEqual(store.string(forKey: "agent.model"), "anthropic.claude-opus-5-5")
        store.set("anthropic", forKey: "agent.provider")
        XCTAssertNil(AgentSettings.migrateProvider(store, availability: onlyBedrock, preferred: .anthropic), "only once")

        let explicit = defaults()
        explicit.set("anthropic", forKey: "agent.provider")
        explicit.set(true, forKey: "agent.providerExplicit")
        XCTAssertNil(AgentSettings.migrateProvider(explicit, availability: onlyBedrock, preferred: .anthropic), "an explicit pick isn't migrated")
        XCTAssertEqual(explicit.string(forKey: "agent.provider"), "anthropic")

        let working = defaults()
        working.set("anthropic", forKey: "agent.provider")
        XCTAssertNil(AgentSettings.migrateProvider(working, availability: Availability(anthropic: true, bedrock: true), preferred: .anthropic),
                     "a provider that works is left alone")
    }

    // MARK: Engine

    @MainActor
    func testAgentRunsOnBedrockAndOffersInsteadOfAskingForAKey() async throws {
        let container = try ModelContainer(for: AgentTask.self, AgentToolAction.self, AgentApproval.self, AgentEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = AgentEngine(context: container.mainContext, defaults: UserDefaults(suiteName: "resolver-engine-\(UUID().uuidString)")!)
        engine.recordUsage = { _, _, _ in }
        var used: [AIProviderID] = []
        engine.adapterFactory = { provider, _ in used.append(provider); return ScriptedAdapter(provider: provider, turns: []) }
        let store = defaults()
        engine.settingsProvider = { AgentSettings.load(store, availability: Availability(bedrock: true), preferred: .anthropic) }

        let task = engine.submit("list files in workspace")
        await engine.waitUntilIdle()
        XCTAssertEqual(task.provider, .bedrock)
        XCTAssertEqual(used, [.bedrock])
        XCTAssertEqual(task.state, .done)

        // Explicitly picked Anthropic without a key: the task explains and offers Bedrock, no adapter call.
        var picked = AgentSettings()
        picked.provider = .anthropic
        picked.providerExplicit = true
        picked.save(store)
        let second = engine.submit("list files in workspace")
        await engine.waitUntilIdle()
        XCTAssertEqual(used.count, 1, "nothing was sent to a provider without credentials")
        XCTAssertEqual(second.state, .failed)
        XCTAssertTrue(second.errorMessage?.contains("Anthropic isn't set up — use Claude (Bedrock) instead?") == true, second.errorMessage ?? "")
        withExtendedLifetime(container) {}
    }
}
