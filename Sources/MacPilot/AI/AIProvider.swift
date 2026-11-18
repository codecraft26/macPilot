import Foundation

/// AI chat providers. Transcription providers are configured separately (PRD section 5).
enum AIProviderID: String, CaseIterable, Identifiable, Codable {
    case anthropic
    case openAI = "openai"
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI"
        case .ollama: return "Ollama (local)"
        }
    }

    var shortName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        case .ollama: return "Ollama"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-5-5"
        case .openAI: return "gpt-5"
        case .ollama: return "llama3.2"
        }
    }

    /// Shown until the user runs "Test connection", which fetches the live list.
    var suggestedModels: [String] {
        switch self {
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"]
        case .openAI: return ["gpt-5", "gpt-5-mini"]
        case .ollama: return ["llama3.2"]
        }
    }

    var requiresAPIKey: Bool { self != .ollama }

    /// True when user data leaves the Mac for a third-party service.
    var isExternal: Bool { self != .ollama }

    var dataNotice: String {
        switch self {
        case .anthropic: return "Prompts, attachments and history are sent to Anthropic's API."
        case .openAI: return "Prompts, attachments and history are sent to OpenAI's API."
        case .ollama: return "Runs on your Ollama server. Nothing leaves this Mac when it is on localhost."
        }
    }
}

struct ChatTurn: Equatable {
    var role: ChatRole
    var content: String
}

enum StreamChunk: Equatable {
    case text(String)
    case usage(input: Int, output: Int)
    case notice(String)
}

protocol ChatProvider {
    func stream(model: String, system: String?, turns: [ChatTurn]) -> AsyncThrowingStream<StreamChunk, Error>
    func listModels() async throws -> [String]
}

enum AIError: LocalizedError {
    case missingKey(AIProviderID)
    case providerDisabled(AIProviderID)
    case limitReached(AIProviderID)
    case http(provider: AIProviderID, status: Int, message: String)
    case invalidResponse
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            return "No \(provider.shortName) API key yet. Add one in Settings → Providers."
        case .providerDisabled(let provider):
            return "\(provider.displayName) is turned off in Settings → Providers."
        case .limitReached(let provider):
            return "The monthly token limit for \(provider.shortName) has been reached. Change it in Settings → Usage."
        case let .http(provider, status, message):
            return "\(provider.shortName) returned \(status): \(Redactor.redact(message))"
        case .invalidResponse:
            return "The provider sent a response MacPilot could not read."
        case .stream(let message):
            return Redactor.redact(message)
        }
    }

    static func describe(_ error: Error) -> String {
        if let aiError = error as? AIError, let text = aiError.errorDescription {
            return text
        }
        return Redactor.redact(error.localizedDescription)
    }
}

/// Removes anything that looks like an API key before text is shown or logged.
enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        "sk-ant-[A-Za-z0-9_\\-\\*]{4,}",
        "sk-[A-Za-z0-9_\\-\\*]{6,}"
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redact(_ text: String) -> String {
        var result = text
        for regex in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted key]")
        }
        return result
    }
}

/// Server-Sent Events helpers shared by the streaming clients.
enum SSE {
    /// Returns the payload of a `data:` line, or nil for any other line.
    static func payload(fromLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        var rest = line.dropFirst(5)
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum HTTPSupport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: configuration)
    }()

    /// Throws `AIError.http` with the provider's error message when the status is not 2xx.
    static func ensureOK(_ response: URLResponse, bytes: URLSession.AsyncBytes, provider: AIProviderID) async throws {
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 32_768 { break }
            }
            throw AIError.http(provider: provider, status: http.statusCode, message: errorMessage(from: data))
        }
    }

    static func ensureOK(_ response: URLResponse, data: Data, provider: AIProviderID) throws {
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(provider: provider, status: http.statusCode, message: errorMessage(from: data))
        }
    }

    static func errorMessage(from data: Data) -> String {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["error"] as? String {
                return message
            }
        }
        let text = String(data: data.prefix(500), encoding: .utf8) ?? ""
        return text.isEmpty ? "Unknown error" : text
    }

    /// Wraps an async producer in an AsyncThrowingStream that cancels the work when the consumer stops.
    static func makeStream(
        _ body: @escaping (AsyncThrowingStream<StreamChunk, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
