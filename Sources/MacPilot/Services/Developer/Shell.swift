import Foundation
import Observation

struct ShellResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false

    var ok: Bool { status == 0 && !timedOut }
    var combined: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum Shell {
    /// Runs an executable with an argument array (no shell, so user input is never interpolated).
    static func run(_ executable: String, _ arguments: [String], in directory: String? = nil, timeout: TimeInterval = 30) async -> ShellResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_PAGER"] = "cat"
            process.environment = environment

            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice

            let collector = OutputCollector()
            output.fileHandleForReading.readabilityHandler = { collector.appendOut($0.availableData) }
            errors.fileHandleForReading.readabilityHandler = { collector.appendErr($0.availableData) }

            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(output.fileHandleForReading.readDataToEndOfFile())
                collector.appendErr(errors.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: collector.result(status: finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(returning: ShellResult(status: -1, stdout: "", stderr: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    collector.markTimedOut()
                    process.terminate()
                }
            }
        }
    }
}

/// Thread-safe output buffer for a running process.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var timedOut = false
    static let limit = 5_000_000

    func appendOut(_ data: Data) { lock.lock(); if out.count < Self.limit { out.append(data) }; lock.unlock() }
    func appendErr(_ data: Data) { lock.lock(); if err.count < Self.limit { err.append(data) }; lock.unlock() }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    func result(status: Int32) -> ShellResult {
        lock.lock(); defer { lock.unlock() }
        return ShellResult(status: status, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut)
    }
}

/// Runs one user-approved terminal command with live output and a Stop button.
@Observable
@MainActor
final class CommandRunner {
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var exitStatus: Int32?
    private var process: Process?

    func run(_ command: String, in directory: String, timeout: TimeInterval = 600) {
        guard !isRunning else { return }
        output = "$ \(command)\n"
        exitStatus = nil
        isRunning = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.output.count < 2_000_000 else { return }
                self.output += text
            }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.exitStatus = status
                self.isRunning = false
                self.output += "\n[exit \(status)]"
                CommandHistory.record(command: command, directory: directory, status: status)
            }
        }
        do {
            try process.run()
            self.process = process
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
        } catch {
            output += "Could not start: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        process?.terminate()
    }
}

/// Flags commands that can destroy data or change the system, so they need a second confirmation.
enum CommandSafety {
    private static let rules: [(pattern: String, reason: String)] = [
        (#"(^|[;&|\s])rm\s"#, "deletes files (rm)"),
        (#"(^|[;&|\s])rmdir\s"#, "deletes folders (rmdir)"),
        (#"\bgit\s+reset\s+--hard"#, "discards local changes (git reset --hard)"),
        (#"\bgit\s+clean\b"#, "deletes untracked files (git clean)"),
        (#"\bgit\s+push\b.*(--force|-f\b|--force-with-lease)"#, "rewrites remote history (force push)"),
        (#"\bgit\s+branch\s+-D\b"#, "deletes a branch (git branch -D)"),
        (#"\bgit\s+checkout\s+--\s"#, "discards file changes (git checkout --)"),
        (#"\bgit\s+restore\b"#, "discards file changes (git restore)"),
        (#"\bgit\s+stash\s+(drop|clear)\b"#, "deletes stashes"),
        (#"(^|[;&|\s])sudo\s"#, "runs as administrator (sudo)"),
        (#"(^|[;&|\s])dd\s"#, "writes raw disk data (dd)"),
        (#"\bmkfs"#, "formats a disk (mkfs)"),
        (#"\bdiskutil\s+(erase|partition|zero)"#, "erases a disk (diskutil)"),
        (#"\bchmod\s+(-R|--recursive)"#, "changes permissions recursively (chmod -R)"),
        (#"\bchown\s+(-R|--recursive)"#, "changes ownership recursively (chown -R)"),
        (#"(^|[^>&0-9])>\s*[^&>\s]"#, "overwrites a file (>)"),
        (#"\b(kill|killall|pkill)\b"#, "stops processes"),
        (#"\bshutdown\b|\breboot\b|\bhalt\b"#, "shuts down or restarts the Mac"),
        (#"\bdrop\s+(table|database)\b"#, "drops a database object"),
        (#"\btruncate\b"#, "truncates data"),
        (#"\bnpm\s+publish\b|\bgit\s+push\b"#, "publishes or pushes to a remote"),
        (#"\bcurl\b[^|]*\|\s*(sh|bash|zsh)\b"#, "pipes a download into a shell")
    ]

    /// Reasons this command is risky; empty when it looks safe.
    static func risks(in command: String) -> [String] {
        rules.compactMap { rule in
            command.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil ? rule.reason : nil
        }
    }

    static func isDestructive(_ command: String) -> Bool { !risks(in: command).isEmpty }
}

/// Recently run commands (redacted), stored in preferences.
enum CommandHistory {
    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var command: String
        var directory: String
        var status: Int32
        var date: Date
    }

    private static let key = "developer.commandHistory"

    static var entries: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func record(command: String, directory: String, status: Int32) {
        var list = entries
        list.insert(Entry(command: Redactor.redact(SensitiveContent.looksSensitive(command) ? "[command with a secret removed]" : command),
                          directory: directory, status: status, date: Date()), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(100))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
