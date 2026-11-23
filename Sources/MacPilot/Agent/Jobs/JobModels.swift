import CryptoKit
import Foundation
import SwiftData

enum JobTemplate: String, Codable, CaseIterable, Identifiable {
    /// A prompt the agent runs with web tools, emailing its result.
    case custom
    /// The built-in job finder (no AI needed to collect postings).
    case jobFinder
    var id: String { rawValue }
    var label: String { self == .custom ? "Custom (agent prompt)" : "Job finder" }
}

/// How a job's email leaves the Mac.
enum EmailSenderKind: String, Codable, CaseIterable, Identifiable {
    case none, mailApp, gmail
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Don't email (show in the app only)"
        case .mailApp: return "Mail app (default account)"
        case .gmail: return "Gmail account"
        }
    }
}

@Model
final class AgentJob {
    var uid: UUID = UUID()
    var name: String = ""
    var templateRaw: String = JobTemplate.custom.rawValue
    var prompt: String = ""
    var scheduleData: Data?
    var enabled: Bool = true
    var createdAt: Date = Date()
    var lastRun: Date?
    var nextRun: Date?
    /// The one address this job may email (typed by the user).
    var recipient: String = ""
    var senderRaw: String = EmailSenderKind.none.rawValue
    /// For Gmail: the connected account that sends.
    var senderAccount: String = ""
    /// SHA-256 of job ID + recipient + sender + account at the moment the user approved the sample email.
    var sendApprovalDigest: String = ""
    var sendApprovedAt: Date?
    var notifyTelegram: Bool = false
    var finderData: Data?
    /// Dedupe keys of postings already reported (job finder) — URLs and company+title.
    var seenKeysData: Data?
    /// Values remembered between runs for change detection ("price" → "$399").
    var memoryData: Data?

    init(name: String, template: JobTemplate, prompt: String = "", schedule: JobSchedule = JobSchedule()) {
        self.name = name
        self.templateRaw = template.rawValue
        self.prompt = prompt
        self.schedule = schedule
    }

    var template: JobTemplate {
        get { JobTemplate(rawValue: templateRaw) ?? .custom }
        set { templateRaw = newValue.rawValue }
    }

    var schedule: JobSchedule {
        get { scheduleData.flatMap { try? JSONDecoder().decode(JobSchedule.self, from: $0) } ?? JobSchedule() }
        set { scheduleData = try? JSONEncoder().encode(newValue) }
    }

    var sender: EmailSenderKind {
        get { EmailSenderKind(rawValue: senderRaw) ?? .none }
        set { senderRaw = newValue.rawValue }
    }

    var finder: JobFinderConfig {
        get { finderData.flatMap { try? JSONDecoder().decode(JobFinderConfig.self, from: $0) } ?? JobFinderConfig() }
        set { finderData = try? JSONEncoder().encode(newValue) }
    }

    var seenKeys: Set<String> {
        get { seenKeysData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? [] }
        set { seenKeysData = try? JSONEncoder().encode(newValue) }
    }

    var memory: [String: String] {
        get { memoryData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        set { memoryData = try? JSONEncoder().encode(newValue) }
    }

    var shortID: String { String(uid.uuidString.prefix(8)).lowercased() }
    var wantsEmail: Bool { sender != .none && !recipient.isEmpty }
}

@Model
final class JobRun {
    var uid: UUID = UUID()
    var jobID: UUID = UUID()
    var taskID: UUID?
    var startedAt: Date = Date()
    var finishedAt: Date?
    var statusRaw: String = "running"
    var summary: String = ""
    var newCount: Int = 0
    var emailed: Bool = false
    /// New postings found (job finder), for the app.
    var resultsData: Data?

    init(jobID: UUID) { self.jobID = jobID }

    var results: [JobPosting] {
        get { resultsData.flatMap { try? JSONDecoder().decode([JobPosting].self, from: $0) } ?? [] }
        set { resultsData = try? JSONEncoder().encode(newValue) }
    }
}

/// The send approval: bound to the job, the exact recipient and the sending account. Changing any of them voids it.
enum JobSendApproval {
    static func digest(jobID: UUID, recipient: String, sender: EmailSenderKind, account: String) -> String {
        let canonical = [jobID.uuidString, EmailAddress.normalize(recipient) ?? "", sender.rawValue, account.lowercased()].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isApproved(_ job: AgentJob) -> Bool {
        guard !job.sendApprovalDigest.isEmpty, job.wantsEmail else { return false }
        return job.sendApprovalDigest == digest(jobID: job.uid, recipient: job.recipient, sender: job.sender, account: job.senderAccount)
    }

    static func approve(_ job: AgentJob, now: Date = Date()) {
        job.sendApprovalDigest = digest(jobID: job.uid, recipient: job.recipient, sender: job.sender, account: job.senderAccount)
        job.sendApprovedAt = now
    }

    static func revoke(_ job: AgentJob) {
        job.sendApprovalDigest = ""
        job.sendApprovedAt = nil
    }
}

enum EmailAddress {
    /// Lowercased address if it's one plain address (no names, lists or header tricks), else nil.
    static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil else { return nil }
        return trimmed.lowercased()
    }

    /// Addresses written in some text (used to check an address was typed by the user).
    static func all(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).flatMap { normalize(String(text[$0])) }
        }
    }
}

// MARK: - Job finder

enum ATSKind: String, Codable, CaseIterable, Identifiable {
    case greenhouse, lever, ashby
    var id: String { rawValue }
}

struct CompanySource: Codable, Equatable, Hashable, Identifiable {
    var name: String
    var ats: ATSKind
    var slug: String
    var id: String { "\(ats.rawValue):\(slug)" }
}

enum ExperienceLevel: String, Codable, CaseIterable, Identifiable {
    case any, entry, mid, senior, lead
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: return "Any level"
        case .entry: return "Entry / junior"
        case .mid: return "Mid-level"
        case .senior: return "Senior"
        case .lead: return "Staff / lead / principal"
        }
    }
}

struct JobFinderConfig: Codable, Equatable {
    var keywords: [String] = ["iOS", "Swift"]
    var location = ""
    var includeRemote = true
    var remoteOnly = false
    var level: ExperienceLevel = .any
    var excludeWords: [String] = ["intern"]
    var companies: [CompanySource] = JobFinderConfig.starterCompanies
    var rssFeeds: [String] = []
    /// Read the user's own LinkedIn / Indeed job-alert emails (from Mail or Gmail; never their websites).
    var readAlertEmails = false
    var alertSource: EmailSenderKind = .mailApp
    var maxAgeDays = 30

    static let starterCompanies: [CompanySource] = [
        ("Airbnb", "airbnb"), ("Stripe", "stripe"), ("Figma", "figma"), ("Dropbox", "dropbox"), ("Discord", "discord"),
        ("Reddit", "reddit"), ("Coinbase", "coinbase"), ("Robinhood", "robinhood"), ("Pinterest", "pinterest"), ("Lyft", "lyft"),
        ("Instacart", "instacart"), ("GitLab", "gitlab"), ("Cloudflare", "cloudflare"), ("Datadog", "datadog"), ("Databricks", "databricks"),
        ("Asana", "asana"), ("Twilio", "twilio"), ("Airtable", "airtable"), ("Duolingo", "duolingo"), ("Anthropic", "anthropic")
    ].map { CompanySource(name: $0.0, ats: .greenhouse, slug: $0.1) }
        + [("Palantir", "palantir"), ("Spotify", "spotify")].map { CompanySource(name: $0.0, ats: .lever, slug: $0.1) }
        + [("Notion", "notion"), ("OpenAI", "openai"), ("Ramp", "ramp"), ("Linear", "linear"), ("Vercel", "vercel"),
           ("Deel", "deel"), ("Supabase", "supabase"), ("PostHog", "posthog")].map { CompanySource(name: $0.0, ats: .ashby, slug: $0.1) }

    /// "greenhouse:stripe Stripe" lines ↔ sources (for the editor).
    static func parseCompanies(_ text: String) -> [CompanySource] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard let first = parts.first else { return nil }
            let pieces = first.split(separator: ":").map(String.init)
            guard pieces.count == 2, let ats = ATSKind(rawValue: pieces[0].lowercased()), !pieces[1].isEmpty else { return nil }
            let slug = pieces[1].lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            guard !slug.isEmpty else { return nil }
            return CompanySource(name: parts.count > 1 ? parts[1] : pieces[1].capitalized, ats: ats, slug: slug)
        }
    }

    static func formatCompanies(_ companies: [CompanySource]) -> String {
        companies.map { "\($0.ats.rawValue):\($0.slug) \($0.name)" }.joined(separator: "\n")
    }
}

struct JobPosting: Codable, Equatable, Hashable, Identifiable {
    var company: String
    var title: String
    var location: String
    var remote: Bool
    var posted: Date?
    var url: String
    var source: String
    var id: String { url }
}
