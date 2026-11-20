import AppKit
import CryptoKit
import Foundation
import Network
import Observation

enum GoogleCalendarError: LocalizedError {
    case missingClientID
    case notConnected
    case authorizationDenied(String)
    case timedOut
    case stateMismatch

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Add your Google OAuth client ID in Settings → Recording & Calendar first."
        case .notConnected:
            return "Google Calendar is not connected."
        case .authorizationDenied(let reason):
            return "Google sign-in did not finish: \(reason)."
        case .timedOut:
            return "Google sign-in timed out. Try Connect again."
        case .stateMismatch:
            return "Google sign-in returned an unexpected response. Try Connect again."
        }
    }
}

/// Google Calendar over its REST API, for one or more Google accounts. Sign-in uses the OAuth 2.0 desktop flow
/// (PKCE + loopback redirect) with the user's own OAuth client. Each account's refresh token and the client
/// secret live in the Keychain.
@Observable
@MainActor
final class GoogleCalendarService {
    static let shared = GoogleCalendarService()

    static let scopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.readonly",
        "openid",
        "email"
    ]
    /// Pre-0.20 single-account token, migrated on first launch.
    private static let legacyRefreshTokenAccount = "google.refreshToken"
    static let clientSecretAccount = "google.clientSecret"
    private static let accountsKey = "google.accounts"

    static func refreshTokenAccount(for email: String) -> String { "google.refreshToken.\(email.lowercased())" }

    /// Connected Google accounts (email addresses), in the order they were added.
    private(set) var accounts: [String] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var isSigningIn = false
    var lastError: String?

    var isConnected: Bool { !accounts.isEmpty }

    /// Cached events by id. Filled by `load(from:to:)`.
    private var cache: [String: CalendarEvent] = [:]
    private var tokens: [String: AccessToken] = [:]
    /// Called after calendars or events change so the merged calendar view reloads.
    var onChange: (() -> Void)?

    private init() {
        accounts = UserDefaults.standard.stringArray(forKey: Self.accountsKey) ?? []
        migrateSingleAccount()
    }

    /// 0.19 and earlier stored one token; move it under its account's email.
    private func migrateSingleAccount() {
        guard accounts.isEmpty, let refresh = KeychainStore.read(account: Self.legacyRefreshTokenAccount) else { return }
        let email = UserDefaults.standard.string(forKey: PrefKey.googleAccountEmail).flatMap { $0.isEmpty ? nil : $0 } ?? "Google account"
        guard (try? KeychainStore.save(refresh, account: Self.refreshTokenAccount(for: email))) != nil else { return }
        try? KeychainStore.delete(account: Self.legacyRefreshTokenAccount)
        accounts = [email]
        saveAccounts()
    }

    private func saveAccounts() {
        UserDefaults.standard.set(accounts, forKey: Self.accountsKey)
        UserDefaults.standard.set(accounts.first ?? "", forKey: PrefKey.googleAccountEmail)
    }

    /// For display: "a@x.com, b@y.com".
    var accountEmail: String { accounts.joined(separator: ", ") }

    var clientID: String {
        get { UserDefaults.standard.string(forKey: PrefKey.googleClientID) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: PrefKey.googleClientID) }
    }

    #if DEBUG
    func setPreview(accounts: [String], calendars: [CalendarInfo]) {
        self.accounts = accounts
        self.calendars = calendars
    }
    #endif

    func calendars(of account: String) -> [CalendarInfo] {
        calendars.filter { $0.account == account }
    }

    // MARK: Sign in / out

    /// Signs in to a Google account and adds it (Google lets you pick which account in the browser).
    /// Signing in again to an account that's already connected just renews its access.
    func connect() async {
        lastError = nil
        let clientID = self.clientID
        guard !clientID.isEmpty else {
            lastError = GoogleCalendarError.missingClientID.localizedDescription
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let verifier = PKCE.verifier()
            let state = UUID().uuidString
            let receiver = LoopbackReceiver()
            let port = try await receiver.start()
            let redirect = "http://127.0.0.1:\(port)"

            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
                URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "access_type", value: "offline"),
                // Always show the account chooser so another account can be added.
                URLQueryItem(name: "prompt", value: "select_account consent"),
                URLQueryItem(name: "state", value: state)
            ]
            NSWorkspace.shared.open(components.url!)

            let query = try await receiver.waitForRedirect(timeout: 300)
            if let error = query["error"] { throw GoogleCalendarError.authorizationDenied(error) }
            guard query["state"] == state else { throw GoogleCalendarError.stateMismatch }
            guard let code = query["code"] else { throw GoogleCalendarError.authorizationDenied("no authorization code") }

            var fields = [
                "code": code,
                "client_id": clientID,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirect
            ]
            if let secret = KeychainStore.read(account: Self.clientSecretAccount), !secret.isEmpty {
                fields["client_secret"] = secret
            }
            let token = try await tokenRequest(fields, account: nil)
            guard let refresh = token["refresh_token"] as? String else {
                throw GoogleCalendarError.authorizationDenied("Google did not return a refresh token")
            }
            let email = (token["id_token"] as? String).flatMap(JWT.email) ?? "Google account \(accounts.count + 1)"
            try KeychainStore.save(refresh, account: Self.refreshTokenAccount(for: email))
            tokens[email.lowercased()] = AccessToken(response: token)
            if !accounts.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
                accounts.append(email)
                saveAccounts()
            }
            NSApp.activate(ignoringOtherApps: true)
            await refreshCalendars()
        } catch {
            lastError = AIError.describe(error)
        }
    }

    /// Disconnects one account (revoking its access at Google) and removes its calendars and events.
    func disconnect(_ email: String) {
        if let refresh = KeychainStore.read(account: Self.refreshTokenAccount(for: email)) {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = FormEncoding.encode(["token": refresh])
            Task { _ = try? await HTTPSupport.session.data(for: request) }
        }
        forget(email)
    }

    /// Disconnects every account.
    func disconnect() {
        for email in accounts { disconnect(email) }
        forgetCredentials()
    }

    private func forget(_ email: String) {
        try? KeychainStore.delete(account: Self.refreshTokenAccount(for: email))
        tokens[email.lowercased()] = nil
        accounts.removeAll { $0.caseInsensitiveCompare(email) == .orderedSame }
        saveAccounts()
        calendars.removeAll { $0.account.caseInsensitiveCompare(email) == .orderedSame }
        cache = cache.filter { $0.value.calendar.account.caseInsensitiveCompare(email) != .orderedSame }
        onChange?()
    }

    /// Removes all tokens locally (used by "Delete all API keys").
    func forgetCredentials() {
        for email in accounts { try? KeychainStore.delete(account: Self.refreshTokenAccount(for: email)) }
        try? KeychainStore.delete(account: Self.legacyRefreshTokenAccount)
        tokens = [:]
        accounts = []
        saveAccounts()
        calendars = []
        cache = [:]
        onChange?()
    }

    // MARK: Calendars and events

    /// Loads the calendar list of every account. A calendar shared with two of your accounts is shown once
    /// (from the account that can edit it).
    func refreshCalendars() async {
        guard isConnected else { return }
        var all: [CalendarInfo] = []
        var errors: [String] = []
        for email in accounts {
            do {
                let json = try await get("users/me/calendarList", account: email, query: [URLQueryItem(name: "maxResults", value: "250")])
                let items = json["items"] as? [[String: Any]] ?? []
                all += items.compactMap { GoogleMapping.calendar($0, account: email) }
            } catch {
                errors.append("\(email): \(AIError.describe(error))")
            }
        }
        calendars = GoogleMapping.deduplicated(all)
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        onChange?()
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        cache.values.filter { $0.start < end && $0.end > start }
    }

    func event(withID id: String) -> CalendarEvent? { cache[id] }

    /// Fetches events for the visible Google calendars (all accounts) in the range and replaces the cached ones.
    func load(from start: Date, to end: Date, visible: (CalendarInfo) -> Bool) async {
        guard isConnected else { return }
        if calendars.isEmpty { await refreshCalendars() }
        let iso = ISO8601DateFormatter()
        var fetched: [CalendarEvent] = []
        var errors: [String] = []
        for calendar in calendars where visible(calendar) {
            let (account, calendarID) = GoogleMapping.split(calendar.rawID)
            do {
                var pageToken: String?
                repeat {
                    var query = [
                        URLQueryItem(name: "timeMin", value: iso.string(from: start)),
                        URLQueryItem(name: "timeMax", value: iso.string(from: end)),
                        URLQueryItem(name: "singleEvents", value: "true"),
                        URLQueryItem(name: "orderBy", value: "startTime"),
                        URLQueryItem(name: "maxResults", value: "250")
                    ]
                    if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
                    let json = try await get("calendars/\(GoogleMapping.pathEscape(calendarID))/events", account: account, query: query)
                    let items = json["items"] as? [[String: Any]] ?? []
                    fetched += items.compactMap { GoogleMapping.event($0, calendar: calendar) }
                    pageToken = json["nextPageToken"] as? String
                } while pageToken != nil
            } catch {
                errors.append("\(calendar.title) (\(account)): \(AIError.describe(error))")
            }
        }
        cache = cache.filter { !($0.value.start < end && $0.value.end > start) }
        for event in fetched { cache[event.id] = event }
        lastError = errors.isEmpty ? nil : "Google Calendar: " + errors.joined(separator: "; ")
        onChange?()
    }

    func save(_ draft: EventDraft, calendarRawID: String) async throws {
        let body = GoogleMapping.body(for: draft)
        let (account, calendarID) = GoogleMapping.split(calendarRawID)
        if let eventID = draft.eventID, let existing = cache[eventID], let googleID = GoogleMapping.eventID(from: eventID) {
            if existing.calendar.rawID == calendarRawID {
                _ = try await send("PATCH", "calendars/\(GoogleMapping.pathEscape(calendarID))/events/\(GoogleMapping.pathEscape(googleID))",
                                   account: account, body: body)
            } else {
                // Moving between calendars (or accounts): create in the new one, remove from the old one.
                _ = try await send("POST", "calendars/\(GoogleMapping.pathEscape(calendarID))/events", account: account, body: body)
                try await delete(existing)
            }
        } else {
            _ = try await send("POST", "calendars/\(GoogleMapping.pathEscape(calendarID))/events", account: account, body: body)
        }
    }

    func delete(_ event: CalendarEvent) async throws {
        guard let googleID = GoogleMapping.eventID(from: event.id) else { return }
        let (account, calendarID) = GoogleMapping.split(event.calendar.rawID)
        _ = try await send("DELETE", "calendars/\(GoogleMapping.pathEscape(calendarID))/events/\(GoogleMapping.pathEscape(googleID))",
                           account: account, body: nil)
        cache[event.id] = nil
        onChange?()
    }

    // MARK: HTTP

    private let apiBase = "https://www.googleapis.com/calendar/v3/"

    private func validAccessToken(for account: String) async throws -> String {
        let key = account.lowercased()
        if let value = tokens[key]?.validValue() { return value }
        guard let refresh = KeychainStore.read(account: Self.refreshTokenAccount(for: account)) else { throw GoogleCalendarError.notConnected }
        guard !clientID.isEmpty else { throw GoogleCalendarError.missingClientID }
        var fields = ["refresh_token": refresh, "client_id": clientID, "grant_type": "refresh_token"]
        if let secret = KeychainStore.read(account: Self.clientSecretAccount), !secret.isEmpty {
            fields["client_secret"] = secret
        }
        let response = try await tokenRequest(fields, account: account)
        tokens[key] = AccessToken(response: response)
        guard let value = tokens[key]?.validValue() else { throw GoogleCalendarError.notConnected }
        return value
    }

    private func tokenRequest(_ fields: [String: String], account: String?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(fields)
        let (data, response) = try await HTTPSupport.session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let reason = json["error_description"] as? String ?? json["error"] as? String ?? "token request failed"
            if json["error"] as? String == "invalid_grant", let account {
                // That account revoked access or its token expired: it needs a fresh sign-in.
                forget(account)
            }
            throw GoogleCalendarError.authorizationDenied(reason)
        }
        return json
    }

    private func get(_ path: String, account: String, query: [URLQueryItem]) async throws -> [String: Any] {
        var components = URLComponents(string: apiBase + path)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await validAccessToken(for: account))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTPSupport.session.data(for: request)
        try Self.ensureOK(response, data: data)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func send(_ method: String, _ path: String, account: String, body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: apiBase + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(try await validAccessToken(for: account))", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await HTTPSupport.session.data(for: request)
        try Self.ensureOK(response, data: data)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.stream("Google Calendar returned \(http.statusCode): \(Redactor.redact(HTTPSupport.errorMessage(from: data)))")
        }
    }
}

// MARK: - Mapping between Google JSON and MacPilot types

enum GoogleMapping {
    static let idPrefix = "google:"

    /// Composite id: "google:<calendar id>|<event id>".
    static func compositeID(calendar: String, event: String) -> String { "\(idPrefix)\(calendar)|\(event)" }

    static func eventID(from composite: String) -> String? {
        guard composite.hasPrefix(idPrefix), let bar = composite.lastIndex(of: "|") else { return nil }
        return String(composite[composite.index(after: bar)...])
    }

    static func pathEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    /// Separates the account from the calendar id inside a Google calendar's rawID: "me@gmail.com::work@group.calendar.google.com".
    static let accountSeparator = "::"

    static func rawID(account: String, calendar: String) -> String {
        account.isEmpty ? calendar : account + accountSeparator + calendar
    }

    /// (account, calendar id). Ids without an account (older data) belong to the first connected account.
    @MainActor
    static func split(_ rawID: String) -> (String, String) {
        if let range = rawID.range(of: accountSeparator) {
            return (String(rawID[..<range.lowerBound]), String(rawID[range.upperBound...]))
        }
        return (GoogleCalendarService.shared.accounts.first ?? "", rawID)
    }

    static func calendar(_ item: [String: Any], account: String = "") -> CalendarInfo? {
        guard let id = item["id"] as? String else { return nil }
        let role = item["accessRole"] as? String ?? "reader"
        return CalendarInfo(
            rawID: rawID(account: account, calendar: id),
            source: .google,
            title: item["summaryOverride"] as? String ?? item["summary"] as? String ?? id,
            color: RGBColor(hex: item["backgroundColor"] as? String ?? "") ?? RGBColor(red: 0.26, green: 0.52, blue: 0.96),
            isWritable: role == "owner" || role == "writer",
            account: account
        )
    }

    /// One entry per Google calendar id across accounts, preferring the account that can edit it.
    static func deduplicated(_ calendars: [CalendarInfo]) -> [CalendarInfo] {
        var seen: [String: Int] = [:]
        var result: [CalendarInfo] = []
        for calendar in calendars {
            let id = calendar.rawID.range(of: accountSeparator).map { String(calendar.rawID[$0.upperBound...]) } ?? calendar.rawID
            if let index = seen[id] {
                if calendar.isWritable && !result[index].isWritable { result[index] = calendar }
            } else {
                seen[id] = result.count
                result.append(calendar)
            }
        }
        return result
    }

    static func event(_ item: [String: Any], calendar: CalendarInfo) -> CalendarEvent? {
        guard let id = item["id"] as? String, item["status"] as? String != "cancelled",
              let startObject = item["start"] as? [String: Any], let endObject = item["end"] as? [String: Any],
              let (start, allDay) = date(startObject), let (end, _) = date(endObject) else { return nil }
        let attendees = (item["attendees"] as? [[String: Any]] ?? []).compactMap { attendee -> String? in
            guard attendee["self"] as? Bool != true, attendee["resource"] as? Bool != true else { return nil }
            return attendee["displayName"] as? String ?? attendee["email"] as? String
        }
        var alarm: Int?
        if let reminders = item["reminders"] as? [String: Any],
           let overrides = reminders["overrides"] as? [[String: Any]],
           let minutes = overrides.first?["minutes"] as? Int {
            alarm = minutes
        }
        return CalendarEvent(
            id: compositeID(calendar: calendar.rawID, event: id),
            title: item["summary"] as? String ?? "(No title)",
            start: start,
            end: end,
            isAllDay: allDay,
            location: item["location"] as? String ?? "",
            notes: item["description"] as? String ?? "",
            attendees: attendees,
            calendar: calendar,
            alarmMinutes: alarm
        )
    }

    /// Google uses `dateTime` (RFC 3339) for timed events and `date` (yyyy-MM-dd, end exclusive) for all-day ones.
    static func date(_ object: [String: Any]) -> (Date, Bool)? {
        if let value = object["dateTime"] as? String, let date = EventQuickAdd.date(value) {
            return (date, false)
        }
        if let value = object["date"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: value) { return (date, true) }
        }
        return nil
    }

    static func body(for draft: EventDraft, timeZone: TimeZone = .current) -> [String: Any] {
        var body: [String: Any] = [
            "summary": draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New event" : draft.title,
            "location": draft.location,
            "description": draft.notes
        ]
        if draft.isAllDay {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let startDay = Calendar.current.startOfDay(for: draft.start)
            var endDay = Calendar.current.startOfDay(for: draft.end)
            if endDay <= startDay { endDay = Calendar.current.date(byAdding: .day, value: 1, to: startDay) ?? startDay }
            body["start"] = ["date": formatter.string(from: startDay)]
            body["end"] = ["date": formatter.string(from: endDay)]
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = timeZone
            let end = max(draft.end, draft.start.addingTimeInterval(300))
            body["start"] = ["dateTime": formatter.string(from: draft.start), "timeZone": timeZone.identifier]
            body["end"] = ["dateTime": formatter.string(from: end), "timeZone": timeZone.identifier]
        }
        if let minutes = draft.alarmMinutes {
            body["reminders"] = ["useDefault": false, "overrides": [["method": "popup", "minutes": minutes]]]
        } else {
            body["reminders"] = ["useDefault": false, "overrides": [[String: Any]]()]
        }
        return body
    }
}

enum FormEncoding {
    static func encode(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}

/// A one-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect's query parameters.
final class LoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.macpilot.oauth-loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            // State updates arrive on the serial `queue`, so this flag needs no lock.
            let resumed = Flag()
            listener.stateUpdateHandler = { state in
                guard !resumed.value else { return }
                switch state {
                case .ready:
                    resumed.value = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed.value = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(GoogleCalendarError.timedOut))
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let query = Self.query(fromRequest: request)
            let success = query["code"] != nil
            let message = success
                ? "MacPilot is connected to Google Calendar. You can close this tab."
                : "MacPilot did not get access to Google Calendar. You can close this tab and try again."
            let html = "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>\(message)</h2></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            // Ignore stray requests such as /favicon.ico.
            if !query.isEmpty { self.finish(.success(query)) }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }

    static func query(fromRequest request: String) -> [String: String] {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return [:] }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}

/// An OAuth access token kept in memory only, treated as expired a minute early.
struct AccessToken: Equatable {
    var value: String?
    var expiresAt: Date = .distantPast

    init() {}

    init(response: [String: Any], now: Date = Date()) {
        value = response["access_token"] as? String
        let seconds = (response["expires_in"] as? Double) ?? Double(response["expires_in"] as? Int ?? 3600)
        expiresAt = now.addingTimeInterval(seconds)
    }

    func validValue(now: Date = Date(), margin: TimeInterval = 60) -> String? {
        guard let value, expiresAt > now.addingTimeInterval(margin) else { return nil }
        return value
    }
}

enum JWT {
    /// Reads the `email` claim from an ID token's payload (no signature check; it came straight from Google's token endpoint over TLS).
    static func email(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["email"] as? String
    }
}
