import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - RemoteTransport (iOS)
//
// The iOS twin of the macOS `RemoteTransport` (Sources/AgentCoding/
// FatClientRemote.swift), exposing the SAME static API the shared fat-client
// code calls — but with the Process-based guts (system ssh, ssh-keygen,
// ssh-keyscan, in-memory ssh-agent) replaced by the in-process `SSHDialer`
// (FatClientSSHDial.swift) and CryptoKit. The shared `ControlClient`,
// `RemoteHostController`, `RemoteHostStore`, and the connect flow all bind to
// this type name, so nothing above the transport changes between platforms.

enum RemoteTransport {
    // MARK: Paths (mirror the macOS layout under the app-support container)

    static var dir: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BromureAC/remote-client", isDirectory: true)
    }
    static var hostsFile: URL { dir.appendingPathComponent("hosts.json") }
    static var knownHostsPath: URL { dir.appendingPathComponent("known_hosts") }
    static var controlDir: URL { dir.appendingPathComponent("control", isDirectory: true) }
    /// No plaintext private key on iOS — the identity lives in the keychain
    /// (FatClientKeyStore). The macOS-migration checks in shared code test this
    /// path's existence; it never exists here.
    static var privateKeyPath: URL { dir.appendingPathComponent("id_ed25519") }
    static var publicKeyPath: URL { dir.appendingPathComponent("id_ed25519.pub") }

    static func ensureDirs() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: controlDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    // MARK: Host records

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

    // MARK: Client identity (CryptoKit ed25519 in the keychain)
    //
    // The private half is a Curve25519 signing key; `FatClientKeyStore` (shared)
    // persists it as the base64 of its 32-byte raw seed in the data-protection
    // keychain — the same item the macOS build uses for an OpenSSH PEM, but this
    // device's keychain is its own, so the encodings never meet.

    /// Loaded once and configured onto SSHDialer at first use.
    private static let bootstrap: Void = {
        SSHDialer.shared.knownHostsURL = knownHostsPath
        SSHDialer.shared.loadClientKey = { loadClientKeyCrypto() }
    }()

    static func loadClientKeyCrypto() -> Curve25519.Signing.PrivateKey? {
        guard case .found(let seedB64) = FatClientKeyStore.load(),
              let seed = Data(base64Encoded: seedB64),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        return key
    }

    /// Ensure the ed25519 client identity exists; returns the OpenSSH public
    /// line to enroll on the remote's `authorized_keys`. Never regenerates over
    /// an identity the keychain is merely refusing to serve right now.
    @discardableResult
    static func ensureClientKey() -> String? {
        _ = bootstrap
        ensureDirs()
        switch FatClientKeyStore.load() {
        case .found:
            return clientPublicKey()
        case .unavailable(let status):
            FatClientLog.log("client key unavailable (OSStatus \(status)) — "
                + "not regenerating; retry after unlocking this device")
            return nil
        case .notFound:
            break
        }
        let key = Curve25519.Signing.PrivateKey()
        guard FatClientKeyStore.store(key.rawRepresentation.base64EncodedString()) else { return nil }
        return clientPublicKey()
    }

    static func clientPublicKey() -> String? {
        guard let key = loadClientKeyCrypto() else { return nil }
        return SSHKeyWire.opensshPublicLine(key.publicKey, comment: "bromure-remote-ios")
    }

    /// Publish this device's SSH public key to bromure.io so the user's servers
    /// authorize it with no password (they pull it in via /v1/devices/ssh-keys).
    /// Safe to call repeatedly — on launch and after sign-in. No-op until this
    /// device has a bromure.io identity and an SSH key.
    static func publishSSHKey() {
        guard let line = ensureClientKey(),
              let (client, bearer) = ControlPlaneClient.current() else { return }
        // iOS is a client, never an SSH server, so its username is never dialed;
        // publish it anyway for a uniform record.
        let user = NSUserName()
        Task { try? await client.uploadSSHKey(bearer: bearer, sshPublicKey: line, sshUsername: user) }
    }

    static func clientKeyFingerprint() -> String? {
        guard let key = loadClientKeyCrypto() else { return nil }
        return SSHKeyWire.fingerprint(ofBlob: SSHKeyWire.ed25519Blob(key.publicKey))
    }

    // MARK: Peer resolution (P2P) — identical policy to macOS

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

    // MARK: ControlClient factories (SSHDialer transport)

    static func client(for rawHost: RemoteHost, interactive: Bool = false) -> ControlClient {
        _ = bootstrap
        ensureClientKey()
        let host = resolved(rawHost)
        // Terminal streams get their own pooled connection ("term" lane) so a
        // long-lived, possibly backed-up PTY channel can't stall the control
        // connection the mirror poll rides — a shared connection let one wedge
        // freeze everything on "Connecting…".
        let lane = interactive ? "term" : ""
        return ControlClient(socketPath: "ssh://\(host.connectLabel)") {
            SSHDialer.shared.dial(host: host, verb: FatClient.controlVerb, lane: lane)
        }
    }

    static func client(hostID: UUID, interactive: Bool = false) -> ControlClient? {
        // Saved (by-address) hosts resolve from disk; peer hosts live only in
        // the live controller's actor-isolated registry, read on the main actor.
        var host = loadHosts().first(where: { $0.id == hostID })
        if host == nil {
            host = MainActor.assumeIsolated { RemoteHostController.liveHosts[hostID] }
        }
        guard let host else { return nil }
        return client(for: host, interactive: interactive)
    }

    // MARK: Forward tunnel

    /// Open a raw TCP tunnel to a guest `ip:port` on the remote's vmnet subnet
    /// (`bromure-fatclient/1 forward <ip> <port>`) — the mobile twin of the
    /// macOS `RemoteTransport.forwardDial` (Process ssh there, SSHDialer here;
    /// same verb MobileForward opens per browser connection). Returns a
    /// bidirectional fd bridged to the remote guest; the caller owns and
    /// closes it.
    static func forwardDial(host rawHost: RemoteHost, ip: String, port: Int) -> Int32? {
        _ = bootstrap
        ensureClientKey()
        let host = resolved(rawHost)
        return SSHDialer.shared.dial(host: host,
                                     verb: "\(FatClient.forwardVerbPrefix)\(ip) \(port)")
    }

    // MARK: Host-key TOFU

    static func scanHostKey(address: String, port: Int) -> HostKeyInfo? {
        _ = bootstrap
        return SSHDialer.shared.scanHostKey(address: address, port: port)
    }

    static func pinHostKey(address: String, port: Int, info: HostKeyInfo) {
        ensureDirs()
        let token = KnownHostsStore.hostToken(address: address, port: port)
        KnownHostsStore(url: knownHostsPath).pin(token: token, keyLine: info.line)
    }

    static func pinHostKey(alias: String, info: HostKeyInfo) {
        ensureDirs()
        // The scanned line is "<host-token> <algo> <b64>"; re-key it under the
        // peer alias so the pin follows the device, not the ephemeral loopback.
        let parts = info.line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        KnownHostsStore(url: knownHostsPath).pin(token: alias, keyLine: "\(alias) \(parts[1])")
    }

    static func hasAliasPin(_ alias: String) -> Bool {
        KnownHostsStore(url: knownHostsPath).hasPin(token: alias)
    }

    // MARK: Probe (classified connection attempt)

    static func probe(host rawHost: RemoteHost, strictHostKey: Bool) -> RemoteProbe {
        _ = bootstrap
        ensureClientKey()
        // TWO attempts, because everything this touches can be a zombie after
        // the app was backgrounded: iOS freezes our sockets, the peer's FIN
        // never arrives, and both liveness checks still say yes —
        // `SSHConnection.isAlive` is just `channel.isActive`, and a cached P2P
        // shim's loopback listener stays up even when the relay behind it is
        // dead. Reusing either fails on FIRST USE with a raw EOF, which the
        // login sheet showed as "end of file". `SSHDialer.dial` already retries
        // like this for verb channels; sign-in went without.
        //
        // The host is re-resolved per attempt so a dead peer path gets a chance
        // to re-establish (off the main thread `resolved` establishes rather
        // than just reading the cache), and the failed connection is closed so
        // the pool evicts it instead of handing the same corpse back.
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
                // failures — a retry would return the same thing.
                case .authFailed:      return .authFailed
                case .hostKeyChanged:  return .hostKeyChanged
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
}
