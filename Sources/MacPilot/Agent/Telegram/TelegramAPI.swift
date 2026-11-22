import Foundation
import Security

/// The Bot API calls MacPilot makes. Real traffic goes through `TelegramHTTPTransport`; tests use a mock.
protocol TelegramTransport: AnyObject {
    /// Calls a Bot API method and returns its `result`.
    func call(_ method: String, _ params: [String: Any]) async throws -> Any
    func sendPhoto(chatID: Int64, jpeg: Data, caption: String) async throws
}

enum TelegramError: LocalizedError, Equatable {
    case noToken
    case api(code: Int, description: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noToken: return "No Telegram bot token yet. Paste it in Settings → Agent → Telegram."
        case let .api(code, description): return AgentRedactor.redact("Telegram error \(code): \(description)")
        case .badResponse: return "Telegram sent a response MacPilot couldn't read."
        }
    }
}

/// Bot API over HTTPS with long polling (no inbound port). The token stays in this object and the Keychain;
/// it's never logged, stored in the database or put in error messages.
final class TelegramHTTPTransport: TelegramTransport {
    static let keychainAccount = "telegram.botToken"
    private let token: String
    private let session: URLSession

    init(token: String) {
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    static func fromKeychain() -> TelegramHTTPTransport? {
        guard let token = KeychainStore.read(account: keychainAccount), !token.isEmpty else { return nil }
        return TelegramHTTPTransport(token: token)
    }

    /// Bot tokens look like 123456789:AA… (digits, colon, 30+ URL-safe characters).
    static func looksLikeToken(_ text: String) -> Bool {
        text.range(of: #"^[0-9]{5,15}:[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil
    }

    private func url(_ method: String) -> URL {
        URL(string: "https://api.telegram.org/bot\(token)/\(method)")!
    }

    func call(_ method: String, _ params: [String: Any]) async throws -> Any {
        var request = URLRequest(url: url(method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        if let timeout = params["timeout"] as? Int { request.timeoutInterval = TimeInterval(timeout + 15) }
        return try await perform(request)
    }

    func sendPhoto(chatID: Int64, jpeg: Data, caption: String) async throws {
        let boundary = "macpilot-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("chat_id", String(chatID))
        field("caption", String(caption.prefix(1_000)))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"screen.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url("sendPhoto"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Any {
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            // URL errors can include the request URL, which contains the token.
            throw TelegramError.api(code: (error as NSError).code, description: AgentRedactor.redact(error.localizedDescription))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TelegramError.badResponse }
        guard object["ok"] as? Bool == true, let result = object["result"] else {
            throw TelegramError.api(code: object["error_code"] as? Int ?? 0, description: object["description"] as? String ?? "unknown")
        }
        return result
    }
}

/// One incoming update, reduced to what MacPilot uses.
struct TelegramIncoming: Equatable {
    enum Kind: Equatable {
        case message(text: String, messageID: Int)
        case callback(id: String, data: String, messageID: Int)
    }

    var updateID: Int
    var userID: Int64
    var chatID: Int64
    var chatType: String
    var isBot: Bool
    var name: String
    var kind: Kind

    /// Parses a Bot API update; ignores anything that isn't a text message or a button press.
    static func parse(_ update: [String: Any]) -> TelegramIncoming? {
        guard let updateID = update["update_id"] as? Int else { return nil }
        func person(_ from: [String: Any]?) -> (Int64, Bool, String)? {
            guard let from, let id = (from["id"] as? NSNumber)?.int64Value else { return nil }
            let name = [from["first_name"] as? String, from["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
            return (id, from["is_bot"] as? Bool ?? false, name)
        }
        if let message = update["message"] as? [String: Any], let text = message["text"] as? String,
           let chat = message["chat"] as? [String: Any], let chatID = (chat["id"] as? NSNumber)?.int64Value,
           let (userID, isBot, name) = person(message["from"] as? [String: Any]) {
            return TelegramIncoming(updateID: updateID, userID: userID, chatID: chatID, chatType: chat["type"] as? String ?? "",
                                    isBot: isBot, name: name, kind: .message(text: text, messageID: message["message_id"] as? Int ?? 0))
        }
        if let callback = update["callback_query"] as? [String: Any], let id = callback["id"] as? String,
           let (userID, isBot, name) = person(callback["from"] as? [String: Any]) {
            let message = callback["message"] as? [String: Any]
            let chat = message?["chat"] as? [String: Any]
            return TelegramIncoming(updateID: updateID, userID: userID, chatID: (chat?["id"] as? NSNumber)?.int64Value ?? 0,
                                    chatType: chat?["type"] as? String ?? "", isBot: isBot, name: name,
                                    kind: .callback(id: id, data: callback["data"] as? String ?? "", messageID: message?["message_id"] as? Int ?? 0))
        }
        return nil
    }
}

enum TelegramRandom {
    /// Characters that can't be confused (no 0/O, 1/I/L).
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    static func string(length: Int, alphabet: [Character] = TelegramRandom.alphabet) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// Compares without leaking where the first difference is.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// One-time pairing codes and the list of paired Telegram users (numeric IDs only, never usernames).
struct TelegramPairing {
    struct PairedUser: Codable, Equatable, Identifiable {
        var userID: Int64
        var chatID: Int64
        var name: String
        var pairedAt: Date
        var id: Int64 { userID }
    }

    enum Outcome: Equatable {
        case paired(PairedUser)
        case rejected(String)
    }

    static let codeLifetime: TimeInterval = 5 * 60
    static let maxAttempts = 5

    private(set) var users: [PairedUser]
    private(set) var code: String?
    private(set) var codeExpiresAt: Date?
    private var failedAttempts = 0

    init(users: [PairedUser] = []) { self.users = users }

    /// A fresh 8-character code valid for 5 minutes; any older code stops working.
    mutating func newCode(now: Date = Date()) -> String {
        let fresh = TelegramRandom.string(length: 8)
        code = fresh
        codeExpiresAt = now.addingTimeInterval(Self.codeLifetime)
        failedAttempts = 0
        return fresh
    }

    mutating func cancelCode() {
        code = nil
        codeExpiresAt = nil
    }

    func isPaired(userID: Int64, chatID: Int64) -> Bool {
        users.contains { $0.userID == userID && $0.chatID == chatID }
    }

    /// /pair <code>: private chat only, unexpired, used once; five wrong guesses burn the code.
    mutating func redeem(_ attempt: String, userID: Int64, chatID: Int64, chatType: String, isBot: Bool, name: String, now: Date = Date()) -> Outcome {
        guard chatType == "private", chatID == userID else { return .rejected("Pairing only works in a private chat with the bot.") }
        guard !isBot else { return .rejected("Bots can't pair.") }
        guard let code, let expires = codeExpiresAt else { return .rejected("There's no active pairing code. Create one in MacPilot → Settings → Agent → Telegram.") }
        guard now < expires else {
            cancelCode()
            return .rejected("That code expired. Create a new one on the Mac.")
        }
        let cleaned = attempt.trimmingCharacters(in: .whitespaces).uppercased()
        guard TelegramRandom.constantTimeEqual(cleaned, code) else {
            failedAttempts += 1
            if failedAttempts >= Self.maxAttempts { cancelCode() }
            return .rejected("That code isn't right.")
        }
        cancelCode()
        let user = PairedUser(userID: userID, chatID: chatID, name: name, pairedAt: now)
        users.removeAll { $0.userID == userID }
        users.append(user)
        return .paired(user)
    }

    mutating func remove(userID: Int64) {
        users.removeAll { $0.userID == userID }
    }
}

/// Inline Approve/Deny buttons for one agent approval, usable once by the user who asked for the task.
struct TelegramApprovalTicket: Equatable {
    var approvalID: UUID
    var taskID: UUID
    var actionHash: String
    var userID: Int64
    var chatID: Int64
    var nonce: String
    var expiresAt: Date
    var messageID = 0
    var used = false

    var shortID: String { String(approvalID.uuidString.prefix(8)).lowercased() }

    /// "a:<32 hex>:<nonce>" — 45 bytes, inside Telegram's 64-byte limit.
    func callbackData(approve: Bool) -> String {
        "\(approve ? "a" : "d"):\(approvalID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()):\(nonce)"
    }

    static func parseCallback(_ data: String) -> (approve: Bool, approvalHex: String, nonce: String)? {
        let parts = data.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "a" || parts[0] == "d", parts[1].count == 32 else { return nil }
        return (parts[0] == "a", parts[1], parts[2])
    }

    var approvalHex: String { approvalID.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    enum Check: Equatable {
        case ok
        case rejected(String)
    }

    /// Bound to the user, the task, the exact action digest and a nonce; once; before it expires.
    func check(fromUser: Int64, nonce: String?, approval: AgentApproval?, now: Date) -> Check {
        if used { return .rejected("This approval was already used.") }
        if fromUser != userID { return .rejected("Only the person who asked for this task can approve it.") }
        if let nonce, !TelegramRandom.constantTimeEqual(nonce, self.nonce) { return .rejected("These buttons are out of date.") }
        if now >= expiresAt { return .rejected("This approval expired (10 minutes).") }
        guard let approval, approval.taskID == taskID, approval.actionHash == actionHash else {
            return .rejected("The action changed, so this approval no longer applies.")
        }
        guard approval.decision == .pending, now < approval.expiresAt else { return .rejected("This approval is no longer open.") }
        return .ok
    }
}

/// At most `limit` messages per user in a sliding window.
struct TelegramRateLimiter {
    var limit = 20
    var window: TimeInterval = 60
    private var hits: [Int64: [Date]] = [:]

    mutating func allow(_ userID: Int64, now: Date = Date()) -> Bool {
        let recent = (hits[userID] ?? []).filter { now.timeIntervalSince($0) < window }
        guard recent.count < limit else { hits[userID] = recent; return false }
        hits[userID] = recent + [now]
        return true
    }
}
