import Foundation

/// AI actions on a clipboard item, run with the analysis provider.
enum ClipAIAction: String, CaseIterable, Identifiable {
    case explain = "Explain", summarize = "Summarize", fixGrammar = "Fix grammar", translate = "Translate", formatJSON = "Format JSON"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .explain: return "questionmark.bubble"
        case .summarize: return "text.badge.checkmark"
        case .fixGrammar: return "textformat.abc"
        case .translate: return "globe"
        case .formatJSON: return "curlybraces"
        }
    }

    var isLocal: Bool { self == .formatJSON }

    func instruction(language: String) -> String {
        switch self {
        case .explain: return "Explain what this is and what it does, briefly and clearly. If it is code or an error, explain it for a developer."
        case .summarize: return "Summarize this in a few bullet points."
        case .fixGrammar: return "Fix spelling, grammar and punctuation. Keep the meaning, tone and formatting. Reply with the corrected text only."
        case .translate: return "Translate this into \(language). Reply with the translation only."
        case .formatJSON: return ""
        }
    }

    func run(on text: String, language: String = "English") async throws -> String {
        if self == .formatJSON {
            return try JSONTools.format(text, sortKeys: false)
        }
        let reply = try await AIRouter.complete(
            provider: Prefs.analysisProvider,
            system: "You help with text the user copied. " + instruction(language: language),
            prompt: String(text.prefix(100_000))
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Fuzzy matching for the clipboard panel and the command launcher.
enum FuzzyMatcher {
    /// Higher is better; nil when not every query character appears in order.
    static func score(_ query: String, in candidate: String) -> Int? {
        let query = query.lowercased().filter { !$0.isWhitespace }
        guard !query.isEmpty else { return 0 }
        let text = Array(candidate.lowercased())
        let needle = Array(query)
        // Contiguous substring matches beat scattered ones.
        if let range = candidate.lowercased().range(of: query) {
            let offset = candidate.lowercased().distance(from: candidate.lowercased().startIndex, to: range.lowerBound)
            let atWordStart = offset == 0 || !(text[offset - 1].isLetter || text[offset - 1].isNumber)
            return 1000 - min(offset, 200) + (offset == 0 ? 300 : 0) + (atWordStart ? 150 : 0) - min(text.count, 300) / 10
        }
        var score = 0
        var index = 0
        var previous = -2
        for character in needle {
            var found = false
            while index < text.count {
                if text[index] == character {
                    let atWordStart = index == 0 || !(text[index - 1].isLetter || text[index - 1].isNumber)
                    score += 10
                    if index == previous + 1 { score += 15 }
                    if atWordStart { score += 25 }
                    previous = index
                    index += 1
                    found = true
                    break
                }
                index += 1
            }
            if !found { return nil }
        }
        return score - min(text.count, 300) / 10
    }

    /// Items whose text matches, best first (stable for ties).
    static func rank<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.enumerated()
            .compactMap { index, item in score(trimmed, in: text(item)).map { (index, item, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }
}

enum JSONTools {
    enum JSONError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            }
        }
    }

    static func parse(_ text: String) throws -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else { throw JSONError.invalid("Nothing to format.") }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch let error as NSError {
            let detail = (error.userInfo["NSDebugDescription"] as? String) ?? error.localizedDescription
            throw JSONError.invalid("Invalid JSON: \(detail)")
        }
    }

    static func format(_ text: String, sortKeys: Bool) throws -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]
        if sortKeys { options.insert(.sortedKeys) }
        let data = try JSONSerialization.data(withJSONObject: try parse(text), options: options)
        return String(decoding: data, as: UTF8.self)
    }

    static func minify(_ text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: try parse(text), options: [.withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
}
