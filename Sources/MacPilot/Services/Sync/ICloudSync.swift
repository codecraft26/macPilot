import AppKit
import Foundation
import Observation
import SwiftData

/// Syncs notes, tasks, meetings, chats, prompts and snippets between your Macs through iCloud Drive.
///
/// Each Mac writes only its own file (`iCloud Drive/MacPilot/Sync/<device>.json`) and reads the others,
/// so iCloud never has to resolve conflicting edits to one file. Newest change wins per item; deletions
/// travel as tombstones. Works with the ad-hoc signed app (CloudKit would need a paid developer team).
@Observable
@MainActor
final class ICloudSync {
    static let shared = ICloudSync()

    struct Device: Identifiable, Equatable {
        var id: String
        var name: String
        var updatedAt: Date
        var itemCount: Int
    }

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastSummary: String?
    private(set) var lastError: String?
    private(set) var devices: [Device] = []

    private var timer: Timer?
    private var saveObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var isApplying = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.iCloudSyncEnabled) }

    // MARK: Locations

    nonisolated static var iCloudDriveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    nonisolated static var isICloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudDriveRoot.path)
    }

    nonisolated static var folder: URL { iCloudDriveRoot.appendingPathComponent("MacPilot/Sync", isDirectory: true) }

    nonisolated static var deviceID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "sync.deviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "sync.deviceID")
        return id
    }

    nonisolated static var deviceName: String { Host.current().localizedName ?? "This Mac" }

    nonisolated static var stateURL: URL { Persistence.storeDirectory.appendingPathComponent("sync-state.json") }

    // MARK: Lifecycle

    func start() {
        stop()
        guard Self.isEnabled else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard !ICloudSync.shared.isApplying else { return }
                ICloudSync.shared.scheduleSync(after: 4)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ICloudSync.shared.scheduleSync(after: 10) }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in ICloudSync.shared.scheduleSync(after: 0) }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduleSync(after: 1)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        saveObserver = nil
        wakeObserver = nil
        pending?.cancel()
    }

    func scheduleSync(after seconds: Double) {
        guard Self.isEnabled else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            syncNow()
        }
    }

    /// Snapshot local data, merge the other Macs' files, then publish this Mac's file.
    func syncNow() {
        guard !isSyncing else { return }
        guard Self.isICloudDriveAvailable else {
            lastError = "iCloud Drive is off. Turn it on in System Settings → Apple Account → iCloud → iCloud Drive."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let summary = try performSync(context: Persistence.container.mainContext, folder: Self.folder, now: Date())
            lastSummary = summary
            lastError = nil
            lastSync = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Sync

    func performSync(context: ModelContext, folder: URL, now: Date,
                     deviceID: String = ICloudSync.deviceID, deviceName: String = ICloudSync.deviceName,
                     stateURL: URL = ICloudSync.stateURL) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var state = Self.loadState(stateURL)

        // 1. Note what changed here since last time.
        var snapshot = SyncSnapshot.take(context)
        SyncPlanner.stamp(snapshot.items, present: snapshot.present, state: &state, now: now)

        // 2. Read the other Macs and apply anything newer.
        let files = Self.readOtherDevices(in: folder, deviceID: deviceID)
        devices = files.map { Device(id: $0.deviceID, name: $0.deviceName, updatedAt: $0.updatedAt, itemCount: $0.records.filter { !$0.deleted }.count) }
            .sorted { $0.name < $1.name }
        let incoming = SyncPlanner.incoming(files.flatMap(\.records), state: state)
        var applied: [String: Date] = [:]
        var deletedKeys: [String: Date] = [:]
        var counts: [SyncKind: Int] = [:]
        isApplying = true
        defer { isApplying = false }
        for record in incoming {
            switch SyncApplier.apply(record, context: context) {
            case .updated:
                applied[record.key] = record.modifiedAt
                counts[record.kind, default: 0] += 1
            case .deleted:
                deletedKeys[record.key] = record.modifiedAt
                counts[record.kind, default: 0] += 1
            case .skipped:
                break
            }
        }
        if context.hasChanges { try context.save() }

        // 3. Remember what was applied with the other Mac's time, so it isn't sent back as a new edit.
        if !applied.isEmpty || !deletedKeys.isEmpty {
            snapshot = SyncSnapshot.take(context)
            let byKey = Dictionary(snapshot.items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            for (key, date) in applied {
                if let item = byKey[key] { state.entries[key] = .init(fingerprint: item.fingerprint, modifiedAt: date) }
                state.tombstones.removeValue(forKey: key)
            }
            for (key, date) in deletedKeys {
                state.entries.removeValue(forKey: key)
                state.tombstones[key] = date
            }
            SyncPlanner.stamp(snapshot.items, present: snapshot.present, state: &state, now: now)
        }

        // 4. Publish this Mac's file when it changed.
        let records = SyncPlanner.outgoing(snapshot.items, state: state, now: now)
        let recordsHash = SyncCodec.hash(SyncCodec.encode(records))
        let ownURL = folder.appendingPathComponent("\(deviceID).json")
        if recordsHash != state.lastWrittenHash || !FileManager.default.fileExists(atPath: ownURL.path) {
            let file = SyncFile(deviceID: deviceID, deviceName: deviceName, updatedAt: now, records: records)
            try Self.write(Data(SyncCodec.encode(file).utf8), to: ownURL)
            state.lastWrittenHash = recordsHash
        }
        state.tombstones = state.tombstones.filter { now.timeIntervalSince($0.value) < 90 * 86_400 }
        Self.saveState(state, to: stateURL)

        let parts = counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.label.lowercased())" }
        if files.isEmpty { return "Waiting for your other Mac — turn on sync there too." }
        return parts.isEmpty ? "Up to date with \(files.map(\.deviceName).joined(separator: ", "))." : "Received " + parts.joined(separator: ", ") + "."
    }

    /// Start over: forget sync history (items stay) so the next sync re-sends everything.
    func resetState() {
        try? FileManager.default.removeItem(at: Self.stateURL)
        scheduleSync(after: 0)
    }

    // MARK: Files

    private static func readOtherDevices(in folder: URL, deviceID: String) -> [SyncFile] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        var files: [SyncFile] = []
        for name in names {
            // Files iCloud hasn't downloaded yet show up as ".name.json.icloud".
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let real = folder.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                try? manager.startDownloadingUbiquitousItem(at: real)
                continue
            }
            guard name.hasSuffix(".json"), name != "\(deviceID).json" else { continue }
            let url = folder.appendingPathComponent(name)
            guard let data = read(url), let file = SyncCodec.decode(SyncFile.self, from: String(decoding: data, as: UTF8.self)),
                  file.version == 1, file.deviceID != deviceID else { continue }
            files.append(file)
        }
        return files
    }

    private static func read(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = try? Data(contentsOf: url)
        }
        return result
    }

    private static func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private static func loadState(_ stateURL: URL) -> SyncState {
        guard let data = try? Data(contentsOf: stateURL) else { return SyncState() }
        return SyncCodec.decode(SyncState.self, from: String(decoding: data, as: UTF8.self)) ?? SyncState()
    }

    private static func saveState(_ state: SyncState, to stateURL: URL) {
        try? Data(SyncCodec.encode(state).utf8).write(to: stateURL, options: .atomic)
    }
}

// MARK: - Snapshot

@MainActor
struct SyncSnapshot {
    var items: [LocalItem] = []
    /// Keys that exist but aren't sent yet (meetings still recording or transcribing).
    var present: Set<String> = []

    static func take(_ context: ModelContext) -> SyncSnapshot {
        var snapshot = SyncSnapshot()
        for note in (try? context.fetch(FetchDescriptor<Note>())) ?? [] {
            let dto = NoteDTO(title: note.title, body: note.body, folder: note.folder, tagsRaw: note.tagsRaw, isPinned: note.isPinned,
                              createdAt: note.createdAt, updatedAt: note.updatedAt, eventID: note.eventID, recordingID: note.recordingID)
            snapshot.items.append(LocalItem(kind: .note, id: note.uid, payload: SyncCodec.encode(dto), naturalDate: note.updatedAt))
        }
        for task in (try? context.fetch(FetchDescriptor<TaskItem>())) ?? [] {
            let dto = TaskDTO(title: task.title, notes: task.notes, dueDate: task.dueDate, priorityRaw: task.priorityRaw,
                              recurrenceRaw: task.recurrenceRaw, category: task.category, isCompleted: task.isCompleted,
                              completedAt: task.completedAt, createdAt: task.createdAt, reminderExternalID: task.reminderExternalID)
            snapshot.items.append(LocalItem(kind: .task, id: task.uid, payload: SyncCodec.encode(dto),
                                            naturalDate: max(task.createdAt, task.completedAt ?? .distantPast)))
        }
        for recording in (try? context.fetch(FetchDescriptor<Recording>())) ?? [] {
            if [.recording, .transcribing, .analyzing].contains(recording.status) {
                snapshot.present.insert(SyncKeys.key(.recording, recording.uid))
                continue
            }
            let dto = RecordingDTO(title: recording.title, kindRaw: recording.kindRaw, statusRaw: recording.statusRaw,
                                   startedAt: recording.startedAt, duration: recording.duration, calendarEventID: recording.calendarEventID,
                                   attendees: recording.attendees, prepNotes: recording.prepNotes, segments: recording.segments,
                                   s3Locations: recording.s3Locations, summary: recording.summary, decisions: recording.decisions,
                                   actionItems: recording.actionItems, deadlines: recording.deadlines, openQuestions: recording.openQuestions,
                                   followUpEmail: recording.followUpEmail, notice: recording.notice, errorMessage: recording.errorMessage,
                                   createdAt: recording.createdAt)
            snapshot.items.append(LocalItem(kind: .recording, id: recording.uid, payload: SyncCodec.encode(dto), naturalDate: recording.createdAt))
        }
        for conversation in (try? context.fetch(FetchDescriptor<Conversation>())) ?? [] {
            let messages = conversation.sortedMessages.map {
                ChatMessageDTO(uid: $0.uid, roleRaw: $0.roleRaw, content: $0.content, createdAt: $0.createdAt, providerRaw: $0.providerRaw, model: $0.model)
            }
            let dto = ConversationDTO(title: conversation.title, createdAt: conversation.createdAt, updatedAt: conversation.updatedAt,
                                      providerRaw: conversation.providerRaw, model: conversation.model,
                                      systemPrompt: conversation.systemPrompt, messages: messages)
            snapshot.items.append(LocalItem(kind: .conversation, id: conversation.uid, payload: SyncCodec.encode(dto), naturalDate: conversation.updatedAt))
        }
        for prompt in (try? context.fetch(FetchDescriptor<PromptTemplate>())) ?? [] {
            let dto = PromptDTO(title: prompt.title, body: prompt.body, category: prompt.category, createdAt: prompt.createdAt)
            snapshot.items.append(LocalItem(kind: .prompt, id: prompt.uid, payload: SyncCodec.encode(dto), naturalDate: prompt.createdAt))
        }
        let library = LibraryDTO(links: SnippetLibrary.shared.links, snippets: SnippetLibrary.shared.snippets)
        let isDefault = library.links == QuickLink.defaults && library.snippets == Snippet.defaults
        snapshot.items.append(LocalItem(kind: .library, id: SyncKeys.libraryID, payload: SyncCodec.encode(library),
                                        naturalDate: isDefault ? .distantPast : Date()))
        return snapshot
    }
}

// MARK: - Apply

@MainActor
enum SyncApplier {
    enum Outcome { case updated, deleted, skipped }

    static func apply(_ record: SyncRecord, context: ModelContext) -> Outcome {
        let id = record.id
        if record.deleted {
            return delete(record.kind, id: id, context: context) ? .deleted : .skipped
        }
        guard let payload = record.payload else { return .skipped }
        switch record.kind {
        case .note:
            guard let dto = SyncCodec.decode(NoteDTO.self, from: payload) else { return .skipped }
            let note = fetch(Note.self, #Predicate<Note> { $0.uid == id }, context) ?? insert(Note(), uid: id, context: context)
            note.title = dto.title; note.body = dto.body; note.folder = dto.folder; note.tagsRaw = dto.tagsRaw
            note.isPinned = dto.isPinned; note.createdAt = dto.createdAt; note.updatedAt = dto.updatedAt
            note.eventID = dto.eventID; note.recordingID = dto.recordingID

        case .task:
            guard let dto = SyncCodec.decode(TaskDTO.self, from: payload) else { return .skipped }
            var task = fetch(TaskItem.self, #Predicate<TaskItem> { $0.uid == id }, context)
            if task == nil, let external = dto.reminderExternalID {
                // The same reminder was imported separately on each Mac: keep one copy (the smaller id) everywhere.
                let duplicate = fetch(TaskItem.self, #Predicate<TaskItem> { $0.reminderExternalID == external }, context)
                if let duplicate {
                    guard id.uuidString < duplicate.uid.uuidString else { return .skipped }
                    context.delete(duplicate)
                }
            }
            if task == nil { task = insert(TaskItem(title: dto.title), uid: id, context: context) }
            guard let task else { return .skipped }
            task.title = dto.title; task.notes = dto.notes; task.dueDate = dto.dueDate; task.priorityRaw = dto.priorityRaw
            task.recurrenceRaw = dto.recurrenceRaw; task.category = dto.category; task.isCompleted = dto.isCompleted
            task.completedAt = dto.completedAt; task.createdAt = dto.createdAt
            if let external = dto.reminderExternalID { task.reminderExternalID = external }
            if task.isCompleted {
                NotificationService.cancel(id: task.notificationID)
            } else {
                NotificationService.schedule(id: task.notificationID, title: task.title, at: task.dueDate)
            }

        case .recording:
            guard let dto = SyncCodec.decode(RecordingDTO.self, from: payload) else { return .skipped }
            let existing = fetch(Recording.self, #Predicate<Recording> { $0.uid == id }, context)
            if let existing, [.recording, .transcribing, .analyzing].contains(existing.status) { return .skipped }
            let recording = existing ?? insert(Recording(kind: RecordingKind(rawValue: dto.kindRaw) ?? .meeting, title: dto.title), uid: id, context: context)
            recording.title = dto.title; recording.kindRaw = dto.kindRaw; recording.statusRaw = dto.statusRaw
            recording.startedAt = dto.startedAt; recording.duration = dto.duration; recording.calendarEventID = dto.calendarEventID
            recording.attendees = dto.attendees; recording.prepNotes = dto.prepNotes; recording.segments = dto.segments
            recording.s3Locations = dto.s3Locations; recording.summary = dto.summary; recording.decisions = dto.decisions
            recording.actionItems = dto.actionItems; recording.deadlines = dto.deadlines; recording.openQuestions = dto.openQuestions
            recording.followUpEmail = dto.followUpEmail; recording.notice = dto.notice; recording.errorMessage = dto.errorMessage
            recording.createdAt = dto.createdAt

        case .conversation:
            guard let dto = SyncCodec.decode(ConversationDTO.self, from: payload) else { return .skipped }
            let conversation = fetch(Conversation.self, #Predicate<Conversation> { $0.uid == id }, context)
                ?? insert(Conversation(provider: AIProviderID(rawValue: dto.providerRaw) ?? .anthropic, model: dto.model), uid: id, context: context)
            conversation.title = dto.title; conversation.createdAt = dto.createdAt; conversation.updatedAt = dto.updatedAt
            conversation.providerRaw = dto.providerRaw; conversation.model = dto.model; conversation.systemPrompt = dto.systemPrompt
            let current = conversation.sortedMessages.map {
                ChatMessageDTO(uid: $0.uid, roleRaw: $0.roleRaw, content: $0.content, createdAt: $0.createdAt, providerRaw: $0.providerRaw, model: $0.model)
            }
            if current != dto.messages {
                for message in conversation.messages { context.delete(message) }
                conversation.messages = []
                for item in dto.messages {
                    let message = ChatMessage(role: ChatRole(rawValue: item.roleRaw) ?? .user, content: item.content)
                    message.uid = item.uid; message.roleRaw = item.roleRaw; message.createdAt = item.createdAt
                    message.providerRaw = item.providerRaw; message.model = item.model
                    context.insert(message)
                    message.conversation = conversation
                }
            }

        case .prompt:
            guard let dto = SyncCodec.decode(PromptDTO.self, from: payload) else { return .skipped }
            var prompt = fetch(PromptTemplate.self, #Predicate<PromptTemplate> { $0.uid == id }, context)
            if prompt == nil {
                // Both Macs seeded the same starter prompts: keep one copy (the smaller id) everywhere.
                let title = dto.title, body = dto.body
                if let duplicate = fetch(PromptTemplate.self, #Predicate<PromptTemplate> { $0.title == title && $0.body == body }, context) {
                    guard id.uuidString < duplicate.uid.uuidString else { return .skipped }
                    context.delete(duplicate)
                }
                prompt = insert(PromptTemplate(title: dto.title, body: dto.body), uid: id, context: context)
            }
            guard let prompt else { return .skipped }
            prompt.title = dto.title; prompt.body = dto.body; prompt.category = dto.category; prompt.createdAt = dto.createdAt

        case .library:
            guard let dto = SyncCodec.decode(LibraryDTO.self, from: payload) else { return .skipped }
            if SnippetLibrary.shared.links != dto.links { SnippetLibrary.shared.links = dto.links }
            if SnippetLibrary.shared.snippets != dto.snippets { SnippetLibrary.shared.snippets = dto.snippets }
        }
        return .updated
    }

    private static func delete(_ kind: SyncKind, id: UUID, context: ModelContext) -> Bool {
        switch kind {
        case .note:
            guard let note = fetch(Note.self, #Predicate<Note> { $0.uid == id }, context) else { return false }
            context.delete(note)
        case .task:
            guard let task = fetch(TaskItem.self, #Predicate<TaskItem> { $0.uid == id }, context) else { return false }
            NotificationService.cancel(id: task.notificationID)
            context.delete(task)
        case .recording:
            guard let recording = fetch(Recording.self, #Predicate<Recording> { $0.uid == id }, context) else { return false }
            // Local audio/video only; the Mac that deleted it cleans up S3.
            try? FileManager.default.removeItem(at: RecordingStorage.root.appendingPathComponent(id.uuidString))
            context.delete(recording)
        case .conversation:
            guard let conversation = fetch(Conversation.self, #Predicate<Conversation> { $0.uid == id }, context) else { return false }
            context.delete(conversation)
        case .prompt:
            guard let prompt = fetch(PromptTemplate.self, #Predicate<PromptTemplate> { $0.uid == id }, context) else { return false }
            context.delete(prompt)
        case .library:
            return false
        }
        return true
    }

    private static func fetch<T: PersistentModel>(_ type: T.Type, _ predicate: Predicate<T>, _ context: ModelContext) -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func insert<T: PersistentModel>(_ model: T, uid: UUID, context: ModelContext) -> T {
        (model as? Note)?.uid = uid
        (model as? TaskItem)?.uid = uid
        (model as? Recording)?.uid = uid
        (model as? Conversation)?.uid = uid
        (model as? PromptTemplate)?.uid = uid
        context.insert(model)
        return model
    }
}
