import AppKit
import Foundation

struct OutgoingEmail: Equatable {
    var to: String
    var subject: String
    var text: String
    var html: String?
}

/// Sends mail through Mail.app or Gmail (mocked in tests).
protocol EmailSending: AnyObject {
    func send(_ email: OutgoingEmail, via sender: EmailSenderKind, account: String) async throws
    /// Plain-text bodies of the user's own job-alert emails from the last `days` days.
    func alertEmails(via source: EmailSenderKind, account: String, days: Int) async throws -> [(body: String, received: Date?)]
}

enum EmailError: LocalizedError, Equatable {
    case notApproved
    case recipientNotAllowed(String)
    case invalidAddress(String)
    case noSender
    case gmailScope
    case mail(String)

    var errorDescription: String? {
        switch self {
        case .notApproved: return "This job's email isn't approved yet. Open it in Agent → Jobs and approve the sample email."
        case .recipientNotAllowed(let to): return "Sending to \(to) isn't allowed: a job only emails the one address you typed and approved."
        case .invalidAddress(let to): return "“\(to)” isn't a single valid email address."
        case .noSender: return "Choose how this job sends email (Mail or Gmail)."
        case .gmailScope: return "Gmail needs permission to send (or read alerts). Press “Allow Gmail…” in the job editor."
        case .mail(let message): return message
        }
    }
}

/// Who may email whom. Outside an approved job, sending is high risk and the address must be one the user typed.
enum EmailPolicy {
    /// A scheduled job: only its bound, approved recipient, through the approved account.
    static func authorizeJob(_ job: AgentJob, to: String) throws -> String {
        guard let address = EmailAddress.normalize(to) else { throw EmailError.invalidAddress(to) }
        guard JobSendApproval.isApproved(job) else { throw EmailError.notApproved }
        guard address == EmailAddress.normalize(job.recipient) else { throw EmailError.recipientNotAllowed(address) }
        return address
    }

    /// An interactive task: the address must appear in what the user typed; the action still needs approval.
    static func authorizeInteractive(to: String, userText: String) throws -> String {
        guard let address = EmailAddress.normalize(to) else { throw EmailError.invalidAddress(to) }
        guard EmailAddress.all(in: userText).contains(address) else { throw EmailError.recipientNotAllowed(address) }
        return address
    }
}

final class SystemEmailSender: EmailSending {
    func send(_ email: OutgoingEmail, via sender: EmailSenderKind, account: String) async throws {
        switch sender {
        case .none: throw EmailError.noSender
        case .mailApp: try await MailAppBridge.send(email)
        case .gmail: try await GmailBridge.send(email, account: account)
        }
    }

    func alertEmails(via source: EmailSenderKind, account: String, days: Int) async throws -> [(body: String, received: Date?)] {
        switch source {
        case .none: return []
        case .mailApp: return try await MailAppBridge.alertEmails(days: days)
        case .gmail: return try await GmailBridge.alertEmails(account: account, days: days)
        }
    }
}

/// Mail.app through AppleScript (asks once for Automation permission).
enum MailAppBridge {
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func sendScript(_ email: OutgoingEmail) -> String {
        """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:\(quote(email.subject)), content:\(quote(email.text)), visible:false}
            tell newMessage
                make new to recipient at end of to recipients with properties {address:\(quote(email.to))}
            end tell
            send newMessage
        end tell
        """
    }

    @MainActor
    static func run(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw EmailError.mail("Couldn't prepare the Mail script.") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Mail returned an error."
            throw EmailError.mail("Mail: \(message) (allow MacPilot under System Settings → Privacy & Security → Automation → Mail)")
        }
        return result
    }

    @MainActor
    static func send(_ email: OutgoingEmail) async throws {
        _ = try run(sendScript(email))
    }

    @MainActor
    static func alertEmails(days: Int) async throws -> [(body: String, received: Date?)] {
        let senders = JobSources.alertSenders.map { "sender contains \(quote($0))" }.joined(separator: " or ")
        let source = """
        set cutoff to (current date) - (\(max(1, days)) * days)
        set output to {}
        tell application "Mail"
            set found to (messages of inbox whose (date received > cutoff) and (\(senders)))
            repeat with m in found
                set end of output to (content of m) & "\u{1E}" & ((date received of m) as «class isot» as string)
            end repeat
        end tell
        set AppleScript's text item delimiters to "\u{1D}"
        return output as string
        """
        let result = try run(source).stringValue ?? ""
        return result.split(separator: "\u{1D}").map { item in
            let parts = item.split(separator: "\u{1E}", maxSplits: 1).map(String.init)
            return (parts.first ?? "", parts.count > 1 ? ISO8601DateFormatter().date(from: parts[1] + "Z") : nil)
        }
    }
}

/// Gmail API with the account connected in Settings (gmail.send / gmail.readonly added by incremental consent).
enum GmailBridge {
    /// RFC 2822 message with plain text and HTML parts; headers can't be injected (newlines removed).
    static func mime(_ email: OutgoingEmail, from: String, boundary: String = "macpilot-\(UUID().uuidString)") -> String {
        func header(_ value: String) -> String { value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
        let subject = "=?UTF-8?B?\(Data(header(email.subject).utf8).base64EncodedString())?="
        var lines = ["From: \(header(from))", "To: \(header(email.to))", "Subject: \(subject)", "MIME-Version: 1.0"]
        if let html = email.html {
            lines += ["Content-Type: multipart/alternative; boundary=\"\(boundary)\"", "",
                      "--\(boundary)", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "",
                      Data(email.text.utf8).base64EncodedString(options: .lineLength76Characters),
                      "--\(boundary)", "Content-Type: text/html; charset=UTF-8", "Content-Transfer-Encoding: base64", "",
                      Data(html.utf8).base64EncodedString(options: .lineLength76Characters), "--\(boundary)--"]
        } else {
            lines += ["Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "",
                      Data(email.text.utf8).base64EncodedString(options: .lineLength76Characters)]
        }
        return lines.joined(separator: "\r\n")
    }

    @MainActor
    static func send(_ email: OutgoingEmail, account: String) async throws {
        let google = GoogleCalendarService.shared
        guard google.hasScope(GoogleCalendarService.gmailSendScope, account: account) else { throw EmailError.gmailScope }
        let raw = PKCE.base64URL(Data(mime(email, from: account).utf8))
        let body = try JSONSerialization.data(withJSONObject: ["raw": raw])
        _ = try await google.authorizedRequest("POST", url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!,
                                               account: account, body: body, contentType: "application/json")
    }

    @MainActor
    static func alertEmails(account: String, days: Int) async throws -> [(body: String, received: Date?)] {
        let google = GoogleCalendarService.shared
        guard google.hasScope(GoogleCalendarService.gmailReadScope, account: account) else { throw EmailError.gmailScope }
        let query = "from:(\(JobSources.alertSenders.joined(separator: " OR "))) newer_than:\(max(1, days))d"
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: "25")]
        let list = try JSONSerialization.jsonObject(with: try await google.authorizedRequest("GET", url: components.url!, account: account)) as? [String: Any]
        var results: [(String, Date?)] = []
        for item in (list?["messages"] as? [[String: Any]] ?? []).prefix(25) {
            guard let id = item["id"] as? String,
                  let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full") else { continue }
            let message = try JSONSerialization.jsonObject(with: try await google.authorizedRequest("GET", url: url, account: account)) as? [String: Any]
            let received = (message?["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000) }
            results.append((plainText(message?["payload"] as? [String: Any] ?? [:]), received))
        }
        return results
    }

    /// The text/plain part of a Gmail payload (falling back to HTML converted to text).
    static func plainText(_ payload: [String: Any]) -> String {
        func decode(_ data: String) -> String {
            var base64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            return Data(base64Encoded: base64).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        var html = ""
        func walk(_ part: [String: Any]) -> String? {
            let type = part["mimeType"] as? String ?? ""
            let data = (part["body"] as? [String: Any])?["data"] as? String
            if type == "text/plain", let data { return decode(data) }
            if type == "text/html", let data, html.isEmpty { html = decode(data) }
            for child in part["parts"] as? [[String: Any]] ?? [] { if let text = walk(child) { return text } }
            return nil
        }
        return walk(payload) ?? HTMLText.text(html)
    }
}
