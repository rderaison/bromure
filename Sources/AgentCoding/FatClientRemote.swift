import Crypto
import Foundation
import SandboxEngine
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Fat-client remote transport (client side, macOS)
//
// The shared types (RemoteHost, RemoteProbe, HostKeyInfo, FatClientKeyStore,
// FatClientLog, RemoteHostStore) live in FatClientTypes.swift so the iOS
// client can compile them; this file is the macOS transport.
//
// Both platforms now speak SSH in-process through `SSHDialer`
// (FatClientSSHDial.swift, swift-nio-ssh) — no `ssh`, `ssh-keygen`,
// `ssh-keyscan`, or `ssh-agent` subprocesses. What that buys over shelling
// out to the system binary:
//   • The keychain-held identity goes straight to the dialer. The old path
//     couldn't (system ssh can't read the keychain), so every dial detoured
//     through a private in-memory ssh-agent primed with `ssh-add -`.
//   • One connection per host multiplexes every channel, including
//     interactive attaches. ControlMaster couldn't carry those — OpenSSH
//     buffers a multiplexed channel's spontaneous server→client output, so
//     terminal streams needed their own TCP connection each.
//   • Failures are typed (`SSHDialError`) instead of scraped out of ssh's
//     stderr, and no argv quoting hazards (the support dir has a space).
// macOS keeps its own key-at-rest format: the keychain item is an OpenSSH
// PEM, which `OpenSSHKeyFormat.ed25519Seed(fromPEM:)` decodes for the dialer
// so a Mac paired before this change keeps its enrolled identity.

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

    /// Wire the shared NIOSSH dialer to this platform's pins + identity. Runs
    /// once, lazily, before anything dials (`_ = bootstrap`), mirroring iOS.
    private static let bootstrap: Void = {
        SSHDialer.shared.knownHostsURL = knownHostsPath
        SSHDialer.shared.loadClientKey = { loadClientKeyCrypto() }
        reapLegacyKeyAgent()
    }()

    /// Kill the in-memory ssh-agent the old system-`ssh` transport kept the
    /// client key in. It runs `-D` (foreground) and gets orphaned to launchd
    /// when we exit, so upgrading would otherwise leave a signing oracle for
    /// this Mac's fat-client identity alive indefinitely, with nothing left to
    /// use it. One deterministic socket path per uid; safe to run every launch.
    private static func reapLegacyKeyAgent() {
        let sock = "/tmp/bromure-fc-agent-\(getuid()).sock"
        defer { unlink(sock) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // -f matches (and -l prints) the whole command line.
        p.arguments = ["-fl", "ssh-agent .*bromure-fc-agent"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return }
        for line in out.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[..<space]) else { continue }
            // Re-check the command: `-f` also matches a shell whose arguments
            // merely contain the pattern.
            let command = trimmed[trimmed.index(after: space)...]
            guard command.contains("ssh-agent"), command.contains(sock),
                  pid != getpid() else { continue }
            kill(pid, SIGTERM)
            FatClientLog.log("reaped legacy fat-client ssh-agent (pid \(pid))")
        }
    }

    /// The client identity as a CryptoKit key, for the in-process dialer. The
    /// keychain item is an OpenSSH PEM (what this Mac has always stored, and
    /// what its remotes already authorize), decoded here rather than
    /// re-minted — a new key would mean a password re-pair against every
    /// enrolled server.
    static func loadClientKeyCrypto() -> Curve25519.Signing.PrivateKey? {
        guard case .found(let pem) = FatClientKeyStore.load() else { return nil }
        guard let seed = OpenSSHKeyFormat.ed25519Seed(fromPEM: pem) else {
            FatClientLog.log("client key: keychain item is not an unencrypted ed25519 PEM")
            return nil
        }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// Ensure the ed25519 client identity exists; returns the OpenSSH
    /// public line to enroll on the remote's `authorized_keys`.
    ///
    /// ONE identity per client Mac, with the PRIVATE half in the
    /// data-protection keychain (app-scoped by code signature, no prompt —
    /// same choice as SecretsVault), not as a plaintext file: stealing the
    /// remote-client directory yields only the public key. A pre-keychain
    /// plaintext id_ed25519 is migrated on first use and shredded.
    @discardableResult
    static func ensureClientKey() -> String? {
        _ = bootstrap
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
        // Fresh identity, minted in-process. Stored as an OpenSSH PEM — the
        // format this Mac's keychain item has always held, so the key stays
        // readable by anything that expects it (and by an older build).
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        let pem = OpenSSHKeyFormat.ed25519PEM(seed: key.rawRepresentation,
                                              publicKey: pub,
                                              comment: "bromure-ac-fatclient")
        guard FatClientKeyStore.store(String(decoding: pem, as: UTF8.self)) else { return nil }
        let line = SSHKeyWire.opensshPublicLine(key.publicKey, comment: "bromure-ac-fatclient")
        try? (line + "\n").write(to: publicKeyPath, atomically: true, encoding: .utf8)
        return clientPublicKey()
    }

    /// SHA256 fingerprint of the client's public key — the selector for
    /// revoking it on a server at unpair time.
    static func clientKeyFingerprint() -> String? {
        guard let line = clientPublicKey() else { return nil }
        return SSHKeyWire.fingerprint(ofPublicLine: line)
    }

    static func clientPublicKey() -> String? {
        if let onDisk = (try? String(contentsOf: publicKeyPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !onDisk.isEmpty {
            return onDisk
        }
        // The .pub is a convenience copy; the keychain is the source of truth.
        // Re-derive (and re-write) it if the file went missing.
        guard let key = loadClientKeyCrypto() else { return nil }
        let line = SSHKeyWire.opensshPublicLine(key.publicKey, comment: "bromure-ac-fatclient")
        try? (line + "\n").write(to: publicKeyPath, atomically: true, encoding: .utf8)
        return line
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

    // MARK: Host-key TOFU
    //
    // Pins live in our own known_hosts, managed by the shared
    // `KnownHostsStore` (the dialer reads the same file). A peer's loopback
    // endpoint is ephemeral, so peer pins key on the stable device alias
    // instead of host:port — the same policy the ssh path expressed as
    // HostKeyAlias.

    /// Fetch the remote's ed25519 host key + SHA256 fingerprint (for the
    /// user-visible TOFU prompt). Nil if the host is unreachable.
    static func scanHostKey(address: String, port: Int) -> HostKeyInfo? {
        _ = bootstrap
        return SSHDialer.shared.scanHostKey(address: address, port: port)
    }

    /// Trust a host key: replace any prior entry for this host in known_hosts
    /// with `info.line`. Called after the user confirms the fingerprint.
    static func pinHostKey(address: String, port: Int, info: HostKeyInfo) {
        ensureDirs()
        let token = KnownHostsStore.hostToken(address: address, port: port)
        KnownHostsStore(url: knownHostsPath).pin(token: token, keyLine: info.line)
    }

    /// Trust a host key under a peer alias (peer hosts — their loopback
    /// endpoint is ephemeral, so the pin keys on the stable device identity):
    /// re-key the scanned line onto the alias and replace any prior entry.
    static func pinHostKey(alias: String, info: HostKeyInfo) {
        ensureDirs()
        let parts = info.line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        KnownHostsStore(url: knownHostsPath).pin(token: alias, keyLine: "\(alias) \(parts[1])")
    }

    /// Whether `alias` already has a pinned key in our known_hosts — i.e. this
    /// peer completed fingerprint TOFU on an earlier connect.
    static func hasAliasPin(_ alias: String) -> Bool {
        KnownHostsStore(url: knownHostsPath).hasPin(token: alias)
    }

    // MARK: Probe (classified connection attempt)

    /// Probe a remote with the client key by running one `GET /health` over the
    /// tunnel. `strictHostKey` = enforce the pinned key (detects MITM).
    /// Password auth lives in `FatClientNIOSSH`; this path is public-key only.
    ///
    /// Two attempts, because a pooled connection can be a corpse: after a sleep
    /// or a P2P path change the socket is dead but `channel.isActive` still
    /// reads true, so the reuse fails on FIRST USE with a bare EOF. The host is
    /// re-resolved per attempt (off the main thread that re-establishes a peer
    /// path) and the failed connection is closed so the pool evicts it.
    static func probe(host rawHost: RemoteHost, strictHostKey: Bool) -> RemoteProbe {
        _ = bootstrap
        ensureClientKey()
        guard rawHost.sshDestination != nil else {
            return .unreachable("invalid SSH username or address")
        }
        for attempt in 0..<2 {
            let host = resolved(rawHost)
            do {
                let conn = try SSHDialer.shared.ensureConnection(host: host, strict: strictHostKey)
                guard let fd = conn.openVerbChannel(FatClient.controlVerb) else {
                    conn.close()
                    if attempt == 0 { continue }
                    return .unreachable("couldn't open control channel")
                }
                let client = ControlClient(socketPath: "ssh://\(host.connectLabel)") { fd }
                let resp = try? client.request("GET", "/health")
                if resp?.status == 200 { return .ok }
                conn.close()
                if attempt == 0 { continue }
                return .unreachable("no response from remote")
            } catch let e as SSHDialError {
                switch e {
                // Auth and host-key verdicts are answers, not transport
                // failures — a retry returns the same thing.
                case .authFailed:     return .authFailed
                case .hostKeyChanged: return .hostKeyChanged
                case .unreachable(let m):
                    if attempt == 0 { continue }
                    return .unreachable(m)
                }
            } catch {
                if attempt == 0 { continue }
                return .unreachable("\(error)")
            }
        }
        return .unreachable("no response from remote")
    }

    /// A `ControlClient` whose transport is an SSH channel to `host`: a
    /// `bromure-fatclient control` exec channel bridged to the remote's
    /// owner-only control socket, so the whole control-plane HTTP API +
    /// `InteractiveExec` run over SSH unchanged.
    static func client(for rawHost: RemoteHost, interactive: Bool = false) -> ControlClient {
        _ = bootstrap
        ensureClientKey()
        let host = resolved(rawHost)
        // Terminal streams get their own pooled connection ("term" lane) so a
        // long-lived, possibly backed-up PTY channel can't stall the control
        // connection the mirror poll rides — sharing one let a wedged terminal
        // freeze the whole mirror on "Connecting…".
        let lane = interactive ? "term" : ""
        return ControlClient(socketPath: "ssh://\(host.connectLabel)") {
            SSHDialer.shared.dial(host: host, verb: FatClient.controlVerb, lane: lane)
        }
    }

    /// Resolve a remote client by host id (used by the `__attach-window
    /// --remote <hostID>` subprocess).
    static func client(hostID: UUID, interactive: Bool = false) -> ControlClient? {
        guard let host = loadHosts().first(where: { $0.id == hostID }) else { return nil }
        return client(for: host, interactive: interactive)
    }

    /// Open a raw TCP tunnel to a guest `ip:port` on the remote's vmnet subnet
    /// (`bromure-fatclient/1 forward <ip> <port>`). Returns a bidirectional fd
    /// bridged to the remote guest; the caller owns and closes it.
    static func forwardDial(host rawHost: RemoteHost, ip: String, port: Int) -> Int32? {
        _ = bootstrap
        ensureClientKey()
        let host = resolved(rawHost)
        guard host.sshDestination != nil else { return nil }
        return SSHDialer.shared.dial(host: host,
                                     verb: "\(FatClient.forwardVerbPrefix)\(ip) \(port)")
    }

    /// Open a `forward-udp <ip>` channel: a multiplexed byte stream carrying
    /// length-prefixed UDP datagrams to a remote guest.
    static func forwardDialUDP(host rawHost: RemoteHost, ip: String) -> Int32? {
        _ = bootstrap
        ensureClientKey()
        let host = resolved(rawHost)
        guard host.sshDestination != nil else { return nil }
        return SSHDialer.shared.dial(host: host,
                                     verb: "\(FatClient.forwardUDPVerbPrefix)\(ip)")
    }

    /// Open a `browser-mcp <vm>` channel: a raw byte stream carrying the remote
    /// workspace agent's line-delimited JSON-RPC, which the fat client answers
    /// with its own `BrowserMCPServer`.
    static func browserMCPDial(host rawHost: RemoteHost, vm: String) -> Int32? {
        _ = bootstrap
        ensureClientKey()
        let host = resolved(rawHost)
        guard host.sshDestination != nil else { return nil }
        return SSHDialer.shared.dial(host: host,
                                     verb: "\(FatClient.browserMCPVerbPrefix)\(vm)")
    }
}
