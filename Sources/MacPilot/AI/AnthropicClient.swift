import Foundation

/// Claude through the Messages API (raw HTTP; there is no official Swift SDK), either on the
/// Anthropic API or on Claude in Amazon Bedrock (`bedrock-mantle`), which serves the same request
/// body and SSE stream at a different URL with AWS authentication.
struct AnthropicClient: ChatProvider {
    enum Backend {
        case anthropic
        case bedrock
    }

    var backend: Backend = .anthropic

    private let anthropicBaseURL = URL(string: "https://api.anthropic.com/v1")!

    /// Models that accept the server-side refusal fallback. Bedrock does not support it at all.
    private static let fallbackModels: Set<String> = [
        "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1"
    ]

    private var providerID: AIProviderID { backend == .bedrock ? .bedrock : .anthropic }

    // MARK: Requests

    private func anthropicKey() throws -> String {
        guard let key = KeychainStore.read(account: AIProviderID.anthropic.rawValue), !key.isEmpty else {
            throw AIError.missingKey(.anthropic)
        }
        return key
    }

    /// Builds a POST to the Messages endpoint with authentication applied. `body` must be final.
    private func messagesRequest(body: [String: Any], useFallbackBeta: Bool) throws -> URLRequest {
        let data = try JSONSerialization.data(withJSONObject: body)
        switch backend {
        case .anthropic:
            var request = URLRequest(url: anthropicBaseURL.appendingPathComponent("messages"))
            request.httpMethod = "POST"
            request.setValue(try anthropicKey(), forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if useFallbackBeta {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
            request.httpBody = data
            return request
        case .bedrock:
            let url = BedrockConfig.messagesURL
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let signedHeaders = ["content-type": "application/json", "anthropic-version": "2026-10-21"]
            for (name, value) in signedHeaders { request.setValue(value, forHTTPHeaderField: name) }
            let auth = try BedrockConfig.authHeaders(method: "POST", url: url, headers: signedHeaders, body: data)
            for (name, value) in auth { request.setValue(value, forHTTPHeaderField: name) }
            request.httpBody = data
            return request
        }
    }

    func stream(model: String, system: String?, turns: [ChatTurn]) -> AsyncThrowingStream<StreamChunk, Error> {
        let backend = backend
        let provider = providerID
        return HTTPSupport.makeStream { continuation in
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 32_000,
                "stream": true,
                "messages": turns
                    .filter { !$0.content.isEmpty }
                    .map { ["role": $0.role.rawValue, "content": $0.content] }
            ]
            if let system, !system.isEmpty {
                body["system"] = system
            }
            // If a safety classifier declines, the API retries on a suitable model instead of failing.
            // Not available on Bedrock, so it is never sent there.
            let useFallback = backend == .anthropic && Self.fallbackModels.contains(model)
            if useFallback {
                body["fallbacks"] = "default"
            }
            var request = try messagesRequest(body: body, useFallbackBeta: useFallback)
            request.timeoutInterval = 600

            let (bytes, response) = try await HTTPSupport.session.bytes(for: request)
            try await HTTPSupport.ensureOK(response, bytes: bytes, provider: provider)
            try await Self.parseStream(bytes.lines, into: continuation)
        }
    }

    /// Anthropic Messages SSE events → chunks. Shared by both backends.
    static func parseStream<Lines: AsyncSequence>(
        _ lines: Lines,
        into continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws where Lines.Element == String {
        var inputTokens = 0
        for try await line in lines {
            try Task.checkCancellation()
            guard let payload = SSE.payload(fromLine: line), let event = SSE.json(payload),
                  let type = event["type"] as? String else { continue }
            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    continuation.yield(.text(text))
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let stopReason = delta["stop_reason"] as? String {
                    switch stopReason {
                    case "refusal": continuation.yield(.notice("Claude declined to answer this request."))
                    case "max_tokens": continuation.yield(.notice("The reply hit the maximum length and was cut off."))
                    default: break
                    }
                }
                if let usage = event["usage"] as? [String: Any] {
                    let output = usage["output_tokens"] as? Int ?? 0
                    continuation.yield(.usage(input: inputTokens, output: output))
                }
            case "error":
                let error = event["error"] as? [String: Any]
                throw AIError.stream(error?["message"] as? String ?? "Stream error")
            default:
                continue
            }
        }
    }

    func listModels() async throws -> [String] {
        switch backend {
        case .anthropic:
            let key = try anthropicKey()
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let (data, response) = try await HTTPSupport.session.data(for: request)
            try HTTPSupport.ensureOK(response, data: data, provider: .anthropic)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let items = object?["data"] as? [[String: Any]] ?? []
            return items.compactMap { $0["id"] as? String }
        case .bedrock:
            // Bedrock has no Models endpoint: check access with a tiny request to the configured model.
            let model = Prefs.model(for: .bedrock)
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 16,
                "messages": [["role": "user", "content": "ping"]]
            ]
            var request = try messagesRequest(body: body, useFallbackBeta: false)
            request.timeoutInterval = 60
            let (data, response) = try await HTTPSupport.session.data(for: request)
            try HTTPSupport.ensureOK(response, data: data, provider: .bedrock)
            return AIProviderID.bedrock.suggestedModels
        }
    }
}
