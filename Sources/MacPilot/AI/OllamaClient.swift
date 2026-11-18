import Foundation

/// Local models through an Ollama server (newline-delimited JSON streaming).
struct OllamaClient: ChatProvider {
    let baseURL: URL

    func stream(model: String, system: String?, turns: [ChatTurn]) -> AsyncThrowingStream<StreamChunk, Error> {
        HTTPSupport.makeStream { continuation in
            var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var messages: [[String: String]] = []
            if let system, !system.isEmpty {
                messages.append(["role": "system", "content": system])
            }
            messages += turns.map { ["role": $0.role.rawValue, "content": $0.content] }
            let body: [String: Any] = ["model": model, "stream": true, "messages": messages]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await HTTPSupport.session.bytes(for: request)
            try await HTTPSupport.ensureOK(response, bytes: bytes, provider: .ollama)

            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let event = SSE.json(line) else { continue }
                if let error = event["error"] as? String {
                    throw AIError.stream(error)
                }
                if let message = event["message"] as? [String: Any], let text = message["content"] as? String, !text.isEmpty {
                    continuation.yield(.text(text))
                }
                if event["done"] as? Bool == true {
                    continuation.yield(.usage(
                        input: event["prompt_eval_count"] as? Int ?? 0,
                        output: event["eval_count"] as? Int ?? 0
                    ))
                    break
                }
            }
        }
    }

    func listModels() async throws -> [String] {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        let (data, response) = try await HTTPSupport.session.data(for: request)
        try HTTPSupport.ensureOK(response, data: data, provider: .ollama)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let models = object?["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
