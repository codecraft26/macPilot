import Foundation

/// OpenAI chat via the Chat Completions streaming API.
struct OpenAIClient: ChatProvider {
    private let baseURL = URL(string: "https://api.openai.com/v1")!

    private func apiKey() throws -> String {
        guard let key = KeychainStore.read(account: AIProviderID.openAI.rawValue), !key.isEmpty else {
            throw AIError.missingKey(.openAI)
        }
        return key
    }

    private func makeRequest(path: String, key: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func stream(model: String, system: String?, turns: [ChatTurn]) -> AsyncThrowingStream<StreamChunk, Error> {
        HTTPSupport.makeStream { continuation in
            let key = try apiKey()
            var request = makeRequest(path: "chat/completions", key: key)
            request.httpMethod = "POST"
            request.timeoutInterval = 600

            var messages: [[String: String]] = []
            if let system, !system.isEmpty {
                messages.append(["role": "system", "content": system])
            }
            messages += turns.map { ["role": $0.role.rawValue, "content": $0.content] }

            let body: [String: Any] = [
                "model": model,
                "stream": true,
                "stream_options": ["include_usage": true],
                "messages": messages
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await HTTPSupport.session.bytes(for: request)
            try await HTTPSupport.ensureOK(response, bytes: bytes, provider: .openAI)

            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let payload = SSE.payload(fromLine: line) else { continue }
                if payload == "[DONE]" { break }
                guard let event = SSE.json(payload) else { continue }

                if let error = event["error"] as? [String: Any] {
                    throw AIError.stream(error["message"] as? String ?? "Stream error")
                }
                if let choices = event["choices"] as? [[String: Any]], let first = choices.first {
                    if let delta = first["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
                        continuation.yield(.text(text))
                    }
                    if first["finish_reason"] as? String == "length" {
                        continuation.yield(.notice("The reply hit the maximum length and was cut off."))
                    }
                }
                if let usage = event["usage"] as? [String: Any] {
                    continuation.yield(.usage(
                        input: usage["prompt_tokens"] as? Int ?? 0,
                        output: usage["completion_tokens"] as? Int ?? 0
                    ))
                }
            }
        }
    }

    func listModels() async throws -> [String] {
        let key = try apiKey()
        let request = makeRequest(path: "models", key: key)
        let (data, response) = try await HTTPSupport.session.data(for: request)
        try HTTPSupport.ensureOK(response, data: data, provider: .openAI)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = object?["data"] as? [[String: Any]] ?? []
        let chatPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt"]
        return items
            .compactMap { $0["id"] as? String }
            .filter { id in chatPrefixes.contains { id.hasPrefix($0) } }
            .filter { !$0.contains("transcribe") && !$0.contains("tts") && !$0.contains("audio") && !$0.contains("realtime") }
            .sorted()
    }
}
