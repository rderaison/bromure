import SwiftUI
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Agent-driven in-app browser (iOS)
//
// The iOS counterpart to the desktop fat client's BrowserMCPRelayClient, cut
// down to what a phone can do: SHOW a page. A coding agent in the workspace VM
// calls the browser MCP's `browser_navigate`; on the desktop that drives a real
// Chromium VM over CDP, but the phone runs no VM — it just loads the page in the
// WebBrowserPane's WKWebView, tunnelled to the workspace over the SAME P2P
// forward the manual browser uses. Inspection/automation tools (screenshot,
// evaluate, console, network, click, …) aren't supported here and answer with a
// short "use the desktop app" note so the agent gets a clean reply, not a hang.
//
// Wire path: guest stdio shim → vsock 5830 → host BrowserMCPVsockBridge, which
// (once this relay opens `browser-mcp <vm>`) splices the agent's JSON-RPC stream
// straight to us. We answer with the display subset and drive the shared bridge.

/// Shared per-workspace state between the MCP relay (which the agent drives) and
/// the WebBrowserPane (which renders). The relay calls `navigate`; the pane
/// observes `displayURL` and loads it, registers its `WebNav` for back/forward/
/// reload, and the workspace screen switches to the Web pane when `showTick`
/// bumps so an agent-opened page comes to the front.
@MainActor
final class MobileBrowserBridge: ObservableObject {
    let controller: RemoteHostController
    let profileID: Profile.ID

    /// The loopback URL the WKWebView should load (agent- or user-driven).
    @Published private(set) var displayURL: URL?
    /// A human label for the address bar — the real target (e.g. "172.20.0.5:3000").
    @Published private(set) var displayTitle: String = ""
    /// Bumped whenever a page is requested, so the workspace screen switches to
    /// the Web pane and the browser comes forward.
    @Published private(set) var showTick: Int = 0

    /// The live loopback→VM forwarder backing `displayURL`; replaced per navigate.
    private var forward: MobileForward?
    /// The rendered WebView's nav handle, set by the pane while it's on screen —
    /// lets the agent's reload/back/forward drive the actual WKWebView.
    weak var nav: WebNav?
    private var relay: MobileBrowserMCPRelay?

    init(controller: RemoteHostController, profileID: Profile.ID) {
        self.controller = controller
        self.profileID = profileID
    }

    /// Open the browser-MCP relay (idempotent). Runs for the life of this bridge
    /// — i.e. while the workspace screen is on the stack.
    func start() {
        guard relay == nil else { return }
        let r = MobileBrowserMCPRelay(host: controller.host,
                                      vm: profileID.uuidString, bridge: self)
        r.start()
        relay = r
    }

    deinit { relay?.stop() }

    private var vmIP: String? {
        let ip = controller.tabsModel(for: profileID)?.ipAddress
        return (ip?.isEmpty ?? true) ? nil : ip
    }

    /// Point the in-app browser at `raw` (agent- or user-supplied), tunnelling to
    /// the workspace VM. A loopback host means "this workspace"; any other host
    /// (the agent's own LAN IP for a dev server) is honoured verbatim — the SSH
    /// forward reaches the remote vmnet either way. Returns a short status line
    /// for the MCP reply.
    @discardableResult
    func navigate(_ raw: String) -> String {
        guard let t = Self.parse(raw) else { return "Couldn't parse the URL: \(raw)" }
        let host: String
        if t.isLoopback {
            guard let ip = vmIP else { return "The workspace has no network address yet." }
            host = ip
        } else {
            host = t.host
        }
        forward?.stop()
        guard let fwd = MobileForward(host: controller.host, vmIP: host, vmPort: t.port),
              let local = URL(string: "\(t.scheme)://127.0.0.1:\(fwd.localPort)\(t.pathAndQuery)") else {
            forward = nil
            return "Couldn't open a tunnel to \(host):\(t.port)."
        }
        forward = fwd
        displayURL = local
        displayTitle = "\(host):\(t.port)"
        showTick &+= 1
        return "Showing \(t.scheme)://\(host):\(t.port)\(t.pathAndQuery) "
            + "in the Bromure viewer on the phone."
    }

    /// Close the page and drop the tunnel (the pane's back-to-list button).
    func close() {
        forward?.stop(); forward = nil
        displayURL = nil; displayTitle = ""
    }

    func reload()  { nav?.reload() }
    func back()    { nav?.goBack() }
    func forward_() { nav?.goForward() }

    // MARK: URL parsing

    struct Target {
        let scheme: String        // "http" | "https"
        let host: String
        let port: Int
        let pathAndQuery: String  // begins with "/"
        let isLoopback: Bool
    }

    static func parse(_ raw: String) -> Target? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
        let scheme = (c.scheme?.lowercased() == "https") ? "https" : "http"
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        var pq = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        if let q = c.percentEncodedQuery { pq += "?" + q }
        let lower = host.lowercased()
        let loop = lower == "localhost" || host == "127.0.0.1"
            || host == "::1" || host == "[::1]"
        return Target(scheme: scheme, host: host, port: port,
                      pathAndQuery: pq, isLoopback: loop)
    }
}

// MARK: - Relay (fat-client side, iOS)

/// Opens a `browser-mcp <vm>` SSH channel to the remote host and answers the
/// line-delimited JSON-RPC the workspace agent emits with the display subset,
/// driving `MobileBrowserBridge`. Reconnects on drop (the guest shim reconnects
/// forever, so a re-dial re-establishes the relay). Mirrors the desktop
/// BrowserMCPRelayClient's transport, minus the CDP/Chromium browser.
final class MobileBrowserMCPRelay: @unchecked Sendable {
    private let host: RemoteHost
    private let vm: String
    private weak var bridge: MobileBrowserBridge?
    private let lock = NSLock()
    private var running = false
    private var fd: Int32 = -1

    init(host: RemoteHost, vm: String, bridge: MobileBrowserBridge) {
        self.host = host
        self.vm = vm
        self.bridge = bridge
    }

    func start() {
        lock.lock(); let already = running; running = true; lock.unlock()
        guard !already else { return }
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    func stop() {
        lock.lock(); running = false; let f = fd; fd = -1; lock.unlock()
        if f >= 0 { Darwin.shutdown(f, SHUT_RDWR); Darwin.close(f) }
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func loop() {
        while isRunning() {
            let resolved = RemoteTransport.resolved(host)
            guard let raw = SSHDialer.shared.dial(
                    host: resolved, verb: FatClient.browserMCPVerbPrefix + vm), raw >= 0 else {
                Thread.sleep(forTimeInterval: 1.0); continue
            }
            lock.lock(); fd = raw; lock.unlock()
            pump(raw)                           // blocks until the channel drops
            Darwin.close(raw)
            lock.lock(); if fd == raw { fd = -1 }; lock.unlock()
            if isRunning() { Thread.sleep(forTimeInterval: 0.5) }
        }
    }

    /// Read request lines, answer each via the bridge on the main actor, write
    /// the response back. Serial per connection (MCP issues one at a time).
    private func pump(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var pending = Data()
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            if pending.count > 8 * 1024 * 1024 { break }   // pathological
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = Data(pending[pending.startIndex..<nl])
                pending = Data(pending[(nl + 1)...])
                guard !lineData.isEmpty,
                      let line = String(data: lineData, encoding: .utf8) else { continue }
                let sem = DispatchSemaphore(value: 0)
                var response: String?
                Task { @MainActor [weak self] in
                    response = self?.handle(line: line)
                    sem.signal()
                }
                sem.wait()
                if let response { writeLine(fd, response) }
            }
        }
    }

    private func writeLine(_ fd: Int32, _ s: String) {
        var data = Data(s.utf8); data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0, rem = raw.count
            while rem > 0 {
                let w = Darwin.write(fd, base.advanced(by: off), rem)
                if w <= 0 { break }
                off += w; rem -= w
            }
        }
    }

    // MARK: JSON-RPC (display subset)

    @MainActor private func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return respond(id, [
                "protocolVersion": "2025-03-26",
                "serverInfo": ["name": "bromure-browser-ios", "version": "1.0.0"],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": Self.instructions,
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return respond(id, [:])
        case "tools/list":
            return respond(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return respond(id, callTool(name, args))
        default:
            guard id != nil else { return nil }
            return respondError(id, -32601, "Method not found: \(method)")
        }
    }

    @MainActor private func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        guard let bridge else { return text("The phone viewer isn't available right now.") }
        switch name {
        case "browser_navigate", "browser_new_tab":
            let url = (args["url"] as? String) ?? ""
            guard !url.isEmpty else { return text("Provide a `url` to show.") }
            return text(bridge.navigate(url))
        case "browser_reload":  bridge.reload();   return text("Reloaded.")
        case "browser_back":    bridge.back();      return text("Went back.")
        case "browser_forward": bridge.forward_();  return text("Went forward.")
        case "browser_list_tabs":
            if let u = bridge.displayURL {
                return text("Showing \(bridge.displayTitle) — \(u.absoluteString)")
            }
            return text("No page open in the phone viewer yet.")
        default:
            // The agent may hold the host's full tool list (cached before this
            // relay attached), so answer any other tool cleanly rather than hang.
            return text("The Bromure iOS viewer only SHOWS pages (browser_navigate). "
                + "‘\(name)’ — screenshots, evaluate, console, network, clicking and "
                + "other automation — runs in the desktop app, not on the phone.")
        }
    }

    static let instructions = """
    Shows a web page on the user's iPhone/iPad, inside the Bromure app, over the \
    same private connection the app already uses — nothing is exposed publicly. \
    This is a VIEWER: browser_navigate opens a URL for the user to look at; \
    browser_back / browser_forward / browser_reload drive it. There is NO \
    screenshot, evaluate, console, network, or clicking here (that's the desktop \
    app). To show a dev server you started in THIS workspace, navigate to the \
    workspace's LAN IP (`hostname -I`, e.g. http://172.x.x.x:3000) — or just \
    http://localhost:PORT, which the phone resolves to this workspace for you.
    """

    static let tools: [[String: Any]] = [
        tool("browser_navigate",
             "Show a URL on the user's phone in the Bromure viewer. Accepts the "
             + "workspace's LAN IP (from `hostname -I`) or localhost:PORT for a "
             + "dev server running in this workspace.",
             ["url": ["type": "string", "description": "URL to show"]],
             required: ["url"]),
        tool("browser_new_tab", "Alias of browser_navigate on the phone (single view).",
             ["url": ["type": "string", "description": "URL to show"]], required: ["url"]),
        tool("browser_back", "Go back in the viewer's history.", [:]),
        tool("browser_forward", "Go forward in the viewer's history.", [:]),
        tool("browser_reload", "Reload the page in the viewer.", [:]),
        tool("browser_list_tabs", "Report what the viewer is currently showing.", [:]),
    ]

    // MARK: helpers

    private func respond(_ id: Any?, _ result: [String: Any]) -> String {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        return Self.line(msg)
    }
    private func respondError(_ id: Any?, _ code: Int, _ message: String) -> String {
        var msg: [String: Any] = ["jsonrpc": "2.0",
                                  "error": ["code": code, "message": message]]
        if let id { msg["id"] = id }
        return Self.line(msg)
    }
    private static func line(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
    @MainActor private func text(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
    }
    private static func tool(_ name: String, _ desc: String,
                             _ props: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "inputSchema": schema]
    }
}
