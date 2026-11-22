import Foundation
import Observation
import SwiftData

/// Runs scheduled jobs while MacPilot is open. Each run is an agent task (channel "schedule") under the
/// usual budgets, kill switch and local-only mode. After a launch, each missed job runs once — never a burst.
@Observable
@MainActor
final class JobScheduler {
    static let shared = JobScheduler(engine: .shared)

    let engine: AgentEngine
    var now: () -> Date = Date.init
    /// Called when a run finishes (Telegram notifications).
    var onRunFinished: ((AgentJob, JobRun) -> Void)?
    private var timer: Timer?
    private var observerID: UUID?
    private(set) var revision = 0

    init(engine: AgentEngine) {
        self.engine = engine
    }

    private var context: ModelContext { engine.context }

    func start() {
        attachObserver()
        catchUp()
        timer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { JobScheduler.shared.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func attachObserver() {
        guard observerID == nil else { return }
        observerID = engine.addObserver { [weak self] update in
            if case .taskChanged(let id) = update { self?.taskChanged(id) }
        }
    }

    var jobs: [AgentJob] {
        (try? context.fetch(FetchDescriptor<AgentJob>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func runs(of jobID: UUID, limit: Int = 20) -> [JobRun] {
        var descriptor = FetchDescriptor<JobRun>(predicate: #Predicate { $0.jobID == jobID }, sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// At launch: every enabled job whose time passed while MacPilot was closed runs once.
    func catchUp() {
        for job in jobs { apply(job, reason: "missed while MacPilot was closed") }
        save()
    }

    func tick() {
        for job in jobs { apply(job, reason: "scheduled") }
        save()
    }

    private func apply(_ job: AgentJob, reason: String) {
        let plan = JobTiming.plan(nextRun: job.nextRun, schedule: job.schedule, enabled: job.enabled, now: now())
        job.nextRun = plan.nextRun
        if plan.run { run(job, reason: reason) }
    }

    // MARK: Controls

    @discardableResult
    func add(_ job: AgentJob) -> AgentJob {
        job.nextRun = job.schedule.next(after: now())
        context.insert(job)
        engine.audit("Job “\(job.name)” created (\(job.schedule.summary))")
        save()
        return job
    }

    /// After editing: recompute the next run; a changed recipient or sender voids the send approval.
    func updated(_ job: AgentJob) {
        if !JobSendApproval.isApproved(job) { JobSendApproval.revoke(job) }
        job.nextRun = job.enabled ? job.schedule.next(after: now()) : nil
        engine.audit("Job “\(job.name)” edited")
        save()
    }

    func setEnabled(_ job: AgentJob, _ enabled: Bool) {
        job.enabled = enabled
        job.nextRun = enabled ? job.schedule.next(after: now()) : nil
        engine.audit("Job “\(job.name)” \(enabled ? "resumed" : "paused")")
        save()
    }

    func approveSending(_ job: AgentJob, via: String = "the app") {
        JobSendApproval.approve(job, now: now())
        engine.audit("Job “\(job.name)”: email to \(job.recipient) via \(job.sender == .gmail ? "Gmail (\(job.senderAccount))" : "Mail") approved in \(via)")
        save()
    }

    func delete(_ job: AgentJob) {
        let id = job.uid
        for run in runs(of: id, limit: 10_000) { context.delete(run) }
        engine.audit("Job “\(job.name)” deleted")
        context.delete(job)
        save()
    }

    /// Starts a run now (manual or scheduled). Refused while the kill switch is on.
    @discardableResult
    func run(_ job: AgentJob, reason: String = "run now") -> JobRun? {
        guard !engine.isHalted else {
            engine.audit("Job “\(job.name)” skipped: the kill switch is on", kind: .policy)
            return nil
        }
        let run = JobRun(jobID: job.uid)
        run.startedAt = now()
        context.insert(run)
        job.lastRun = now()
        var tools = AgentTools.jobToolNames
        if !job.wantsEmail { tools.remove("send_email") }
        let task: AgentTask
        switch job.template {
        case .custom:
            task = engine.submit("\(job.prompt)\n\n(Scheduled job “\(job.name)”, \(reason).)", channel: "schedule", jobID: job.uid, allowedTools: tools)
        case .jobFinder:
            let jobID = job.uid, runID = run.uid
            task = engine.submit("Job finder: \(job.name)", channel: "schedule", jobID: job.uid, allowedTools: tools) { [weak self] context in
                guard let self, let job = self.engine.fetchJob(jobID), let run = self.fetchRun(runID) else { return "The job was deleted." }
                return try await JobFinderRunner.run(job: job, run: run, context: context)
            }
        }
        run.taskID = task.uid
        save()
        return run
    }

    private func fetchRun(_ id: UUID) -> JobRun? {
        var descriptor = FetchDescriptor<JobRun>(predicate: #Predicate { $0.uid == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func taskChanged(_ taskID: UUID) {
        guard let task = engine.fetchTask(taskID), task.state.isFinished, let jobID = task.jobID, let job = engine.fetchJob(jobID) else { return }
        guard let run = runs(of: jobID, limit: 50).first(where: { $0.taskID == taskID }), run.finishedAt == nil else { return }
        run.finishedAt = now()
        run.statusRaw = task.state.rawValue
        run.summary = String((task.state == .done ? task.finalAnswer : (task.errorMessage ?? task.state.label)).prefix(2_000))
        run.emailed = engine.fetchActions(taskID: taskID).contains { $0.tool == "send_email" && $0.state == .succeeded }
        save()
        onRunFinished?(job, run)
    }

    private func save() {
        try? context.save()
        revision += 1
    }

    // MARK: Approval sample

    /// What the user approves once: the exact recipient, sender, schedule and a rendered sample.
    static func sampleEmail(for job: AgentJob) -> OutgoingEmail {
        switch job.template {
        case .jobFinder:
            let email = JobFinder.email(jobName: job.name, postings: JobFinder.samplePostings)
            return OutgoingEmail(to: job.recipient, subject: email.subject, text: "(Sample with example postings)\n\n" + email.text, html: email.html)
        case .custom:
            return OutgoingEmail(to: job.recipient, subject: "\(job.name) — \(Date().formatted(date: .abbreviated, time: .omitted))",
                                 text: "(Sample) The agent writes a short summary of what it found for:\n“\(job.prompt)”\n\nChanges since the last run are listed, for example: price changed from $399 to $349.",
                                 html: nil)
        }
    }
}

/// The job finder pipeline: public job-board APIs, RSS and the user's own alert emails → filter → dedupe → email.
@MainActor
enum JobFinderRunner {
    static let emailLimit = 100

    static func run(job: AgentJob, run: JobRun, context: AgentNativeContext) async throws -> String {
        let config = job.finder
        let web = context.engine.web
        var postings: [JobPosting] = []
        var problems: [String] = []

        for company in config.companies {
            try context.checkStop()
            guard let url = JobSources.apiURL(company) else { continue }
            do {
                // Documented public JSON APIs (not crawled pages); still rate-limited per host with MacPilot's User-Agent.
                let (data, _) = try await web.get(url, robotsCheck: false)
                postings += JobSources.parse(data, source: company)
            } catch {
                problems.append("\(company.name): \(error.localizedDescription)")
            }
        }
        for feed in config.rssFeeds {
            try context.checkStop()
            guard let url = URL(string: feed.trimmingCharacters(in: .whitespaces)) else { continue }
            do {
                let (data, _) = try await web.get(url)
                postings += JobSources.feed(data, defaultCompany: url.host ?? "")
            } catch {
                problems.append("\(url.host ?? feed): \(error.localizedDescription)")
            }
        }
        if config.readAlertEmails {
            do {
                for mail in try await context.engine.email.alertEmails(via: config.alertSource, account: job.senderAccount, days: 3) {
                    postings += JobSources.alertEmail(mail.body, received: mail.received)
                }
            } catch {
                problems.append("Alert emails: \(error.localizedDescription)")
            }
        }

        let matching = postings.filter { JobFinder.matches($0, config: config, now: context.engine.now()) }
        let (fresh, seen) = JobFinder.newPostings(matching, seen: job.seenKeys)
        job.seenKeys = seen
        run.results = fresh
        run.newCount = fresh.count
        context.log("Job finder: \(postings.count) postings checked, \(matching.count) match, \(fresh.count) new")

        if !fresh.isEmpty, job.wantsEmail {
            let shown = Array(fresh.prefix(emailLimit))
            var email = JobFinder.email(jobName: job.name, postings: shown)
            if fresh.count > shown.count { email.text += "\n…and \(fresh.count - shown.count) more in MacPilot → Agent → Jobs.\n" }
            let result = try await context.tool("send_email", ["to": job.recipient, "subject": email.subject, "body": email.text, "html": email.html])
            if result.isError { problems.append("Email: \(result.content)") }
        }
        var summary = fresh.isEmpty ? "No new postings." : "\(fresh.count) new posting\(fresh.count == 1 ? "" : "s"): " +
            Dictionary(grouping: fresh, by: \.company).map { "\($0.key) (\($0.value.count))" }.sorted().prefix(10).joined(separator: ", ")
        if !problems.isEmpty { summary += "\nSkipped: " + problems.prefix(5).joined(separator: "; ") }
        return summary
    }
}
