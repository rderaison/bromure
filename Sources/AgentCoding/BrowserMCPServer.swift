import BrowserBridges
import Foundation

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
            default:
                return errorResult("Unknown tool: \(name)")
            }
        } catch {
            return errorResult(error.localizedDescription)
        }
    }

    /// The controller, opening the browser and waiting for the guest agents if
    /// needed (up to ~12s). Throws if it never comes up.
    private func readyBrowser() async throws -> WorkspaceBrowserController {
        if browser()?.isReady == true { return browser()! }
        ensureBrowser()
        for _ in 0..<120 {   // ~12s
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
