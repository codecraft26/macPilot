import SwiftData
import SwiftUI

/// Agent → Jobs: scheduled jobs with pause, resume, run now, edit and delete, run history and job-finder results.
struct JobsView: View {
    @Query(sort: \AgentJob.createdAt) private var jobs: [AgentJob]
    @State private var editing: AgentJob?
    @State private var creating = false
    @State private var approving: AgentJob?
    @State private var deleting: AgentJob?
    private let scheduler = JobScheduler.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scheduled jobs").font(.title2.bold())
                Spacer()
                Menu {
                    Button("Job finder…") { creating = true; templateForNew = .jobFinder }
                    Button("Custom agent job…") { creating = true; templateForNew = .custom }
                } label: { Label("New job", systemImage: "plus") }
                .fixedSize()
            }
            .padding(DS.Space.m)
            Divider()
            if jobs.isEmpty {
                EmptyStateView(systemImage: "calendar.badge.clock", title: "No jobs yet",
                               message: "A job runs the agent on a schedule — for example a daily job finder that emails you new iOS roles, or a price watch.",
                               actionTitle: "New job finder", action: { creating = true; templateForNew = .jobFinder })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: DS.Space.s) {
                        ForEach(jobs) { job in
                            JobRow(job: job, edit: { editing = job }, approve: { approving = job }, delete: { deleting = job })
                        }
                    }
                    .padding(DS.Space.m)
                }
            }
        }
        .sheet(isPresented: $creating) {
            JobEditor(job: nil, template: templateForNew) { saved in
                creating = false
                if let saved, saved.wantsEmail { approving = saved }
            }
        }
        .sheet(item: $editing) { job in
            JobEditor(job: job, template: job.template) { saved in
                editing = nil
                if let saved, saved.wantsEmail, !JobSendApproval.isApproved(saved) { approving = saved }
            }
        }
        .sheet(item: $approving) { job in JobApprovalSheet(job: job) { approving = nil } }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete job", role: .destructive) { if let job = deleting { scheduler.delete(job) }; deleting = nil }
        } message: { Text("Its run history and remembered results are removed.") }
    }

    @State private var templateForNew: JobTemplate = .jobFinder
}

private struct JobRow: View {
    let job: AgentJob
    var edit: () -> Void
    var approve: () -> Void
    var delete: () -> Void
    @State private var expanded = false
    private let scheduler = JobScheduler.shared

    var body: some View {
        let _ = scheduler.revision
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                IconTile(systemImage: job.template == .jobFinder ? "briefcase.fill" : "clock.arrow.2.circlepath",
                         color: job.enabled ? .mint : .gray, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).font(.headline)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if job.wantsEmail && !JobSendApproval.isApproved(job) {
                    Button("Approve email…", action: approve).tint(.orange)
                }
                Button { scheduler.run(job) } label: { Label("Run now", systemImage: "play.fill") }
                    .disabled(AgentEngine.shared.isHalted)
                Button(job.enabled ? "Pause" : "Resume") { scheduler.setEnabled(job, !job.enabled) }
                Menu {
                    Button("Edit…", action: edit)
                    Button("Delete…", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? "Hide history" : "Show history")
            }
            if expanded { history }
        }
        .padding(DS.Space.s)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.hairline))
    }

    private var details: String {
        var parts = [job.schedule.summary + " (\(job.schedule.timeZone.identifier))"]
        if !job.enabled { parts.append("Paused") } else if let next = job.nextRun { parts.append("Next: \(next.formatted(date: .abbreviated, time: .shortened))") }
        if let last = job.lastRun { parts.append("Last: \(last.formatted(date: .abbreviated, time: .shortened))") }
        if job.wantsEmail { parts.append("Emails \(job.recipient) via \(job.sender == .gmail ? job.senderAccount : "Mail")" + (JobSendApproval.isApproved(job) ? "" : " (not approved)")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var history: some View {
        let runs = scheduler.runs(of: job.uid)
        if runs.isEmpty {
            Text("No runs yet.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(runs) { run in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption.monospacedDigit())
                    Text(AgentTaskState(rawValue: run.statusRaw)?.label ?? "Running").font(.caption.weight(.semibold))
                    if run.emailed { Label("Emailed", systemImage: "envelope.fill").font(.caption).foregroundStyle(.green) }
                    Spacer()
                    if let taskID = run.taskID {
                        Button("Timeline") { AppState.shared.selectedSection = .agent; AgentTabState.shared.show(taskID) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                if !run.summary.isEmpty { Text(run.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                let results = run.results
                if !results.isEmpty {
                    ForEach(results.prefix(25)) { posting in
                        HStack(spacing: 6) {
                            Text(posting.company).font(.caption.weight(.semibold))
                            Link(posting.title, destination: URL(string: posting.url) ?? URL(string: "https://example.com")!).font(.caption)
                            Text(posting.location).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if results.count > 25 { Text("+\(results.count - 25) more").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .padding(.leading, 34)
        }
    }
}

/// Which tab the Agent section shows and which task to open (for links from Jobs and Telegram).
@Observable
@MainActor
final class AgentTabState {
    static let shared = AgentTabState()
    var tab = "Tasks"
    var focusTaskID: UUID?
    /// Words from ⌥K to put in the Reminders box.
    var pendingReminder: String?

    func show(_ taskID: UUID) {
        tab = "Tasks"
        focusTaskID = taskID
    }
}

// MARK: - Editor

private struct JobEditor: View {
    let job: AgentJob?
    let template: JobTemplate
    var done: (AgentJob?) -> Void

    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = JobSchedule()
    @State private var recipient = ""
    @State private var sender: EmailSenderKind = .mailApp
    @State private var account = ""
    @State private var notifyTelegram = false
    @State private var finder = JobFinderConfig()
    @State private var keywords = ""
    @State private var exclude = ""
    @State private var companies = ""
    @State private var feeds = ""
    @State private var error: String?
    private let google = GoogleCalendarService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(job == nil ? "New \(template == .jobFinder ? "job finder" : "job")" : "Edit job").font(.title2.bold()).padding(DS.Space.m)
            Form {
                Section("Job") {
                    TextField("Name", text: $name)
                    if template == .custom {
                        TextField("What should the agent do each time?", text: $prompt, axis: .vertical).lineLimit(3...8)
                        Text("Scheduled jobs can only search the web, read pages, extract data, compare with the last run and email you. They can't touch files or run commands.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Schedule") {
                    Picker("Repeat", selection: $schedule.kind) { ForEach(JobSchedule.Kind.allCases) { Text($0.label).tag($0) } }
                    switch schedule.kind {
                    case .daily, .weekly:
                        if schedule.kind == .weekly {
                            HStack {
                                ForEach(1...7, id: \.self) { day in
                                    Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                                        get: { schedule.weekdays.contains(day) },
                                        set: { if $0 { schedule.weekdays.insert(day) } else { schedule.weekdays.remove(day) } }))
                                    .toggleStyle(.button)
                                }
                            }
                        }
                        DatePicker("Time", selection: Binding(get: { timeDate }, set: { setTime($0) }), displayedComponents: .hourAndMinute)
                    case .everyHours:
                        Stepper("Every \(schedule.intervalHours) hour\(schedule.intervalHours == 1 ? "" : "s")", value: $schedule.intervalHours, in: 1...24)
                    case .cron:
                        TextField("minute hour day month weekday", text: $schedule.cron).font(.body.monospaced())
                        if CronExpression(schedule.cron) == nil { Text("Not a valid cron expression.").font(.caption).foregroundStyle(.red) }
                    }
                    Picker("Time zone", selection: $schedule.timeZoneID) {
                        ForEach(Array(Set([TimeZone.current.identifier, schedule.timeZoneID] + TimeZone.knownTimeZoneIdentifiers)).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    if let next = schedule.next(after: Date()) {
                        Text("Next run: \(next.formatted(date: .complete, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if template == .jobFinder { finderSection }
                Section("Delivery") {
                    Picker("Send with", selection: $sender) { ForEach(EmailSenderKind.allCases) { Text($0.label).tag($0) } }
                    if sender != .none {
                        TextField("Email to (one address you type)", text: $recipient)
                        if !recipient.isEmpty && EmailAddress.normalize(recipient) == nil {
                            Text("Enter one plain email address.").font(.caption).foregroundStyle(.red)
                        }
                    }
                    if sender == .gmail {
                        Picker("Gmail account", selection: $account) {
                            Text("Choose…").tag("")
                            ForEach(google.accounts, id: \.self) { Text($0).tag($0) }
                        }
                        if google.accounts.isEmpty {
                            Text("Connect a Google account in Settings → Recording & Calendar first.").font(.caption).foregroundStyle(.orange)
                        } else if !account.isEmpty && !google.hasScope(GoogleCalendarService.gmailSendScope, account: account) {
                            Button("Allow Gmail to send for \(account)…") { Task { await google.requestScope(GoogleCalendarService.gmailSendScope, account: account) } }
                        }
                    }
                    Toggle("Also post results to Telegram", isOn: $notifyTelegram)
                    Text("You'll see the exact recipient, sender and a sample email, and approve it once. Changing the recipient or sender needs a new approval.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(job == nil ? "Create" : "Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.m)
        }
        .frame(width: 620, height: 720)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var finderSection: some View {
        Section("Job finder") {
            TextField("Role keywords (comma separated)", text: $keywords)
            TextField("Location (city or country; empty = anywhere)", text: $finder.location)
            Toggle("Include remote roles", isOn: $finder.includeRemote)
            Toggle("Remote only", isOn: $finder.remoteOnly)
            Picker("Experience", selection: $finder.level) { ForEach(ExperienceLevel.allCases) { Text($0.label).tag($0) } }
            TextField("Exclude words (comma separated)", text: $exclude)
            Stepper("Only postings from the last \(finder.maxAgeDays) days", value: $finder.maxAgeDays, in: 1...365)
        }
        Section {
            TextEditor(text: $companies).font(.caption.monospaced()).frame(height: 140)
            Text("One per line: greenhouse:slug, lever:slug or ashby:slug, then the name — from the company's careers URL (boards.greenhouse.io/slug, jobs.lever.co/slug, jobs.ashbyhq.com/slug).")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Companies (public job-board APIs)") }
        Section("Feeds and alerts") {
            TextEditor(text: $feeds).font(.caption.monospaced()).frame(height: 50)
            Text("RSS or Atom feed URLs, one per line.").font(.caption).foregroundStyle(.secondary)
            Toggle("Read my LinkedIn and Indeed job-alert emails", isOn: $finder.readAlertEmails)
            if finder.readAlertEmails {
                Picker("From", selection: $finder.alertSource) {
                    Text("Mail app").tag(EmailSenderKind.mailApp)
                    Text("Gmail (account above)").tag(EmailSenderKind.gmail)
                }
                if finder.alertSource == .gmail, !account.isEmpty, !google.hasScope(GoogleCalendarService.gmailReadScope, account: account) {
                    Button("Allow Gmail to read alert emails for \(account)…") { Task { await google.requestScope(GoogleCalendarService.gmailReadScope, account: account) } }
                }
                Text("Only your own alert emails are read. MacPilot never scrapes the LinkedIn or Indeed websites.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var timeDate: Date {
        Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
    }

    private func setTime(_ date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        schedule.hour = parts.hour ?? 9
        schedule.minute = parts.minute ?? 0
    }

    private func load() {
        guard let job else {
            name = template == .jobFinder ? "iOS jobs" : "Daily check"
            keywords = finder.keywords.joined(separator: ", ")
            exclude = finder.excludeWords.joined(separator: ", ")
            companies = JobFinderConfig.formatCompanies(finder.companies)
            return
        }
        name = job.name
        prompt = job.prompt
        schedule = job.schedule
        recipient = job.recipient
        sender = job.sender
        account = job.senderAccount
        notifyTelegram = job.notifyTelegram
        finder = job.finder
        keywords = finder.keywords.joined(separator: ", ")
        exclude = finder.excludeWords.joined(separator: ", ")
        companies = JobFinderConfig.formatCompanies(finder.companies)
        feeds = finder.rssFeeds.joined(separator: "\n")
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { error = "Give the job a name."; return }
        if template == .custom && prompt.trimmingCharacters(in: .whitespaces).isEmpty { error = "Describe what the job should do."; return }
        if schedule.kind == .cron && CronExpression(schedule.cron) == nil { error = "Fix the cron expression."; return }
        if schedule.kind == .weekly && schedule.weekdays.isEmpty { error = "Pick at least one day."; return }
        if sender != .none && EmailAddress.normalize(recipient) == nil { error = "Enter the email address to send to."; return }
        if sender == .gmail && account.isEmpty { error = "Choose the Gmail account that sends."; return }
        let target = job ?? AgentJob(name: name, template: template)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.prompt = prompt
        target.schedule = schedule
        target.recipient = sender == .none ? "" : (EmailAddress.normalize(recipient) ?? "")
        target.sender = sender
        target.senderAccount = sender == .gmail ? account : ""
        target.notifyTelegram = notifyTelegram
        var config = finder
        config.keywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        config.excludeWords = exclude.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        config.companies = JobFinderConfig.parseCompanies(companies)
        config.rssFeeds = feeds.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        target.finder = config
        if job == nil { JobScheduler.shared.add(target) } else { JobScheduler.shared.updated(target) }
        done(target)
    }
}

/// Shows exactly who gets what, from which account, on which schedule — approved once per job.
struct JobApprovalSheet: View {
    let job: AgentJob
    var done: () -> Void

    var body: some View {
        let sample = JobScheduler.sampleEmail(for: job)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Label("Approve this job's email", systemImage: "envelope.badge.shield.half.filled").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("To").foregroundStyle(.secondary); Text(job.recipient).font(.body.monospaced()).textSelection(.enabled) }
                GridRow { Text("From").foregroundStyle(.secondary); Text(job.sender == .gmail ? "Gmail · \(job.senderAccount)" : "Mail app (default account)") }
                GridRow { Text("When").foregroundStyle(.secondary); Text("\(job.schedule.summary), \(job.schedule.timeZone.identifier)") }
                GridRow { Text("Subject").foregroundStyle(.secondary); Text(sample.subject) }
            }
            Text("Sample").font(.headline)
            ScrollView {
                Text(sample.text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            Text("After you approve, this job may email only \(job.recipient), only from this sender, without asking each time. Every email is written to the audit log. Changing the recipient or sender needs a new approval.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now", action: done).keyboardShortcut(.cancelAction)
                Button("Approve sending") {
                    JobScheduler.shared.approveSending(job)
                    done()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 560, height: 560)
    }
}
