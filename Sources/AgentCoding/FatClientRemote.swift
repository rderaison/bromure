import Foundation
import SandboxEngine
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Fat-client diagnostics

/// Unbuffered stderr logging for the fat-client path (print() is fully buffered
/// when stdout is redirected, so it's unreliable for a GUI process we kill).
enum FatClientLog {
    static let enabled = ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_LOG"] != nil
        || ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_OPEN"] != nil
    /// When set to a path, also append to that file (survives pty/stderr mixing).
    static let filePath = ProcessInfo.processInfo.environment["BROMURE_ATTACH_DEBUG"]
    static func log(_ msg: @autoclosure () -> String) {
        let line = "[fatclient] \(msg())\n"
        if enabled { FileHandle.standardError.write(Data(line.utf8)) }
        if let filePath {
            if !FileManager.default.fileExists(atPath: filePath) {
                FileManager.default.createFile(atPath: filePath, contents: nil)
            }
            if let h = FileHandle(forWritingAtPath: filePath) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            }
        }
    }
}

// MARK: - Fat-client remote transport (client side)

/// A configured remote bromure-ac instance the fat client can mirror.
struct RemoteHost: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String            // display label ("rack mini")
    var address: String         // hostname or IP the SSH server listens on
    var port: Int = 2222
    var user: String            // the macOS account running the remote app
    /// TOFU-pinned SSH host-key fingerprint (`SHA256:…`). Set on first trust;
    /// a mismatch on a later connect is flagged as a possible MITM.
    var pinnedHostKey: String? = nil

    var connectLabel: String { "\(user)@\(address):\(port)" }
}

/// Result of probing a remote with a given credential, classified from ssh's
/// exit + stderr so the connect UI can react (retry password, warn on host-key
/// change, etc.).
enum RemoteProbe: Equatable {
    case ok
    case authFailed          // key/password rejected
    case hostKeyChanged      // pinned host key no longer matches — possible MITM
    case unreachable(String) // refused / timeout / DNS / remote access off
}

/// A scanned remote host key: the `known_hosts` line + its SHA256 fingerprint.
struct HostKeyInfo: Equatable {
    let line: String
    let fingerprint: String
}

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

    /// Ensure the ed25519 client keypair exists; returns the OpenSSH public line
    /// to enroll on the remote's `authorized_keys`.
    @discardableResult
    static func ensureClientKey() -> String? {
        ensureDirs()
        let fm = FileManager.default
        if !fm.fileExists(atPath: privateKeyPath.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = ["-t", "ed25519", "-N", "", "-C", "bromure-ac-fatclient",
                           "-f", privateKeyPath.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { return nil }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyPath.path)
        }
        return clientPublicKey()
    }

    static func clientPublicKey() -> String? {
        (try? String(contentsOf: publicKeyPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    private static func commonArgs(for host: RemoteHost) -> [String] {
        [
            "-p", String(host.port),
            "-i", privateKeyPath.path,   // -i takes a separate argv → spaces are fine
            "-o", "IdentitiesOnly=yes",
            "-o", "UserKnownHostsFile=\"\(knownHostsPath.path)\"",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=ERROR",
        ]
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

    // MARK: Probe (classified connection attempt)

    /// Probe a remote with the client key, by running one `GET /health` over the
    /// tunnel and classifying ssh's result. `strictHostKey` = enforce the pinned
    /// key (detects MITM). Password auth lives in `FatClientNIOSSH` — the system
    /// `ssh` binary is only ever used here with public-key auth (no askpass).
    static func probe(host: RemoteHost, strictHostKey: Bool) -> RemoteProbe {
        ensureClientKey()
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
    static func client(for host: RemoteHost, interactive: Bool = false) -> ControlClient {
        ensureClientKey()
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
    static func forwardDial(host: RemoteHost, ip: String, port: Int) -> Int32? {
        ensureClientKey()
        var args = commonArgs(for: host)
        args += ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                 "\(host.user)@\(host.address)", "\(FatClient.forwardVerbPrefix)\(ip) \(port)"]
        return SSHTunnel.shared.dial(args)
    }
}

/// UI-facing, observable store of configured remote hosts. Delegates all path /
/// transport work to `RemoteTransport`.
@MainActor
@Observable
final class RemoteHostStore {
    static let shared = RemoteHostStore()

    private(set) var hosts: [RemoteHost] = []

    init() { hosts = RemoteTransport.loadHosts() }

    func reload() { hosts = RemoteTransport.loadHosts() }

    @discardableResult
    func upsert(_ host: RemoteHost) -> RemoteHost {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        RemoteTransport.saveHosts(hosts)
        return host
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        RemoteTransport.saveHosts(hosts)
    }

    func host(_ id: UUID) -> RemoteHost? { hosts.first { $0.id == id } }

    @discardableResult
    func ensureClientKey() -> String? { RemoteTransport.ensureClientKey() }

    func client(for host: RemoteHost) -> ControlClient { RemoteTransport.client(for: host) }
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
