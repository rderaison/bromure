import ArgumentParser
import Foundation

// MARK: - CLI Subcommand

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the MCP server for AI tool integration (stdio)."
    )

    @Flag(name: .long, help: "Include debug tools (VM shell access, app state).")
    var debug = false

    @Option(name: .long, help: "Bromure automation API URL.")
    var apiURL: String = "http://127.0.0.1:9222"

    func run() throws {
        let server = MCPServerImpl(apiBase: apiURL, debug: debug)
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

// MARK: - MCP Server

private actor MCPServerImpl {
    let apiBase: String
    let debug: Bool
    /// Active CDP WebSocket connections keyed by sessionId.
    var cdpConns: [String: CDPConnection] = [:]

    init(apiBase: String, debug: Bool) {
        self.apiBase = apiBase
        self.debug = debug
    }

    func run() async {
        // Read stdin on a dedicated thread to avoid blocking the actor's executor,
        // which would prevent async tool handlers from completing.
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

            let id = msg["id"]  // nil for notifications
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                respond(id: id, result: [
                    "protocolVersion": "2025-03-26",
                    "serverInfo": ["name": "bromure", "version": "1.0.0"],
                    "capabilities": ["tools": ["listChanged": false]],
                ])
            case "notifications/initialized", "notifications/cancelled":
                break // no response
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

    // MARK: - Tool Definitions

    private func toolDefinitions() -> [[String: Any]] {
        var tools: [[String: Any]] = [
            tool("bromure_list_profiles",
                 "List all available Bromure browser profiles.",
                 [:]),
            tool("bromure_list_sessions",
                 "List active browser sessions with IDs, profiles, and CDP endpoints.",
                 [:]),
            tool("bromure_open_session",
                 "Open a new sandboxed browser session. Returns the session ID.",
                 ["profile": prop("string", "Profile name", required: true),
                  "url": prop("string", "Initial URL to navigate to")]),
            tool("bromure_close_session",
                 "Close and destroy a browser session.",
                 ["sessionId": prop("string", "Session ID to close", required: true)]),
            tool("bromure_navigate",
                 "Navigate the browser to a URL.",
                 ["sessionId": prop("string", "Session ID", required: true),
                  "url": prop("string", "URL to navigate to", required: true)]),
            tool("bromure_screenshot",
                 "Take a screenshot of the current page. Returns base64-encoded PNG.",
                 ["sessionId": prop("string", "Session ID", required: true),
                  "fullPage": prop("boolean", "Capture full scrollable page"),
                  "selector": prop("string", "CSS selector of element to screenshot")]),
            tool("bromure_click",
                 "Click an element on the page by CSS selector.",
                 ["sessionId": prop("string", "Session ID", required: true),
                  "selector": prop("string", "CSS selector", required: true)]),
            tool("bromure_type",
                 "Type text into an input element.",
                 ["sessionId": prop("string", "Session ID", required: true),
                  "selector": prop("string", "CSS selector of input", required: true),
                  "text": prop("string", "Text to type", required: true),
                  "clear": prop("boolean", "Clear field before typing"),
                  "pressEnter": prop("boolean", "Press Enter after typing")]),
            tool("bromure_evaluate",
                 "Execute JavaScript in the page and return the result.",
                 ["sessionId": prop("string", "Session ID", required: true),
                  "expression": prop("string", "JavaScript expression", required: true)]),
            tool("bromure_get_content",
                 "Get the text content or HTML of the page or a specific element.",
                 ["sessionId": prop("string", "Session ID", required: true),
                  "selector": prop("string", "CSS selector (default: body)"),
                  "format": prop("string", "text or html (default: text)")]),
            tool("bromure_get_links",
                 "Extract all links from the page with their text and URLs.",
                 ["sessionId": prop("string", "Session ID", required: true),
                  "selector": prop("string", "Scope to links within this selector")]),
            tool("bromure_wait_for",
                 "Wait for an element matching the CSS selector to appear.",
                 ["sessionId": prop("string", "Session ID", required: true),
                  "selector": prop("string", "CSS selector to wait for", required: true),
                  "timeout": prop("number", "Max wait time in ms (default: 10000)")]),
            tool("bromure_search",
                 "Search Google and return results. Opens a session, searches, extracts results, closes.",
                 ["query": prop("string", "Search query", required: true),
                  "profile": prop("string", "Profile name (default: Private Browsing)")]),
            tool("bromure_get_page",
                 "Fetch a URL and return its text content. Opens, loads, extracts, closes.",
                 ["url": prop("string", "URL to fetch", required: true),
                  "profile": prop("string", "Profile name (default: Private Browsing)"),
                  "selector": prop("string", "CSS selector to extract (default: body)")]),
        ]
        if debug {
            tools.append(contentsOf: [
                tool("vm_exec",
                     "Execute a shell command inside a VM session. Returns stdout, stderr, exit code.",
                     ["sessionId": prop("string", "Session ID", required: true),
                      "command": prop("string", "Shell command", required: true),
                      "timeout": prop("number", "Timeout in seconds (default: 30)")]),
                tool("vm_read_file",
                     "Read a file from the VM filesystem.",
                     ["sessionId": prop("string", "Session ID", required: true),
                      "path": prop("string", "Absolute path in the VM", required: true)]),
                tool("vm_write_file",
                     "Write content to a file in the VM.",
                     ["sessionId": prop("string", "Session ID", required: true),
                      "path": prop("string", "Absolute path in the VM", required: true),
                      "content": prop("string", "File content", required: true),
                      "mode": prop("string", "File permissions (default: 644)")]),
                tool("vm_processes",
                     "List running processes in the VM.",
                     ["sessionId": prop("string", "Session ID", required: true),
                      "filter": prop("string", "Optional grep filter")]),
                tool("vm_network",
                     "Run network diagnostics in the VM.",
                     ["sessionId": prop("string", "Session ID", required: true),
                      "check": prop("string", "dns, connectivity, proxy, ports, or all (default: all)")]),
                tool("app_health",
                     "Check if the Bromure automation API is reachable.",
                     [:]),
                tool("app_state",
                     "Get app state: phase, pool status, sessions, profiles.",
                     [:]),
                tool("app_sessions",
                     "List active sessions (shorthand).",
                     [:]),
                tool("app_profiles",
                     "List available profiles (shorthand).",
                     [:]),
            ])
        }
        // Trace tools (always available when a session has tracing enabled)
        tools.append(contentsOf: [
            tool("bromure_get_trace",
                 "Get captured HTTP trace events for a session. Supports filtering by hostname, method, status, URL pattern, body content, time range, and tab. Use this to answer questions like 'which pages reached out to google.com?' or 'show all POST requests'.",
                 ["sessionId": prop("string", "Session ID", required: true),
                  "hostname": prop("string", "Filter by hostname (e.g. 'google.com')"),
                  "method": prop("string", "Filter by HTTP method (GET, POST, PUT, DELETE)"),
                  "status": prop("string", "Filter by status: '2xx', '3xx', '4xx', '5xx', or exact code like '200'"),
                  "urlPattern": prop("string", "Filter by URL substring"),
                  "bodyContent": prop("string", "Search in request/response bodies"),
                  "timeFrom": prop("number", "Start time in seconds from session start"),
                  "timeTo": prop("number", "End time in seconds from session start"),
                  "tabId": prop("number", "Filter by browser tab ID"),
                  "limit": prop("number", "Max events to return (default: 100)"),
                  "format": prop("string", "summary or full (default: summary)")]),
            tool("bromure_trace_hostnames",
                 "List all distinct hostnames contacted during a session. Useful for discovering which domains were reached.",
                 ["sessionId": prop("string", "Session ID", required: true)]),
            tool("bromure_trace_summary",
                 "Get an overview of a trace session: total events, unique hostnames, method distribution, status distribution, and top pages by sub-request count.",
                 ["sessionId": prop("string", "Session ID", required: true)]),
            tool("bromure_clear_trace",
                 "Clear all captured trace events for a session.",
                 ["sessionId": prop("string", "Session ID", required: true)]),
        ])
        return tools
    }

    // MARK: - Tool Schema Helpers

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

    // MARK: - Tool Dispatch

    private func callTool(name: String, args: [String: Any]) async -> [String: Any] {
        do {
            let result = try await dispatchTool(name: name, args: args)
            return result
        } catch {
            return ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true]
        }
    }

    private func dispatchTool(name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        // Session management
        case "bromure_list_profiles":   return try await toolListProfiles()
        case "bromure_list_sessions":   return try await toolListSessions()
        case "bromure_open_session":    return try await toolOpenSession(args)
        case "bromure_close_session":   return try await toolCloseSession(args)
        // Browser control
        case "bromure_navigate":        return try await toolNavigate(args)
        case "bromure_screenshot":      return try await toolScreenshot(args)
        case "bromure_click":           return try await toolClick(args)
        case "bromure_type":            return try await toolType(args)
        case "bromure_evaluate":        return try await toolEvaluate(args)
        case "bromure_get_content":     return try await toolGetContent(args)
        case "bromure_get_links":       return try await toolGetLinks(args)
        case "bromure_wait_for":        return try await toolWaitFor(args)
        // Compound
        case "bromure_search":          return try await toolSearch(args)
        case "bromure_get_page":        return try await toolGetPage(args)
        // Debug
        case "vm_exec":                 return try await toolVMExec(args)
        case "vm_read_file":            return try await toolVMReadFile(args)
        case "vm_write_file":           return try await toolVMWriteFile(args)
        case "vm_processes":            return try await toolVMProcesses(args)
        case "vm_network":              return try await toolVMNetwork(args)
        case "app_health":              return try await toolAppHealth()
        case "app_state":               return try await toolAppState()
        case "app_sessions":            return try await toolListSessions()
        case "app_profiles":            return try await toolListProfiles()
        // Trace
        case "bromure_get_trace":       return try await toolGetTrace(args)
        case "bromure_trace_hostnames": return try await toolTraceHostnames(args)
        case "bromure_trace_summary":   return try await toolTraceSummary(args)
        case "bromure_clear_trace":     return try await toolClearTrace(args)
        default:
            throw MCPError.unknownTool(name)
        }
    }

    // MARK: - Text Result Helper

    nonisolated private func text(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
    }

    nonisolated private func image(_ base64: String) -> [String: Any] {
        ["content": [["type": "image", "data": base64, "mimeType": "image/png"]]]
    }

    // MARK: - HTTP API

    /// Raw HTTP request on a background thread (avoids blocking the actor).
    private func apiCall(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let base = apiBase
        let bodyData = body != nil ? try JSONSerialization.data(withJSONObject: body!) : nil
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.rawHTTP(base: base, method: method, path: path, bodyData: bodyData).json)
            }
        }
    }

    /// Raw HTTP returning Data (for CDP /json/list which returns an array).
    private func apiCallRaw(_ method: String, _ path: String) async -> Data? {
        let base = apiBase
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.rawHTTP(base: base, method: method, path: path, bodyData: nil).data)
            }
        }
    }

    /// Synchronous raw socket HTTP. Thread-safe, no actor.
    nonisolated private static func rawHTTP(base: String, method: String, path: String, bodyData: Data?) -> (json: [String: Any], data: Data?) {
        guard let url = URL(string: "\(base)\(path)"),
              let host = url.host, let port = url.port else {
            return (["error": "Invalid API URL"], nil)
        }
        let req = "\(method) \(url.path) HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData?.count ?? 0)\r\nConnection: close\r\n\r\n"

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (["error": "Socket failed"], nil) }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        guard withUnsafePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0 else { return (["error": "Connect failed"], nil) }

        _ = req.withCString { Darwin.write(fd, $0, strlen($0)) }
        if let bodyData {
            bodyData.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, bodyData.count) }
        }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            response.append(contentsOf: buf[0..<n])
        }

        guard let str = String(data: response, encoding: .utf8),
              let r = str.range(of: "\r\n\r\n") else {
            return (["error": "Invalid HTTP response"], nil)
        }
        let body = Data(str[r.upperBound...].utf8)
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? ["error": "Invalid JSON"]
        return (json, body)
    }

    // MARK: - CDP Connection Management

    /// Get or create a CDP connection to the active page of a session.
    private func cdp(for sessionId: String) async throws -> CDPConnection {
        if let existing = cdpConns[sessionId], existing.isConnected {
            return existing
        }

        // Get page targets — retry up to 30s while Chromium boots in the VM

        var targets: [[String: Any]]?
        for attempt in 0..<30 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }

            if let data = await apiCallRaw("GET", "/cdp/\(sessionId)/json/list"),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               !arr.isEmpty {
                targets = arr
                break
            }
        }
        guard let targets else {
            throw MCPError.cdpFailed("Failed to list CDP targets after 30s")
        }
        guard let pageTarget = targets.first(where: { $0["type"] as? String == "page" }),
              let _ = pageTarget["webSocketDebuggerUrl"] as? String else {
            throw MCPError.cdpFailed("No page target found")
        }

        // Rewrite the WebSocket URL to go through our proxy
        let targetId = pageTarget["id"] as? String ?? ""
        let proxyWS = "\(apiBase.replacingOccurrences(of: "http://", with: "ws://"))/cdp/\(sessionId)/devtools/page/\(targetId)"


        let conn = CDPConnection(url: proxyWS)
        try await conn.connect()

        cdpConns[sessionId] = conn
        return conn
    }

    private func disconnectCDP(sessionId: String) {
        cdpConns[sessionId]?.disconnect()
        cdpConns.removeValue(forKey: sessionId)
    }

    // MARK: - Session Tools

    private func toolListProfiles() async throws -> [String: Any] {
        let data = try await apiCall("GET", "/profiles")
        let profiles = data["profiles"] ?? data
        return text(jsonString(profiles))
    }

    private func toolListSessions() async throws -> [String: Any] {
        let data = try await apiCall("GET", "/sessions")
        let sessions = data["sessions"] ?? data
        return text(jsonString(sessions))
    }

    private func toolOpenSession(_ args: [String: Any]) async throws -> [String: Any] {
        let profile = args["profile"] as? String ?? ""
        guard !profile.isEmpty else { throw MCPError.missingParam("profile") }
        var body: [String: Any] = ["profile": profile]
        if let url = args["url"] as? String { body["url"] = url }

        let data = try await apiCall("POST", "/sessions", body: body)
        if let err = data["error"] as? String { throw MCPError.apiFailed(err) }
        let sessionId = data["id"] as? String ?? ""

        // Return immediately — CDP connection happens lazily on first tool use.
        // The VM needs a few seconds to boot Chromium; subsequent tools (navigate,
        // evaluate, etc.) call cdp(for:) which retries up to 30s.
        return text("Session \(sessionId) opened with profile \"\(profile)\". Use bromure_navigate or other tools to interact.")
    }

    private func toolCloseSession(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        guard !sessionId.isEmpty else { throw MCPError.missingParam("sessionId") }
        disconnectCDP(sessionId: sessionId)
        let data = try await apiCall("DELETE", "/sessions/\(sessionId)")
        return text(jsonString(data))
    }

    // MARK: - Browser Tools

    private func toolNavigate(_ args: [String: Any]) async throws -> [String: Any] {
        let conn = try await cdp(for: requireSession(args))
        let url = args["url"] as? String ?? ""
        guard !url.isEmpty else { throw MCPError.missingParam("url") }
        _ = try await conn.send("Page.navigate", params: ["url": url])
        try await conn.waitForLoad()
        let title = try await conn.evaluate("document.title") as? String ?? ""
        let currentURL = try await conn.evaluate("window.location.href") as? String ?? ""
        return text("Navigated to \(currentURL) — title: \"\(title)\"")
    }

    private func toolScreenshot(_ args: [String: Any]) async throws -> [String: Any] {
        let conn = try await cdp(for: requireSession(args))
        let selector = args["selector"] as? String

        if let selector {
            // Element screenshot via JS
            let js = """
                (() => {
                    const el = document.querySelector(\(jsQuote(selector)));
                    if (!el) return null;
                    const r = el.getBoundingClientRect();
                    return {x: r.x, y: r.y, width: r.width, height: r.height, scale: window.devicePixelRatio};
                })()
            """
            guard let rect = try await conn.evaluate(js) as? [String: Any] else {
                throw MCPError.apiFailed("Element not found: \(selector)")
            }
            let clip: [String: Any] = [
                "x": rect["x"] ?? 0, "y": rect["y"] ?? 0,
                "width": rect["width"] ?? 0, "height": rect["height"] ?? 0,
                "scale": rect["scale"] ?? 1,
            ]
            let result = try await conn.send("Page.captureScreenshot", params: ["format": "png", "clip": clip])
            let b64 = result["data"] as? String ?? ""
            return image(b64)
        } else {
            let result = try await conn.send("Page.captureScreenshot", params: ["format": "png"])
            let b64 = result["data"] as? String ?? ""
            return image(b64)
        }
    }

    private func toolClick(_ args: [String: Any]) async throws -> [String: Any] {
        let conn = try await cdp(for: requireSession(args))
        let selector = args["selector"] as? String ?? ""
        let js = "document.querySelector(\(jsQuote(selector)))?.click()"
        _ = try await conn.evaluate(js)
        return text("Clicked: \(selector)")
    }

    private func toolType(_ args: [String: Any]) async throws -> [String: Any] {
        let conn = try await cdp(for: requireSession(args))
        let selector = args["selector"] as? String ?? ""
        let textVal = args["text"] as? String ?? ""
        let clear = args["clear"] as? Bool ?? false
        let pressEnter = args["pressEnter"] as? Bool ?? false

        if clear {
            _ = try await conn.evaluate("""
                (() => { const el = document.querySelector(\(jsQuote(selector))); if(el) { el.focus(); el.select(); } })()
            """)
            _ = try await conn.send("Input.dispatchKeyEvent", params: ["type": "keyDown", "key": "Backspace"])
            _ = try await conn.send("Input.dispatchKeyEvent", params: ["type": "keyUp", "key": "Backspace"])
        }

        _ = try await conn.evaluate("document.querySelector(\(jsQuote(selector)))?.focus()")
        for char in textVal {
            _ = try await conn.send("Input.dispatchKeyEvent", params: [
                "type": "keyDown", "text": String(char), "key": String(char),
            ])
            _ = try await conn.send("Input.dispatchKeyEvent", params: [
                "type": "keyUp", "key": String(char),
            ])
        }
        if pressEnter {
            _ = try await conn.send("Input.dispatchKeyEvent", params: ["type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13])
            _ = try await conn.send("Input.dispatchKeyEvent", params: ["type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13])
        }
        return text("Typed into \(selector)")
    }

    private func toolEvaluate(_ args: [String: Any]) async throws -> [String: Any] {
        let conn = try await cdp(for: requireSession(args))
        let expr = args["expression"] as? String ?? ""
        let result = try await conn.evaluate(expr)
        if let s = result as? String { return text(s) }
        return text(jsonString(result as Any))
    }

    private func toolGetContent(_ args: [String: Any]) async throws -> [String: Any] {
        let conn = try await cdp(for: requireSession(args))
        let sel = args["selector"] as? String ?? "body"
        let fmt = args["format"] as? String ?? "text"
        let prop = fmt == "html" ? "outerHTML" : "innerText"
        let js = "document.querySelector(\(jsQuote(sel)))?.\(prop)"
        var content = try await conn.evaluate(js) as? String ?? ""
        if content.count > 100_000 { content = String(content.prefix(100_000)) + "\n\n[... truncated]" }
        return text(content)
    }

    private func toolGetLinks(_ args: [String: Any]) async throws -> [String: Any] {
        let conn = try await cdp(for: requireSession(args))
        let scope = args["selector"] as? String ?? "body"
        let js = """
            JSON.stringify(Array.from(document.querySelector(\(jsQuote(scope)))?.querySelectorAll('a[href]') ?? []).map(a => ({text: a.innerText.trim().slice(0, 200), href: a.href})))
        """
        let result = try await conn.evaluate(js) as? String ?? "[]"
        return text(result)
    }

    private func toolWaitFor(_ args: [String: Any]) async throws -> [String: Any] {
        let conn = try await cdp(for: requireSession(args))
        let selector = args["selector"] as? String ?? ""
        let timeoutMs = args["timeout"] as? Int ?? 10000
        let js = """
            await new Promise((resolve, reject) => {
                if (document.querySelector(\(jsQuote(selector)))) { resolve(); return; }
                const timeout = setTimeout(() => { observer.disconnect(); reject(new Error('Timeout')); }, \(timeoutMs));
                const observer = new MutationObserver(() => {
                    if (document.querySelector(\(jsQuote(selector)))) { clearTimeout(timeout); observer.disconnect(); resolve(); }
                });
                observer.observe(document.documentElement, {childList: true, subtree: true});
            })
        """
        _ = try await conn.evaluate(js)
        return text("Found: \(selector)")
    }

    // MARK: - Compound Tools

    private func toolSearch(_ args: [String: Any]) async throws -> [String: Any] {
        let query = args["query"] as? String ?? ""
        let profile = args["profile"] as? String ?? "Private Browsing"
        let url = "https://www.google.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"

        let sess = try await apiCall("POST", "/sessions", body: ["profile": profile, "url": url])
        guard let sessionId = sess["id"] as? String else { throw MCPError.apiFailed(sess["error"] as? String ?? "Failed") }
        defer { Task { [sessionId] in disconnectCDP(sessionId: sessionId); _ = try? await apiCall("DELETE", "/sessions/\(sessionId)") } }

        try await Task.sleep(for: .seconds(5))
        let conn = try await cdp(for: sessionId)

        let content = try await conn.evaluate("""
            (document.querySelector('#search') || document.body).innerText.substring(0, 8000)
        """) as? String ?? ""
        return text(content)
    }

    private func toolGetPage(_ args: [String: Any]) async throws -> [String: Any] {
        let url = args["url"] as? String ?? ""
        let profile = args["profile"] as? String ?? "Private Browsing"
        let selector = args["selector"] as? String ?? "body"

        let sess = try await apiCall("POST", "/sessions", body: ["profile": profile, "url": url])
        guard let sessionId = sess["id"] as? String else { throw MCPError.apiFailed(sess["error"] as? String ?? "Failed") }
        defer { Task { [sessionId] in disconnectCDP(sessionId: sessionId); _ = try? await apiCall("DELETE", "/sessions/\(sessionId)") } }

        try await Task.sleep(for: .seconds(5))
        let conn = try await cdp(for: sessionId)

        var content = try await conn.evaluate("document.querySelector(\(jsQuote(selector)))?.innerText") as? String ?? ""
        if content.count > 100_000 { content = String(content.prefix(100_000)) + "\n\n[... truncated]" }
        return text(content)
    }

    // MARK: - Debug Tools

    private func toolVMExec(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        let command = args["command"] as? String ?? ""
        let timeout = args["timeout"] as? Int ?? 30
        let data = try await apiCall("POST", "/sessions/\(sessionId)/exec", body: ["command": command, "timeout": timeout])
        if let err = data["error"] as? String { throw MCPError.apiFailed(err) }
        var output = ""
        if let stdout = data["stdout"] as? String, !stdout.isEmpty { output += stdout }
        if let stderr = data["stderr"] as? String, !stderr.isEmpty { output += (output.isEmpty ? "" : "\n--- stderr ---\n") + stderr }
        if output.isEmpty { output = "(no output)" }
        output += "\n--- exit code: \(data["exitCode"] ?? "?") ---"
        return text(output)
    }

    private func toolVMReadFile(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        let path = args["path"] as? String ?? ""
        let data = try await apiCall("POST", "/sessions/\(sessionId)/exec", body: ["command": "cat \(shellQuote(path))", "timeout": 10])
        if let err = data["error"] as? String { throw MCPError.apiFailed(err) }
        if (data["exitCode"] as? Int ?? -1) != 0 { throw MCPError.apiFailed(data["stderr"] as? String ?? "read failed") }
        return text(data["stdout"] as? String ?? "(empty)")
    }

    private func toolVMWriteFile(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        let path = args["path"] as? String ?? ""
        let content = args["content"] as? String ?? ""
        let mode = args["mode"] as? String ?? "644"
        let b64 = Data(content.utf8).base64EncodedString()
        let cmd = "echo '\(b64)' | base64 -d > \(shellQuote(path)) && chmod \(mode) \(shellQuote(path))"
        let data = try await apiCall("POST", "/sessions/\(sessionId)/exec", body: ["command": cmd, "timeout": 10])
        if let err = data["error"] as? String { throw MCPError.apiFailed(err) }
        return text("Wrote \(content.count) bytes to \(path)")
    }

    private func toolVMProcesses(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        let filter = args["filter"] as? String
        var cmd = "ps aux"
        if let f = filter { cmd += " | grep -i \(shellQuote(f)) | grep -v grep" }
        let data = try await apiCall("POST", "/sessions/\(sessionId)/exec", body: ["command": cmd, "timeout": 10])
        return text(data["stdout"] as? String ?? "(no processes)")
    }

    private func toolVMNetwork(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        let check = args["check"] as? String ?? "all"
        var cmds: [String] = []
        if check == "dns" || check == "all" { cmds.append("echo '=== DNS ===' && cat /etc/resolv.conf && nslookup google.com 2>&1 | head -10") }
        if check == "connectivity" || check == "all" { cmds.append("echo '=== CONNECTIVITY ===' && wget -qO /dev/null --spider http://google.com 2>&1 && echo OK || echo FAILED") }
        if check == "proxy" || check == "all" { cmds.append("echo '=== PROXY ===' && ps aux | grep -E 'squid|proxychains' | grep -v grep") }
        if check == "ports" || check == "all" { cmds.append("echo '=== PORTS ===' && netstat -tlnp 2>/dev/null || ss -tlnp") }
        let cmd = cmds.joined(separator: " ; ")
        let data = try await apiCall("POST", "/sessions/\(sessionId)/exec", body: ["command": cmd, "timeout": 15])
        return text(data["stdout"] as? String ?? "(no output)")
    }

    private func toolAppHealth() async throws -> [String: Any] {
        let data = try await apiCall("GET", "/health")
        return text(jsonString(data))
    }

    private func toolAppState() async throws -> [String: Any] {
        let data = try await apiCall("GET", "/app/state")
        return text(jsonString(data))
    }

    // MARK: - Trace Tools

    private func toolGetTrace(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        guard !sessionId.isEmpty else { throw MCPError.missingParam("sessionId") }
        let limit = args["limit"] as? Int ?? 100
        let format = args["format"] as? String ?? "summary"

        // Build query string from filter parameters
        var query = ""
        if let h = args["hostname"] as? String { query += "&hostname=\(h)" }
        if let m = args["method"] as? String { query += "&method=\(m)" }
        if let s = args["status"] as? String { query += "&status=\(s)" }
        if let u = args["urlPattern"] as? String { query += "&url=\(u.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? u)" }
        if let b = args["bodyContent"] as? String { query += "&body=\(b.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? b)" }
        if let tf = args["timeFrom"] as? Double { query += "&timeFrom=\(tf)" }
        if let tt = args["timeTo"] as? Double { query += "&timeTo=\(tt)" }
        if let tab = args["tabId"] as? Int { query += "&tabId=\(tab)" }
        let path = query.isEmpty ? "/sessions/\(sessionId)/trace" : "/sessions/\(sessionId)/trace?\(query.dropFirst())"

        let data = try await apiCall("GET", path)
        if let err = data["error"] as? String { throw MCPError.apiFailed(err) }
        guard let events = data["events"] as? [[String: Any]] else { return text("No trace data") }

        let limited = Array(events.suffix(limit))
        if format == "full" {
            return text(jsonString(limited))
        }
        // Summary: one line per event
        let lines = limited.map { e -> String in
            let ts = String(format: "%.3f", e["timestamp"] as? Double ?? 0)
            let method = e["method"] as? String ?? "?"
            let host = e["hostname"] as? String ?? ""
            let url = e["url"] as? String ?? "?"
            let status = (e["statusCode"] as? Int).map { String($0) } ?? "-"
            let dur = (e["duration"] as? Double).map { String(format: "%.0fms", $0) } ?? "-"
            return "\(ts) \(method) \(status) \(host) \(dur) \(url)"
        }
        let header = "\(events.count) events total, showing last \(limited.count):\n"
        return text(header + lines.joined(separator: "\n"))
    }

    private func toolTraceHostnames(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        guard !sessionId.isEmpty else { throw MCPError.missingParam("sessionId") }

        let data = try await apiCall("GET", "/sessions/\(sessionId)/trace")
        guard let events = data["events"] as? [[String: Any]] else { return text("No trace data") }

        // Extract unique hostnames with request counts
        var hostCounts: [String: Int] = [:]
        for e in events {
            let host = e["hostname"] as? String ?? "(unknown)"
            hostCounts[host, default: 0] += 1
        }
        let sorted = hostCounts.sorted { $0.value > $1.value }
        let lines = sorted.map { "\($0.value) requests — \($0.key)" }
        return text("\(sorted.count) unique hostnames:\n" + lines.joined(separator: "\n"))
    }

    private func toolTraceSummary(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        guard !sessionId.isEmpty else { throw MCPError.missingParam("sessionId") }

        let data = try await apiCall("GET", "/sessions/\(sessionId)/trace")
        guard let events = data["events"] as? [[String: Any]] else { return text("No trace data") }

        let total = events.count

        // Unique hostnames
        let hostnames = Set(events.compactMap { $0["hostname"] as? String })

        // Method distribution
        var methods: [String: Int] = [:]
        for e in events { methods[e["method"] as? String ?? "?", default: 0] += 1 }

        // Status distribution
        var statuses: [String: Int] = [:]
        for e in events {
            if let code = e["statusCode"] as? Int {
                let cat = "\(code / 100)xx"
                statuses[cat, default: 0] += 1
            } else {
                statuses["error", default: 0] += 1
            }
        }

        // Top pages by sub-request count (group by documentUrl)
        var pageCounts: [String: Int] = [:]
        for e in events {
            let page = e["documentUrl"] as? String ?? e["url"] as? String ?? "?"
            pageCounts[page, default: 0] += 1
        }
        let topPages = pageCounts.sorted { $0.value > $1.value }.prefix(10)

        var output = "=== Trace Summary ===\n"
        output += "Total events: \(total)\n"
        output += "Unique hostnames: \(hostnames.count)\n\n"
        output += "Methods:\n"
        for (m, c) in methods.sorted(by: { $0.value > $1.value }) { output += "  \(m): \(c)\n" }
        output += "\nStatus codes:\n"
        for (s, c) in statuses.sorted(by: { $0.key < $1.key }) { output += "  \(s): \(c)\n" }
        output += "\nTop pages:\n"
        for (url, c) in topPages {
            let short = url.count > 60 ? String(url.prefix(57)) + "..." : url
            output += "  \(c) req — \(short)\n"
        }
        return text(output)
    }

    private func toolClearTrace(_ args: [String: Any]) async throws -> [String: Any] {
        let sessionId = args["sessionId"] as? String ?? ""
        guard !sessionId.isEmpty else { throw MCPError.missingParam("sessionId") }
        return text("Trace cleared for session \(sessionId)")
    }

    // MARK: - Utilities

    private func requireSession(_ args: [String: Any]) throws -> String {
        guard let s = args["sessionId"] as? String, !s.isEmpty else { throw MCPError.missingParam("sessionId") }
        return s
    }

    nonisolated private func jsonString(_ obj: Any) -> String {
        // JSONSerialization.data(withJSONObject:) throws an NSInvalidArgumentException
        // (Obj-C, not catchable with try?) when the graph contains NaN/Infinity or
        // non-String keys — which can happen with CDP eval results from pages that
        // return non-finite numbers. Sanitize first.
        let safe = Self.sanitizeForJSON(obj)
        guard JSONSerialization.isValidJSONObject(safe),
              let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return String(describing: obj) }
        return s
    }

    /// Recursively replace values that would crash JSONSerialization:
    ///   - NaN / ±Infinity doubles → NSNull
    ///   - non-String dictionary keys → their String(describing:) form
    ///   - unknown reference types → their String(describing:) form
    nonisolated private static func sanitizeForJSON(_ obj: Any) -> Any {
        if let dict = obj as? [String: Any] {
            return dict.mapValues { sanitizeForJSON($0) }
        }
        if let dict = obj as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[String(describing: k)] = sanitizeForJSON(v) }
            return out
        }
        if let arr = obj as? [Any] {
            return arr.map { sanitizeForJSON($0) }
        }
        if let d = obj as? Double {
            return d.isFinite ? d : NSNull()
        }
        if let f = obj as? Float {
            return f.isFinite ? f : NSNull()
        }
        if let n = obj as? NSNumber {
            // NSNumber may wrap a non-finite double. CFNumber's type check is
            // the only reliable way to know it's floating-point before reading.
            let t = CFNumberGetType(n)
            if t == .doubleType || t == .float32Type || t == .float64Type || t == .cgFloatType {
                let d = n.doubleValue
                if !d.isFinite { return NSNull() }
            }
            return n
        }
        return obj
    }

    nonisolated private func jsQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "'\(escaped)'"
    }

    nonisolated private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - CDP WebSocket Connection

private final class CDPConnection: @unchecked Sendable {
    private let url: URL
    private var fd: Int32 = -1
    private var nextId = 1
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: Any], any Error>] = [:]
    private(set) var isConnected = false

    init(url: String) {
        self.url = URL(string: url)!
    }

    /// Connect via raw socket + WebSocket handshake on a background thread.
    func connect() async throws {
        let connectURL = url
        let result: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let host = connectURL.host, let port = connectURL.port else {
                    continuation.resume(throwing: MCPError.cdpFailed("Invalid CDP URL"))
                    return
                }

                let sockFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                guard sockFD >= 0 else {
                    continuation.resume(throwing: MCPError.cdpFailed("Socket failed"))
                    return
                }

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                addr.sin_addr.s_addr = inet_addr(host)
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(sockFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard ok == 0 else {
                    Darwin.close(sockFD)
                    continuation.resume(throwing: MCPError.cdpFailed("Connect failed"))
                    return
                }

                // WebSocket upgrade handshake
                var keyBytes = [UInt8](repeating: 0, count: 16)
                _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
                let wsKey = Data(keyBytes).base64EncodedString()
                let path = connectURL.path.isEmpty ? "/" : connectURL.path

                let upgradeReq = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(wsKey)\r\nSec-WebSocket-Version: 13\r\n\r\n"
                _ = upgradeReq.withCString { Darwin.write(sockFD, $0, strlen($0)) }

                // Read upgrade response
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(sockFD, &buf, buf.count)
                guard n > 0, let resp = String(bytes: buf[0..<n], encoding: .utf8), resp.contains("101") else {
                    Darwin.close(sockFD)
                    continuation.resume(throwing: MCPError.cdpFailed("WebSocket upgrade failed"))
                    return
                }

                continuation.resume(returning: sockFD)
            }
        }

        self.fd = result
        isConnected = true

        // Start reading frames on a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.receiveLoop()
        }
    }

    func disconnect() {
        isConnected = false
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        lock.lock()
        let p = pending
        pending.removeAll()
        lock.unlock()
        for (_, cont) in p { cont.resume(throwing: MCPError.cdpFailed("Disconnected")) }
    }

    func send(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        guard fd >= 0, isConnected else { throw MCPError.cdpFailed("Not connected") }
        let id: Int = lock.withLock { let v = nextId; nextId += 1; return v }

        var msg: [String: Any] = ["id": id, "method": method]
        if let params { msg["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: msg)

        // Store continuation BEFORE writing frame to avoid race with receiveLoop
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[id] = cont
            lock.unlock()
            Self.writeWSFrame(fd: fd, data: data)
        }
    }

    func evaluate(_ expression: String) async throws -> Any? {
        let params: [String: Any] = ["expression": expression, "returnByValue": true, "awaitPromise": true]
        let result = try await send("Runtime.evaluate", params: params)
        if let exn = result["exceptionDetails"] as? [String: Any],
           let text = (exn["exception"] as? [String: Any])?["description"] as? String {
            throw MCPError.cdpFailed(text)
        }
        let r = result["result"] as? [String: Any]
        return r?["value"]
    }

    func waitForLoad(timeout: TimeInterval = 15) async throws {
        _ = try? await send("Page.enable")
        _ = try? await evaluate("await new Promise(r => { if (document.readyState === 'complete') r(); else window.addEventListener('load', r, {once: true}); setTimeout(r, \(Int(timeout * 1000))); })")
    }

    // MARK: - Raw WebSocket frame I/O

    /// Write a WebSocket text frame (masked, as required by client-to-server).
    private static func writeWSFrame(fd: Int32, data: Data) {
        var frame = Data()
        frame.append(0x81) // FIN + text opcode
        let len = data.count
        if len < 126 {
            frame.append(UInt8(len) | 0x80) // masked
        } else if len < 65536 {
            frame.append(126 | 0x80)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127 | 0x80)
            for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) }
        }
        // Mask key (random)
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        frame.append(contentsOf: mask)
        // Masked payload
        for (i, byte) in data.enumerated() {
            frame.append(byte ^ mask[i % 4])
        }
        frame.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, frame.count) }
    }

    /// Read WebSocket frames continuously on a background thread.
    private func receiveLoop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var accumulated = Data()

        while isConnected && fd >= 0 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            accumulated.append(contentsOf: buf[0..<n])

            // Parse complete frames from accumulated data
            while let (payload, consumed) = Self.parseWSFrame(accumulated) {
                accumulated = Data(accumulated.dropFirst(consumed))
                handleMessage(payload)
            }
        }
        isConnected = false
        // Fail any pending continuations
        lock.lock()
        let p = pending
        pending.removeAll()
        lock.unlock()
        for (_, cont) in p { cont.resume(throwing: MCPError.cdpFailed("Connection closed")) }
    }

    /// Parse one WebSocket frame from data. Returns (payload, bytesConsumed) or nil if incomplete.
    private static func parseWSFrame(_ data: Data) -> (Data, Int)? {
        guard data.count >= 2 else { return nil }
        let byte1 = data[1] & 0x7F
        var offset = 2
        var payloadLen: Int

        if byte1 < 126 {
            payloadLen = Int(byte1)
        } else if byte1 == 126 {
            guard data.count >= 4 else { return nil }
            payloadLen = Int(data[2]) << 8 | Int(data[3])
            offset = 4
        } else {
            guard data.count >= 10 else { return nil }
            payloadLen = 0
            for i in 0..<8 { payloadLen = (payloadLen << 8) | Int(data[2 + i]) }
            offset = 10
        }

        // Server frames are not masked
        guard data.count >= offset + payloadLen else { return nil }
        let payload = Data(data[offset..<offset + payloadLen])
        return (payload, offset + payloadLen)
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let id = json["id"] as? Int else { return } // ignore events
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        if let error = json["error"] as? [String: Any] {
            cont?.resume(throwing: MCPError.cdpFailed(error["message"] as? String ?? "CDP error"))
        } else {
            cont?.resume(returning: json["result"] as? [String: Any] ?? [:])
        }
    }
}

// MARK: - Errors

private enum MCPError: LocalizedError {
    case missingParam(String)
    case apiFailed(String)
    case cdpFailed(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .missingParam(let p): return "Missing required parameter: \(p)"
        case .apiFailed(let m): return m
        case .cdpFailed(let m): return "CDP: \(m)"
        case .unknownTool(let n): return "Unknown tool: \(n)"
        }
    }
}
