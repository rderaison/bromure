import ArgumentParser
import Foundation

// MARK: - CLI subcommand

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the AC MCP server for AI tool integration (stdio)."
    )

    @Flag(name: .long, help: "Include debug tools (VM shell access, app state).")
    var debug = false

    @Option(name: .long, help: "Bromure AC automation API URL.")
    var apiURL: String = "http://127.0.0.1:9223"

    func run() throws {
        let server = ACMCPServerImpl(apiBase: apiURL, debug: debug)
        var finished = false
        Task {
            await server.run()
            finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
        while !finished {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
    }
}

// MARK: - MCP server actor

private actor ACMCPServerImpl {
    let apiBase: String
    let debug: Bool

    init(apiBase: String, debug: Bool) {
        self.apiBase = apiBase
        self.debug = debug
    }

    func run() async {
        let lines = AsyncStream<String> { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }
        for await line in lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                respond(id: id, result: [
                    "protocolVersion": "2025-03-26",
                    "serverInfo": ["name": "bromure-ac", "version": "1.0.0"],
                    "capabilities": ["tools": ["listChanged": false]],
                ])
            case "notifications/initialized", "notifications/cancelled":
                continue
            case "ping":
                respond(id: id, result: [:])
            case "tools/list":
                respond(id: id, result: ["tools": toolDefinitions()])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                let result = await callTool(name: name, args: args)
                respond(id: id, result: result)
            default:
                respondError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    // MARK: - JSON-RPC I/O

    nonisolated private func respond(id: Any?, result: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        writeLine(msg)
    }

    nonisolated private func respondError(id: Any?, code: Int, message: String) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { msg["id"] = id }
        writeLine(msg)
    }

    nonisolated private func writeLine(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    // MARK: - Tool definitions

    private func toolDefinitions() -> [[String: Any]] {
        var tools: [[String: Any]] = [
            tool("bromure_ac_list_profiles",
                 "List all AC profiles with their id, name, color, tool, authMode, and MCP-server count.",
                 [:]),
            tool("bromure_ac_list_sessions",
                 "List currently-open AC session windows.",
                 [:]),
            tool("bromure_ac_open_session",
                 "Launch the session window for a profile. Returns when the window is visible (or after a 30s timeout).",
                 ["profile": prop("string", "Profile name or UUID", required: true)]),
            tool("bromure_ac_close_session",
                 "Close any open session window for the given profile.",
                 ["profile": prop("string", "Profile name or UUID", required: true)]),
            tool("bromure_ac_get_profile",
                 "Return the full Codable-serialized Profile (including nested credentials, MCP servers, etc.) as JSON.",
                 ["profile": prop("string", "Profile name or UUID", required: true)]),
            tool("bromure_ac_set_profile",
                 "Replace a profile atomically from a JSON blob. The profile's id is preserved.",
                 ["profile": prop("string", "Profile name or UUID", required: true),
                  "json": prop("string", "JSON-encoded Profile", required: true)]),
            tool("bromure_ac_get_profile_setting",
                 "Read one simple profile field (name, color, comments, tool, authMode, apiKey, closeAction, memoryGB, folderPathsCount, mcpServerCount, keyboardLayoutOverride, keyRepeatDelayMs, keyRepeatRateHz).",
                 ["profile": prop("string", "Profile name or UUID", required: true),
                  "key": prop("string", "Setting key", required: true)]),
            tool("bromure_ac_set_profile_setting",
                 "Write one simple profile field. See bromure_ac_get_profile_setting for the supported keys.",
                 ["profile": prop("string", "Profile name or UUID", required: true),
                  "key": prop("string", "Setting key", required: true),
                  "value": prop("string", "New value (as text)", required: true)]),
        ]
        if debug {
            tools.append(contentsOf: [
                tool("bromure_ac_app_state",
                     "Debug: full app-state snapshot (locale, window visibility, profile/session counts, hasBaseImage).",
                     [:]),
                tool("bromure_ac_vm_exec",
                     "Debug: execute a shell command inside the profile's VM. Returns stdout, stderr, exit code. Requires BROMURE_DEBUG_CLAUDE on the host and an active session.",
                     ["profile": prop("string", "Profile UUID", required: true),
                      "command": prop("string", "Shell command", required: true),
                      "timeout": prop("number", "Max wait time in seconds (default: 30)")]),
                tool("bromure_ac_vm_read_file",
                     "Debug: read a file from the profile's VM. Returns its contents as text.",
                     ["profile": prop("string", "Profile UUID", required: true),
                      "path": prop("string", "File path inside the VM", required: true)]),
                tool("bromure_ac_vm_write_file",
                     "Debug: write a UTF-8 text file inside the profile's VM.",
                     ["profile": prop("string", "Profile UUID", required: true),
                      "path": prop("string", "File path inside the VM", required: true),
                      "content": prop("string", "File content", required: true),
                      "mode": prop("string", "POSIX mode (default: 644)")]),
            ])
        }
        return tools
    }

    nonisolated private func tool(_ name: String, _ desc: String, _ props: [String: [String: Any]]) -> [String: Any] {
        let required = props.compactMap { (k, v) -> String? in v["_required"] as? Bool == true ? k : nil }
        let cleanProps = props.mapValues { v -> [String: Any] in
            var p = v; p.removeValue(forKey: "_required"); return p
        }
        var schema: [String: Any] = ["type": "object", "properties": cleanProps]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "inputSchema": schema]
    }

    nonisolated private func prop(_ type: String, _ desc: String, required: Bool = false) -> [String: Any] {
        var p: [String: Any] = ["type": type, "description": desc]
        if required { p["_required"] = true }
        return p
    }

    // MARK: - Dispatch

    private func callTool(name: String, args: [String: Any]) async -> [String: Any] {
        do {
            return try await dispatchTool(name: name, args: args)
        } catch {
            return errorResult(error.localizedDescription)
        }
    }

    private func dispatchTool(name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "bromure_ac_list_profiles":
            let r = try await apiCall("GET", "/profiles")
            return textResult(jsonString(r["profiles"] ?? r))
        case "bromure_ac_list_sessions":
            let r = try await apiCall("GET", "/sessions")
            return textResult(jsonString(r["sessions"] ?? r))
        case "bromure_ac_open_session":
            let profile = try requireArg(args, "profile")
            let r = try await apiCall("POST", "/sessions", body: ["profile": profile])
            if let err = r["error"] as? String { throw MCPACError.api(err) }
            return textResult(jsonString(r))
        case "bromure_ac_close_session":
            let profile = try requireArg(args, "profile")
            // Look up the profile UUID so /sessions/{id} resolves
            let profilesResp = try await apiCall("GET", "/profiles")
            let profiles = (profilesResp["profiles"] as? [[String: Any]]) ?? []
            let lower = profile.lowercased()
            guard let id = profiles.first(where: {
                (($0["id"] as? String) ?? "").lowercased() == lower
                || (($0["name"] as? String) ?? "").lowercased() == lower
            })?["id"] as? String else {
                throw MCPACError.api("Profile not found: \(profile)")
            }
            let r = try await apiCall("DELETE", "/sessions/\(id)")
            return textResult(jsonString(r))
        case "bromure_ac_get_profile":
            let profile = try requireArg(args, "profile")
            return textResult(try acScript("get profile json \"\(escapeAS(profile))\""))
        case "bromure_ac_set_profile":
            let profile = try requireArg(args, "profile")
            let json = try requireArg(args, "json")
            let r = try acScript("set profile json \"\(escapeAS(profile))\" to value \"\(escapeAS(json))\"")
            if r != "ok" { throw MCPACError.api(r) }
            return textResult("ok")
        case "bromure_ac_get_profile_setting":
            let profile = try requireArg(args, "profile")
            let key = try requireArg(args, "key")
            return textResult(try acScript("get profile setting \"\(escapeAS(profile))\" key \"\(escapeAS(key))\""))
        case "bromure_ac_set_profile_setting":
            let profile = try requireArg(args, "profile")
            let key = try requireArg(args, "key")
            let value = try requireArg(args, "value")
            let r = try acScript("set profile setting \"\(escapeAS(profile))\" key \"\(escapeAS(key))\" to value \"\(escapeAS(value))\"")
            if r != "ok" { throw MCPACError.api(r) }
            return textResult("ok")
        case "bromure_ac_app_state" where debug:
            let r = try await apiCall("GET", "/app/state")
            return textResult(jsonString(r))
        case "bromure_ac_vm_exec" where debug:
            let profile = try requireArg(args, "profile")
            let command = try requireArg(args, "command")
            let timeout = (args["timeout"] as? Int) ?? Int((args["timeout"] as? Double) ?? 30)
            let r = try await apiCall("POST", "/sessions/\(profile)/exec",
                                      body: ["command": command, "timeout": timeout])
            if let err = r["error"] as? String { throw MCPACError.api(err) }
            var output = ""
            if let stdout = r["stdout"] as? String, !stdout.isEmpty { output += stdout }
            if let stderr = r["stderr"] as? String, !stderr.isEmpty {
                output += (output.isEmpty ? "" : "\n--- stderr ---\n") + stderr
            }
            output += "\n--- exit code: \(r["exitCode"] ?? "?") ---"
            return textResult(output)
        case "bromure_ac_vm_read_file" where debug:
            let profile = try requireArg(args, "profile")
            let path = try requireArg(args, "path")
            let r = try await apiCall("POST", "/sessions/\(profile)/exec",
                                      body: ["command": "cat \(shellQuote(path))", "timeout": 10])
            if let err = r["error"] as? String { throw MCPACError.api(err) }
            if (r["exitCode"] as? Int ?? -1) != 0 {
                throw MCPACError.api(r["stderr"] as? String ?? "read failed")
            }
            return textResult(r["stdout"] as? String ?? "(empty)")
        case "bromure_ac_vm_write_file" where debug:
            let profile = try requireArg(args, "profile")
            let path = try requireArg(args, "path")
            let content = try requireArg(args, "content")
            let mode = (args["mode"] as? String) ?? "644"
            let b64 = Data(content.utf8).base64EncodedString()
            let cmd = "echo '\(b64)' | base64 -d > \(shellQuote(path)) && chmod \(mode) \(shellQuote(path))"
            let r = try await apiCall("POST", "/sessions/\(profile)/exec",
                                      body: ["command": cmd, "timeout": 10])
            if let err = r["error"] as? String { throw MCPACError.api(err) }
            return textResult("Wrote \(content.count) bytes to \(path)")
        default:
            throw MCPACError.unknownTool(name)
        }
    }

    // MARK: - Helpers

    nonisolated private func textResult(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
    }

    nonisolated private func errorResult(_ msg: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(msg)"]], "isError": true]
    }

    nonisolated private func jsonString(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "\(v)" }
        return s
    }

    nonisolated private func requireArg(_ args: [String: Any], _ key: String) throws -> String {
        if let v = args[key] as? String { return v }
        throw MCPACError.missingParam(key)
    }

    nonisolated private func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func acScript(_ cmd: String) throws -> String {
        // osascript subprocess. The MCP server runs out-of-process from
        // the AC app, so this is the cleanest channel for AppleScript-only
        // commands (the HTTP server's surface is intentionally smaller).
        let full = "tell application \"Bromure Agentic Coding\" to \(cmd)"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", full]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - HTTP

    private func apiCall(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let base = apiBase
        let bodyData = body != nil ? try JSONSerialization.data(withJSONObject: body!) : nil
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.rawHTTP(base: base, method: method, path: path, bodyData: bodyData))
            }
        }
    }

    nonisolated private static func rawHTTP(base: String, method: String, path: String, bodyData: Data?) -> [String: Any] {
        guard let url = URL(string: "\(base)\(path)"),
              let host = url.host, let port = url.port else {
            return ["error": "Invalid API URL"]
        }
        let req = "\(method) \(url.path) HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData?.count ?? 0)\r\nConnection: close\r\n\r\n"

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return ["error": "Socket failed"] }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        guard withUnsafePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0 else { return ["error": "Connect failed"] }

        _ = req.withCString { Darwin.write(fd, $0, strlen($0)) }
        if let bodyData {
            _ = bodyData.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!, bodyData.count)
            }
        }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress!, ptr.count)
            }
            if n <= 0 { break }
            response.append(contentsOf: buf[0..<n])
        }

        guard let str = String(data: response, encoding: .utf8),
              let r = str.range(of: "\r\n\r\n") else {
            return ["error": "Invalid HTTP response"]
        }
        let body = Data(str[r.upperBound...].utf8)
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? ["error": "Invalid JSON"]
    }
}

// MARK: - Errors

private enum MCPACError: LocalizedError {
    case missingParam(String)
    case api(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .missingParam(let p): return "Missing required parameter: \(p)"
        case .api(let m):          return m
        case .unknownTool(let n):  return "Unknown tool: \(n)"
        }
    }
}
