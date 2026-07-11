import BrowserBridges
import Foundation
import SandboxEngine

// The browser MCP server exposed to the in-VM coding agents: navigate, tabs,
// screenshot, evaluate JS, read page text — so Claude/Codex/Grok can drive and
// inspect the workspace's embedded browser. Transport-agnostic: `handle(line:)`
// takes one JSON-RPC request line and returns the response line (nil for
// notifications). The transport (a guest stdio shim ↔ vsock ↔ this handler)
// and the ~/.claude.json config injection are wired separately.
//
// Tools are backed by the workspace's WorkspaceBrowserController — navigate/
// tabs via TabBridge, screenshot/eval/text via BrowserCDP. A tool call on a
// not-yet-open browser opens it (ensureBrowser) and waits briefly for the
// guest agents to connect.

@MainActor
final class BrowserMCPServer {
    /// Resolves the workspace's browser controller (nil until opened).
    private let browser: () -> WorkspaceBrowserController?
    /// Opens the browser pane + boots the VM (agent-initiated open).
    private let ensureBrowser: () -> Void

    init(browser: @escaping () -> WorkspaceBrowserController?,
         ensureBrowser: @escaping () -> Void) {
        self.browser = browser
        self.ensureBrowser = ensureBrowser
    }

    // MARK: - JSON-RPC line handling

    /// Handle one request line; returns the response line, or nil for a
    /// notification (no id).
    func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return respond(id: id, result: [
                "protocolVersion": "2025-03-26",
                "serverInfo": ["name": "bromure-browser", "version": "1.0.0"],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": Self.serverInstructions,
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return respond(id: id, result: [:])
        case "tools/list":
            return respond(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = await callTool(name: name, args: args)
            return respond(id: id, result: result)
        default:
            guard id != nil else { return nil }
            return respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Dispatch

    private func callTool(name: String, args: [String: Any]) async -> [String: Any] {
        do {
            let b = try await readyBrowser()
            // Register the console-capture hook before anything navigates, so
            // page-load errors are buffered from the start (idempotent, cheap).
            await b.ensureConsoleHook()
            switch name {
            case "browser_navigate":
                let url = try requireArg(args, "url")
                b.navigate(url)
                return textResult("Navigating to \(url)")
            case "browser_new_tab":
                b.newTab((args["url"] as? String) ?? "")
                return textResult("Opened a new tab")
            case "browser_list_tabs":
                let tabs = b.tabs().map { t -> [String: Any] in
                    ["id": t.id, "title": t.title, "url": t.url, "active": t.active]
                }
                return textResult(jsonString(tabs))
            case "browser_activate_tab":
                b.activateTab(try requireArg(args, "id")); return textResult("ok")
            case "browser_close_tab":
                b.closeTab(try requireArg(args, "id")); return textResult("ok")
            case "browser_back": b.back(); return textResult("ok")
            case "browser_forward": b.forward(); return textResult("ok")
            case "browser_reload": b.reload(); return textResult("ok")
            case "browser_screenshot":
                let full = (args["fullPage"] as? Bool) ?? false
                let png = try await b.screenshot(fullPage: full)
                return imageResult(png)
            case "browser_evaluate":
                let js = try requireArg(args, "expression")
                let value = try await b.evaluate(js)
                return textResult(jsonString(value ?? NSNull()))
            case "browser_get_text":
                return textResult(try await b.pageText())
            case "browser_get_html":
                let sel = (args["selector"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "html"
                return textResult(try await b.html(selector: sel))
            case "browser_get_links":
                let sel = (args["selector"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "body"
                return textResult(try await b.links(selector: sel))
            case "browser_click":
                let sel = try requireArg(args, "selector")
                let ok = try await b.click(selector: sel)
                return ok ? textResult("Clicked: \(sel)")
                          : errorResult("No element matched selector: \(sel)")
            case "browser_fill":
                let sel = try requireArg(args, "selector")
                let value = args["value"] as? String ?? ""
                let ok = try await b.fill(selector: sel, value: value)
                return ok ? textResult("Filled: \(sel)")
                          : errorResult("No element matched selector: \(sel)")
            case "browser_type":
                let sel = try requireArg(args, "selector")
                let text = args["text"] as? String ?? ""
                let clear = (args["clear"] as? Bool) ?? false
                let submit = (args["submit"] as? Bool) ?? (args["pressEnter"] as? Bool) ?? false
                try await b.type(selector: sel, text: text, clear: clear, submit: submit)
                return textResult("Typed into \(sel)")
            case "browser_press_key":
                let key = try requireArg(args, "key")
                try await b.pressKey(key)
                return textResult("Pressed \(key)")
            case "browser_wait_for":
                let sel = try requireArg(args, "selector")
                let timeout = (args["timeout"] as? Int) ?? 10000
                try await b.waitFor(selector: sel, timeoutMs: timeout)
                return textResult("Found: \(sel)")
            case "browser_network":
                return networkResult(b, args)
            case "browser_network_summary":
                return networkSummary(b)
            case "browser_clear_network":
                b.clearNetwork(); return textResult("Network log cleared")
            case "browser_pick_element":
                guard let picked = try await b.pickElement() else {
                    return textResult("Element pick cancelled or timed out (no element clicked).")
                }
                let sel = picked["selector"] as? String ?? ""
                let tag = picked["tag"] as? String ?? ""
                let txt = picked["text"] as? String ?? ""
                return textResult("Picked <\(tag)>"
                    + (txt.isEmpty ? "" : " \"\(txt)\"")
                    + "\nselector: \(sel)")
            case "browser_console":
                let clear = (args["clear"] as? Bool) ?? false
                let level = (args["level"] as? String)?.lowercased()
                var logs = try await b.consoleLogs(clear: clear)
                if let level, level != "all" { logs = logs.filter { ($0["level"] as? String) == level } }
                if logs.isEmpty { return textResult("No console output captured.") }
                let lines = logs.map { e -> String in
                    let lvl = (e["level"] as? String ?? "log").uppercased()
                    return "[\(lvl)] \(e["text"] as? String ?? "")"
                }
                return textResult(lines.joined(separator: "\n"))
            default:
                return errorResult("Unknown tool: \(name)")
            }
        } catch {
            return errorResult(error.localizedDescription)
        }
    }

    // MARK: - Network trace helpers

    private func networkResult(_ b: WorkspaceBrowserController, _ args: [String: Any]) -> [String: Any] {
        var f = TraceFilter()
        if let h = args["hostname"] as? String, !h.isEmpty { f.hostnames = [h] }
        if let m = args["method"] as? String, !m.isEmpty { f.methods = [m.uppercased()] }
        if let s = args["status"] as? String, let d = Int(s.prefix(1)), (1...5).contains(d) {
            f.statusCategories = [d]   // 2 → 2xx, 4 → 4xx, …
        }
        if let u = args["urlPattern"] as? String, !u.isEmpty { f.searchText = u }
        let events = b.networkEvents(filter: f)
        let limit = (args["limit"] as? Int) ?? 100
        let limited = Array(events.suffix(limit))
        if (args["format"] as? String) == "full" {
            if let data = try? JSONEncoder().encode(limited),
               let s = String(data: data, encoding: .utf8) { return textResult(s) }
        }
        let lines = limited.map { e -> String in
            let status = e.statusCode.map(String.init) ?? (e.errorText != nil ? "ERR" : "-")
            let host = e.hostname ?? URLComponents(string: e.url)?.host ?? ""
            let dur = e.duration.map { String(format: "%.0fms", $0) } ?? "-"
            return "\(e.method) \(status) \(host) \(dur) \(e.url)"
        }
        let header = "\(events.count) requests total, showing last \(limited.count):\n"
        return textResult(events.isEmpty ? "No network requests recorded yet." : header + lines.joined(separator: "\n"))
    }

    private func networkSummary(_ b: WorkspaceBrowserController) -> [String: Any] {
        let events = b.networkEvents(filter: .all)
        if events.isEmpty { return textResult("No network requests recorded yet.") }
        var hosts: [String: Int] = [:], methods: [String: Int] = [:], statuses: [String: Int] = [:]
        for e in events {
            hosts[e.hostname ?? URLComponents(string: e.url)?.host ?? "(unknown)", default: 0] += 1
            methods[e.method, default: 0] += 1
            if let code = e.statusCode, code > 0 { statuses["\(code / 100)xx", default: 0] += 1 }
            else { statuses["error", default: 0] += 1 }
        }
        var out = "=== Network summary ===\n\(events.count) requests, \(hosts.count) hostnames\n\nMethods:\n"
        for (m, c) in methods.sorted(by: { $0.value > $1.value }) { out += "  \(m): \(c)\n" }
        out += "\nStatus:\n"
        for (s, c) in statuses.sorted(by: { $0.key < $1.key }) { out += "  \(s): \(c)\n" }
        out += "\nTop hosts:\n"
        for (h, c) in hosts.sorted(by: { $0.value > $1.value }).prefix(15) { out += "  \(c) — \(h)\n" }
        return textResult(out)
    }

    /// The controller, opening the browser and waiting for it to come up if
    /// needed. The browser VM isn't pre-warmed, so the first call cold-boots it
    /// (VM + Chromium + guest agents) — allow a generous 90s so the agent's
    /// first navigate doesn't spuriously time out and retry. Throws if it never
    /// comes up.
    private func readyBrowser() async throws -> WorkspaceBrowserController {
        if browser()?.isReady == true { return browser()! }
        ensureBrowser()
        for _ in 0..<900 {   // ~90s @ 100ms
            if let b = browser(), b.isReady { return b }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MCPBrowserError.notReady
    }

    // MARK: - Tool schema

    /// Surfaced to the agent at initialize. The CRITICAL point: the browser is
    /// a SEPARATE VM from this workspace, so localhost differs between them.
    static let serverInstructions = """
    Controls a real Chromium browser running in a separate, disposable VM on \
    the same LAN as this workspace.

    CRITICAL — reaching a server you run in THIS workspace: the browser runs in \
    a DIFFERENT VM, so 127.0.0.1 / localhost inside the browser point at the \
    browser's own VM, NOT this workspace. To open a dev server (e.g. one you \
    started on port 3000) in the browser, navigate to this workspace's LAN IP, \
    e.g. http://192.168.x.x:3000 — find it with `hostname -I` (the 192.168.x.x \
    address). NEVER use http://localhost:PORT or http://127.0.0.1:PORT with \
    browser_navigate; it will not reach your server.

    Interacting: browser_click / browser_fill (fast) or browser_type (real \
    keystrokes) / browser_press_key drive the page by CSS selector; \
    browser_wait_for blocks until an element appears. Inspecting: \
    browser_screenshot, browser_get_text, browser_get_html, browser_get_links, \
    browser_evaluate. Debugging (verify your app the way you'd verify it by \
    hand): browser_console shows console output + uncaught errors, and \
    browser_network / browser_network_summary show the request log — call \
    browser_clear_network for a clean baseline before an action, then re-read.
    """

    static let toolDefinitions: [[String: Any]] = [
        tool("browser_navigate",
             "Navigate the active tab to a URL (or search terms). To open a "
             + "server running in THIS workspace, use the workspace's LAN IP "
             + "(192.168.x.x from `hostname -I`), NOT localhost/127.0.0.1 — the "
             + "browser is a separate VM.",
             ["url": prop("string", "URL or search query", required: true)]),
        tool("browser_new_tab", "Open a new tab, optionally at a URL.",
             ["url": prop("string", "URL to open (optional)")]),
        tool("browser_list_tabs", "List the open tabs (id, title, url, active).", [:]),
        tool("browser_activate_tab", "Switch to a tab by id.",
             ["id": prop("string", "Tab id", required: true)]),
        tool("browser_close_tab", "Close a tab by id.",
             ["id": prop("string", "Tab id", required: true)]),
        tool("browser_back", "Go back in the active tab's history.", [:]),
        tool("browser_forward", "Go forward in the active tab's history.", [:]),
        tool("browser_reload", "Reload the active tab.", [:]),
        tool("browser_screenshot", "Capture a PNG screenshot of the active page.",
             ["fullPage": prop("boolean", "Capture the whole scrollable page (default false)")]),
        tool("browser_evaluate", "Evaluate a JavaScript expression in the active page and return its value.",
             ["expression": prop("string", "JavaScript expression", required: true)]),
        tool("browser_get_text", "Return the active page's visible text (document.body.innerText).", [:]),
        tool("browser_get_html", "Return the outerHTML of a CSS selector (default the whole page). Truncated at 100k chars.",
             ["selector": prop("string", "CSS selector (default 'html')")]),
        tool("browser_get_links", "Return all links (text + href) under a CSS selector (default 'body') as JSON.",
             ["selector": prop("string", "CSS selector scope (default 'body')")]),
        tool("browser_click", "Click the first element matching a CSS selector.",
             ["selector": prop("string", "CSS selector", required: true)]),
        tool("browser_fill", "Set an input/textarea/contenteditable's value and fire input+change (fast form fill).",
             ["selector": prop("string", "CSS selector", required: true),
              "value": prop("string", "Value to set")]),
        tool("browser_type", "Type real key events into an element (drives keydown handlers). Optionally clear first / press Enter after.",
             ["selector": prop("string", "CSS selector", required: true),
              "text": prop("string", "Text to type"),
              "clear": prop("boolean", "Clear the field first (default false)"),
              "submit": prop("boolean", "Press Enter after typing (default false)")]),
        tool("browser_press_key", "Press a single named key in the active page (Enter, Tab, Escape, ArrowDown, PageDown, …).",
             ["key": prop("string", "Key name", required: true)]),
        tool("browser_wait_for", "Wait until a CSS selector appears (or time out).",
             ["selector": prop("string", "CSS selector", required: true),
              "timeout": prop("integer", "Timeout in ms (default 10000)")]),
        tool("browser_network",
             "List recorded network requests (method, status, host, duration, url). "
             + "Great for debugging failed requests. Filterable; newest last.",
             ["hostname": prop("string", "Only requests to this host"),
              "method": prop("string", "Only this HTTP method (GET/POST/…)"),
              "status": prop("string", "Status class: '2xx','4xx','5xx' (matches on the first digit)"),
              "urlPattern": prop("string", "Substring the URL/host must contain"),
              "limit": prop("integer", "Max rows (default 100, newest)"),
              "format": prop("string", "'summary' (default, one line each) or 'full' (JSON with headers/bodies)")]),
        tool("browser_network_summary",
             "Aggregate view of recorded requests: counts by host, method, and status class.", [:]),
        tool("browser_clear_network",
             "Clear the recorded network log — call before an action to get a clean baseline.", [:]),
        tool("browser_console",
             "Read the page's captured console output + uncaught errors/rejections. "
             + "Essential for debugging why a page misbehaves.",
             ["level": prop("string", "Filter: 'error','warn','log','info','debug' or 'all' (default)"),
              "clear": prop("boolean", "Clear the buffer after reading (default false)")]),
        tool("browser_pick_element",
             "Ask the user to point at an element: highlights elements on hover in "
             + "the browser and returns the CSS selector of the one they click. Use "
             + "when the user refers to something on the page you can't unambiguously "
             + "target — tell them to click it. Waits up to 60s.", [:]),
    ]

    // MARK: - JSON-RPC / result helpers

    private func respond(id: Any?, result: [String: Any]) -> String {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        return Self.line(msg)
    }
    private func respondError(id: Any?, code: Int, message: String) -> String {
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { msg["id"] = id }
        return Self.line(msg)
    }
    private static func line(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func textResult(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
    }
    private func imageResult(_ png: Data) -> [String: Any] {
        ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]]
    }
    private func errorResult(_ msg: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(msg)"]], "isError": true]
    }
    private func jsonString(_ v: Any) -> String {
        if let s = v as? String { return s }
        guard JSONSerialization.isValidJSONObject(v)
                || JSONSerialization.isValidJSONObject([v]),
              let data = try? JSONSerialization.data(withJSONObject: v),
              let s = String(data: data, encoding: .utf8) else { return "\(v)" }
        return s
    }
    private func requireArg(_ args: [String: Any], _ key: String) throws -> String {
        if let v = args[key] as? String, !v.isEmpty { return v }
        throw MCPBrowserError.missingParam(key)
    }

    private static func tool(_ name: String, _ desc: String,
                             _ props: [String: [String: Any]]) -> [String: Any] {
        let required = props.compactMap { (k, v) -> String? in v["_required"] as? Bool == true ? k : nil }
        let cleanProps = props.mapValues { v -> [String: Any] in
            var p = v; p.removeValue(forKey: "_required"); return p
        }
        var schema: [String: Any] = ["type": "object", "properties": cleanProps]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "inputSchema": schema]
    }
    private static func prop(_ type: String, _ desc: String, required: Bool = false) -> [String: Any] {
        var p: [String: Any] = ["type": type, "description": desc]
        if required { p["_required"] = true }
        return p
    }
}

enum MCPBrowserError: LocalizedError {
    case missingParam(String)
    case notReady
    var errorDescription: String? {
        switch self {
        case .missingParam(let p): return "Missing required parameter: \(p)"
        case .notReady: return "The browser didn't come up in time."
        }
    }
}
