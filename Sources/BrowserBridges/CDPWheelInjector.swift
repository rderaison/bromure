import Foundation
@preconcurrency import Virtualization

private let wheelDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil
@inline(__always) private func wLog(_ msg: @autoclosure () -> String) {
    if wheelDebug { print(msg()) }
}

/// One persistent DevTools WebSocket from the host straight into the
/// guest Chromium, used to deliver trackpad scroll deltas as
/// `Input.dispatchMouseEvent(mouseWheel)` — the only path on which
/// Chromium applies precise deltas 1:1 and immediately (no wheel-tick
/// quantisation, no smooth-scroll animator; see ``PrecisionScrollBridge``).
///
/// Why not the guest input agent (vsock 5007)? It takes one message per
/// connection, so 120 events/s means 120 vsock connect→write→close cycles
/// per second through a normal-priority Python process on a guest whose
/// Xorg and Chromium run at nice −10. Under load the cycle stretches past
/// a frame and events bunch (measured: frames alternating 0 / 2× deltas).
/// A single socket has none of that: ordered, no handshakes, C++ on the
/// far end.
///
/// Transport: the guest's cdp-agent keeps vsock connections to port 5200
/// pooled in ``CDPBridge``; the first bytes written on one make the guest
/// splice it to Chromium's `127.0.0.1:9222`. We take two — one for the
/// `/json/version` probe (browser WebSocket path), one for the WebSocket —
/// and speak the minimum of RFC 6455 ourselves (masked text frames out,
/// unmasked frames in). Chromium never fragments DevTools frames.
///
/// Pages are addressed by CDP target id — the same ids the native tab bar
/// gets from tab-agent — through flattened `Target.attachToTarget`
/// sessions, cached per target.
///
/// Threading: `start`/`wheel`/`stop` on the main actor; all socket work and
/// state on `io` (a serial queue); a dedicated thread blocks on reads and
/// funnels parsed responses back onto `io`.
@MainActor
public final class CDPWheelInjector {
    private weak var bridge: CDPBridge?
    private let io = DispatchQueue(label: "io.bromure.cdp-wheel", qos: .userInteractive)

    /// Main-actor mirror of the io-side state, for cheap per-event checks.
    public private(set) var isReady = false
    private var starting = false
    private var stopped = false
    private var restartAttempts = 0

    // io-queue state: touched only on `io`, which serialises it — hence
    // nonisolated(unsafe) rather than the class's main-actor isolation.
    nonisolated(unsafe) private var wsConn: VZVirtioSocketConnection?
    nonisolated(unsafe) private var wsFD: Int32 = -1
    nonisolated(unsafe) private var nextID = 1
    nonisolated(unsafe) private var sessions: [String: String] = [:]        // targetId → sessionId
    nonisolated(unsafe) private var attachInFlight: [Int: String] = [:]     // command id → targetId
    nonisolated(unsafe) private var queued: [String: [Wheel]] = [:]         // target awaiting attach → events
    nonisolated(unsafe) private var readerGeneration = 0

    private struct Wheel {
        var x: Double, y: Double, dx: Double, dy: Double, modifiers: Int
    }

    public init(bridge: CDPBridge) {
        self.bridge = bridge
    }

    /// Open the socket. Waits (polling every 500 ms) for the guest pool to
    /// hold two connections — the guest refills it as connections are used.
    public func start() {
        guard !stopped, !starting, !isReady else { return }
        guard let bridge, bridge.poolSize >= 2,
              let probe = bridge.dequeueConnection(),
              let ws = bridge.dequeueConnection() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
            return
        }
        starting = true
        // Handed to the io queue and used only there.
        nonisolated(unsafe) let probeConn = probe, wsSock = ws
        io.async { [self] in
            let ok = handshake(probe: probeConn, ws: wsSock)
            DispatchQueue.main.async {
                self.starting = false
                self.isReady = ok
                if ok {
                    self.restartAttempts = 0
                    wLog("[CDPWheel] ready")
                } else {
                    self.scheduleRestart()
                }
            }
        }
    }

    public func stop() {
        stopped = true
        isReady = false
        io.async { [self] in
            closeSocket()
        }
    }

    /// Deliver one wheel event to the page `targetId`. Fire-and-forget.
    /// `x`/`y` in CSS pixels of the page viewport; deltas in CSS pixels,
    /// positive `dy` scrolls down. `modifiers` uses CDP bits
    /// (Alt=1, Ctrl=2, Meta=4, Shift=8).
    public func wheel(targetId: String, x: Double, y: Double, dx: Double, dy: Double, modifiers: Int) {
        guard isReady else { return }
        let ev = Wheel(x: x, y: y, dx: dx, dy: dy, modifiers: modifiers)
        io.async { [self] in
            if coalesceWindow > 0 {
                // Leading-edge coalescing: the first event of a burst goes
                // out at once (first-move latency untouched); events that
                // follow within the window are summed and flushed as one
                // dispatch. DevTools wraps every mouseWheel in its own
                // scroll gesture (begin/update/end), so two events per
                // guest frame meant two gestures per frame and visible
                // pacing jitter (presented-frame p95 21 ms vs 18).
                let now = DispatchTime.now().uptimeNanoseconds
                if var held = pendingCoalesced[targetId] {
                    held.dx += dx; held.dy += dy; held.x = x; held.y = y; held.modifiers = modifiers
                    pendingCoalesced[targetId] = held
                    return
                }
                if now - lastSendNanos[targetId, default: 0] < UInt64(coalesceWindow * 1_000_000) {
                    pendingCoalesced[targetId] = ev
                    let due = lastSendNanos[targetId, default: now] + UInt64(coalesceWindow * 1_000_000)
                    io.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due)) { [weak self] in
                        guard let self, let held = self.pendingCoalesced.removeValue(forKey: targetId) else { return }
                        self.lastSendNanos[targetId] = DispatchTime.now().uptimeNanoseconds
                        self.dispatch(held, targetId: targetId)
                    }
                    return
                }
                lastSendNanos[targetId] = now
            }
            dispatch(ev, targetId: targetId)
        }
    }

    /// Window in ms; 0 = dispatch every event. `vm.scrollCoalesceMs`.
    private let coalesceWindow: Double = {
        let v = UserDefaults.standard.object(forKey: "vm.scrollCoalesceMs") as? Double
        return v ?? 0
    }()
    nonisolated(unsafe) private var pendingCoalesced: [String: Wheel] = [:]
    nonisolated(unsafe) private var lastSendNanos: [String: UInt64] = [:]

    nonisolated private func dispatch(_ ev: Wheel, targetId: String) {
        if let sessionId = sessions[targetId] {
            send(ev, sessionId: sessionId)
        } else {
            var q = queued[targetId] ?? []
            if q.isEmpty {
                let id = sendCommand("Target.attachToTarget",
                                     params: ["targetId": targetId, "flatten": true])
                attachInFlight[id] = targetId
            }
            if q.count < 240 { q.append(ev) }
            queued[targetId] = q
        }
    }

    // MARK: - io queue

    nonisolated private func send(_ ev: Wheel, sessionId: String) {
        var params: [String: Any] = [
            "type": "mouseWheel",
            "x": ev.x, "y": ev.y,
            "deltaX": ev.dx, "deltaY": ev.dy,
        ]
        if ev.modifiers != 0 { params["modifiers"] = ev.modifiers }
        _ = sendCommand("Input.dispatchMouseEvent", params: params, sessionId: sessionId)
    }

    @discardableResult
    nonisolated private func sendCommand(_ method: String, params: [String: Any], sessionId: String? = nil) -> Int {
        let id = nextID
        nextID += 1
        var msg: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId { msg["sessionId"] = sessionId }
        guard wsFD >= 0, let data = try? JSONSerialization.data(withJSONObject: msg) else { return id }
        if !Self.writeAll(fd: wsFD, Self.frame(text: data)) {
            wLog("[CDPWheel] write failed")
            socketLost()
        }
        return id
    }

    nonisolated private func handleMessage(_ json: [String: Any]) {
        if let id = json["id"] as? Int, let targetId = attachInFlight.removeValue(forKey: id) {
            if let result = json["result"] as? [String: Any],
               let sessionId = result["sessionId"] as? String {
                sessions[targetId] = sessionId
                for ev in queued.removeValue(forKey: targetId) ?? [] {
                    send(ev, sessionId: sessionId)
                }
            } else {
                // Tab gone before we attached; drop what was queued for it.
                queued.removeValue(forKey: targetId)
            }
            return
        }
        if let method = json["method"] as? String {
            if method == "Target.detachedFromTarget",
               let p = json["params"] as? [String: Any],
               let sid = p["sessionId"] as? String {
                sessions = sessions.filter { $0.value != sid }
            }
            return
        }
        // An error on a dispatch (e.g. session closed underneath us): forget
        // every mapping and let the next event re-attach.
        if json["error"] != nil, json["id"] != nil {
            sessions.removeAll()
        }
    }

    nonisolated private func socketLost() {
        closeSocket()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.isReady = false
            self.scheduleRestart()
        }
    }

    nonisolated private func closeSocket() {
        readerGeneration += 1
        if wsFD >= 0 { wsConn?.close() }
        wsFD = -1
        wsConn = nil
        sessions.removeAll()
        attachInFlight.removeAll()
        queued.removeAll()
    }

    private func scheduleRestart() {
        guard !stopped, restartAttempts < 20 else { return }
        restartAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.start() }
    }

    // MARK: - Handshake (io queue)

    nonisolated private func handshake(probe: VZVirtioSocketConnection, ws: VZVirtioSocketConnection) -> Bool {
        defer { probe.close() }
        // 1. Browser WebSocket path.
        let req = "GET /json/version HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nConnection: close\r\n\r\n"
        guard Self.writeAll(fd: probe.fileDescriptor, Data(req.utf8)) else { return false }
        guard let resp = Self.readUntilEOF(fd: probe.fileDescriptor, timeout: 5),
              let body = Self.httpBody(resp),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let wsURL = json["webSocketDebuggerUrl"] as? String,
              let url = URL(string: wsURL) else {
            wLog("[CDPWheel] /json/version failed")
            ws.close()
            return false
        }
        let path = url.path.isEmpty ? "/" : url.path

        // 2. Upgrade. Chromium checks Host (DNS-rebinding guard) and rejects
        //    non-localhost Origins; sending none is accepted.
        var keyBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { keyBytes[i] = UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        let upgrade = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard Self.writeAll(fd: ws.fileDescriptor, Data(upgrade.utf8)) else { ws.close(); return false }
        guard let (head, leftover) = Self.readHTTPHead(fd: ws.fileDescriptor, timeout: 5),
              head.contains(" 101 ") else {
            wLog("[CDPWheel] upgrade refused")
            ws.close()
            return false
        }
        wsConn = ws
        wsFD = ws.fileDescriptor
        readerGeneration += 1
        startReader(fd: ws.fileDescriptor, generation: readerGeneration, initial: leftover)
        return true
    }

    // MARK: - Reader thread

    nonisolated private func startReader(fd: Int32, generation: Int, initial: Data) {
        let thread = Thread { [weak self] in
            var buf = initial
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                // Parse every complete frame in the buffer.
                while let (frame, consumed) = Self.parseFrame(buf) {
                    buf.removeSubrange(0..<consumed)
                    switch frame.opcode {
                    case 0x1, 0x2:
                        if let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] {
                            self?.io.async { [weak self] in
                                guard let self, self.readerGeneration == generation else { return }
                                self.handleMessage(json)
                            }
                        }
                    case 0x9: // ping → pong
                        _ = Self.writeAll(fd: fd, Self.frame(payload: frame.payload, opcode: 0xA))
                    case 0x8:
                        self?.io.async { [weak self] in
                            guard let self, self.readerGeneration == generation else { return }
                            self.socketLost()
                        }
                        return
                    default:
                        break
                    }
                }
                let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n <= 0 {
                    self?.io.async { [weak self] in
                        guard let self, self.readerGeneration == generation else { return }
                        wLog("[CDPWheel] socket closed")
                        self.socketLost()
                    }
                    return
                }
                buf.append(contentsOf: chunk[0..<n])
            }
        }
        thread.name = "io.bromure.cdp-wheel.reader"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - WebSocket framing

    private struct Frame { let opcode: UInt8; let payload: Data }

    /// Client → server frames must be masked.
    nonisolated static func frame(text: Data) -> Data { frame(payload: text, opcode: 0x1) }

    nonisolated static func frame(payload: Data, opcode: UInt8) -> Data {
        var out = Data()
        out.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            out.append(0x80 | UInt8(len))
        } else if len <= 0xFFFF {
            out.append(0x80 | 126)
            out.append(UInt8(len >> 8)); out.append(UInt8(len & 0xFF))
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((len >> shift) & 0xFF)) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { mask[i] = UInt8.random(in: 0...255) }
        out.append(contentsOf: mask)
        var masked = [UInt8](repeating: 0, count: len)
        // Typed: the untyped closure is ambiguous between Data's two
        // `withUnsafeBytes` overloads on some toolchains (CI's).
        payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for i in 0..<len { masked[i] = src[i] ^ mask[i & 3] }
        }
        out.append(contentsOf: masked)
        return out
    }

    /// One complete server frame from the front of `buf`, or nil if more
    /// bytes are needed. Returns (frame, bytesConsumed).
    nonisolated private static func parseFrame(_ buf: Data) -> (Frame, Int)? {
        guard buf.count >= 2 else { return nil }
        let b0 = buf[buf.startIndex], b1 = buf[buf.startIndex + 1]
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7F)
        var off = 2
        if len == 126 {
            guard buf.count >= 4 else { return nil }
            len = Int(buf[buf.startIndex + 2]) << 8 | Int(buf[buf.startIndex + 3]); off = 4
        } else if len == 127 {
            guard buf.count >= 10 else { return nil }
            len = 0
            for i in 2..<10 { len = len << 8 | Int(buf[buf.startIndex + i]) }
            off = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard buf.count >= off + 4 else { return nil }
            mask = (0..<4).map { buf[buf.startIndex + off + $0] }
            off += 4
        }
        guard buf.count >= off + len else { return nil }
        var payload = Data(buf[(buf.startIndex + off)..<(buf.startIndex + off + len)])
        if masked {
            for i in 0..<len { payload[payload.startIndex + i] ^= mask[i & 3] }
        }
        return (Frame(opcode: opcode, payload: payload), off + len)
    }

    // MARK: - Socket helpers

    nonisolated private static func writeAll(fd: Int32, _ data: Data) -> Bool {
        var off = 0
        return data.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                off += n
            }
            return true
        }
    }

    nonisolated private static func waitReadable(fd: Int32, timeout: TimeInterval) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, Int32(timeout * 1000)) > 0
    }

    nonisolated private static func readUntilEOF(fd: Int32, timeout: TimeInterval) -> Data? {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard waitReadable(fd: fd, timeout: max(0, deadline.timeIntervalSinceNow)) else { break }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: chunk[0..<n])
            // Chromium honours Connection: close, but be robust: stop once
            // the announced body has arrived.
            if let body = httpBody(out), let cl = contentLength(out), body.count >= cl { break }
        }
        return out.isEmpty ? nil : out
    }

    /// Reads up to and including the blank line ending the response head;
    /// returns the head and any bytes read past it.
    nonisolated private static func readHTTPHead(fd: Int32, timeout: TimeInterval) -> (String, Data)? {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        let sep = Data("\r\n\r\n".utf8)
        while out.range(of: sep) == nil {
            guard waitReadable(fd: fd, timeout: max(0, deadline.timeIntervalSinceNow)) else { return nil }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return nil }
            out.append(contentsOf: chunk[0..<n])
        }
        let r = out.range(of: sep)!
        let head = String(decoding: out[out.startIndex..<r.lowerBound], as: UTF8.self)
        return (head, Data(out[r.upperBound...]))
    }

    nonisolated private static func httpBody(_ resp: Data) -> Data? {
        guard let r = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return Data(resp[r.upperBound...])
    }

    nonisolated private static func contentLength(_ resp: Data) -> Int? {
        guard let r = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: resp[resp.startIndex..<r.lowerBound], as: UTF8.self)
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
