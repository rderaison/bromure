import Foundation
import Darwin

/// Where the agents' `bromure-delegation` MCP streams meet the Bromure AC
/// that serves them. Each agent's MCP shim (`__mcp-delegation`) connects to
/// delegation.sock and says `bromure-hello w<window>`; a connected Bromure
/// AC keeps a `delegation-mcp` SSH channel parked here (see the shared
/// RemoteSSHHandlers), and the hub splices the next stream into it — the
/// delegation engine and every record live on that Mac. With no Bromure AC
/// connected, a stream is answered here: the tool list, and a plain "not
/// connected" from each call. When a channel parks later, one such stream is
/// dropped so its shim reconnects and lands on the relay.
final class DelegationHub: @unchecked Sendable {
    static let shared = DelegationHub()

    static var socketPath: String { AgentHostPaths.support.appendingPathComponent("delegation.sock").path }

    private let lock = NSLock()
    /// Parked SSH channels, newest last. `alive`, when the parker can say,
    /// lets a park drop the dead ones beneath it: handing out goes newest
    /// first, so an old dead one would never be reached, and its waiting
    /// thread and link would stay forever.
    private var offers: [(take: (Int32) -> Bool, alive: (() -> Bool)?)] = []
    /// Streams answered locally, and which one a park is for.
    private var fallbacks = DelegationFallbacks()
    /// A Bromure AC has parked a channel here since this Sidecar started:
    /// a stream answered locally then is a relay gap (a link reconnecting),
    /// not "no Bromure AC at all".
    private var everParked = false
    /// How long a call on the local fallback waits for a relay to park (a
    /// link redialling after a drop) before it's refused.
    static let relayGrace: TimeInterval = 20
    /// The first line the local fallback sends: the shim learns its stream
    /// reaches no Bromure AC — whatever it held there was never done, and
    /// is safe to send again once a relay is back.
    static let localMarker = "bromure-local"

    // MARK: Parked channels (the SSH server's resolver)

    /// `offer` takes a stream (true) or declines it (false: its channel died
    /// while parked). Given `alive`, a dead offer is also handed -1 when a
    /// later park prunes it, and must decline it — that releases its waiter.
    func park(_ offer: @escaping @Sendable (Int32) -> Bool, alive: (@Sendable () -> Bool)? = nil) {
        lock.lock()
        var dead: [(Int32) -> Bool] = []
        offers.removeAll { o in
            guard let alive = o.alive, !alive() else { return false }
            dead.append(o.take)
            return true
        }
        let wasEmpty = offers.isEmpty
        let first = !everParked
        everParked = true
        offers.append((offer, alive))
        let kick = fallbacks.kick()
        lock.unlock()
        if first { AgentHostLog.log("delegation: a Bromure AC relay is parked") }
        else if wasEmpty, kick != nil { AgentHostLog.log("delegation: a Bromure AC relay is back") }
        for d in dead { _ = d(-1) }
        // Its shim reconnects at once — onto the channel just parked.
        if let kick { shutdown(kick, SHUT_RDWR) }
    }

    /// Offers waiting (tests).
    var parkedCount: Int { lock.lock(); defer { lock.unlock() }; return offers.count }

    /// Whether a relay parks for stream `fd` within `grace` — kicked by a
    /// park, first in line among the streams holding a call. Another
    /// stream's offer isn't this one's: it waits on, keeping its place.
    func waitForRelay(_ fd: Int32, within grace: TimeInterval) -> Bool {
        lock.lock(); fallbacks.hold(fd); lock.unlock()
        defer { lock.lock(); fallbacks.release(fd); lock.unlock() }
        let deadline = Date().addingTimeInterval(grace)
        func picked() -> Bool { lock.lock(); defer { lock.unlock() }; return fallbacks.kicked(fd) }
        while Date() < deadline {
            if picked() { return true }
            // Its shim hung up: out of line, or a park would spend its one
            // offer on a stream that never reconnects.
            if Self.peerClosed(fd) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return picked()
    }

    /// The other end closed `fd` (EOF waiting, nothing unread before it).
    static func peerClosed(_ fd: Int32) -> Bool {
        var b: UInt8 = 0
        return recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    var hadRelay: Bool { lock.lock(); defer { lock.unlock() }; return everParked }

    /// Hand `fd` to a live parked channel; false when there is none.
    private func relay(_ fd: Int32) -> Bool {
        while true {
            lock.lock()
            guard let offer = offers.popLast() else { lock.unlock(); return false }
            lock.unlock()
            if offer.take(fd) { return true }   // else that channel died while parked
        }
    }

    // MARK: The agents' side

    func start() throws {
        let path = Self.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostError.failed("delegation socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() where i < buf.count - 1 { buf[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, listen(fd, 32) == 0 else { close(fd); throw HostError.failed("bind \(path)") }
        chmod(path, 0o600)
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                guard let self else { close(c); return }
                if self.relay(c) { continue }   // the SSH channel owns it now
                self.lock.lock(); self.fallbacks.add(c); self.lock.unlock()
                Thread.detachNewThread { [weak self] in
                    Self.serveLocally(c)
                    self?.lock.lock()
                    self?.fallbacks.remove(c)
                    self?.lock.unlock()
                    close(c)
                }
            }
        }
        AgentHostLog.log("delegation: listening on \(path)")
    }

    // MARK: No Bromure AC connected

    private static let notConnected = "No Bromure AC is connected to this Mac right now, so other agents can't be reached. Delegation works while Bromure Agentic Coding has this Mac's window open — tell your user."
    /// A relay was here and hasn't come back within the grace: the link is
    /// down or reconnecting — not "no Bromure AC".
    private static let reconnecting = "The link to Bromure AC dropped and hasn't come back yet (it usually does within a minute) — wait a moment and retry. If it keeps failing, Bromure AC may have closed: tell your user."

    /// Answer a stream here: enough MCP for Claude to know the tools, and a
    /// clear refusal from every call.
    private static func serveLocally(_ fd: Int32) {
        ControlServer.writeAll(fd, Data((localMarker + "\n").utf8))
        var buf = [UInt8](repeating: 0, count: 65536)
        var pending = Data()
        var sawHello = false
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = Data(pending[pending.startIndex..<nl])
                pending = Data(pending[(nl + 1)...])
                if !sawHello { sawHello = true; continue }   // bromure-hello w<N>
                guard let msg = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
                // A call: a relay may be on its way back (a link redialling) —
                // hold it, and if one parks, end this stream unanswered: the
                // shim sends it again over the relay (nothing here did it).
                if msg["method"] as? String == "tools/call", msg["id"] != nil {
                    AgentHostLog.log("delegation: a call with no Bromure AC relay — holding it up to \(Int(relayGrace)) s")
                    if shared.waitForRelay(fd, within: relayGrace) {
                        AgentHostLog.log("delegation: relay back — the call goes to it")
                        return
                    }
                    AgentHostLog.log("delegation: no relay after \(Int(relayGrace)) s — refused")
                }
                guard let reply = answer(msg),
                      let out = try? JSONSerialization.data(withJSONObject: reply) else { continue }
                ControlServer.writeAll(fd, out + Data([0x0A]))
            }
        }
    }

    private static func answer(_ msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        guard let id else { return nil }   // notifications
        func result(_ r: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": r] }
        switch msg["method"] as? String ?? "" {
        case "initialize":
            return result([
                "protocolVersion": "2025-03-26",
                "serverInfo": ["name": "bromure-delegation", "version": "1.1.0"],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": DelegationMCPCatalog.instructions,
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": DelegationMCPCatalog.tools])
        case "tools/call":
            let text = shared.hadRelay ? reconnecting : notConnected
            return result(["content": [["type": "text", "text": text]], "isError": true])
        default:
            return ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": "Method not found"]]
        }
    }
}

/// `bromure-sidecar __mcp-delegation`: the stdio MCP server Claude runs.
/// Pipes stdio to delegation.sock, announcing its tmux window first, and
/// reconnects (announcing again) whenever the socket drops — the stream
/// moves between the local fallback and a Bromure AC's relay that way,
/// without Claude noticing. bromure-agentd's python shim, in Swift.
enum DelegationShim {
    static func run() -> Int32 {
        let hello: String = {
            guard let pane = ProcessInfo.processInfo.environment["TMUX_PANE"], !pane.isEmpty else { return "w-1" }
            let r = Tmux.run(["display-message", "-p", "-t", pane, "w#{window_index}"], timeout: 5)
            let w = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return w.hasPrefix("w") ? w : "w-1"
        }()
        signal(SIGPIPE, SIG_IGN)

        func connectHub() -> Int32 {
            var delay = 0.2
            while true {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(DelegationHub.socketPath.utf8)
                withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                    for (i, b) in bytes.enumerated() where i < buf.count - 1 { buf[i] = b }
                }
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if ok == 0 {
                    ControlServer.writeAll(fd, Data("bromure-hello \(hello)\n".utf8))
                    return fd
                }
                close(fd)
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 5)
            }
        }

        // In-flight calls (JSON-RPC requests not answered yet), with the
        // stream they went out on. A stream answered by the hub's local
        // fallback did nothing: what it held is sent again once a relay is
        // back. A relay stream that drops — or falls silent past a call's
        // deadline — may have done it or not: those calls get an error
        // reply, never silence (Claude waited for a reply until its own
        // 30-minute limit, a `wait` well past its timeout). Only this
        // (reader) thread opens and closes streams: see DelegationShimStream.
        let stream = DelegationShimStream()

        let out = NSLock()
        func emit(_ line: Data) {
            out.lock(); FileHandle.standardOutput.write(line); out.unlock()
        }

        // stdin → hub, one line at a time (a line never splits across two
        // connections).
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: false) {
                let data = Data(line.utf8)
                while let (fd, gen) = stream.current() {
                    // stale: a newer stream took over — write there; failed:
                    // this one is shut down, the reader reconnects.
                    let r = stream.send(data, fd, gen)
                    if r == .sent || r == .ownedByReader { break }
                }
            }
            stream.inputClosed()
        }

        // A relay that falls silent (no EOF: a half-dead link) holds its
        // calls for ever: past a call's deadline, the stream counts as lost.
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 2)
                let (orphans, late) = stream.watchdog()
                for o in orphans { emit(DelegationShimCalls.lostReply(o)) }
                if let late {
                    AgentHostLog.log("delegation: no reply to \(late.label) within \(Int(late.limit)) s — dropping the relay stream")
                }
            }
        }

        // hub → stdout, a line at a time.
        var buf = [UInt8](repeating: 0, count: 65536)
        var carry: [DelegationShimCalls.Call] = []   // held by a local stream: to send again
        while true {
            let fd = connectHub()
            let gen = stream.open(fd)
            if !carry.isEmpty {
                AgentHostLog.log("delegation: \(carry.count) held call(s) go to the relay")
                while let h = carry.first {
                    let r = stream.send(h.line, fd, gen)
                    guard r == .sent || r == .ownedByReader else { break }   // this stream's gone too: its EOF follows
                    carry.removeFirst()
                }
            }
            var partial = Data()
            while true {
                let n = read(fd, &buf, buf.count)
                guard n > 0 else { break }
                partial.append(contentsOf: buf[0..<n])
                while let nl = partial.firstIndex(of: 0x0A) {
                    let line = Data(partial[partial.startIndex...nl])
                    partial = Data(partial[(nl + 1)...])
                    if String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        == DelegationHub.localMarker {
                        stream.markLocal(gen)
                        continue
                    }
                    stream.answered(line)
                    emit(line)
                }
            }
            let (wasLocal, held, open) = stream.ended(fd, gen)
            if wasLocal {
                carry += held                     // never done: again, over the next stream
            } else {
                for h in held { emit(DelegationShimCalls.lostReply(h)) }
                if !held.isEmpty { AgentHostLog.log("delegation: relay stream lost with \(held.count) call(s) under way") }
            }
            if !open { return 0 }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
