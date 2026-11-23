import Foundation
import Observation

/// What kind of reclaimable developer files an item is.
enum CleanupCategory: String, CaseIterable, Codable, Identifiable {
    case nodeModules, derivedData, archives, deviceSupport, simulatorCaches, unavailableSimulators
    case dockerImages, dockerContainers, dockerBuildCache
    case npmCache, yarnCache, pnpmStore, pipCache, homebrew, cocoapods, gradle
    case swiftBuild, pythonVenv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nodeModules: return "node_modules"
        case .derivedData: return "Xcode DerivedData"
        case .archives: return "Xcode Archives"
        case .deviceSupport: return "iOS DeviceSupport"
        case .simulatorCaches: return "Simulator caches"
        case .unavailableSimulators: return "Unavailable simulators"
        case .dockerImages: return "Docker dangling images"
        case .dockerContainers: return "Docker stopped containers"
        case .dockerBuildCache: return "Docker build cache"
        case .npmCache: return "npm cache"
        case .yarnCache: return "Yarn cache"
        case .pnpmStore: return "pnpm store"
        case .pipCache: return "pip cache"
        case .homebrew: return "Homebrew cleanup"
        case .cocoapods: return "CocoaPods cache"
        case .gradle: return "Gradle caches"
        case .swiftBuild: return "Swift .build folders"
        case .pythonVenv: return "Python virtualenvs"
        }
    }

    var systemImage: String {
        switch self {
        case .nodeModules: return "shippingbox"
        case .derivedData, .archives, .deviceSupport, .simulatorCaches, .unavailableSimulators: return "hammer"
        case .dockerImages, .dockerContainers, .dockerBuildCache: return "cube.box"
        case .swiftBuild: return "swift"
        case .pythonVenv: return "chevron.left.forwardslash.chevron.right"
        default: return "archivebox"
        }
    }

    /// Regenerated automatically: may be deleted permanently (after a second confirmation).
    var isCache: Bool {
        switch self {
        case .derivedData, .simulatorCaches, .deviceSupport, .npmCache, .yarnCache, .pnpmStore, .pipCache, .cocoapods, .gradle,
             .dockerImages, .dockerContainers, .dockerBuildCache, .homebrew, .unavailableSimulators: return true
        case .nodeModules, .archives, .swiftBuild, .pythonVenv: return false
        }
    }

    /// Cleaned by a command (shown exactly before it runs) instead of moving files.
    var isCommand: Bool { [.unavailableSimulators, .dockerImages, .dockerContainers, .dockerBuildCache, .homebrew].contains(self) }
}

struct CleanupItem: Identifiable, Equatable, Hashable {
    var category: CleanupCategory
    var title: String
    var detail: String = ""
    var url: URL?
    var bytes: Int64
    /// The project's (or the folder's) last change.
    var modified: Date?
    /// For command items: the exact command line.
    var command: [String] = []
    /// node_modules of a project changed in the last 7 days: never selected unless picked explicitly.
    var isRecent = false

    var id: String { url?.path ?? (category.rawValue + ":" + command.joined(separator: " ")) }
    var commandLine: String { command.joined(separator: " ") }
}

enum CleanupFormat {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

/// Pure rules: aggregation, age filter, the recent-project skip and what a selection may do.
enum CleanupRules {
    static let recentProjectDays: Double = 7

    static func total(_ items: [CleanupItem]) -> Int64 { items.reduce(0) { $0 + $1.bytes } }

    static func byCategory(_ items: [CleanupItem]) -> [(CleanupCategory, Int64, [CleanupItem])] {
        Dictionary(grouping: items, by: \.category).map { ($0.key, total($0.value), $0.value) }.sorted { $0.1 > $1.1 }
    }

    /// "Not touched in N days" (items without a date are kept).
    static func untouched(_ items: [CleanupItem], days: Int, now: Date = Date()) -> [CleanupItem] {
        guard days > 0 else { return items }
        return items.filter { item in item.modified.map { now.timeIntervalSince($0) >= Double(days) * 86_400 } ?? true }
    }

    static func isRecent(_ modified: Date?, now: Date = Date()) -> Bool {
        modified.map { now.timeIntervalSince($0) < recentProjectDays * 86_400 } ?? false
    }

    /// Select all: everything except recent projects' node_modules.
    static func selectAll(_ items: [CleanupItem]) -> Set<String> {
        Set(items.filter { !$0.isRecent }.map(\.id))
    }

    /// Permanent delete is offered only when every selected item is a cache.
    static func canDeletePermanently(_ items: [CleanupItem]) -> Bool {
        !items.isEmpty && items.allSatisfy(\.category.isCache)
    }

    /// ⌥K phrases: "clean up developer files", "how much can I free?", "free space", "node_modules"…
    static func isLauncherQuery(_ text: String) -> Bool {
        let q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 4 else { return false }
        let phrases = ["clean up developer", "cleanup developer", "developer cleanup", "clean up dev", "how much can i free", "free space", "free up",
                       "reclaim", "node_modules", "deriveddata", "disk space", "dev cleanup", "clean caches"]
        return phrases.contains { q.contains($0) } || "clean up developer files".hasPrefix(q) || "how much can i free?".hasPrefix(q)
    }

    static func confirmation(_ items: [CleanupItem], permanent: Bool) -> String {
        let files = items.filter { !$0.category.isCommand }
        let commands = items.filter(\.category.isCommand)
        var text = "\(items.count) item\(items.count == 1 ? "" : "s"), \(CleanupFormat.bytes(total(items)))."
        if !files.isEmpty { text += permanent ? " Files are deleted permanently." : " Files go to the Trash." }
        if !commands.isEmpty { text += "\nCommands that will run:\n" + commands.map { "  " + $0.commandLine }.joined(separator: "\n") }
        return text
    }
}

/// Never delete outside the scanned roots and known cache folders; never follow a link out of them.
struct CleanupGuard {
    var roots: [URL]
    var cachePaths: [URL]

    enum Refusal: Error, Equatable { case symlink(String), outside(String), missing(String) }

    func check(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else { throw Refusal.missing(path.path) }
        if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Refusal.symlink(path.path) }
        let resolved = WorkspaceGuard.canonical(path)
        // Strictly inside a scanned root (never the root itself); a known cache folder may be removed whole.
        let insideRoot = roots.map { WorkspaceGuard.canonical($0) }.contains { WorkspaceGuard.isInside(resolved, root: $0) && resolved.pathComponents != $0.pathComponents }
        let inCache = cachePaths.map { WorkspaceGuard.canonical($0) }.contains { WorkspaceGuard.isInside(resolved, root: $0) }
        guard insideRoot || inCache else {
            // Lexically inside but resolved elsewhere means a link somewhere along the path.
            if (roots + cachePaths).contains(where: { WorkspaceGuard.isInside(path, root: $0.standardizedFileURL) }) { throw Refusal.symlink(path.path) }
            throw Refusal.outside(path.path)
        }
        return resolved
    }
}

/// Exact commands for the CLI cleanups (shown before running; tested as strings).
enum CleanupCommands {
    static let simctlDeleteUnavailable = ["xcrun", "simctl", "delete", "unavailable"]
    static let dockerImagePrune = ["docker", "image", "prune", "-f"]
    static let dockerContainerPrune = ["docker", "container", "prune", "-f"]
    static let dockerBuilderPrune = ["docker", "builder", "prune", "-f"]
    static let brewCleanup = ["brew", "cleanup"]
    static let brewPreview = ["brew", "cleanup", "-n"]
    static let dockerDF = ["docker", "system", "df", "--format", "{{json .}}"]
    static let searchPath = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Applications/Docker.app/Contents/Resources/bin"]

    static func executable(_ name: String) -> String? {
        searchPath.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// "1.234GB" / "512MB" / "0B" → bytes.
    static func parseSize(_ text: String) -> Int64 {
        let cleaned = text.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        guard let range = cleaned.range(of: #"^[0-9.]+"#, options: .regularExpression), let number = Double(cleaned[range]) else { return 0 }
        let unit = cleaned[range.upperBound...].uppercased()
        let scale: Double = unit.hasPrefix("T") ? 1e12 : unit.hasPrefix("G") ? 1e9 : unit.hasPrefix("M") ? 1e6 : unit.hasPrefix("K") ? 1e3 : 1
        return Int64(number * scale)
    }

    /// `docker system df --format '{{json .}}'` → reclaimable bytes per type.
    static func parseDockerDF(_ output: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let type = object["Type"] as? String else { continue }
            result[type] = parseSize(object["Reclaimable"] as? String ?? "0B")
        }
        return result
    }

    /// `brew cleanup -n` ends with "This operation would free approximately 1.2GB of disk space."
    static func parseBrewPreview(_ output: String) -> Int64 {
        guard let range = output.range(of: #"approximately\s+[0-9.]+\s*[KMGT]?B"#, options: .regularExpression) else { return 0 }
        return parseSize(String(output[range]).replacingOccurrences(of: "approximately", with: "").replacingOccurrences(of: " ", with: ""))
    }
}

/// Finds reclaimable developer files. Runs off the main thread at low priority and can be cancelled.
struct CleanupScanner {
    var home = URL(fileURLWithPath: NSHomeDirectory())
    var roots: [URL]
    var includeSwiftBuild = false
    var includeVenvs = false
    var archiveAgeDays = 90
    var runCommand: (String, [String]) async -> String? = { executable, arguments in
        let result = await Shell.run(executable, arguments, timeout: 60)
        return result.ok ? result.stdout : nil
    }

    static let defaultRoots = ["Developer", "Projects", "Code", "Documents"]
    static let skipNames: Set<String> = [".git", "Library", ".Trash", "Pods", ".build", "DerivedData", "venv", ".venv"]

    var knownCachePaths: [URL] {
        ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives", "Library/Developer/Xcode/iOS DeviceSupport",
         "Library/Developer/CoreSimulator/Caches", ".npm/_cacache", "Library/Caches/Yarn", "Library/pnpm/store", "Library/Caches/pip",
         "Library/Caches/CocoaPods", ".gradle/caches"].map { home.appendingPathComponent($0) }
    }

    func scan(now: Date = Date(), progress: @escaping @Sendable (String) -> Void = { _ in }) async -> [CleanupItem] {
        var items: [CleanupItem] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            if Task.isCancelled { return items }
            progress("Scanning \(root.lastPathComponent)…")
            items += projectItems(in: root, now: now)
        }
        progress("Checking Xcode and caches…")
        items += xcodeItems(now: now)
        items += cacheItems()
        if Task.isCancelled { return items }
        progress("Checking tools…")
        items += await commandItems()
        return items.filter { $0.bytes > 0 || $0.category.isCommand }
    }

    // MARK: Projects

    func projectItems(in root: URL, now: Date) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                             options: [.skipsPackageDescendants]) else { return [] }
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if enumerator.level > 8 { enumerator.skipDescendants(); continue }
            let name = url.lastPathComponent
            let project = url.deletingLastPathComponent()
            if name == "node_modules" {
                enumerator.skipDescendants()
                let modified = Self.projectModified(project)
                items.append(CleanupItem(category: .nodeModules, title: project.lastPathComponent, detail: project.path.replacingOccurrences(of: home.path, with: "~"),
                                         url: url, bytes: Self.size(of: url), modified: modified, isRecent: CleanupRules.isRecent(modified, now: now)))
            } else if name == ".build", fm.fileExists(atPath: project.appendingPathComponent("Package.swift").path) {
                enumerator.skipDescendants()
                if includeSwiftBuild {
                    items.append(CleanupItem(category: .swiftBuild, title: project.lastPathComponent, detail: project.path.replacingOccurrences(of: home.path, with: "~"),
                                             url: url, bytes: Self.size(of: url), modified: Self.projectModified(project)))
                }
            } else if fm.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) {
                enumerator.skipDescendants()
                if includeVenvs {
                    items.append(CleanupItem(category: .pythonVenv, title: "\(project.lastPathComponent)/\(name)", detail: project.path.replacingOccurrences(of: home.path, with: "~"),
                                             url: url, bytes: Self.size(of: url), modified: Self.projectModified(project)))
                }
            } else if Self.skipNames.contains(name) {
                enumerator.skipDescendants()
            }
        }
        return items
    }

    /// The newest change among a project's top-level entries (excluding the dependency folders themselves).
    static func projectModified(_ project: URL) -> Date? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return entries.filter { !["node_modules", ".build", ".git", "venv", ".venv"].contains($0.lastPathComponent) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            ?? (try? project.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    /// Allocated size on disk, without following symlinks.
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Xcode and caches

    func xcodeItems(now: Date) -> [CleanupItem] {
        var items: [CleanupItem] = []
        func children(_ relative: String) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(relative), includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles])) ?? []
        }
        func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        for folder in children("Library/Developer/Xcode/DerivedData") where folder.lastPathComponent != "ModuleCache.noindex" || true {
            items.append(CleanupItem(category: .derivedData, title: folder.lastPathComponent.components(separatedBy: "-").first ?? folder.lastPathComponent,
                                     url: folder, bytes: Self.size(of: folder), modified: modified(folder)))
        }
        for day in children("Library/Developer/Xcode/Archives") {
            for archive in ((try? FileManager.default.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []) where archive.pathExtension == "xcarchive" {
                let date = modified(archive)
                guard let date, now.timeIntervalSince(date) > Double(archiveAgeDays) * 86_400 else { continue }
                items.append(CleanupItem(category: .archives, title: archive.deletingPathExtension().lastPathComponent, detail: day.lastPathComponent,
                                         url: archive, bytes: Self.size(of: archive), modified: date))
            }
        }
        for version in children("Library/Developer/Xcode/iOS DeviceSupport") {
            items.append(CleanupItem(category: .deviceSupport, title: version.lastPathComponent, url: version, bytes: Self.size(of: version), modified: modified(version)))
        }
        let simCaches = home.appendingPathComponent("Library/Developer/CoreSimulator/Caches")
        if FileManager.default.fileExists(atPath: simCaches.path) {
            for child in children("Library/Developer/CoreSimulator/Caches") {
                items.append(CleanupItem(category: .simulatorCaches, title: child.lastPathComponent, url: child, bytes: Self.size(of: child), modified: modified(child)))
            }
        }
        return items
    }

    func cacheItems() -> [CleanupItem] {
        let caches: [(CleanupCategory, String)] = [(.npmCache, ".npm/_cacache"), (.yarnCache, "Library/Caches/Yarn"), (.pnpmStore, "Library/pnpm/store"),
                                                   (.pipCache, "Library/Caches/pip"), (.cocoapods, "Library/Caches/CocoaPods"), (.gradle, ".gradle/caches")]
        return caches.compactMap { category, relative in
            let url = home.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return CleanupItem(category: category, title: category.title, detail: "~/" + relative, url: url, bytes: Self.size(of: url),
                               modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
    }

    // MARK: Command-based

    func commandItems() async -> [CleanupItem] {
        var items: [CleanupItem] = []
        if let xcrun = CleanupCommands.executable("xcrun"),
           let output = await runCommand(xcrun, ["simctl", "list", "devices", "unavailable"]) {
            let count = output.split(whereSeparator: \.isNewline).filter { $0.contains("(unavailable") }.count
            if count > 0 {
                items.append(CleanupItem(category: .unavailableSimulators, title: "\(count) unavailable simulator\(count == 1 ? "" : "s")",
                                         bytes: 0, command: CleanupCommands.simctlDeleteUnavailable))
            }
        }
        if let docker = CleanupCommands.executable("docker"),
           let output = await runCommand(docker, Array(CleanupCommands.dockerDF.dropFirst())) {
            let sizes = CleanupCommands.parseDockerDF(output)
            let map: [(String, CleanupCategory, [String])] = [("Images", .dockerImages, CleanupCommands.dockerImagePrune),
                                                              ("Containers", .dockerContainers, CleanupCommands.dockerContainerPrune),
                                                              ("Build Cache", .dockerBuildCache, CleanupCommands.dockerBuilderPrune)]
            for (type, category, command) in map where (sizes[type] ?? 0) > 0 {
                items.append(CleanupItem(category: category, title: category.title, bytes: sizes[type] ?? 0, command: command))
            }
        }
        if let brew = CleanupCommands.executable("brew"),
           let output = await runCommand(brew, Array(CleanupCommands.brewPreview.dropFirst())) {
            let bytes = CleanupCommands.parseBrewPreview(output)
            if bytes > 0 { items.append(CleanupItem(category: .homebrew, title: "Old Homebrew downloads and versions", bytes: bytes, command: CleanupCommands.brewCleanup)) }
        }
        return items
    }
}

/// Runs a confirmed cleanup: Trash by default, permanent only for caches, exact commands for CLI items, audited.
@Observable
@MainActor
final class DevCleanup {
    static let shared = DevCleanup()

    private(set) var items: [CleanupItem] = []
    private(set) var scanning = false
    private(set) var status = ""
    private(set) var lastScan: Date?
    var trash: AgentTools.TrashFunction = AgentTools.systemTrash
    var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    var runCommand: ([String]) async -> ShellResult = { command in
        guard let first = command.first, let executable = CleanupCommands.executable(first) else {
            return ShellResult(status: 127, stdout: "", stderr: "\(command.first ?? "") isn't installed")
        }
        return await Shell.run(executable, Array(command.dropFirst()), timeout: 600)
    }
    var audit: (String) -> Void = { AgentEngine.shared.audit($0, kind: .policy) }
    private var running: Task<[CleanupItem], Never>?

    static let rootsKey = "cleanup.roots", swiftKey = "cleanup.swiftBuild", venvKey = "cleanup.venvs", monthlyKey = "cleanup.monthlyReminder"
    static let lastTotalKey = "cleanup.lastTotal", lastNoticeKey = "cleanup.lastNotice"

    var roots: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? CleanupScanner.defaultRoots.map { NSHomeDirectory() + "/" + $0 } }
        set { UserDefaults.standard.set(newValue, forKey: Self.rootsKey) }
    }

    func scanner() -> CleanupScanner {
        CleanupScanner(roots: roots.map { URL(fileURLWithPath: $0) }, includeSwiftBuild: UserDefaults.standard.bool(forKey: Self.swiftKey),
                       includeVenvs: UserDefaults.standard.bool(forKey: Self.venvKey))
    }

    /// The scanner behind the current items; the guard only allows its roots and cache folders.
    private var lastScanner: CleanupScanner?

    var guardian: CleanupGuard {
        let scanner = lastScanner ?? scanner()
        return CleanupGuard(roots: scanner.roots, cachePaths: scanner.knownCachePaths)
    }

    var total: Int64 { CleanupRules.total(items) }
    var lastKnownTotal: Int64 { lastScan == nil ? Int64(UserDefaults.standard.integer(forKey: Self.lastTotalKey)) : total }

    /// Scans in a detached, utility-priority task. Cancelling keeps what was found so far.
    func scan(using custom: CleanupScanner? = nil) async {
        running?.cancel()
        scanning = true
        status = "Scanning…"
        let scanner = custom ?? scanner()
        let owner = self
        let work = Task.detached(priority: .utility) { () -> [CleanupItem] in
            await scanner.scan { message in Task { @MainActor in if owner.scanning { owner.status = message } } }
        }
        running = work
        let found = await work.value
        guard running == work else { return }
        running = nil
        lastScanner = scanner
        items = found
        lastScan = Date()
        if !work.isCancelled { UserDefaults.standard.set(Int(total), forKey: Self.lastTotalKey) }
        scanning = false
        status = work.isCancelled ? "Cancelled · \(CleanupFormat.bytes(total)) found so far" : "\(CleanupFormat.bytes(total)) reclaimable"
    }

    func cancel() {
        running?.cancel()
    }

    /// Previews and snapshots: show a fixed result without scanning.
    func showForPreview(_ items: [CleanupItem]) {
        self.items = items
        lastScan = Date()
        status = "\(CleanupFormat.bytes(total)) reclaimable"
    }

    /// Resolves ids from scan_cleanup (or the same path spelled differently, e.g. /var vs /private/var) to scanned items.
    func resolve(_ ids: [String]) -> (found: [CleanupItem], missing: [String]) {
        var found: [CleanupItem] = [], missing: [String] = []
        for id in ids {
            if let item = items.first(where: { $0.id == id }) ?? (id.hasPrefix("/") ? items.first(where: { item in
                item.url.map { WorkspaceGuard.canonical($0).path == WorkspaceGuard.canonical(URL(fileURLWithPath: id)).path } ?? false
            }) : nil) {
                if !found.contains(item) { found.append(item) }
            } else {
                missing.append(id)
            }
        }
        return (found, missing)
    }

    struct Outcome: Equatable {
        var freed: Int64 = 0
        var done: [String] = []
        var refused: [String] = []
        var failed: [String] = []
    }

    /// Only after the user confirmed exactly these items. `permanent` is ignored for anything that isn't a cache.
    func clean(_ selected: [CleanupItem], permanent: Bool, via: String = "the app") async -> Outcome {
        var outcome = Outcome()
        let guardian = guardian
        for item in selected {
            if item.category.isCommand {
                let result = await runCommand(item.command)
                if result.ok { outcome.done.append(item.commandLine); outcome.freed += item.bytes } else { outcome.failed.append("\(item.commandLine): \(result.stderr.prefix(200))") }
                continue
            }
            guard let url = item.url else { continue }
            do {
                let safe = try guardian.check(url)
                if permanent && item.category.isCache { try remove(safe) } else { try trash(safe) }
                outcome.done.append(url.path)
                outcome.freed += item.bytes
            } catch let refusal as CleanupGuard.Refusal {
                outcome.refused.append("\(url.path): \(refusal)")
            } catch {
                outcome.failed.append("\(url.path): \(error.localizedDescription)")
            }
        }
        items.removeAll { item in outcome.done.contains(item.url?.path ?? item.commandLine) }
        audit("Cleanup via \(via): \(outcome.done.count) item(s), \(CleanupFormat.bytes(outcome.freed)) \(permanent ? "deleted permanently/pruned" : "moved to Trash/pruned")"
              + (outcome.refused.isEmpty ? "" : "; refused \(outcome.refused.count)") + (outcome.failed.isEmpty ? "" : "; failed \(outcome.failed.count)"))
        return outcome
    }

    /// Monthly (optional): scans quietly and notifies when developer files exceed 5 GB.
    func monthlyCheck(now: Date = Date()) async {
        guard UserDefaults.standard.bool(forKey: Self.monthlyKey) else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastNoticeKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) > 30 * 86_400 else { return }
        await scan()
        UserDefaults.standard.set(now, forKey: Self.lastNoticeKey)
        guard total > 5_000_000_000 else { return }
        let title = "Developer files are using \(CleanupFormat.bytes(total))"
        NotchController.shared.peek(NotchPeek(systemImage: "externaldrive.badge.minus", tint: .orange, title: title, subtitle: "Open Developer → Cleanup", duration: 8))
        NotificationService.alert(id: "cleanup-monthly", heading: title, body: "Review them in MacPilot → Developer → Cleanup.", after: 1)
    }
}
