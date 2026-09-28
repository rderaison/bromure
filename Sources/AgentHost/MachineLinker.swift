import Crypto
import Foundation
import Darwin

/// Attaches this Mac to a Bromure AC — the one on this Mac, or one of the
/// account's servers (ark…) reached through bromure.io — as one more machine
/// in ITS lists, beside its VMs: its agents appear in that app's sessions and
/// reach its agents through that app's delegation engine. This side always
/// dials: it parks a few links there (`POST /machines/link`) and serves what
/// comes down them (MachineLinks.swift in bromure-ac has the other half).
final class MachineLinker: @unchecked Sendable {
    static let shared = MachineLinker()

    /// Where to attach.
    enum Target: Codable, Equatable {
        /// The Bromure AC on this Mac, through its control socket.
        case local
        /// An account server, through bromure.io and SSH.
        case device(id: String, name: String, user: String)

        var label: String {
            switch self {
            case .local: return "this Mac’s Bromure AC"
            case .device(_, let name, _): return name
            }
        }
    }

    static let slots = 3
    private static let targetKey = "attach.target"

    private let lock = NSLock()
    private var generation = 0
    private var target: Target?
    private var parkedCount = 0
    private var lastError: String?
    private var live: Set<Int32> = []
    /// Parked, but the server's user hasn't let this Mac into the fleet yet.
    private var awaitingApproval = false

    var current: Target? { lock.lock(); defer { lock.unlock() }; return target }
    var isLinked: Bool { lock.lock(); defer { lock.unlock() }; return parkedCount > 0 }
    var error: String? { lock.lock(); defer { lock.unlock() }; return lastError }
    var isAwaitingApproval: Bool { lock.lock(); defer { lock.unlock() }; return awaitingApproval && parkedCount > 0 }

    static var localControlSocket: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BromureAC/control.sock").path
    }

    // MARK: Lifecycle

    /// Re-attach where we were last time.
    func resume() {
        guard let data = UserDefaults.standard.data(forKey: Self.targetKey),
              let t = try? JSONDecoder().decode(Target.self, from: data) else { return }
        attach(t)
    }

    func attach(_ t: Target) {
        detach(forget: false)
        if let data = try? JSONEncoder().encode(t) { UserDefaults.standard.set(data, forKey: Self.targetKey) }
        lock.lock()
        generation += 1
        let gen = generation
        target = t
        lastError = nil
        lock.unlock()
        AgentHostLog.log("attach: to \(t.label)")
        for _ in 0..<Self.slots {
            Thread.detachNewThread { [weak self] in self?.slotLoop(gen, t) }
        }
    }

    /// Stop attaching; `forget` also tells the server to drop this machine.
    func detach(forget: Bool = true) {
        lock.lock()
        let t = target
        generation += 1
        target = nil
        parkedCount = 0
        let fds = live
        live.removeAll()
        lock.unlock()
        fds.forEach { shutdown($0, SHUT_RDWR) }
        if forget { UserDefaults.standard.removeObject(forKey: Self.targetKey) }
        if forget, let t {
            DispatchQueue.global().async {
                let id = SessionEngine.shared.hostID.uuidString
                let fd: Int32?
                switch t {
                case .local:
                    fd = Self.connectUnix(Self.localControlSocket)
                    let body = (try? JSONSerialization.data(withJSONObject: ["id": id])) ?? Data()
                    if let fd {
                        ControlServer.writeAll(fd, Data("POST /machines/detach HTTP/1.1\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
                    }
                case .device:
                    fd = Self.dialDevice(t, verb: FatClient.machineDetachVerbPrefix + id)
                }
                guard let fd else { return }
                var b = [UInt8](repeating: 0, count: 512)
                _ = read(fd, &b, b.count)
                close(fd)
            }
        }
    }

    private func alive(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }

    // MARK: One link at a time, forever

    private func slotLoop(_ gen: Int, _ t: Target) {
        var backoff = 1.0
        var failures = 0
        while alive(gen) {
            guard let fd = Self.openLink(t) else {
                note(error: "Can't reach \(t.label)")
                // A server that restarted leaves the cached P2P path pointing
                // at its old session: the loopback shim still listens, every
                // dial through it fails. Drop it and let the next dial
                // re-establish.
                failures += 1
                if failures >= 2, case .device(let id, _, _) = t {
                    P2PBroker.shared.closePeer(id)
                    failures = 0
                }
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 10)
                continue
            }
            guard track(fd, gen) else { close(fd); return }
            switch Self.readAccepted(fd) {
            case .accepted(let pending):
                lock.lock(); awaitingApproval = pending; lock.unlock()
            case .refused(let why):
                // Blocked by the server's user (or refused outright): ask
                // again rarely, not every few seconds.
                untrack(fd); close(fd)
                note(error: why.map { "\(t.label): \($0)" } ?? "\(t.label) refused this Mac")
                AgentHostLog.log("attach: \(t.label) refused: \(why ?? "?")")
                Thread.sleep(forTimeInterval: 120)
                continue
            case .failed:
                untrack(fd); close(fd)
                note(error: "\(t.label) didn't accept this Mac (is it up to date?)")
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 10)
                continue
            }
            backoff = 1
            failures = 0
            setParked(+1)
            // Parked. The server writes a verb when it needs us.
            let verb = Self.readLine(fd)
            setParked(-1)
            // A verb only comes to a machine in the fleet.
            if verb != nil { lock.lock(); awaitingApproval = false; lock.unlock() }
            guard let verb else { untrack(fd); close(fd); Thread.sleep(forTimeInterval: 1); continue }
            Thread.detachNewThread { [weak self] in
                self?.serve(fd, verb: verb)
                self?.untrack(fd)
                close(fd)
            }
        }
    }

    private func serve(_ fd: Int32, verb: String) {
        switch verb {
        case "control":
            // The server's request, answered by our own control API.
            guard let ctl = Self.connectUnix(AgentHostPaths.controlSocket.path) else { return }
            Self.splice(fd, ctl)
            close(ctl)
        case "delegation-mcp":
            // Carries the next agent MCP stream to the server's engine.
            let done = DispatchSemaphore(value: 0)
            DelegationHub.shared.park { shim in
                // The server may have gone while this waited: don't hand an
                // agent's stream to a dead link (it'd reconnect, but lose a call).
                guard Self.isOpen(fd) else { done.signal(); return false }
                Thread.detachNewThread {
                    Self.splice(fd, shim)
                    close(shim)
                    done.signal()
                }
                return true
            }
            done.wait()
        default:
            AgentHostLog.log("attach: unknown verb \(verb)")
        }
    }

    // MARK: Connecting

    /// A new link, asked to be parked: locally a `POST /machines/link` on the
    /// control socket; on a server, the `machine-link` SSH verb — the only
    /// thing this Mac's key is allowed to do there.
    private static func openLink(_ t: Target) -> Int32? {
        let id = SessionEngine.shared.hostID.uuidString
        switch t {
        case .local:
            guard let fd = connectUnix(localControlSocket) else { return nil }
            let body: [String: Any] = ["id": id, "name": ControlServer.machineName]
            let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            ControlServer.writeAll(fd, Data("POST /machines/link HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n".utf8) + payload)
            return fd
        case .device:
            let name = Data(ControlServer.machineName.utf8).base64EncodedString()
            return dialDevice(t, verb: FatClient.machineLinkVerbPrefix + "\(id) \(name)")
        }
    }

    private static func dialDevice(_ t: Target, verb: String) -> Int32? {
        guard case .device(let id, let name, let user) = t,
              let ep = P2PBroker.shared.endpoint(forPeer: id, timeout: 20) else { return nil }
        _ = configureDialer
        // A stable id: the dialer pools one SSH connection per host.
        let host = RemoteHost(id: UUID(uuidString: id) ?? UUID(), name: name, address: ep.host,
                              port: ep.port, user: user, peerDeviceID: id)
        return SSHDialer.shared.dial(host: host, verb: verb)
    }

    /// The dialer's pins and identity, set once: the link threads dial
    /// concurrently, and those properties aren't safe to write while they
    /// read them (writing them per dial crashed on a double release).
    private static let configureDialer: Void = {
        SSHDialer.shared.knownHostsURL = AgentHostPaths.support.appendingPathComponent("known_hosts")
        SSHDialer.shared.loadClientKey = { ClientKey.load() }
    }()

    /// The server's answer to a link request; true once it parked it.
    enum Acceptance { case accepted(pending: Bool), refused(String?), failed }

    /// The park's reply: in (or waiting for the user's answer), refused
    /// (403, with the server's reason), or no sense to be made of it.
    private static func readAccepted(_ fd: Int32) -> Acceptance {
        var head = Data()
        var b = [UInt8](repeating: 0, count: 1)
        while head.count < 4096 {
            guard read(fd, &b, 1) == 1 else { return .failed }
            head.append(b[0])
            if head.count >= 4, head.suffix(4) == Data("\r\n\r\n".utf8) { break }
        }
        let text = String(decoding: head, as: UTF8.self)
        if text.hasPrefix("HTTP/1.1 200") {
            return .accepted(pending: text.lowercased().contains("x-bromure-fleet: pending"))
        }
        guard text.hasPrefix("HTTP/1.1 403") else { return .failed }
        // The reason is in the JSON body, up to Content-Length.
        let len = text.lowercased().range(of: "content-length:").map {
            Int(text[$0.upperBound...].drop(while: { $0 == " " }).prefix(while: { $0.isNumber })) ?? 0
        } ?? 0
        var body = [UInt8](repeating: 0, count: min(max(len, 0), 4096))
        var got = 0
        while got < body.count {
            let want = body.count - got
            let n = body.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, want) }
            if n <= 0 { break }
            got += n
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(body[0..<got]))) as? [String: Any]
        return .refused(json?["error"] as? String)
    }

    private static func readLine(_ fd: Int32) -> String? {
        var line = Data()
        var b = [UInt8](repeating: 0, count: 1)
        while line.count < 256 {
            guard read(fd, &b, 1) == 1 else { return nil }
            if b[0] == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(b[0])
        }
        return nil
    }

    /// Still connected: no hangup and no pending EOF on `fd`.
    static func isOpen(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 0) >= 0 else { return false }
        if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }
        if p.revents & Int16(POLLIN) != 0 {
            var b: UInt8 = 0
            return recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT) > 0
        }
        return true
    }

    static func connectUnix(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() where i < buf.count - 1 { buf[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func splice(_ a: Int32, _ b: Int32) {
        let done = DispatchSemaphore(value: 0)
        func copy(_ from: Int32, _ to: Int32) {
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(from, &buf, buf.count)
                    if n <= 0 { break }
                    var off = 0
                    while off < n {
                        let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
                        if w <= 0 { break }
                        off += w
                    }
                    if off < n { break }
                }
                shutdown(to, SHUT_WR)
                shutdown(from, SHUT_RD)
                done.signal()
            }
        }
        copy(a, b)
        copy(b, a)
        done.wait()
        done.wait()
    }

    // MARK: Bookkeeping

    private func track(_ fd: Int32, _ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == gen else { return false }
        live.insert(fd)
        return true
    }

    private func untrack(_ fd: Int32) { lock.lock(); live.remove(fd); lock.unlock() }

    private func setParked(_ delta: Int) {
        lock.lock()
        parkedCount = max(0, parkedCount + delta)
        if parkedCount > 0 { lastError = nil }
        lock.unlock()
    }

    private func note(error: String) {
        lock.lock()
        if parkedCount == 0 { lastError = error }
        lock.unlock()
    }
}

/// This Mac's SSH client identity for attaching to account servers: an
/// ed25519 seed in an owner-only file (no keychain group, see
/// DeviceIdentityStore), published to the account so the servers accept it.
enum ClientKey {
    static var url: URL { AgentHostPaths.support.appendingPathComponent("client_ed25519") }

    static func load() -> Curve25519.Signing.PrivateKey? {
        if let d = try? Data(contentsOf: url), d.count == 32,
           let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.Signing.PrivateKey()
        FileManager.default.createFile(atPath: url.path, contents: k.rawRepresentation,
                                       attributes: [.posixPermissions: 0o600])
        return k
    }

    static var publicLine: String? {
        guard let k = load() else { return nil }
        var blob = Data()
        func sshString(_ d: Data) {
            var be = UInt32(d.count).bigEndian
            withUnsafeBytes(of: &be) { blob.append(contentsOf: $0) }
            blob.append(d)
        }
        sshString(Data("ssh-ed25519".utf8))
        sshString(k.publicKey.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) bromure-agent-host"
    }
}
