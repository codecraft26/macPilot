import Foundation

/// Parsers for the public job-board APIs, RSS feeds and job-alert emails (all pure, fixture-tested).
enum JobSources {
    static func apiURL(_ source: CompanySource) -> URL? {
        let slug = source.slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.slug
        switch source.ats {
        case .greenhouse: return URL(string: "https://boards-api.greenhouse.io/v1/boards/\(slug)/jobs")
        case .lever: return URL(string: "https://api.lever.co/v0/postings/\(slug)?mode=json")
        case .ashby: return URL(string: "https://api.ashbyhq.com/posting-api/job-board/\(slug)")
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = isoFormatter.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: text)
    }

    static func isRemote(_ text: String) -> Bool {
        text.range(of: #"\bremote\b|anywhere|distributed|work from home"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// boards-api.greenhouse.io/v1/boards/{slug}/jobs
    static func greenhouse(_ data: Data, company: String) -> [JobPosting] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let jobs = object["jobs"] as? [[String: Any]] else { return [] }
        return jobs.compactMap { job in
            guard let title = job["title"] as? String, let url = job["absolute_url"] as? String else { return nil }
            let location = (job["location"] as? [String: Any])?["name"] as? String ?? ""
            return JobPosting(company: job["company_name"] as? String ?? company, title: title, location: location,
                              remote: isRemote(location), posted: date(job["first_published"] as? String) ?? date(job["updated_at"] as? String),
                              url: url, source: "Greenhouse")
        }
    }

    /// api.lever.co/v0/postings/{slug}?mode=json
    static func lever(_ data: Data, company: String) -> [JobPosting] {
        guard let jobs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return jobs.compactMap { job in
            guard let title = job["text"] as? String, let url = job["hostedUrl"] as? String else { return nil }
            let categories = job["categories"] as? [String: Any] ?? [:]
            let location = categories["location"] as? String ?? ""
            let workplace = job["workplaceType"] as? String ?? ""
            let created = (job["createdAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1_000) }
            return JobPosting(company: company, title: title, location: location, remote: workplace == "remote" || isRemote(location),
                              posted: created, url: url, source: "Lever")
        }
    }

    /// api.ashbyhq.com/posting-api/job-board/{slug}
    static func ashby(_ data: Data, company: String) -> [JobPosting] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let jobs = object["jobs"] as? [[String: Any]] else { return [] }
        return jobs.compactMap { job in
            guard let title = job["title"] as? String, let url = (job["jobUrl"] as? String) ?? (job["applyUrl"] as? String) else { return nil }
            if job["isListed"] as? Bool == false { return nil }
            let location = job["location"] as? String ?? ""
            let remote = job["isRemote"] as? Bool == true || (job["workplaceType"] as? String)?.lowercased() == "remote" || isRemote(location)
            return JobPosting(company: company, title: title, location: location, remote: remote,
                              posted: date(job["publishedAt"] as? String), url: url, source: "Ashby")
        }
    }

    static func parse(_ data: Data, source: CompanySource) -> [JobPosting] {
        switch source.ats {
        case .greenhouse: return greenhouse(data, company: source.name)
        case .lever: return lever(data, company: source.name)
        case .ashby: return ashby(data, company: source.name)
        }
    }

    // MARK: RSS / Atom

    static func feed(_ data: Data, defaultCompany: String) -> [JobPosting] {
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items.compactMap { item in
            guard let title = item["title"], let link = item["link"], !link.isEmpty else { return nil }
            // Many job feeds use "Title at Company" or "Company: Title".
            var company = item["author"] ?? item["dc:creator"] ?? defaultCompany
            var role = title
            if let range = title.range(of: " at ", options: .backwards) {
                role = String(title[..<range.lowerBound]); company = String(title[range.upperBound...])
            }
            let posted = (item["pubDate"]).flatMap(rfc822) ?? date(item["updated"] ?? item["published"])
            let location = item["location"] ?? ""
            return JobPosting(company: company.trimmingCharacters(in: .whitespaces), title: role.trimmingCharacters(in: .whitespaces),
                              location: location, remote: isRemote(title + " " + location + " " + (item["description"] ?? "")),
                              posted: posted, url: link.trimmingCharacters(in: .whitespacesAndNewlines), source: "RSS")
        }
    }

    static func rfc822(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    private final class FeedParser: NSObject, XMLParserDelegate {
        var items: [[String: String]] = []
        private var current: [String: String]?
        private var element = ""
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" || name == "entry" { current = [:] }
            element = name
            buffer = ""
            if name == "link", current != nil, let href = attributes["href"], (attributes["rel"] ?? "alternate") == "alternate" { current?["link"] = href }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { buffer += String(decoding: data, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "item" || name == "entry" {
                if let current { items.append(current) }
                current = nil
            } else if current != nil {
                let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, current?[name] == nil { current?[name] = value }
            }
            buffer = ""
        }
    }

    // MARK: Job-alert emails (the user's own LinkedIn / Indeed alerts — their websites are never scraped)

    static let alertSenders = ["jobalerts-noreply@linkedin.com", "jobs-noreply@linkedin.com", "alert@indeed.com", "noreply@indeed.com"]

    /// Postings from the plain-text body of a LinkedIn or Indeed job-alert email.
    static func alertEmail(_ body: String, received: Date? = nil) -> [JobPosting] {
        let lines = body.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var postings: [JobPosting] = []
        for (index, line) in lines.enumerated() {
            guard let url = firstURL(in: line), let canonical = canonicalAlertURL(url) else { continue }
            // The lines above the link describe the job: title, company, location (LinkedIn) or "Company - Location" (Indeed).
            let context = lines[max(0, index - 4)..<index].filter { !$0.isEmpty && firstURL(in: $0) == nil && !$0.lowercased().hasPrefix("view job") }
            guard let title = context.first else { continue }
            var company = context.count > 1 ? context[1] : ""
            var location = context.count > 2 ? context[2] : ""
            if canonical.contains("indeed.com"), location.isEmpty, let dash = company.range(of: " - ") {
                location = String(company[dash.upperBound...]); company = String(company[..<dash.lowerBound])
            }
            postings.append(JobPosting(company: company, title: title, location: location, remote: isRemote(location + " " + title),
                                       posted: received, url: canonical, source: canonical.contains("linkedin") ? "LinkedIn alert" : "Indeed alert"))
        }
        // One posting per link (alerts repeat links for the logo and the title).
        var seen = Set<String>()
        return postings.filter { seen.insert($0.url).inserted }
    }

    static func firstURL(in text: String) -> String? {
        guard let range = text.range(of: #"https?://[^\s<>"\)\]]+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// LinkedIn …/jobs/view/123… and Indeed …jk=abc… links reduced to a stable job URL (tracking removed).
    static func canonicalAlertURL(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw), let host = components.host?.lowercased() else { return nil }
        if host.hasSuffix("linkedin.com"), let match = raw.range(of: #"/jobs/view/(\d+)"#, options: .regularExpression) {
            let id = raw[match].filter(\.isNumber)
            return "https://www.linkedin.com/jobs/view/\(id)"
        }
        if host.hasSuffix("indeed.com"), let jk = components.queryItems?.first(where: { $0.name == "jk" || $0.name == "vjk" })?.value {
            return "https://www.indeed.com/viewjob?jk=\(jk)"
        }
        return nil
    }
}

/// Filters, dedupe and the email.
enum JobFinder {
    static func matches(_ posting: JobPosting, config: JobFinderConfig, now: Date = Date()) -> Bool {
        let title = posting.title.lowercased()
        let haystack = (posting.title + " " + posting.company).lowercased()
        let keywords = config.keywords.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !keywords.isEmpty, !keywords.contains(where: { containsWord($0, in: title) }) { return false }
        if config.excludeWords.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }).contains(where: { !$0.isEmpty && containsWord($0, in: haystack) }) {
            return false
        }
        if config.remoteOnly && !posting.remote { return false }
        let place = config.location.trimmingCharacters(in: .whitespaces).lowercased()
        if !place.isEmpty, !config.remoteOnly {
            let here = posting.location.lowercased().contains(place)
            if !(here || (config.includeRemote && posting.remote)) { return false }
        }
        if config.level != .any, level(of: title) != config.level { return false }
        if let posted = posting.posted, config.maxAgeDays > 0, now.timeIntervalSince(posted) > Double(config.maxAgeDays) * 86_400 { return false }
        return true
    }

    static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "(^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "($|[^a-z0-9])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func level(of title: String) -> ExperienceLevel {
        let t = title.lowercased()
        if ["staff", "principal", "lead", "head of", "director", "distinguished"].contains(where: { containsWord($0, in: t) }) { return .lead }
        if ["senior", "sr", "sr."].contains(where: { containsWord($0, in: t) }) || t.contains("sr ") { return .senior }
        if ["junior", "jr", "entry", "graduate", "new grad", "associate", "intern"].contains(where: { containsWord($0, in: t) }) { return .entry }
        return .mid
    }

    /// Tracking parameters, case and trailing slashes removed, so the same posting has one URL.
    static func canonicalURL(_ raw: String) -> String {
        if let alert = JobSources.canonicalAlertURL(raw) { return alert }
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return raw.lowercased() }
        components.scheme = "https"
        components.host = components.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        components.fragment = nil
        let tracking: Set<String> = ["utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term", "gh_src", "source", "ref", "lever-source", "src"]
        let kept = (components.queryItems ?? []).filter { !tracking.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
        components.queryItems = kept.isEmpty ? nil : kept.sorted { $0.name < $1.name }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string ?? raw
    }

    static func titleKey(_ posting: JobPosting) -> String {
        func clean(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return "t:" + clean(posting.company) + "|" + clean(posting.title)
    }

    static func keys(_ posting: JobPosting) -> [String] { ["u:" + canonicalURL(posting.url), titleKey(posting)] }

    /// Postings not seen before (by canonical URL or company+title), deduped within this batch too.
    static func newPostings(_ postings: [JobPosting], seen: Set<String>) -> (fresh: [JobPosting], seen: Set<String>) {
        var known = seen
        var fresh: [JobPosting] = []
        for posting in postings {
            let keys = keys(posting)
            if keys.contains(where: known.contains) { continue }
            known.formUnion(keys)
            var copy = posting
            copy.url = canonicalURL(posting.url)
            fresh.append(copy)
        }
        // Keep the memory bounded.
        if known.count > 20_000 { known = Set(known.shuffled().prefix(15_000)) }
        return (fresh, known)
    }

    struct Email: Equatable {
        var subject: String
        var text: String
        var html: String
    }

    /// New postings grouped by company, as plain text and HTML.
    static func email(jobName: String, postings: [JobPosting], date: Date = Date()) -> Email {
        let groups = Dictionary(grouping: postings, by: \.company).sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        let day = date.formatted(date: .abbreviated, time: .omitted)
        let subject = "\(jobName): \(postings.count) new job\(postings.count == 1 ? "" : "s") · \(day)"
        var text = "\(postings.count) new posting\(postings.count == 1 ? "" : "s") found by MacPilot (\(jobName)).\n"
        var html = "<html><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif\"><p>\(postings.count) new posting\(postings.count == 1 ? "" : "s") found by MacPilot (\(escape(jobName))).</p>"
        for (company, jobs) in groups {
            text += "\n\(company.isEmpty ? "Other" : company)\n" + String(repeating: "-", count: max(5, company.count)) + "\n"
            html += "<h3 style=\"margin-bottom:4px\">\(escape(company.isEmpty ? "Other" : company))</h3><ul>"
            for job in jobs.sorted(by: { ($0.posted ?? .distantPast) > ($1.posted ?? .distantPast) }) {
                let details = [job.location.isEmpty ? nil : job.location, job.remote && !job.location.lowercased().contains("remote") ? "Remote" : nil,
                               job.posted.map { "posted \($0.formatted(date: .abbreviated, time: .omitted))" }].compactMap { $0 }.joined(separator: " · ")
                text += "• \(job.title)\(details.isEmpty ? "" : " — \(details)")\n  Apply: \(job.url)\n"
                html += "<li><a href=\"\(escape(job.url))\">\(escape(job.title))</a>\(details.isEmpty ? "" : " — \(escape(details))")</li>"
            }
            html += "</ul>"
        }
        text += "\nYou get this because you set up the “\(jobName)” job in MacPilot. Pause it in MacPilot → Agent → Jobs.\n"
        html += "<p style=\"color:#888;font-size:12px\">Sent by MacPilot for the “\(escape(jobName))” job. Pause it in MacPilot → Agent → Jobs.</p></body></html>"
        return Email(subject: subject, text: text, html: html)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let samplePostings = [
        JobPosting(company: "Example Co", title: "Senior iOS Engineer", location: "Remote (US)", remote: true, posted: Date(), url: "https://boards.greenhouse.io/example/jobs/1", source: "Greenhouse"),
        JobPosting(company: "Example Co", title: "Swift Platform Engineer", location: "New York, NY", remote: false, posted: Date(), url: "https://boards.greenhouse.io/example/jobs/2", source: "Greenhouse"),
        JobPosting(company: "Sample Labs", title: "Mobile Engineer (iOS)", location: "Berlin", remote: false, posted: Date(), url: "https://jobs.ashbyhq.com/sample/3", source: "Ashby")
    ]
}
