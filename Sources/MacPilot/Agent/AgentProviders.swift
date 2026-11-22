import Foundation

/// A tool call, the same for every provider.
struct AgentToolCall: Equatable {
    var id: String
    var name: String
    /// Parsed JSON object; nil when the model sent arguments that aren't valid JSON.
    var arguments: [String: Any]?
    var rawArguments: String

    static func == (lhs: AgentToolCall, rhs: AgentToolCall) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.rawArguments == rhs.rawArguments
    }
}

/// Provider-neutral conversation the loop keeps in memory (never persisted: it may hold file contents).
enum AgentMessage {
    case user(String)
    /// `raw` is the provider's own assistant message, echoed back unchanged (e.g. Claude's thinking blocks).
    case assistant(text: String, calls: [AgentToolCall], raw: Any?)
    case toolResults([(call: AgentToolCall, result: AgentToolResult)])
}

struct AgentModelResponse {
    var text: String
    var calls: [AgentToolCall]
    var inputTokens: Int
    var outputTokens: Int
    /// Normalized stop: finished, wants tools, cut off, or refused.
    var stop: Stop
    var raw: Any?

    enum Stop: Equatable { case done, toolUse, maxTokens, refusal }
}

struct AgentCapabilities: Equatable {
    var toolCalling: Bool
    var parallelToolCalls: Bool
    var isLocal: Bool
    /// Can look at screenshots (needed for coordinate clicks).
    var vision = false
}

/// Provider errors, normalized so the loop can explain them the same way.
enum AgentProviderError: LocalizedError {
    case noToolSupport(String)
    case badResponse(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .noToolSupport(let model): return "\(model) doesn't support tool calling. Choose a model with tools in Settings → Agent."
        case .badResponse(let detail): return "The provider sent a response the agent couldn't read (\(detail))."
        case .refused: return "The model declined this request."
        }
    }
}

/// One adapter per provider: request encoding, tool-call normalization and a cost estimate.
protocol AgentModelAdapter {
    var provider: AIProviderID { get }
    var model: String { get }
    var capabilities: AgentCapabilities { get }
    func generate(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) async throws -> AgentModelResponse
    func normalizeToolCalls(_ response: [String: Any]) throws -> AgentModelResponse
    func estimateCost(inputTokens: Int, outputTokens: Int) -> Double
}

enum AgentPricing {
    /// USD per million tokens (input, output). Estimates for the caps; Bedrock uses first-party list prices.
    static func rates(provider: AIProviderID, model: String) -> (input: Double, output: Double) {
        let name = model.lowercased()
        switch provider {
        case .ollama: return (0, 0)
        case .anthropic, .bedrock:
            if name.contains("fable") || name.contains("mythos") { return name.contains("5-2") ? (8, 40) : (10, 50) }
            if name.contains("opus-5-5") { return (4, 20) }
            if name.contains("opus") { return (5, 25) }
            if name.contains("sonnet-5-5") || name.contains("sonnet-5") { return (2, 10) }
            if name.contains("sonnet") { return (3, 15) }
            if name.contains("haiku-5-5") { return (0.10, 0.50) }
            if name.contains("haiku") { return (1, 5) }
            return (5, 25)
        case .openAI:
            if name.contains("mini") { return (0.25, 2) }
            if name.contains("nano") { return (0.05, 0.4) }
            return (1.25, 10)
        }
    }

    static func cost(provider: AIProviderID, model: String, input: Int, output: Int) -> Double {
        let rate = rates(provider: provider, model: model)
        return (Double(input) * rate.input + Double(output) * rate.output) / 1_000_000
    }
}

enum AgentAdapters {
    /// The adapter for exactly the configured provider. There is no fallback to another provider.
    static func make(provider: AIProviderID, model: String) -> any AgentModelAdapter {
        switch provider {
        case .anthropic: return AnthropicAgentAdapter(backend: .anthropic, model: model)
        case .bedrock: return AnthropicAgentAdapter(backend: .bedrock, model: model)
        case .openAI: return OpenAIAgentAdapter(model: model)
        case .ollama: return OllamaAgentAdapter(model: model, baseURL: Prefs.ollamaBaseURL)
        }
    }

    static func parseArguments(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw.trimmingCharacters(in: .whitespaces).isEmpty ? [:] : nil
        }
        return object
    }

    static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func post(_ request: URLRequest, provider: AIProviderID) async throws -> [String: Any] {
        let (data, response) = try await HTTPSupport.session.data(for: request)
        try HTTPSupport.ensureOK(response, data: data, provider: provider)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentProviderError.badResponse("not a JSON object")
        }
        return object
    }
}

// MARK: - Claude (Anthropic API and Amazon Bedrock mantle)

struct AnthropicAgentAdapter: AgentModelAdapter {
    var backend: AnthropicClient.Backend
    var model: String
    var provider: AIProviderID { backend == .bedrock ? .bedrock : .anthropic }
    var capabilities: AgentCapabilities { AgentCapabilities(toolCalling: true, parallelToolCalls: true, isLocal: false, vision: true) }

    func body(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> [String: Any] {
        var wire: [[String: Any]] = []
        for message in messages {
            switch message {
            case .user(let text):
                wire.append(["role": "user", "content": text])
            case let .assistant(text, calls, raw):
                if let raw = raw as? [[String: Any]] {
                    wire.append(["role": "assistant", "content": raw])
                } else {
                    var content: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
                    content += calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.arguments ?? [:]] }
                    wire.append(["role": "assistant", "content": content])
                }
            case .toolResults(let results):
                // All results of one turn go back in a single user message.
                wire.append(["role": "user", "content": results.map { item -> [String: Any] in
                    var content: [[String: Any]] = [["type": "text", "text": item.result.content.isEmpty ? "(empty)" : item.result.content]]
                    if let image = item.result.image {
                        content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]])
                    }
                    return ["type": "tool_result", "tool_use_id": item.call.id, "content": content, "is_error": item.result.isError]
                }])
            }
        }
        // No `fallbacks`: the agent never switches models or providers behind the user's back.
        return ["model": model, "max_tokens": 16_000, "system": system, "messages": wire,
                "tools": tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }]
    }

    func generate(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) async throws -> AgentModelResponse {
        var request = try AnthropicClient(backend: backend).messagesRequest(body: body(system: system, messages: messages, tools: tools), useFallbackBeta: false)
        request.timeoutInterval = 600
        return try normalizeToolCalls(try await AgentAdapters.post(request, provider: provider))
    }

    func normalizeToolCalls(_ response: [String: Any]) throws -> AgentModelResponse {
        guard let content = response["content"] as? [[String: Any]] else { throw AgentProviderError.badResponse("no content") }
        var text = ""
        var calls: [AgentToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text": text += block["text"] as? String ?? ""
            case "tool_use":
                let input = block["input"] as? [String: Any]
                calls.append(AgentToolCall(id: block["id"] as? String ?? UUID().uuidString, name: block["name"] as? String ?? "",
                                           arguments: input, rawArguments: AgentAdapters.jsonString(block["input"] ?? [:])))
            default: break
            }
        }
        let usage = response["usage"] as? [String: Any] ?? [:]
        let stop: AgentModelResponse.Stop
        switch response["stop_reason"] as? String {
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .maxTokens
        case "refusal": stop = .refusal
        default: stop = calls.isEmpty ? .done : .toolUse
        }
        return AgentModelResponse(text: text, calls: calls, inputTokens: usage["input_tokens"] as? Int ?? 0,
                                  outputTokens: usage["output_tokens"] as? Int ?? 0, stop: stop, raw: content)
    }

    func estimateCost(inputTokens: Int, outputTokens: Int) -> Double {
        AgentPricing.cost(provider: provider, model: model, input: inputTokens, output: outputTokens)
    }
}

// MARK: - OpenAI (Chat Completions tool calling)

struct OpenAIAgentAdapter: AgentModelAdapter {
    var model: String
    var provider: AIProviderID { .openAI }
    var capabilities: AgentCapabilities { AgentCapabilities(toolCalling: true, parallelToolCalls: true, isLocal: false, vision: true) }

    func body(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> [String: Any] {
        var wire: [[String: Any]] = [["role": "system", "content": system]]
        for message in messages {
            switch message {
            case .user(let text): wire.append(["role": "user", "content": text])
            case let .assistant(text, calls, _):
                var item: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty {
                    item["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.rawArguments]] }
                }
                wire.append(item)
            case .toolResults(let results):
                for item in results {
                    wire.append(["role": "tool", "tool_call_id": item.call.id, "content": (item.result.isError ? "ERROR: " : "") + item.result.content])
                }
                // Tool messages can't carry images, so screenshots follow as one user message.
                let images = results.compactMap(\.result.image)
                if !images.isEmpty {
                    wire.append(["role": "user", "content": [["type": "text", "text": "Screenshot(s) from the tool results above:"]]
                        + images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]] }])
                }
            }
        }
        return ["model": model, "messages": wire,
                "tools": tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }]
    }

    func generate(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) async throws -> AgentModelResponse {
        guard let key = KeychainStore.read(account: AIProviderID.openAI.rawValue), !key.isEmpty else { throw AIError.missingKey(.openAI) }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(system: system, messages: messages, tools: tools))
        return try normalizeToolCalls(try await AgentAdapters.post(request, provider: .openAI))
    }

    func normalizeToolCalls(_ response: [String: Any]) throws -> AgentModelResponse {
        guard let choice = (response["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            throw AgentProviderError.badResponse("no choices")
        }
        let calls: [AgentToolCall] = (message["tool_calls"] as? [[String: Any]] ?? []).map { call in
            let function = call["function"] as? [String: Any] ?? [:]
            let raw = function["arguments"] as? String ?? "{}"
            return AgentToolCall(id: call["id"] as? String ?? UUID().uuidString, name: function["name"] as? String ?? "",
                                 arguments: AgentAdapters.parseArguments(raw), rawArguments: raw)
        }
        let usage = response["usage"] as? [String: Any] ?? [:]
        let stop: AgentModelResponse.Stop
        switch choice["finish_reason"] as? String {
        case "tool_calls": stop = .toolUse
        case "length": stop = .maxTokens
        case "content_filter": stop = .refusal
        default: stop = calls.isEmpty ? .done : .toolUse
        }
        return AgentModelResponse(text: message["content"] as? String ?? "", calls: calls, inputTokens: usage["prompt_tokens"] as? Int ?? 0,
                                  outputTokens: usage["completion_tokens"] as? Int ?? 0, stop: stop, raw: nil)
    }

    func estimateCost(inputTokens: Int, outputTokens: Int) -> Double {
        AgentPricing.cost(provider: .openAI, model: model, input: inputTokens, output: outputTokens)
    }
}

// MARK: - Ollama (local, /api/chat with tools)

struct OllamaAgentAdapter: AgentModelAdapter {
    var model: String
    var baseURL: URL
    var provider: AIProviderID { .ollama }
    var capabilities: AgentCapabilities { AgentCapabilities(toolCalling: true, parallelToolCalls: false, isLocal: true) }

    func body(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> [String: Any] {
        var wire: [[String: Any]] = [["role": "system", "content": system]]
        for message in messages {
            switch message {
            case .user(let text): wire.append(["role": "user", "content": text])
            case let .assistant(text, calls, _):
                var item: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty { item["tool_calls"] = calls.map { ["function": ["name": $0.name, "arguments": $0.arguments ?? [:]]] } }
                wire.append(item)
            case .toolResults(let results):
                for item in results {
                    wire.append(["role": "tool", "tool_name": item.call.name, "content": (item.result.isError ? "ERROR: " : "") + item.result.content])
                }
            }
        }
        return ["model": model, "stream": false, "messages": wire,
                "tools": tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }]
    }

    func generate(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) async throws -> AgentModelResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(system: system, messages: messages, tools: tools))
        do {
            return try normalizeToolCalls(try await AgentAdapters.post(request, provider: .ollama))
        } catch let AIError.http(_, status, message) where status == 400 && message.localizedCaseInsensitiveContains("does not support tools") {
            throw AgentProviderError.noToolSupport(model)
        }
    }

    func normalizeToolCalls(_ response: [String: Any]) throws -> AgentModelResponse {
        if let error = response["error"] as? String { throw AIError.stream(error) }
        guard let message = response["message"] as? [String: Any] else { throw AgentProviderError.badResponse("no message") }
        let calls: [AgentToolCall] = (message["tool_calls"] as? [[String: Any]] ?? []).enumerated().map { index, call in
            let function = call["function"] as? [String: Any] ?? [:]
            // Arguments arrive as an object (newer servers) or a JSON string (older ones).
            let object = function["arguments"] as? [String: Any] ?? (function["arguments"] as? String).flatMap(AgentAdapters.parseArguments)
            let raw = (function["arguments"] as? String) ?? AgentAdapters.jsonString(function["arguments"] ?? [:])
            return AgentToolCall(id: "ollama-\(index)-\(UUID().uuidString.prefix(8))", name: function["name"] as? String ?? "",
                                 arguments: object, rawArguments: raw)
        }
        return AgentModelResponse(text: message["content"] as? String ?? "", calls: calls,
                                  inputTokens: response["prompt_eval_count"] as? Int ?? 0, outputTokens: response["eval_count"] as? Int ?? 0,
                                  stop: calls.isEmpty ? (response["done_reason"] as? String == "length" ? .maxTokens : .done) : .toolUse, raw: nil)
    }

    func estimateCost(inputTokens: Int, outputTokens: Int) -> Double { 0 }
}
