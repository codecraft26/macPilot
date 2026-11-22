import Darwin
import Foundation

/// A tool the model can call, described with a JSON schema (shared by every provider adapter).
struct AgentToolSpec {
    var name: String
    var description: String
    var properties: [String: [String: Any]]
    var required: [String]

    var schema: [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}

/// Output of a tool, fed back to the model.
struct AgentToolResult: Equatable {
    var content: String
    var isError = false
    /// A screenshot for models that can see images (never stored).
    var image: Data?

    init(content: String, isError: Bool = false, image: Data? = nil) {
        self.content = content
        self.isError = isError
        self.image = image
    }
}

/// The agent's tools: files inside the workspaces, allowlisted commands, and a read-only system status.
enum AgentTools {
    static let specs: [AgentToolSpec] = [
        AgentToolSpec(name: "list_files", description: "List files and folders in a workspace folder.",
                      properties: ["path": ["type": "string", "description": "Folder path (absolute or relative to the first workspace)."],
                                   "recursive": ["type": "boolean", "description": "Include subfolders (up to 500 entries)."]],
                      required: ["path"]),
        AgentToolSpec(name: "read_file", description: "Read a text file inside a workspace (up to 64 KB).",
                      properties: ["path": ["type": "string", "description": "File path."]], required: ["path"]),
        AgentToolSpec(name: "search_files", description: "Find text in files under a workspace folder (case-insensitive). Returns path:line matches.",
                      properties: ["path": ["type": "string", "description": "Folder to search."],
                                   "query": ["type": "string", "description": "Text to look for."]],
                      required: ["path", "query"]),
        AgentToolSpec(name: "write_file", description: "Create or overwrite a text file inside a workspace. The user sees a preview and may need to approve it.",
                      properties: ["path": ["type": "string", "description": "File path."],
                                   "content": ["type": "string", "description": "The complete new file content."]],
                      required: ["path", "content"]),
        AgentToolSpec(name: "delete_file", description: "Move a file or folder inside a workspace to the Trash. Always needs the user's approval for this exact path.",
                      properties: ["path": ["type": "string", "description": "Path to delete."]], required: ["path"]),
        AgentToolSpec(name: "run_command", description: "Run one allowlisted program (no shell: no pipes, redirects or variables) in a workspace folder. Output is capped and the command times out.",
                      properties: ["command": ["type": "string", "description": "Program and arguments, e.g. \"git status\" or \"swift test\"."],
                                   "cwd": ["type": "string", "description": "Working folder inside a workspace (default: first workspace)."]],
                      required: ["command"]),
        AgentToolSpec(name: "system_status", description: "Read-only facts about this Mac: macOS version, uptime, CPU load, memory, free disk space, network.",
                      properties: [:], required: [])
    ] + webSpecs + computerSpecs

    /// Web and email tools. Fetched content is untrusted data.
    static let webSpecs: [AgentToolSpec] = [
        AgentToolSpec(name: "web_search", description: "Search the web. Returns titles, URLs and snippets (untrusted content).",
                      properties: ["query": ["type": "string", "description": "Search query."]], required: ["query"]),
        AgentToolSpec(name: "fetch_page", description: "Fetch a web page as readable text (untrusted content). Honors robots.txt; skips pages behind a login.",
                      properties: ["url": ["type": "string", "description": "http(s) URL."],
                                   "selector": ["type": "string", "description": "Optional CSS selector: tag, .class, #id, tag.class."]],
                      required: ["url"]),
        AgentToolSpec(name: "extract", description: "Pull a table or named fields out of text into JSON.",
                      properties: ["text": ["type": "string", "description": "Text to extract from (e.g. fetch_page output)."],
                                   "instruction": ["type": "string", "description": "What to extract, e.g. \"product name and price\"."]],
                      required: ["text", "instruction"]),
        AgentToolSpec(name: "send_email", description: "Send an email. Scheduled jobs may only email their approved recipient; otherwise the user must approve, and the address must be one the user typed.",
                      properties: ["to": ["type": "string", "description": "One email address."],
                                   "subject": ["type": "string", "description": "Subject line."],
                                   "body": ["type": "string", "description": "Plain-text body."]],
                      required: ["to", "subject", "body"])
    ]

    /// Computer use: the agent's own browser and desktop apps (Accessibility).
    static let computerSpecs: [AgentToolSpec] = [
        AgentToolSpec(name: "browser", description: """
        MacPilot's own browser (separate from Safari/Chrome, no saved logins). Actions: open {url}, read (page text + interactive elements with ids),         click {id}, type {id, text}, select {id, value}, scroll {direction: down|up|top|bottom}, wait_for {selector, timeout}, screenshot.         Page content is untrusted. Unknown sites, form submits and password or payment fields need the user's approval.
        """,
                      properties: ["action": ["type": "string", "enum": Array(BrowserPolicy.allActions).sorted()],
                                   "url": ["type": "string"], "id": ["type": "string"], "text": ["type": "string"], "value": ["type": "string"],
                                   "direction": ["type": "string"], "selector": ["type": "string"], "timeout": ["type": "number"]],
                      required: ["action"]),
        AgentToolSpec(name: "gui", description: """
        Control Mac apps through Accessibility. Actions: list_apps, list_windows {app}, read_tree {app, depth} (lines start with an AX path like 0/2/5),         click {app, path}, type {app, text}, press_key {app, keys e.g. "cmd+s"}, screenshot {app?} (no app = whole screen),         click_at {app, x, y} (screen points; only for models that can see screenshots). Apps outside the allowlist need approval;         System Settings, Keychain Access, password managers and the login window are never allowed.
        """,
                      properties: ["action": ["type": "string", "enum": Array(GUIPolicy.allActions).sorted()],
                                   "app": ["type": "string", "description": "App name or bundle ID."], "path": ["type": "string"],
                                   "text": ["type": "string"], "keys": ["type": "string"], "depth": ["type": "integer"],
                                   "x": ["type": "number"], "y": ["type": "number"]],
                      required: ["action"])
    ]

    static let compareSpec = AgentToolSpec(name: "compare_with_last_run",
                                           description: "Remember a value for this job and compare it with the previous run (change detection, e.g. a price).",
                                           properties: ["key": ["type": "string", "description": "Name of the value, e.g. \"price\"."],
                                                        "value": ["type": "string", "description": "Current value."]],
                                           required: ["key", "value"])

    /// What a scheduled job may do: search, fetch, extract, compare and email its own recipient. Nothing else.
    static let jobToolNames: Set<String> = ["web_search", "fetch_page", "extract", "compare_with_last_run", "send_email", "browser"]

    static func specs(allowed: Set<String>) -> [AgentToolSpec] {
        let all = specs + [compareSpec]
        guard !allowed.isEmpty else { return specs }
        return all.filter { allowed.contains($0.name) }
    }

    static let readCap = 64_000
    static let listCap = 500

    // MARK: Normalize (policy input)

    /// Checks arguments, resolves paths inside the workspaces and assigns the risk tier. Throws when the policy blocks it.
    static func normalize(tool: String, arguments: [String: Any], settings: AgentSettings) throws -> NormalizedAction {
        let workspace = WorkspaceGuard(roots: settings.workspaceRoots)
        func string(_ key: String, required: Bool = true) throws -> String? {
            if let value = arguments[key] as? String { return value }
            if let value = arguments[key], !(value is NSNull) { return "\(value)" }
            if required { throw AgentPolicyError.invalidArguments("missing “\(key)”") }
            return nil
        }
        switch tool {
        case "list_files":
            let path = try workspace.resolve(try string("path")!)
            let recursive = (arguments["recursive"] as? Bool) ?? false
            return NormalizedAction(tool: tool, arguments: ["path": path.path, "recursive": recursive ? "true" : "false"], risk: .low,
                                    summary: "List \(path.path)\(recursive ? " (with subfolders)" : "")")
        case "read_file":
            let path = try workspace.resolve(try string("path")!)
            return NormalizedAction(tool: tool, arguments: ["path": path.path], risk: .low, summary: "Read \(path.path)")
        case "search_files":
            let path = try workspace.resolve(try string("path")!)
            let query = try string("query")!
            guard !query.isEmpty else { throw AgentPolicyError.invalidArguments("empty query") }
            return NormalizedAction(tool: tool, arguments: ["path": path.path, "query": query], risk: .low,
                                    summary: "Search “\(query)” in \(path.path)")
        case "write_file":
            let path = try workspace.resolve(try string("path")!)
            let content = try string("content")!
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue {
                throw AgentPolicyError.invalidArguments("\(path.path) is a folder")
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
            let exists = FileManager.default.fileExists(atPath: path.path)
            return NormalizedAction(tool: tool, arguments: ["path": path.path, "content": content], risk: .medium,
                                    summary: "\(exists ? "Overwrite" : "Create") \(path.path) (\(lines) line\(lines == 1 ? "" : "s"))")
        case "delete_file":
            let path = try workspace.resolve(try string("path")!)
            if workspace.roots.contains(path) { throw AgentPolicyError.forbiddenCommand("The workspace folder itself can't be deleted.") }
            return NormalizedAction(tool: tool, arguments: ["path": path.path], risk: .high, summary: "Move \(path.path) to the Trash")
        case "run_command":
            let line = try string("command")!
            let argv = try CommandGuard.split(line)
            let executable = try CommandGuard(allowlist: settings.commandAllowlist).validate(argv)
            let cwd = try workspace.resolve(try string("cwd", required: false) ?? workspace.roots.first?.path ?? "")
            return NormalizedAction(tool: tool, arguments: ["argv": argv.joined(separator: "\u{1F}"), "executable": executable, "cwd": cwd.path],
                                    risk: .medium, summary: "Run `\(argv.joined(separator: " "))` in \(cwd.path)")
        case "system_status":
            return NormalizedAction(tool: tool, arguments: [:], risk: .low, summary: "Read system status")
        case "web_search":
            let query = try string("query")!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw AgentPolicyError.invalidArguments("empty query") }
            return NormalizedAction(tool: tool, arguments: ["query": String(query.prefix(400))], risk: .low, summary: "Search the web for “\(query.prefix(80))”")
        case "fetch_page":
            let raw = try string("url")!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw AgentPolicyError.invalidArguments("not an http(s) URL")
            }
            var args = ["url": url.absoluteString]
            if let selector = try string("selector", required: false), !selector.isEmpty { args["selector"] = String(selector.prefix(100)) }
            return NormalizedAction(tool: tool, arguments: args, risk: .low, summary: "Fetch \(url.host ?? "")\(url.path)")
        case "extract":
            return NormalizedAction(tool: tool, arguments: ["text": String(try string("text")!.prefix(30_000)), "instruction": String(try string("instruction")!.prefix(1_000))],
                                    risk: .low, summary: "Extract: \(try string("instruction")!.prefix(80))")
        case "compare_with_last_run":
            let key = try string("key")!.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw AgentPolicyError.invalidArguments("empty key") }
            return NormalizedAction(tool: tool, arguments: ["key": String(key.prefix(100)), "value": String(try string("value")!.prefix(1_000))],
                                    risk: .low, summary: "Compare “\(key.prefix(40))” with the last run")
        case "browser", "gui":
            let verb = (try string("action")!).lowercased()
            let known = tool == "browser" ? BrowserPolicy.allActions : GUIPolicy.allActions
            guard known.contains(verb) else { throw AgentPolicyError.invalidArguments("unknown \(tool) action “\(verb)”") }
            var args: [String: String] = ["action": verb]
            for key in ["url", "id", "text", "value", "direction", "selector", "timeout", "app", "path", "keys", "depth", "x", "y"] {
                if let value = try string(key, required: false), !value.isEmpty { args[key] = String(value.prefix(key == "text" ? 5_000 : 500)) }
            }
            if tool == "browser", verb == "open", args["url"] == nil { throw AgentPolicyError.invalidArguments("missing “url”") }
            if tool == "browser", ["click", "type", "select"].contains(verb), args["id"] == nil { throw AgentPolicyError.invalidArguments("missing element “id”") }
            if tool == "gui", verb != "list_apps", verb != "screenshot", args["app"] == nil { throw AgentPolicyError.invalidArguments("missing “app”") }
            // The engine refines risk and summary once it has looked at the page or app.
            return NormalizedAction(tool: tool, arguments: args, risk: .low, summary: "\(tool) \(verb)")
        case "send_email":
            let to = try string("to")!
            guard let address = EmailAddress.normalize(to) else { throw AgentPolicyError.invalidArguments("“\(to)” isn't one valid email address") }
            var args = ["to": address, "subject": String(try string("subject")!.prefix(300)), "body": String(try string("body")!.prefix(100_000))]
            if let html = try string("html", required: false), !html.isEmpty { args["html"] = String(html.prefix(400_000)) }
            return NormalizedAction(tool: tool, arguments: args, risk: .high, summary: "Email \(address): “\(args["subject"]!.prefix(80))”")
        default:
            throw AgentPolicyError.unknownTool(tool)
        }
    }

    /// For the approval drawer: the exact change a write makes.
    static func preview(_ action: NormalizedAction) -> String {
        switch action.tool {
        case "write_file":
            let path = action.arguments["path"] ?? ""
            let new = action.arguments["content"] ?? ""
            let old = (try? String(contentsOfFile: path, encoding: .utf8))
            return AgentRedactor.redact(WritePreview.describe(old: old, new: new))
        case "run_command":
            return "$ " + (action.arguments["argv"] ?? "").split(separator: "\u{1F}").map { word in
                word.contains(" ") ? "\"\(word)\"" : String(word)
            }.joined(separator: " ") + "\n(in \(action.arguments["cwd"] ?? ""))"
        case "delete_file":
            return "Trash: \(action.arguments["path"] ?? "")"
        case "send_email":
            return "To: \(action.arguments["to"] ?? "")\nSubject: \(action.arguments["subject"] ?? "")\n\n\(String((action.arguments["body"] ?? "").prefix(3_000)))"
        default:
            return action.summary
        }
    }

    // MARK: Execute

    /// Moves to the Trash. Injected so tests never touch the user's real Trash.
    typealias TrashFunction = (URL) throws -> Void
    static let systemTrash: TrashFunction = { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
    }

    static func execute(_ action: NormalizedAction, settings: AgentSettings, processes: AgentProcessRegistry,
                        trash: TrashFunction = systemTrash) async -> AgentToolResult {
        do {
            switch action.tool {
            case "list_files": return try listFiles(action.arguments["path"]!, recursive: action.arguments["recursive"] == "true")
            case "read_file": return try readFile(action.arguments["path"]!)
            case "search_files": return searchFiles(action.arguments["path"]!, query: action.arguments["query"]!)
            case "write_file":
                let url = URL(fileURLWithPath: action.arguments["path"]!)
                // Re-check right before writing (a symlink could have appeared since approval).
                _ = try WorkspaceGuard(roots: settings.workspaceRoots).resolve(url.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((action.arguments["content"] ?? "").utf8).write(to: url, options: .atomic)
                return AgentToolResult(content: "Wrote \(url.path)")
            case "delete_file":
                let url = URL(fileURLWithPath: action.arguments["path"]!)
                _ = try WorkspaceGuard(roots: settings.workspaceRoots).resolve(url.path)
                try trash(url)
                return AgentToolResult(content: "Moved \(url.path) to the Trash")
            case "run_command":
                let argv = (action.arguments["argv"] ?? "").split(separator: "\u{1F}").map(String.init)
                return await processes.run(executable: action.arguments["executable"]!, arguments: Array(argv.dropFirst()),
                                           cwd: action.arguments["cwd"]!, timeout: settings.commandTimeout, outputCap: settings.outputCap)
            case "system_status": return AgentToolResult(content: systemStatus())
            default: return AgentToolResult(content: "Unknown tool", isError: true)
            }
        } catch {
            return AgentToolResult(content: AgentRedactor.redact(error.localizedDescription), isError: true)
        }
    }

    private static func listFiles(_ path: String, recursive: Bool) throws -> AgentToolResult {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: path)
        var lines: [String] = []
        if recursive {
            let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL, lines.count < listCap {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir, ["node_modules", ".build", "build", "DerivedData", ".git"].contains(url.lastPathComponent) { enumerator?.skipDescendants() }
                lines.append(String(url.path.dropFirst(base.path.count + 1)) + (isDir ? "/" : ""))
            }
        } else {
            for name in try fm.contentsOfDirectory(atPath: path).sorted().prefix(listCap) {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: base.appendingPathComponent(name).path, isDirectory: &isDir)
                lines.append(name + (isDir.boolValue ? "/" : ""))
            }
        }
        if lines.count >= listCap { lines.append("… (stopped at \(listCap) entries)") }
        return AgentToolResult(content: lines.isEmpty ? "(empty folder)" : lines.joined(separator: "\n"))
    }

    private static func readFile(_ path: String) throws -> AgentToolResult {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: readCap + 1) ?? Data()
        guard let text = String(data: data.prefix(readCap), encoding: .utf8) ?? String(data: data.prefix(readCap - 3), encoding: .utf8) else {
            return AgentToolResult(content: "This isn't a UTF-8 text file.", isError: true)
        }
        return AgentToolResult(content: text + (data.count > readCap ? "\n… (truncated at 64 KB)" : ""))
    }

    private static func searchFiles(_ path: String, query: String) -> AgentToolResult {
        let base = URL(fileURLWithPath: path)
        var matches: [String] = []
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])
        var scanned = 0
        while let url = enumerator?.nextObject() as? URL, matches.count < 200, scanned < 5_000 {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if ["node_modules", ".build", "build", "DerivedData", ".git"].contains(url.lastPathComponent) { enumerator?.skipDescendants() }
                continue
            }
            guard (values?.fileSize ?? 0) < 1_000_000, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: query, options: .caseInsensitive) != nil {
                matches.append("\(url.path.dropFirst(base.path.count + 1)):\(index + 1): \(line.prefix(200))")
                if matches.count >= 200 { break }
            }
        }
        return AgentToolResult(content: matches.isEmpty ? "No matches." : matches.joined(separator: "\n"))
    }

    static func systemStatus() -> String {
        let info = ProcessInfo.processInfo
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        let uptime = Int(info.systemUptime)
        return """
        macOS \(info.operatingSystemVersionString)
        Uptime: \(uptime / 86_400)d \(uptime % 86_400 / 3_600)h \(uptime % 3_600 / 60)m
        CPU: \(info.activeProcessorCount) cores, load \(String(format: "%.2f %.2f %.2f", load[0], load[1], load[2]))
        Memory: \(ByteCountFormatter.string(fromByteCount: Int64(info.physicalMemory), countStyle: .memory))
        Free disk (home volume): \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
        Thermal state: \(["nominal", "fair", "serious", "critical"][min(3, info.thermalState.rawValue)])
        """
    }
}

/// "New file, 12 lines" or a compact line diff for the approval drawer.
enum WritePreview {
    static func describe(old: String?, new: String, maxLines: Int = 40) -> String {
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let old else {
            return "New file, \(newLines.count) lines:\n" + newLines.prefix(maxLines).map { "+ \($0)" }.joined(separator: "\n")
                + (newLines.count > maxLines ? "\n… \(newLines.count - maxLines) more" : "")
        }
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let diff = newLines.difference(from: oldLines)
        var out: [String] = []
        for change in diff {
            switch change {
            case let .remove(offset, line, _): out.append("- \(offset + 1): \(line)")
            case let .insert(offset, line, _): out.append("+ \(offset + 1): \(line)")
            }
        }
        if out.isEmpty { return "No changes (\(oldLines.count) lines)." }
        let removed = diff.removals.count, added = diff.insertions.count
        return "Changes: +\(added) −\(removed) lines\n" + out.prefix(maxLines).joined(separator: "\n") + (out.count > maxLines ? "\n… \(out.count - maxLines) more" : "")
    }
}

/// Runs agent commands and can kill them all at once (Stop and the kill switch).
final class AgentProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [Int32: Process] = [:]

    var runningCount: Int { lock.withLock { running.count } }

    func run(executable: String, arguments: [String], cwd: String, timeout: TimeInterval, outputCap: Int) async -> AgentToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = CommandGuard.scrubbedEnvironment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = CappedBuffer(cap: outputCap)
        pipe.fileHandleForReading.readabilityHandler = { handle in buffer.append(handle.availableData) }

        return await withCheckedContinuation { continuation in
            let timedOut = LockedFlag()
            process.terminationHandler = { [weak self] finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                self?.lock.withLock { _ = self?.running.removeValue(forKey: finished.processIdentifier) }
                var text = AgentRedactor.redact(buffer.text)
                if buffer.truncated { text += "\n… (output truncated at \(outputCap) bytes)" }
                let status = finished.terminationStatus
                if timedOut.value {
                    continuation.resume(returning: AgentToolResult(content: text + "\n(timed out after \(Int(timeout)) s and was stopped)", isError: true))
                } else if finished.terminationReason == .uncaughtSignal {
                    continuation.resume(returning: AgentToolResult(content: text + "\n(stopped)", isError: true))
                } else {
                    continuation.resume(returning: AgentToolResult(content: (text.isEmpty ? "(no output)" : text) + "\n(exit code \(status))", isError: status != 0))
                }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(returning: AgentToolResult(content: "Couldn't start \(executable): \(error.localizedDescription)", isError: true))
                return
            }
            let pid = process.processIdentifier
            lock.withLock { running[pid] = process }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard process.isRunning else { return }
                timedOut.value = true
                self?.kill(pid)
            }
        }
    }

    /// SIGTERM, then SIGKILL after a second if it's still alive (well inside the 2-second kill-switch budget).
    func killAll() {
        let pids = lock.withLock { Array(running.keys) }
        pids.forEach(kill)
    }

    /// Signals the command and everything it started (e.g. `swift test` → compiler and test runner).
    private func kill(_ pid: Int32) {
        let family = Self.descendants(of: pid) + [pid]
        family.forEach { Darwin.kill($0, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            family.forEach { Darwin.kill($0, SIGKILL) }
        }
    }

    static func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var queue = [pid]
        while let next = queue.popLast(), result.count < 512 {
            var buffer = [Int32](repeating: 0, count: 256)
            let count = proc_listchildpids(next, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
            guard count > 0 else { continue }
            let children = buffer.prefix(Int(count)).filter { $0 > 0 }
            result += children
            queue += children
        }
        return result
    }
}

private final class CappedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int
    private(set) var truncated = false

    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.withLock {
            guard !chunk.isEmpty else { return }
            let room = cap - data.count
            if room <= 0 { truncated = true; return }
            data.append(chunk.prefix(room))
            if chunk.count > room { truncated = true }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
