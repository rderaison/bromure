import Foundation
import SandboxEngine
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Fat-client remote transport (client side, macOS)
//
// The shared types (RemoteHost, RemoteProbe, HostKeyInfo, FatClientKeyStore,
// FatClientLog, RemoteHostStore) live in FatClientTypes.swift so the iOS
// client can compile them; this file keeps the macOS transport — system ssh,
// ssh-keygen/-keyscan/-agent subprocesses — which the iOS client replaces
// with an in-process NIOSSH dialer exposing the same `RemoteTransport` API.

/// Nonisolated transport layer: path resolution, the SSH client identity, and
/// building a `ControlClient` whose byte stream is an `ssh … bromure-fatclient
/// control` channel. Free of `@MainActor` so the `__attach-window` subprocess
/// (which runs off the main actor) can build a remote client by host id.
enum RemoteTransport {
    /// ~/Library/Application Support/BromureAC/remote-client/ (relocated with
    /// the rest of the support dir under CFFIXED_USER_HOME).
    static var dir: URL {
        let base = ProfileStore().controlSocketURL.deletingLastPathComponent()
        return base.appendingPathComponent("remote-client", isDirectory: true)
    }
    static var hostsFile: URL { dir.appendingPathComponent("hosts.json") }
    static var privateKeyPath: URL { dir.appendingPathComponent("id_ed25519") }
    static var publicKeyPath: URL { dir.appendingPathComponent("id_ed25519.pub") }
    static var knownHostsPath: URL { dir.appendingPathComponent("known_hosts") }
    static var controlDir: URL { dir.appendingPathComponent("control", isDirectory: true) }

    static func ensureDirs() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: controlDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    static func loadHosts() -> [RemoteHost] {
        guard let data = try? Data(contentsOf: hostsFile),
              let list = try? JSONDecoder().decode([RemoteHost].self, from: data) else { return [] }
        return list
    }

    static func saveHosts(_ hosts: [RemoteHost]) {
        ensureDirs()
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: hostsFile, options: .atomic)
    }

    /// Ensure the ed25519 client identity exists; returns the OpenSSH
    /// public line to enroll on the remote's `authorized_keys`.
    ///
    /// ONE identity per client Mac, but the PRIVATE half lives in the
    /// data-protection keychain (app-scoped by code signature, no prompt —
    /// same choice as SecretsVault), not as a plaintext file: stealing the
    /// remote-client directory yields only the public key. System ssh
    /// can't read the keychain, so dials load the key into a private
    /// in-memory ssh-agent via `ssh-add -` (stdin — never on disk) and
    /// select it with the public-key file. A pre-keychain plaintext
    /// id_ed25519 is migrated on first use and shredded.
    @discardableResult
    static func ensureClientKey() -> String? {
        ensureDirs()
        let fm = FileManager.default
        // Migrate: legacy plaintext private key → keychain, then delete.
        if fm.fileExists(atPath: privateKeyPath.path),
           let pem = try? String(contentsOf: privateKeyPath, encoding: .utf8) {
            if FatClientKeyStore.store(pem) {
                try? fm.removeItem(at: privateKeyPath)
            }
        }
        switch FatClientKeyStore.load() {
        case .found:
            return clientPublicKey()
        case .unavailable(let status):
            // The identity EXISTS — the keychain just won't serve it right
            // now. Regenerating here would delete the enrolled key and
            // force a password re-pair (the long-screen-lock incident).
            // Fail this attempt; the next connect retries.
            FatClientLog.log("client key unavailable (OSStatus \(status)) — "
                + "not regenerating; retry after unlocking this Mac")
            return nil
        case .notFound:
            break
        }
        // Fresh identity: generate to a temp path, move the private half
        // into the keychain, keep only the .pub on disk.
        let tmp = dir.appendingPathComponent("keygen-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-t", "ed25519", "-N", "", "-C", "bromure-ac-fatclient",
                       "-f", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        defer {
            try? fm.removeItem(at: tmp)
            try? fm.removeItem(at: tmp.appendingPathExtension("pub"))
        }
        guard let pem = try? String(contentsOf: tmp, encoding: .utf8),
              FatClientKeyStore.store(pem),
              let pub = try? String(contentsOf: tmp.appendingPathExtension("pub"),
                                    encoding: .utf8) else { return nil }
        try? pub.write(to: publicKeyPath, atomically: true, encoding: .utf8)
        return clientPublicKey()
    }

    /// SHA256 fingerprint of the client's public key — the selector for
    /// revoking it on a server at unpair time.
    static func clientKeyFingerprint() -> String? {
        guard FileManager.default.fileExists(atPath: publicKeyPath.path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-lf", publicKeyPath.path]
        let out = Pipe(); p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: " ").map(String.init)
            .first { $0.hasPrefix("SHA256:") }
    }

    static func clientPublicKey() -> String? {
        (try? String(contentsOf: publicKeyPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Publish this Mac's SSH public key to bromure.io so the user's servers
    /// authorize it with no password (they pull it via /v1/devices/ssh-keys).
    /// Safe to call repeatedly; a no-op until this Mac has a bromure.io device
    /// identity and an SSH key. (A Mac that also serves re-publishes on the
    /// account-key sync — this covers a client-only Mac.)
    static func publishSSHKey() {
        _ = ensureClientKey()
        guard let line = clientPublicKey(),
              let (client, bearer) = ControlPlaneClient.current() else { return }
        let user = NSUserName()   // the login a client must dial this Mac as
        Task { try? await client.uploadSSHKey(bearer: bearer, sshPublicKey: line, sshUsername: user) }
    }

    /// ssh argument vector: pubkey-only (BatchMode), TOFU host-key pinning to
    /// our dedicated known_hosts, and the fat-client control verb as the remote
    /// command.
    ///
    /// `interactive`: short request/response calls (polling, commands) multiplex
    /// over one ControlMaster TCP connection per host — cheap, especially on a
    /// WAN. Long-lived INTERACTIVE streams (terminal attach) must NOT use
    /// ControlMaster: OpenSSH buffers a multiplexed channel's spontaneous
    /// server→client output (the tmux repaint never arrives until the client
    /// types), so those get a dedicated direct connection instead.
    ///
    /// Two subtleties, both because the app support dir contains a space
    /// ("Application Support"): (1) `-o KEY=VALUE` values with spaces must be
    /// double-quoted INSIDE the option string — ssh re-tokenizes the value like
    /// a config line, so an unquoted space becomes "extra arguments". (2) the
    /// ControlMaster socket path (support dir + ssh's random suffix) blows past
    /// the ~104-char AF_UNIX limit, so we put it in /tmp, keyed by host id.
    /// Common ssh options (identity, known_hosts, keepalive). `-o KEY=VALUE`
    /// values with spaces are double-quoted inside the option string because
    /// ssh re-tokenizes them like a config line (the support dir has a space).
    /// Socket of an ssh-agent holding the client key IN MEMORY, loaded from
    /// the keychain via `ssh-add -` (the private key never touches disk).
    /// One agent per uid at a fixed path — a stale one from a previous
    /// process is probed and reused, so orphans don't accumulate.
    private static let agentLock = NSLock()
    private static var agentReady = false
    static func keyAgentSock() -> String? {
        agentLock.lock(); defer { agentLock.unlock() }
        let sock = "/tmp/bromure-fc-agent-\(getuid()).sock"
        func agentAlive() -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            p.arguments = ["-l"]
            p.environment = ["SSH_AUTH_SOCK": sock]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { return false }
            return p.terminationStatus == 0 || p.terminationStatus == 1
        }
        if !agentAlive() {
            agentReady = false
            unlink(sock)
            let agent = Process()
            agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
            agent.arguments = ["-D", "-a", sock]
            agent.standardOutput = FileHandle.nullDevice
            agent.standardError = FileHandle.nullDevice
            do { try agent.run() } catch { return nil }
            for _ in 0..<50 where !FileManager.default.fileExists(atPath: sock) {
                usleep(100_000)
            }
        }
        if !agentReady {
            guard case .found(let pem) = FatClientKeyStore.load() else { return nil }
            let add = Process()
            add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            add.arguments = ["-"]
            add.environment = ["SSH_AUTH_SOCK": sock]
            let stdin = Pipe()
            add.standardInput = stdin
            add.standardOutput = FileHandle.nullDevice
            add.standardError = FileHandle.nullDevice
            do { try add.run() } catch { return nil }
            stdin.fileHandleForWriting.write(Data(pem.utf8))
            try? stdin.fileHandleForWriting.close()
            add.waitUntilExit()
            guard add.terminationStatus == 0 else { return nil }
            agentReady = true
        }
        return sock
    }

    private static func commonArgs(for host: RemoteHost) -> [String] {
        // Keychain-backed identity through the in-memory agent; the -i
        // PUBLIC key selects which agent key to offer (IdentitiesOnly
        // honors it). A pre-migration plaintext private key falls back to
        // the classic -i dial.
        var identity: [String] = []
        if !FileManager.default.fileExists(atPath: privateKeyPath.path),
           let sock = keyAgentSock() {
            identity = ["-o", "IdentityAgent=\"\(sock)\"",
                        "-i", publicKeyPath.path]
        } else {
            identity = ["-i", privateKeyPath.path]
        }
        var args = identity + [
            "-p", String(host.port),
            "-o", "IdentitiesOnly=yes",
            "-o", "UserKnownHostsFile=\"\(knownHostsPath.path)\"",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=ERROR",
        ]
        // For a peer (P2P) connection the address is an ephemeral loopback port
        // that changes per session, so the host-key pin must key on the peer's
        // stable device identity instead. HostKeyAlias makes ssh store/verify
        // the known_hosts entry under that alias regardless of the loopback port.
        if let alias = host.hostKeyAlias {
            args += ["-o", "HostKeyAlias=\(alias)"]
        }
        return args
    }

    /// Swap a peer host for a live loopback endpoint resolved through the P2P
    /// broker; direct hosts pass through unchanged. Off the main thread this
    /// establishes the path if needed (blocking); on the main thread it only
    /// consults the cache (establishment uses main-queue signaling callbacks, so
    /// blocking main would deadlock). A peer that can't be resolved is returned
    /// as-is, so the dial fails and is classified `unreachable` like any other.
    static func resolved(_ host: RemoteHost) -> RemoteHost {
        guard let pid = host.peerDeviceID else { return host }
        let ep: P2PBroker.ResolvedEndpoint?
        if Thread.isMainThread {
            ep = P2PBroker.shared.cachedEndpoint(forPeer: pid)
        } else {
            ep = P2PBroker.shared.endpoint(forPeer: pid)
        }
        guard let ep else { return host }
        var h = host
        h.address = ep.host
        h.port = ep.port
        return h
    }

    static func sshArgs(for host: RemoteHost, interactive: Bool = false) -> [String] {
        var args = commonArgs(for: host)
        // Pubkey-only for the steady-state tunnel. accept-new pins a NEW host
        // key but refuses a CHANGED one (the explicit fingerprint TOFU happens
        // in the connect sheet); that's the safe default here.
        args += ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
        if !interactive {
            // Long-lived INTERACTIVE streams (terminal attach) must NOT use
            // ControlMaster: OpenSSH buffers a multiplexed channel's spontaneous
            // server→client output (the tmux repaint never arrives until the
            // client types). Short calls (polling, commands) multiplex over one
            // ControlMaster TCP connection per host — cheap on a WAN. The socket
            // lives in /tmp (support-dir path overflows the 104-char AF_UNIX limit).
            let controlPath = "/tmp/bromure-ac-cm-\(host.id.uuidString.prefix(12))"
            args += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=60",
            ]
        }
        args += ["\(host.user)@\(host.address)", FatClient.controlVerb]
        return args
    }

    // MARK: Host-key TOFU

    private static let sshKeyscan = "/usr/bin/ssh-keyscan"
    private static let sshKeygen = "/usr/bin/ssh-keygen"

    /// Fetch the remote's ed25519 host key + SHA256 fingerprint (for the
    /// user-visible TOFU prompt). Nil if the host is unreachable.
    static func scanHostKey(address: String, port: Int) -> HostKeyInfo? {
        let scan = Process()
        scan.executableURL = URL(fileURLWithPath: sshKeyscan)
        scan.arguments = ["-T", "8", "-p", String(port), "-t", "ed25519", address]
        let out = Pipe(); scan.standardOutput = out; scan.standardError = FileHandle.nullDevice
        do { try scan.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        scan.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { !$0.hasPrefix("#") && !$0.isEmpty }
        guard let line, let fp = fingerprint(ofKnownHostsLine: line) else { return nil }
        return HostKeyInfo(line: line, fingerprint: fp)
    }

    private static func fingerprint(ofKnownHostsLine line: String) -> String? {
        let tmp = NSTemporaryDirectory() + "bromure-hk-\(abs(line.hashValue)).txt"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard (try? line.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: sshKeygen)
        p.arguments = ["-lf", tmp]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: " ").first { $0.hasPrefix("SHA256:") }.map(String.init)
    }

    /// Trust a host key: replace any prior entry for this host in known_hosts
    /// with `info.line`. Called after the user confirms the fingerprint.
    static func pinHostKey(address: String, port: Int, info: HostKeyInfo) {
        ensureDirs()
        // ssh-keygen -R removes existing entries for the host (handles [host]:port).
        let hostSpec = port == 22 ? address : "[\(address)]:\(port)"
        let rm = Process(); rm.executableURL = URL(fileURLWithPath: sshKeygen)
        rm.arguments = ["-R", hostSpec, "-f", knownHostsPath.path]
        rm.standardOutput = FileHandle.nullDevice; rm.standardError = FileHandle.nullDevice
        try? rm.run(); rm.waitUntilExit()
        var body = (try? String(contentsOf: knownHostsPath, encoding: .utf8)) ?? ""
        if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
        body += info.line + "\n"
        try? body.write(to: knownHostsPath, atomically: true, encoding: .utf8)
    }

    /// Trust a host key under a HostKeyAlias (peer hosts — their loopback
    /// endpoint is ephemeral, so the pin keys on the stable device identity):
    /// replace any prior alias entry, then write the scanned line with its host
    /// token swapped for the alias. ssh consults the alias for both store and
    /// verify, so `StrictHostKeyChecking=yes` matches this entry.
    static func pinHostKey(alias: String, info: HostKeyInfo) {
        ensureDirs()
        let rm = Process(); rm.executableURL = URL(fileURLWithPath: sshKeygen)
        rm.arguments = ["-R", alias, "-f", knownHostsPath.path]
        rm.standardOutput = FileHandle.nullDevice; rm.standardError = FileHandle.nullDevice
        try? rm.run(); rm.waitUntilExit()
        let parts = info.line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        var body = (try? String(contentsOf: knownHostsPath, encoding: .utf8)) ?? ""
        if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
        body += "\(alias) \(parts[1])\n"
        try? body.write(to: knownHostsPath, atomically: true, encoding: .utf8)
    }

    /// Whether `alias` already has a pinned key in our known_hosts — i.e. this
    /// peer completed fingerprint TOFU on an earlier connect.
    static func hasAliasPin(_ alias: String) -> Bool {
        guard let body = try? String(contentsOf: knownHostsPath, encoding: .utf8) else { return false }
        return body.split(whereSeparator: \.isNewline).contains {
            $0.split(separator: " ").first.map(String.init) == alias
        }
    }

    // MARK: Probe (classified connection attempt)

    /// Probe a remote with the client key, by running one `GET /health` over the
    /// tunnel and classifying ssh's result. `strictHostKey` = enforce the pinned
    /// key (detects MITM). Password auth lives in `FatClientNIOSSH` — the system
    /// `ssh` binary is only ever used here with public-key auth (no askpass).
    static func probe(host rawHost: RemoteHost, strictHostKey: Bool) -> RemoteProbe {
        ensureClientKey()
        let host = resolved(rawHost)
        var args = commonArgs(for: host)
        args += ["-o", "StrictHostKeyChecking=\(strictHostKey ? "yes" : "accept-new")",
                 "-o", "BatchMode=yes",
                 "\(host.user)@\(host.address)", FatClient.controlVerb]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe

        do { try p.run() } catch { return .unreachable("couldn't launch ssh") }
        let req = "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        inPipe.fileHandleForWriting.write(Data(req.utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let outStr = String(decoding: out, as: UTF8.self)
        let errStr = String(decoding: err, as: UTF8.self)
        let errLower = errStr.lowercased()
        if outStr.contains("HTTP/1.1 200") { return .ok }
        if errStr.contains("HOST IDENTIFICATION HAS CHANGED")
            || (errLower.contains("host key") && errLower.contains("changed"))
            || errLower.contains("host key verification failed") {
            return .hostKeyChanged
        }
        if errLower.contains("permission denied") || errLower.contains("authentication failed") {
            return .authFailed
        }
        if errLower.contains("connection refused") || errLower.contains("timed out")
            || errLower.contains("could not resolve") || errLower.contains("no route") {
            return .unreachable(firstLine(errStr))
        }
        // No 200 and no clear signal → treat as auth failure (most common:
        // remote reachable but this key not yet authorized).
        return errStr.isEmpty ? .unreachable("no response from remote") : .authFailed
    }

    private static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map(String.init).first { !$0.isEmpty } ?? s
    }

    /// A `ControlClient` whose transport is an SSH tunnel to `host`. Each
    /// connection is a fresh `ssh … bromure-fatclient control` channel bridged
    /// to the remote's owner-only control socket, so the whole control-plane
    /// HTTP API + `InteractiveExec` run over SSH unchanged. Pass
    /// `interactive: true` for the terminal-attach stream (direct connection,
    /// no ControlMaster buffering).
    static func client(for rawHost: RemoteHost, interactive: Bool = false) -> ControlClient {
        ensureClientKey()
        let host = resolved(rawHost)
        let args = sshArgs(for: host, interactive: interactive)
        return ControlClient(socketPath: "ssh://\(host.connectLabel)") {
            SSHTunnel.shared.dial(args)
        }
    }

    /// Resolve a remote client by host id (used by the `__attach-window
    /// --remote <hostID>` subprocess).
    static func client(hostID: UUID, interactive: Bool = false) -> ControlClient? {
        guard let host = loadHosts().first(where: { $0.id == hostID }) else { return nil }
        return client(for: host, interactive: interactive)
    }

    /// Open a raw TCP tunnel to a guest `ip:port` on the remote's vmnet subnet:
    /// `ssh … bromure-fatclient/1 forward <ip> <port>`. Returns a bidirectional
    /// fd (the ssh channel bridged to the remote guest). No ControlMaster —
    /// it's a long-lived raw stream, same as the terminal attach. The caller
    /// owns/closes the fd.
    static func forwardDial(host rawHost: RemoteHost, ip: String, port: Int) -> Int32? {
        ensureClientKey()
        let host = resolved(rawHost)
        var args = commonArgs(for: host)
        args += ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                 "\(host.user)@\(host.address)", "\(FatClient.forwardVerbPrefix)\(ip) \(port)"]
        return SSHTunnel.shared.dial(args)
    }

    /// Open a `forward-udp <ip>` channel: a multiplexed byte stream carrying
    /// length-prefixed UDP datagrams to a remote guest. Fresh ssh process, like
    /// `forwardDial`.
    static func forwardDialUDP(host rawHost: RemoteHost, ip: String) -> Int32? {
        ensureClientKey()
        let host = resolved(rawHost)
        var args = commonArgs(for: host)
        args += ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                 "\(host.user)@\(host.address)", "\(FatClient.forwardUDPVerbPrefix)\(ip)"]
        return SSHTunnel.shared.dial(args)
    }

    /// Open a `browser-mcp <vm>` channel: a raw byte stream carrying the remote
    /// workspace agent's line-delimited JSON-RPC, which the fat client answers
    /// with its own `BrowserMCPServer`. Fresh ssh process per relay (long-lived
    /// stream, no ControlMaster), like `forwardDial`.
    static func browserMCPDial(host rawHost: RemoteHost, vm: String) -> Int32? {
        ensureClientKey()
        let host = resolved(rawHost)
        var args = commonArgs(for: host)
        args += ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                 "\(host.user)@\(host.address)", "\(FatClient.browserMCPVerbPrefix)\(vm)"]
        return SSHTunnel.shared.dial(args)
    }
}

// MARK: - SSH tunnel process pool

/// Spawns `ssh` subprocesses and hands back a single bidirectional fd per
/// channel (a socketpair whose far end is the ssh child's stdin+stdout). The
/// returned fd behaves exactly like the local AF_UNIX control-socket fd, so
/// `ControlClient.request`/`openStream` — and therefore `InteractiveExec` —
/// run over the SSH tunnel unchanged. Retains each Process until it exits so
/// Foundation reaps it (no zombies) and it isn't torn down early.
final class SSHTunnel: @unchecked Sendable {
    static let shared = SSHTunnel()

    private let lock = NSLock()
    private var live: Set<Process> = []

    /// Spawn `ssh <args>` and return a duplex fd bridged to its stdio. The
    /// caller owns the fd and closes it; closing it makes ssh see EOF and exit.
    func dial(_ args: [String]) -> Int32? {
        var fds: [Int32] = [0, 0]
        let sp = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        guard sp == 0 else {
            FatClientLog.log("dial: socketpair FAILED errno=\(errno) (\(String(cString: strerror(errno))))")
            return nil
        }
        let parent = fds[0]
        let child = fds[1]

        let handle = FileHandle(fileDescriptor: child, closeOnDealloc: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.standardInput = handle
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock(); self.live.remove(proc); self.lock.unlock()
        }
        do {
            try p.run()
        } catch {
            FatClientLog.log("dial: ssh spawn FAILED: \(error)")
            Darwin.close(parent); Darwin.close(child)
            return nil
        }
        // The child holds its dup'd copies of `child` on fd 0/1; the parent
        // keeps only `parent`.
        Darwin.close(child)
        lock.lock(); live.insert(p); lock.unlock()
        return parent
    }
}
