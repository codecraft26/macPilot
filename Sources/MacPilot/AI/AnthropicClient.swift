import Foundation

/// Claude via the Anthropic Messages API (raw HTTP; there is no official Swift SDK).
struct AnthropicClient: ChatProvider {
    private let baseURL = URL(string: "https://api.anthropic.com/v1")!
    private let apiVersion = "2023-06-01"

    /// Models that accept the server-side refusal fallback. Other models get a plain request.
    private static let fallbackModels: Set<String> = [
        "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1"
    ]

    private func apiKey() throws -> String {
        guard let key = KeychainStore.read(account: AIProviderID.anthropic.rawValue), !key.isEmpty else {
            throw AIError.missingKey(.anthropic)
        }
        return key
    }

    private func makeRequest(path: String, key: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    func stream(model: String, system: String?, turns: [ChatTurn]) -> AsyncThrowingStream<StreamChunk, Error> {
        HTTPSupport.makeStream { continuation in
            let key = try apiKey()
            var request = makeRequest(path: "messages", key: key)
            request.httpMethod = "POST"
            request.timeoutInterval = 600

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
            if Self.fallbackModels.contains(model) {
                // If a safety classifier declines, the API retries on a suitable model instead of failing.
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await HTTPSupport.session.bytes(for: request)
            try await HTTPSupport.ensureOK(response, bytes: bytes, provider: .anthropic)

            var inputTokens = 0
            for try await line in bytes.lines {
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
    }

    func listModels() async throws -> [String] {
        let key = try apiKey()
        var request = makeRequest(path: "models", key: key)
        request.url = URL(string: "https://api.anthropic.com/v1/models?limit=100")
        let (data, response) = try await HTTPSupport.session.data(for: request)
        try HTTPSupport.ensureOK(response, data: data, provider: .anthropic)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = object?["data"] as? [[String: Any]] ?? []
        return items.compactMap { $0["id"] as? String }
    }
}
