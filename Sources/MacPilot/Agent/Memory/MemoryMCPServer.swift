import Foundation
import Network
import Observation

/// The memory tools exposed over MCP (JSON-RPC 2.0). Pure request → response, shared by stdio and HTTP.
struct MemoryMCPHandler {
    static let protocolVersion = "2025-06-18"
    let store: MemoryStore
    /// Called for every tool call (audit log).
    var audit: (String) -> Void = { _ in }
    var markDone: (String) -> Bool

    static let tools: [[String: Any]] = [
        ["name": "search_memory", "description": "Search the user's MacPilot memory (text they saw in apps they allowed). Read-only.",
         "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 20]],
                         "required": ["query"], "additionalProperties": false]],
        ["name": "get_open_loops", "description": "List open loops: commitments and requests found in the user's memory.",
         "inputSchema": ["type": "object", "properties": ["status": ["type": "string", "enum": ["open", "probablyDone", "all"]]], "additionalProperties": false]],
        ["name": "mark_loop_done", "description": "Mark one open loop as done.",
         "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"], "additionalProperties": false]]
    ]

    /// nil for notifications (no response).
    func handle(_ data: Data) -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.error(id: NSNull(), code: -32700, "Parse error")
        }
        let id = request["id"] ?? NSNull()
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return Self.error(id: id, code: -32600, "Invalid request")
        }
        if request["id"] == nil { return nil } // notification, e.g. notifications/initialized
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return Self.result(id: id, ["protocolVersion": Self.protocolVersion, "capabilities": ["tools": ["listChanged": false]],
                                        "serverInfo": ["name": "macpilot-memory", "version": "0.27.0"]])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return Self.result(id: id, call(name, arguments))
        default:
            return Self.error(id: id, code: -32601, "Method not found")
        }
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        func text(_ value: String, error: Bool = false) -> [String: Any] {
            ["content": [["type": "text", "text": AgentRedactor.redact(value)]], "isError": error]
        }
        switch name {
        case "search_memory":
            guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return text("query is required", error: true) }
            let limit = min(20, max(1, (arguments["limit"] as? Int) ?? 8))
            let results = store.semanticSearch(query, limit: limit)
            audit("MCP search_memory “\(query.prefix(60))” → \(results.count) snippet\(results.count == 1 ? "" : "s")")
            return text(results.isEmpty ? "No matching memories." : results.map {
                "[\($0.date.formatted(date: .abbreviated, time: .shortened)) · \($0.app) · \($0.window.prefix(60))]\n\($0.text.prefix(1_200))"
            }.joined(separator: "\n\n"))
        case "get_open_loops":
            let status = arguments["status"] as? String ?? "open"
            let wanted: Set<LoopStatus> = status == "all" ? [.open, .probablyDone, .snoozed] : status == "probablyDone" ? [.probablyDone] : [.open, .snoozed]
            let loops = store.loops(statuses: wanted)
            audit("MCP get_open_loops (\(status)) → \(loops.count)")
            return text(loops.isEmpty ? "No open loops." : loops.map {
                "\($0.id.prefix(8)) · \($0.what)" + ($0.who.isEmpty ? "" : " · \($0.who)") + ($0.due.map { " · due \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "") + " · \($0.status.label)"
            }.joined(separator: "\n"))
        case "mark_loop_done":
            guard let id = arguments["id"] as? String, !id.isEmpty else { return text("id is required", error: true) }
            let ok = markDone(id)
            audit("MCP mark_loop_done \(id.prefix(8)) → \(ok ? "done" : "not found")")
            return text(ok ? "Marked done." : "No open loop with that id.", error: !ok)
        default:
            return text("Unknown tool \(name)", error: true)
        }
    }

    static func result(id: Any, _ result: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])) ?? Data()
    }

    static func error(id: Any, code: Int, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])) ?? Data()
    }
}

/// Minimal HTTP/1.1 for MCP Streamable HTTP (POST /mcp, JSON responses).
enum MCPHTTP {
    struct Request: Equatable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    /// Parses a complete request; nil until the headers and the full body have arrived.
    static func parse(_ data: Data) -> Request? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<marker.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[marker.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length)))
    }

    static func authorized(_ request: Request, token: String) -> Bool {
        guard !token.isEmpty, let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        return TelegramRandom.constantTimeEqual(String(header.dropFirst(7)), token)
    }

    /// DNS-rebinding guard: a browser Origin must be localhost.
    static func originAllowed(_ request: Request) -> Bool {
        guard let origin = request.headers["origin"], let host = URL(string: origin)?.host?.lowercased() else { return true }
        return host == "localhost" || host == "127.0.0.1" || host == "[::1]"
    }

    static func response(_ status: Int, _ reason: String, body: Data = Data(), contentType: String = "application/json", extra: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (key, value) in extra { head += "\(key): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    /// Routes one request: token, origin, path and method checks, then the MCP handler.
    static func respond(_ request: Request, token: String, handler: MemoryMCPHandler) -> Data {
        guard originAllowed(request) else { return response(403, "Forbidden", body: Data(#"{"error":"origin not allowed"}"#.utf8)) }
        guard authorized(request, token: token) else {
            return response(401, "Unauthorized", body: Data(#"{"error":"missing or wrong bearer token"}"#.utf8), extra: ["WWW-Authenticate": "Bearer"])
        }
        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else { return response(404, "Not Found") }
        switch request.method {
        case "POST":
            guard let reply = handler.handle(request.body) else { return response(202, "Accepted") }
            return response(200, "OK", body: reply)
        case "DELETE":
            return response(200, "OK")
        default:
            return response(405, "Method Not Allowed", extra: ["Allow": "POST"])
        }
    }
}

/// Optional local MCP server: Streamable HTTP on 127.0.0.1 only, with a bearer token in the Keychain. Off by default.
@Observable
@MainActor
final class MemoryMCPServer {
    static let shared = MemoryMCPServer()
    nonisolated static let tokenAccount = "memory.mcpToken"
    nonisolated static let enabledKey = "memory.mcpEnabled", portKey = "memory.mcpPort"
    static let defaultPort: UInt16 = 39_217

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var boundPort: UInt16?
    private var listener: NWListener?
    var tokenProvider: () -> String = { MemoryMCPServer.token() }
    var store: MemoryStore = .shared

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); newValue ? start() : stop() }
    }

    var port: UInt16 {
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        return saved > 1024 && saved < 65_536 ? UInt16(saved) : Self.defaultPort
    }

    /// The bearer token (created on first use, kept in the Keychain).
    static func token() -> String {
        if let token = KeychainStore.read(account: tokenAccount), !token.isEmpty { return token }
        return rotateToken()
    }

    @discardableResult
    static func rotateToken() -> String {
        let token = TelegramRandom.string(length: 40, alphabet: Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"))
        try? KeychainStore.save(token, account: tokenAccount)
        return token
    }

    func handler() -> MemoryMCPHandler {
        let store = store
        return MemoryMCPHandler(store: store, audit: { message in
            Task { @MainActor in AgentEngine.shared.audit(message) }
        }, markDone: { id in
            guard var loop = store.loop(id) else { return false }
            loop.status = .done
            loop.updated = Date()
            store.upsert(loop)
            return true
        })
    }

    func startIfEnabled() { if isEnabled { start() } }

    /// Binds to the loopback interface only.
    func start(port requested: UInt16? = nil) {
        stop()
        let port = requested ?? self.port
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            parameters.acceptLocalOnly = true
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            let token = tokenProvider()
            let handler = handler()
            listener.newConnectionHandler = { connection in
                MemoryMCPServer.serve(connection, token: token, handler: handler)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.boundPort = listener.port?.rawValue
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                    case .cancelled:
                        self?.isRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        boundPort = nil
    }

    var localEndpointHost: String? {
        guard case let .hostPort(host, _)? = listener?.parameters.requiredLocalEndpoint else { return nil }
        return "\(host)"
    }

    nonisolated static func serve(_ connection: NWConnection, token: String, handler: MemoryMCPHandler) {
        connection.start(queue: .global(qos: .utility))
        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, done, error in
                if let data { buffer.append(data) }
                if buffer.count > 4_000_000 {
                    connection.send(content: MCPHTTP.response(413, "Payload Too Large"), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                if let request = MCPHTTP.parse(buffer) {
                    let reply = MCPHTTP.respond(request, token: token, handler: handler)
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                } else if done || error != nil {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }
        receive()
    }

    // MARK: stdio

    /// `MacPilot --mcp-stdio`: newline-delimited JSON-RPC on stdin/stdout, for MCP clients that launch servers.
    nonisolated static func runStdio(store: MemoryStore = .shared) -> Never {
        guard UserDefaults.standard.bool(forKey: enabledKey) else {
            FileHandle.standardError.write(Data("MacPilot memory MCP server is off. Turn it on in MacPilot → Settings → Memory.\n".utf8))
            exit(1)
        }
        let handler = MemoryMCPHandler(store: store, audit: { message in
            // The app's audit log lives in its database; note stdio queries there too.
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            let log = Persistence.storeDirectory.appendingPathComponent("mcp-audit.log")
            if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
            else { try? Data(line.utf8).write(to: log) }
        }, markDone: { id in
            guard var loop = store.loop(id) else { return false }
            loop.status = .done
            loop.updated = Date()
            store.upsert(loop)
            return true
        })
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = handler.handle(Data(line.utf8)) {
                FileHandle.standardOutput.write(reply + Data("\n".utf8))
            }
        }
        exit(0)
    }

    /// Config snippets shown in Settings.
    static func stdioConfig(executable: String) -> String {
        """
        {
          "mcpServers": {
            "macpilot-memory": {
              "command": "\(executable)",
              "args": ["--mcp-stdio"]
            }
          }
        }
        """
    }

    static func httpConfig(port: UInt16, token: String) -> String {
        """
        {
          "mcpServers": {
            "macpilot-memory": {
              "type": "http",
              "url": "http://127.0.0.1:\(port)/mcp",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    static func claudeCodeCommand(port: UInt16, token: String) -> String {
        "claude mcp add --transport http macpilot-memory http://127.0.0.1:\(port)/mcp --header \"Authorization: Bearer \(token)\""
    }
}
