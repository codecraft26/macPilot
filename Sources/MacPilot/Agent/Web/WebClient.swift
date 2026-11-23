import Foundation

/// HTTP GET for the web tools (mocked in tests).
protocol WebTransport: AnyObject {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionWebTransport: WebTransport {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebError.badResponse }
        return (data, http)
    }
}

enum WebError: LocalizedError, Equatable {
    case invalidURL(String)
    case blockedByRobots(String)
    case loginWall(String)
    case http(Int, String)
    case notText(String)
    case badResponse
    case noSearchResults

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "“\(url)” isn't a web address MacPilot can fetch (http or https only)."
        case .blockedByRobots(let url): return "The site's robots.txt doesn't allow fetching \(url), so MacPilot skipped it."
        case .loginWall(let url): return "\(url) needs a login, so MacPilot skipped it."
        case let .http(code, url): return "\(url) returned HTTP \(code)."
        case .notText(let type): return "That page isn't text (\(type))."
        case .badResponse: return "The site sent a response MacPilot couldn't read."
        case .noSearchResults: return "No search results."
        }
    }
}

struct WebPage: Equatable {
    var url: URL
    var title: String
    var text: String
    var html: String
}

struct SearchResult: Equatable, Codable {
    var title: String
    var url: String
    var snippet: String
}

/// robots.txt rules for one site, for the "MacPilot" agent (falling back to "*").
struct RobotsTxt: Equatable {
    var allows: [String] = []
    var disallows: [String] = []

    static func parse(_ text: String, agent: String = "macpilot") -> RobotsTxt {
        var groups: [(agents: [String], rules: [(Bool, String)])] = []
        var currentAgents: [String] = []
        var currentRules: [(Bool, String)] = []
        var lastWasAgent = false
        func flush() {
            if !currentAgents.isEmpty { groups.append((currentAgents, currentRules)) }
            currentAgents = []
            currentRules = []
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "user-agent":
                if !lastWasAgent { flush() }
                currentAgents.append(value.lowercased())
                lastWasAgent = true
            case "allow", "disallow":
                lastWasAgent = false
                if !value.isEmpty || key == "disallow" { currentRules.append((key == "allow", value)) }
            default:
                lastWasAgent = false
            }
        }
        flush()
        let specific = groups.filter { $0.agents.contains { agent.hasPrefix($0) && $0 != "*" } }
        let chosen = specific.isEmpty ? groups.filter { $0.agents.contains("*") } : specific
        var robots = RobotsTxt()
        for group in chosen {
            for (allow, path) in group.rules where !path.isEmpty {
                if allow { robots.allows.append(path) } else { robots.disallows.append(path) }
            }
        }
        return robots
    }

    /// Longest matching rule wins; Allow wins a tie. Supports * and a trailing $.
    func allows(path: String) -> Bool {
        let bestDisallow = disallows.filter { Self.matches($0, path) }.map(\.count).max() ?? -1
        let bestAllow = allows.filter { Self.matches($0, path) }.map(\.count).max() ?? -1
        return bestAllow >= bestDisallow
    }

    static func matches(_ rule: String, _ path: String) -> Bool {
        var pattern = NSRegularExpression.escapedPattern(for: rule).replacingOccurrences(of: "\\*", with: ".*")
        if pattern.hasSuffix("\\$") { pattern = String(pattern.dropLast(2)) + "$" }
        return path.range(of: "^" + pattern, options: .regularExpression) != nil
    }
}

/// Readable text from HTML, optionally from the first element matching a simple CSS selector
/// (`tag`, `.class`, `#id`, `tag.class`, `tag#id`).
enum HTMLText {
    static func title(_ html: String) -> String {
        guard let range = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return "" }
        return decode(String(html[range]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func text(_ html: String, selector: String? = nil) -> String {
        var body = html
        if let selector, !selector.isEmpty { body = element(matching: selector, in: html) ?? "" }
        for tag in ["script", "style", "noscript", "svg", "template", "head"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        if selector == nil || selector?.isEmpty == true {
            for tag in ["nav", "footer", "header", "aside", "form"] {
                body = body.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
            }
        }
        body = body.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article|/table|li|h[1-6]|p|tr)\b[^>]*>"#,
                                         with: "\n", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"</t[dh]>"#, with: " \t ", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        body = decode(body)
        let lines = body.split(whereSeparator: \.isNewline).map {
            $0.replacingOccurrences(of: #"[ \t\u00A0]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    static func decode(_ text: String) -> String {
        var result = text
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let hexRange = Range(match.range(at: 1), in: result),
                      let numRange = Range(match.range(at: 2), in: result),
                      let code = UInt32(result[numRange], radix: result[hexRange].isEmpty ? 10 : 16), let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
    }

    /// Inner HTML of the first element matching `selector`.
    static func element(matching selector: String, in html: String) -> String? {
        let trimmed = selector.trimmingCharacters(in: .whitespaces)
        var tag = "[a-zA-Z][a-zA-Z0-9]*"
        var attribute = ""
        if let dot = trimmed.firstIndex(of: ".") {
            if dot != trimmed.startIndex { tag = NSRegularExpression.escapedPattern(for: String(trimmed[..<dot])) }
            let name = NSRegularExpression.escapedPattern(for: String(trimmed[trimmed.index(after: dot)...]))
            attribute = #"[^>]*\bclass\s*=\s*["'][^"']*\b"# + name + #"\b[^"']*["']"#
        } else if let hash = trimmed.firstIndex(of: "#") {
            if hash != trimmed.startIndex { tag = NSRegularExpression.escapedPattern(for: String(trimmed[..<hash])) }
            let name = NSRegularExpression.escapedPattern(for: String(trimmed[trimmed.index(after: hash)...]))
            attribute = #"[^>]*\bid\s*=\s*["']"# + name + #"["']"#
        } else {
            tag = NSRegularExpression.escapedPattern(for: trimmed)
        }
        guard let open = try? NSRegularExpression(pattern: "<(" + tag + ")\\b" + attribute + "[^>]*>", options: .caseInsensitive),
              let match = open.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let openRange = Range(match.range, in: html), let nameRange = Range(match.range(at: 1), in: html) else { return nil }
        let name = String(html[nameRange]).lowercased()
        // Walk forward counting nested tags of the same name.
        guard let tags = try? NSRegularExpression(pattern: "<(/?)" + NSRegularExpression.escapedPattern(for: name) + "\\b[^>]*?(/?)>", options: .caseInsensitive) else { return nil }
        var depth = 1
        let searchStart = openRange.upperBound
        for tagMatch in tags.matches(in: html, range: NSRange(searchStart..., in: html)) {
            guard let close = Range(tagMatch.range(at: 1), in: html), let selfClose = Range(tagMatch.range(at: 2), in: html) else { continue }
            if !html[selfClose].isEmpty { continue }
            depth += html[close].isEmpty ? 1 : -1
            if depth == 0, let end = Range(tagMatch.range, in: html) { return String(html[searchStart..<end.lowerBound]) }
        }
        return String(html[searchStart...])
    }

    /// Looks like a sign-in wall: a password field, or a redirect to a login URL.
    static func isLoginWall(html: String, finalURL: URL) -> Bool {
        let path = (finalURL.path + "?" + (finalURL.query ?? "")).lowercased()
        if ["/login", "/signin", "/sign-in", "/auth", "/sso", "/account/login", "authwall"].contains(where: path.contains) { return true }
        return html.range(of: #"<input[^>]+type\s*=\s*["']?password"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Links from DuckDuckGo's HTML results page.
    static func duckDuckGoResults(_ html: String) -> [SearchResult] {
        guard let regex = try? NSRegularExpression(pattern: #"<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)</a>"#) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html) else { return nil }
            var href = decode(String(html[hrefRange]))
            if href.hasPrefix("//") { href = "https:" + href }
            if let components = URLComponents(string: href), let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                href = target
            }
            let title = decode(String(html[titleRange]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            return SearchResult(title: title.trimmingCharacters(in: .whitespacesAndNewlines), url: href, snippet: "")
        }
    }
}

/// The web tools' network layer: a clear User-Agent, robots.txt (cached), ≥2 s between requests per site,
/// no cookies and no logged-in pages.
@MainActor
final class WebClient {
    static let shared = WebClient()
    static let userAgent = "MacPilot/0.24 (macOS personal assistant; respects robots.txt)"
    static let braveKeyAccount = "web.braveSearchKey"
    static let serpKeyAccount = "web.serpapiKey"

    var transport: WebTransport = URLSessionWebTransport()
    var minimumInterval: TimeInterval = 2
    var now: () -> Date = Date.init
    var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    var keys: (String) -> String? = { KeychainStore.read(account: $0) }
    private var robots: [String: (RobotsTxt, Date)] = [:]
    private var lastRequest: [String: Date] = [:]

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json,application/xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        return request
    }

    /// Waits so the same host is hit at most once per `minimumInterval`.
    private func throttle(_ host: String) async {
        if let last = lastRequest[host] {
            let wait = minimumInterval - now().timeIntervalSince(last)
            if wait > 0 { await sleep(wait) }
        }
        lastRequest[host] = now()
    }

    func get(_ url: URL, robotsCheck: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host?.lowercased() else {
            throw WebError.invalidURL(url.absoluteString)
        }
        if robotsCheck, !(await isAllowed(url)) { throw WebError.blockedByRobots(url.absoluteString) }
        await throttle(host)
        let (data, response) = try await transport.get(request(url))
        if response.statusCode == 401 || response.statusCode == 403 { throw WebError.loginWall(url.absoluteString) }
        guard (200..<300).contains(response.statusCode) else { throw WebError.http(response.statusCode, url.absoluteString) }
        return (data, response)
    }

    func isAllowed(_ url: URL) async -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let key = "\(url.scheme ?? "https")://\(host)"
        if let (rules, fetched) = robots[key], now().timeIntervalSince(fetched) < 86_400 {
            return rules.allows(path: url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? ""))
        }
        var rules = RobotsTxt()
        if let robotsURL = URL(string: key + "/robots.txt") {
            await throttle(host)
            if let (data, response) = try? await transport.get(request(robotsURL)) {
                if (200..<300).contains(response.statusCode) {
                    rules = RobotsTxt.parse(String(decoding: data, as: UTF8.self))
                } else if response.statusCode == 401 || response.statusCode == 403 {
                    rules = RobotsTxt(disallows: ["/"])
                }
            }
        }
        robots[key] = (rules, now())
        return rules.allows(path: url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? ""))
    }

    /// A page as readable text (untrusted). Login-walled pages are skipped.
    func fetchPage(_ raw: String, selector: String? = nil) async throws -> WebPage {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)) else { throw WebError.invalidURL(raw) }
        let (data, response) = try await get(url)
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
        guard type.contains("html") || type.contains("text") || type.contains("xml") || type.contains("json") else { throw WebError.notText(type) }
        let html = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        let finalURL = response.url ?? url
        if type.contains("html"), HTMLText.isLoginWall(html: html, finalURL: finalURL) { throw WebError.loginWall(url.absoluteString) }
        let text = type.contains("html") ? HTMLText.text(html, selector: selector) : html
        return WebPage(url: finalURL, title: HTMLText.title(html), text: String(text.prefix(40_000)), html: html)
    }

    /// Brave Search or SerpAPI when a key is set, otherwise DuckDuckGo's HTML results.
    func search(_ query: String, count: Int = 8) async throws -> [SearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let key = keys(Self.braveKeyAccount), !key.isEmpty,
           let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=\(count)") {
            var request = request(url)
            request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            await throttle("api.search.brave.com")
            let (data, response) = try await transport.get(request)
            guard (200..<300).contains(response.statusCode) else { throw WebError.http(response.statusCode, "Brave Search") }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let results = ((object?["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []).map {
                SearchResult(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", snippet: HTMLText.decode(($0["description"] as? String ?? "").replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)))
            }
            return Array(results.prefix(count))
        }
        if let key = keys(Self.serpKeyAccount), !key.isEmpty,
           let url = URL(string: "https://serpapi.com/search.json?engine=google&q=\(encoded)&num=\(count)&api_key=\(key)") {
            await throttle("serpapi.com")
            let (data, response) = try await transport.get(request(url))
            guard (200..<300).contains(response.statusCode) else { throw WebError.http(response.statusCode, "SerpAPI") }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (object?["organic_results"] as? [[String: Any]] ?? []).prefix(count).map {
                SearchResult(title: $0["title"] as? String ?? "", url: $0["link"] as? String ?? "", snippet: $0["snippet"] as? String ?? "")
            }
        }
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else { throw WebError.invalidURL(query) }
        let (data, _) = try await get(url)
        let results = HTMLText.duckDuckGoResults(String(decoding: data, as: UTF8.self))
        if results.isEmpty { throw WebError.noSearchResults }
        return Array(results.prefix(count))
    }
}
