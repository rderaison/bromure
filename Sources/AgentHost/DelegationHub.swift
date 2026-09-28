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
    /// Parked SSH channels, newest last.
    private var offers: [(Int32) -> Bool] = []
    /// Streams answered locally, oldest first.
    private var fallbacks: [Int32] = []

    // MARK: Parked channels (the SSH server's resolver)

    func park(_ offer: @escaping @Sendable (Int32) -> Bool) {
        lock.lock()
        offers.append(offer)
        let kick = fallbacks.isEmpty ? nil : fallbacks.removeFirst()
        lock.unlock()
        // Its shim reconnects at once — onto the channel just parked.
        if let kick { shutdown(kick, SHUT_RDWR) }
    }

    /// Hand `fd` to a live parked channel; false when there is none.
    private func relay(_ fd: Int32) -> Bool {
        while true {
            lock.lock()
            guard let offer = offers.popLast() else { lock.unlock(); return false }
            lock.unlock()
            if offer(fd) { return true }   // else that channel died while parked
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
                self.lock.lock(); self.fallbacks.append(c); self.lock.unlock()
                Thread.detachNewThread { [weak self] in
                    Self.serveLocally(c)
                    self?.lock.lock()
                    self?.fallbacks.removeAll { $0 == c }
                    self?.lock.unlock()
                    close(c)
                }
            }
        }
        AgentHostLog.log("delegation: listening on \(path)")
    }

    // MARK: No Bromure AC connected

    private static let notConnected = "No Bromure AC is connected to this Mac right now, so other agents can't be reached. Delegation works while Bromure Agentic Coding has this Mac's window open — tell your user."

    /// Answer a stream here: enough MCP for Claude to know the tools, and a
    /// clear refusal from every call.
    private static func serveLocally(_ fd: Int32) {
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
            return result(["content": [["type": "text", "text": notConnected]], "isError": true])
        default:
            return ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": "Method not found"]]
        }
    }
}

/// `bromure-native __mcp-delegation`: the stdio MCP server Claude runs.
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
        let lock = NSLock()
        var sock: Int32 = -1
        var stdinOpen = true

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

        func current() -> Int32 {
            lock.lock(); defer { lock.unlock() }
            if sock < 0 { sock = connectHub() }
            return sock
        }

        func drop(_ fd: Int32) {
            lock.lock()
            if sock == fd { close(fd); sock = -1 }
            lock.unlock()
        }

        // stdin → hub, one line at a time (a line never splits across two
        // connections).
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: false) {
                let data = Data(line.utf8)
                while true {
                    let fd = current()
                    var ok = true
                    data.withUnsafeBytes { raw in
                        var base = raw.baseAddress!, rem = raw.count
                        while rem > 0 {
                            let w = write(fd, base, rem)
                            if w <= 0 { ok = false; return }
                            base += w; rem -= w
                        }
                    }
                    if ok { break }
                    drop(fd)
                }
            }
            lock.lock(); stdinOpen = false; let fd = sock; lock.unlock()
            if fd >= 0 { shutdown(fd, SHUT_WR) }
        }

        // hub → stdout.
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let fd = current()
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                FileHandle.standardOutput.write(Data(buf[0..<n]))
                continue
            }
            drop(fd)
            lock.lock(); let open = stdinOpen; lock.unlock()
            if !open { return 0 }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
