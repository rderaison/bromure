import BrowserBridges
import Darwin
import Foundation
import SandboxEngine
import Security
@preconcurrency import Virtualization

// Drives the browser VM's Chromium over the Chrome DevTools Protocol for the
// things TabBridge can't do — screenshots, JS evaluation, page text. TabBridge
// (vsock 5810) already handles navigate/tabs/back/forward/reload, so this is
// scoped to CDP-only capabilities, which is exactly the browser MCP surface
// the in-VM agents want.
//
// Transport: the shared CDPBridge (vsock 5200) pool. The guest cdp-agent (run
// by automation mode) opens connections to the host and bridges each to
// Chromium's 127.0.0.1:9222, so a dequeued connection IS a byte pipe to
// Chromium — no host-side TCP proxy (unlike Bromure Web's AutomationServer).
// The WebSocket client below is ported from Bromure Web's CDPConnection,
// adapted to run over a vsock fd instead of a TCP socket.
//
// Runtime-untested (no nested virt in the dev sandbox); build-verified only.

/// Build Input.dispatchKeyEvent params for a named key.
private func keyParams(_ type: String, key: String, code: String, vk: Int) -> [String: Any] {
    ["type": type, "key": key, "code": code, "windowsVirtualKeyCode": vk]
}

@MainActor
final class BrowserCDP {
    private let bridge: CDPBridge

    init(socketDevice: VZVirtioSocketDevice) {
        bridge = CDPBridge(socketDevice: socketDevice)
    }

    func stop() { bridge.stop() }

    enum CDPError: LocalizedError {
        case notReady           // guest cdp-agent hasn't connected yet
        case noPage             // /json/list had no page target
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .notReady: return "The browser's CDP agent isn't ready yet."
            case .noPage: return "No page target found."
            case .failed(let m): return "CDP: \(m)"
            }
        }
    }

    // MARK: - Public tools

    /// PNG screenshot of the active page. `fullPage` captures beyond the
    /// viewport (the whole scrollable page).
    func screenshot(fullPage: Bool = false) async throws -> Data {
        try await withPage { conn in
            var params: [String: Any] = ["format": "png"]
            if fullPage {
                // Size the clip to the full scroll extent at scale 1.
                if let metrics = try? await conn.send("Page.getLayoutMetrics"),
                   let css = metrics["cssContentSize"] as? [String: Any],
                   let w = (css["width"] as? NSNumber)?.doubleValue,
                   let h = (css["height"] as? NSNumber)?.doubleValue {
                    params["captureBeyondViewport"] = true
                    params["clip"] = ["x": 0, "y": 0, "width": w, "height": h, "scale": 1]
                }
            }
            let result = try await conn.send("Page.captureScreenshot", params: params)
            guard let b64 = result["data"] as? String, let png = Data(base64Encoded: b64) else {
                throw CDPError.failed("no screenshot data")
            }
            return png
        }
    }

    /// Evaluate a JS expression in the active page and return its value.
    func evaluate(_ expression: String) async throws -> Any? {
        try await withPage { try await $0.evaluate(expression) }
    }

    /// The active page's visible text (document.body.innerText).
    func pageText() async throws -> String {
        let value = try await evaluate("document.body ? document.body.innerText : ''")
        return value as? String ?? ""
    }

    /// Click the first element matching `selector`. Returns false if nothing
    /// matched. Ported from Bromure Web's toolClick (JS `.click()`), plus a
    /// scrollIntoView so off-screen targets still fire.
    func click(selector: String) async throws -> Bool {
        let js = "(function(){var el=document.querySelector(\(Self.jsQuote(selector)));"
            + "if(!el)return false;el.scrollIntoView({block:'center',inline:'center'});"
            + "el.click();return true;})()"
        return (try await evaluate(js)) as? Bool ?? false
    }

    /// Set an input/textarea/contenteditable's value and fire input+change —
    /// the fast path for filling forms (no per-keystroke events).
    func fill(selector: String, value: String) async throws -> Bool {
        let js = "(function(){var el=document.querySelector(\(Self.jsQuote(selector)));"
            + "if(!el)return false;el.focus();"
            + "if('value' in el){el.value=\(Self.jsQuote(value));}else{el.textContent=\(Self.jsQuote(value));}"
            + "el.dispatchEvent(new Event('input',{bubbles:true}));"
            + "el.dispatchEvent(new Event('change',{bubbles:true}));return true;})()"
        return (try await evaluate(js)) as? Bool ?? false
    }

    /// Type real key events into `selector` (drives keydown/keyup handlers, unlike
    /// fill). Ported from Web's toolType: focus, optionally clear, per-char key
    /// events, optional Enter. All on one CDP connection so focus persists.
    func type(selector: String, text: String, clear: Bool, submit: Bool) async throws {
        try await withPage { conn in
            if clear {
                _ = try await conn.evaluate("(function(){var el=document.querySelector("
                    + "\(Self.jsQuote(selector)));if(el){el.focus();el.select();}})()")
                _ = try await conn.send("Input.dispatchKeyEvent", params: keyParams("keyDown", key: "Backspace", code: "Backspace", vk: 8))
                _ = try await conn.send("Input.dispatchKeyEvent", params: keyParams("keyUp", key: "Backspace", code: "Backspace", vk: 8))
            }
            _ = try await conn.evaluate("document.querySelector(\(Self.jsQuote(selector)))?.focus()")
            for ch in text {
                let s = String(ch)
                _ = try await conn.send("Input.dispatchKeyEvent", params: ["type": "keyDown", "text": s, "key": s])
                _ = try await conn.send("Input.dispatchKeyEvent", params: ["type": "keyUp", "key": s])
            }
            if submit {
                _ = try await conn.send("Input.dispatchKeyEvent", params: keyParams("keyDown", key: "Enter", code: "Enter", vk: 13))
                _ = try await conn.send("Input.dispatchKeyEvent", params: keyParams("keyUp", key: "Enter", code: "Enter", vk: 13))
            }
        }
    }

    /// Press a single named key (Enter, Tab, Escape, ArrowDown, …) in the active
    /// page — for keyboard-driven UIs the click/type tools can't reach.
    func pressKey(_ key: String) async throws {
        let (code, vk) = Self.keyCodeAndVK(for: key)
        try await withPage { conn in
            _ = try await conn.send("Input.dispatchKeyEvent", params: keyParams("keyDown", key: key, code: code, vk: vk))
            _ = try await conn.send("Input.dispatchKeyEvent", params: keyParams("keyUp", key: key, code: code, vk: vk))
        }
    }

    /// outerHTML of the first element matching `selector` (default whole page),
    /// truncated. Web's toolGetContent(format:html).
    func html(selector: String) async throws -> String {
        let js = "document.querySelector(\(Self.jsQuote(selector)))?.outerHTML"
        var s = (try await evaluate(js)) as? String ?? ""
        if s.count > 100_000 { s = String(s.prefix(100_000)) + "\n\n[... truncated]" }
        return s
    }

    /// All `<a href>` links under `selector` as a JSON array of {text, href}.
    /// Ported from Web's toolGetLinks.
    func links(selector: String) async throws -> String {
        let js = "JSON.stringify(Array.from(document.querySelector(\(Self.jsQuote(selector)))"
            + "?.querySelectorAll('a[href]') ?? []).map(function(a){"
            + "return {text:a.innerText.trim().slice(0,200), href:a.href};}))"
        return (try await evaluate(js)) as? String ?? "[]"
    }

    /// Resolve once `selector` appears (MutationObserver), or throw on timeout.
    /// Wrapped in an async IIFE so Runtime.evaluate(awaitPromise:) can await it.
    func waitFor(selector: String, timeoutMs: Int) async throws {
        let sel = Self.jsQuote(selector)
        let js = """
        (async function(){
          if (document.querySelector(\(sel))) return true;
          return await new Promise(function(resolve, reject){
            var t = setTimeout(function(){ obs.disconnect(); reject(new Error('Timeout waiting for \(selector)')); }, \(timeoutMs));
            var obs = new MutationObserver(function(){
              if (document.querySelector(\(sel))) { clearTimeout(t); obs.disconnect(); resolve(true); }
            });
            obs.observe(document.documentElement, {childList:true, subtree:true});
          });
        })()
        """
        _ = try await evaluate(js)
    }

    /// JSON-encode a string into a JS/JSON string literal (with quotes) for safe
    /// embedding in an evaluated expression. Web calls this jsQuote.
    static func jsQuote(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let str = String(data: data, encoding: .utf8), str.count >= 2 else { return "\"\"" }
        return String(str.dropFirst().dropLast())   // strip the surrounding [ ]
    }

    /// DOM `code` + Windows virtual-key for a handful of named keys the agent is
    /// likely to press. Unknown keys fall back to the key string as its own code.
    static func keyCodeAndVK(for key: String) -> (String, Int) {
        switch key {
        case "Enter": return ("Enter", 13)
        case "Tab": return ("Tab", 9)
        case "Escape", "Esc": return ("Escape", 27)
        case "Backspace": return ("Backspace", 8)
        case "Delete": return ("Delete", 46)
        case "ArrowUp": return ("ArrowUp", 38)
        case "ArrowDown": return ("ArrowDown", 40)
        case "ArrowLeft": return ("ArrowLeft", 37)
        case "ArrowRight": return ("ArrowRight", 39)
        case "Home": return ("Home", 36)
        case "End": return ("End", 35)
        case "PageUp": return ("PageUp", 33)
        case "PageDown": return ("PageDown", 34)
        case " ", "Space": return ("Space", 32)
        default: return (key, 0)
        }
    }

    // MARK: - Target selection + connection

    /// Open a CDP WebSocket to the active page target and run `body`.
    private func withPage<T>(_ body: (CDPWSConnection) async throws -> T) async throws -> T {
        let path = try await activePageWSPath()
        guard let conn = dequeueConnection() else { throw CDPError.notReady }
        let ws = CDPWSConnection(connection: conn)
        try await ws.connect(path: path)
        defer { ws.disconnect() }
        return try await body(ws)
    }

    private func dequeueConnection() -> VZVirtioSocketConnection? {
        bridge.dequeueConnection()
    }

    /// The active page target's devtools WS path (`/devtools/page/<id>`), via
    /// an HTTP `GET /json/list` over a pooled connection.
    private func activePageWSPath() async throws -> String {
        guard let conn = dequeueConnection() else { throw CDPError.notReady }
        defer { conn.close() }
        let body = try await CDPWSConnection.httpGet(fd: conn.fileDescriptor, path: "/json/list")
        guard let targets = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            throw CDPError.failed("bad /json/list response")
        }
        // Prefer a "page" target; take the first one otherwise.
        let page = targets.first { ($0["type"] as? String) == "page" } ?? targets.first
        guard let ws = page?["webSocketDebuggerUrl"] as? String,
              let url = URL(string: ws) else {
            throw CDPError.noPage
        }
        return url.path.isEmpty ? "/" : url.path
    }
}

/// Minimal CDP-over-WebSocket client running on a vsock fd. Ported from
/// Bromure Web's CDPConnection; the only change is `connect(path:)` takes the
/// already-open vsock connection instead of doing a TCP connect.
final class CDPWSConnection: @unchecked Sendable {
    private let connection: VZVirtioSocketConnection
    private var fd: Int32 = -1
    private var nextId = 1
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: Any], any Error>] = [:]
    private(set) var isConnected = false

    init(connection: VZVirtioSocketConnection) {
        self.connection = connection
        self.fd = connection.fileDescriptor
    }

    /// Cap blocking reads so a stalled guest can't hang a tool call forever —
    /// a timed-out read returns ≤0, ending the loop and failing any pending
    /// request rather than blocking indefinitely.
    static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = withUnsafePointer(to: &tv) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0,
                       socklen_t(MemoryLayout<timeval>.size))
        }
    }

    /// WebSocket upgrade handshake on the vsock fd, then start the read loop.
    func connect(path: String) async throws {
        let fd = self.fd
        Self.setReadTimeout(fd, seconds: 20)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var keyBytes = [UInt8](repeating: 0, count: 16)
                _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
                let wsKey = Data(keyBytes).base64EncodedString()
                let req = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:9222\r\n"
                    + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Key: \(wsKey)\r\nSec-WebSocket-Version: 13\r\n\r\n"
                _ = req.withCString { Darwin.write(fd, $0, strlen($0)) }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(fd, &buf, buf.count)
                guard n > 0, let resp = String(bytes: buf[0..<n], encoding: .utf8),
                      resp.contains(" 101 ") else {
                    cont.resume(throwing: BrowserCDP.CDPError.failed("WebSocket upgrade failed"))
                    return
                }
                cont.resume()
            }
        }
        isConnected = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.receiveLoop() }
    }

    func disconnect() {
        isConnected = false
        connection.close()
        fd = -1
        lock.lock(); let p = pending; pending.removeAll(); lock.unlock()
        for (_, c) in p { c.resume(throwing: BrowserCDP.CDPError.failed("disconnected")) }
    }

    func send(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        guard fd >= 0, isConnected else { throw BrowserCDP.CDPError.failed("not connected") }
        let id: Int = lock.withLock { let v = nextId; nextId += 1; return v }
        var msg: [String: Any] = ["id": id, "method": method]
        if let params { msg["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: msg)
        let fd = self.fd
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending[id] = cont; lock.unlock()
            Self.writeWSFrame(fd: fd, data: data)
        }
    }

    func evaluate(_ expression: String) async throws -> Any? {
        let result = try await send("Runtime.evaluate", params: [
            "expression": expression, "returnByValue": true, "awaitPromise": true])
        if let exn = result["exceptionDetails"] as? [String: Any],
           let text = (exn["exception"] as? [String: Any])?["description"] as? String {
            throw BrowserCDP.CDPError.failed(text)
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    // MARK: - HTTP GET over the fd (for /json/list)

    /// Blocking HTTP/1.1 GET on `fd`, returning the response body. Reads until
    /// the socket closes or a full Content-Length body has arrived. Chromium's
    /// /json endpoints answer with `Connection: close`, so read-to-EOF is safe.
    static func httpGet(fd: Int32, path: String) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                setReadTimeout(fd, seconds: 20)
                let req = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nConnection: close\r\n\r\n"
                _ = req.withCString { Darwin.write(fd, $0, strlen($0)) }
                var raw = Data()
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = Darwin.read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    raw.append(contentsOf: buf[0..<n])
                    if raw.count > 8 * 1024 * 1024 { break }
                }
                // Split headers/body on the blank line.
                guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else {
                    cont.resume(throwing: BrowserCDP.CDPError.failed("malformed HTTP response"))
                    return
                }
                cont.resume(returning: raw.subdata(in: sep.upperBound..<raw.endIndex))
            }
        }
    }

    // MARK: - WebSocket frame I/O (verbatim from Web's CDPConnection)

    private static func writeWSFrame(fd: Int32, data: Data) {
        var frame = Data()
        frame.append(0x81)   // FIN + text
        let len = data.count
        if len < 126 {
            frame.append(UInt8(len) | 0x80)
        } else if len < 65536 {
            frame.append(126 | 0x80)
            frame.append(UInt8((len >> 8) & 0xFF)); frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127 | 0x80)
            for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        frame.append(contentsOf: mask)
        for (i, byte) in data.enumerated() { frame.append(byte ^ mask[i % 4]) }
        frame.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, frame.count) }
    }

    private func receiveLoop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var acc = Data()
        while isConnected && fd >= 0 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            acc.append(contentsOf: buf[0..<n])
            while let (payload, consumed) = Self.parseWSFrame(acc) {
                acc = Data(acc.dropFirst(consumed))
                handleMessage(payload)
            }
        }
        isConnected = false
        lock.lock(); let p = pending; pending.removeAll(); lock.unlock()
        for (_, c) in p { c.resume(throwing: BrowserCDP.CDPError.failed("connection closed")) }
    }

    private static func parseWSFrame(_ data: Data) -> (Data, Int)? {
        guard data.count >= 2 else { return nil }
        let byte1 = data[data.startIndex + 1] & 0x7F
        var offset = 2
        var payloadLen: Int
        if byte1 < 126 {
            payloadLen = Int(byte1)
        } else if byte1 == 126 {
            guard data.count >= 4 else { return nil }
            payloadLen = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
            offset = 4
        } else {
            guard data.count >= 10 else { return nil }
            payloadLen = 0
            for i in 0..<8 { payloadLen = (payloadLen << 8) | Int(data[data.startIndex + 2 + i]) }
            offset = 10
        }
        guard data.count >= offset + payloadLen else { return nil }
        let start = data.startIndex + offset
        return (data.subdata(in: start..<start + payloadLen), offset + payloadLen)
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else { return }   // ignore CDP events
        lock.lock(); let cont = pending.removeValue(forKey: id); lock.unlock()
        if let error = json["error"] as? [String: Any] {
            cont?.resume(throwing: BrowserCDP.CDPError.failed(error["message"] as? String ?? "error"))
        } else {
            cont?.resume(returning: json["result"] as? [String: Any] ?? [:])
        }
    }
}
