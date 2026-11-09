import CACLinuxShims
import Foundation
import SandboxEngine
import NIOCore
import NIOPosix

/// The shared SSH server's settings (macOS keeps them in UserDefaults under
/// `remoteAccess.*`): `<stateDir>/remote.json`.
// @port-skip linux-only: macOS stores these in UserDefaults
public struct RemoteSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var port = 2222
    public var bindAddress = "0.0.0.0"
    public var passwordAuth = true
    public var pubkeyAuth = true
    /// Password logins may use the account password (PAM), not only
    /// one-time enrollment codes. Off unless asked for.
    public var allowAccountPassword = false

    enum CodingKeys: String, CodingKey { case enabled, port, bindAddress, passwordAuth, pubkeyAuth, allowAccountPassword }

    // @port-skip linux-only: remote settings (files written before allowAccountPassword decode)
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 2222
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "0.0.0.0"
        passwordAuth = try c.decodeIfPresent(Bool.self, forKey: .passwordAuth) ?? true
        pubkeyAuth = try c.decodeIfPresent(Bool.self, forKey: .pubkeyAuth) ?? true
        allowAccountPassword = try c.decodeIfPresent(Bool.self, forKey: .allowAccountPassword) ?? false
    }

    // @port-skip linux-only: remote settings
    public init() {}

    // @port-skip linux-only: remote settings
    static func load(_ path: String) -> RemoteSettings {
        (try? JSONDecoder().decode(RemoteSettings.self, from: Data(contentsOf: URL(fileURLWithPath: path)))) ?? RemoteSettings()
    }

    // @port-skip linux-only: remote settings
    func save(_ path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // @port-skip linux-only: remote settings
    var serverConfig: RemoteAccessServer.Config {
        RemoteAccessServer.Config(port: port, bindAddress: bindAddress, passwordAuth: passwordAuth, pubkeyAuth: pubkeyAuth)
    }
}

// MARK: - The daemon's remote-access glue

extension Daemon {
    // @port-skip linux-only: Linux daemon layout
    var remoteSettingsPath: String { config.stateDir + "/remote.json" }

    /// Points the shared server at this daemon (control socket, guest subnet,
    /// forward resolvers) and starts it if enabled.
    // @port-skip linux-only: the daemon's half of ACAppDelegate.startRemoteAccessIfNeeded
    func setUpRemoteAccess() async {
        // The shared code's ProfileStore() lives in the state dir, and the
        // shared server keeps `remote/` (host key, authorized_keys) beside its
        // control socket: <state>/control.sock links to the real socket, so
        // remote/ is the state dir's own and a pinned host key survives a
        // reboot. The runtime dir's remote/ (older daemons') points at it.
        ProfileStore.defaultRootDir = URL(fileURLWithPath: config.stateDir + "/profiles", isDirectory: true)
        Self.linkControlSocket(config)
        Self.linkRemoteDirectory(state: config.stateDir + "/remote", runtime: config.runtimeDir + "/remote")
        EnrollmentCodes.file.withLockedValue { $0 = config.stateDir + "/remote/enroll-codes" }
        BromureLinuxPaths.stateDir.withLockedValue { $0 = config.stateDir }
        let g = sw.dhcp.server.map(UInt32.init)
        let gw = g[0] << 24 | g[1] << 16 | g[2] << 8 | g[3]
        VMNetSwitch.shared.subnet = VmnetSubnet(gateway: gw, mask: 0xFFFF_FF00, poolEnd: gw & 0xFFFF_FF00 | 254)
        let resolverBox = WeakDaemon(self)
        await MainActor.run {
            RemoteAccessServer.shared.forwardResolver = { ip, port, completion in
                Task { completion(await resolverBox.daemon?.relayFD(ip: ip, header: "\(port)\n") ?? -1) }
            }
            RemoteAccessServer.shared.udpForwardResolver = { ip, completion in
                Task { completion(await resolverBox.daemon?.relayFD(ip: ip, header: "UDP\n") ?? -1) }
            }
            RemoteAccessServer.shared.browserMCPResolver = { vm, completion in
                Task { completion(await resolverBox.daemon?.browserMCPFD(vm: vm) ?? -1) }
            }
        }
        // Signed in to bromure.io: the account's devices' keys, whether this
        // daemon serves SSH itself or the multi-user gateway reads them.
        if P2PIdentity.current() != nil { await MainActor.run { LinuxAccountKeys.shared.start() } }
        let s = RemoteSettings.load(remoteSettingsPath)
        LinuxAccountPassword.allowPAM.withLockedValue { $0 = s.allowAccountPassword }
        defer { Task { await self.refreshP2PServing() } }
        guard s.enabled else { return }
        do {
            try await MainActor.run { try RemoteAccessServer.shared.start(s.serverConfig) }
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: remote access not started: \(error)\n".utf8))
        }
    }

    /// The control socket where the shared code looks for it,
    /// ProfileStore().controlSocketURL: `<state>/control.sock`, a symlink to
    /// the real one (`<runtime>/control.sock`, or multi-user's
    /// /run/bromure-ac/sock/<user>.sock).
    // @port-skip linux-only: Linux daemon layout
    static func linkControlSocket(_ config: DaemonConfig) {
        let local = config.stateDir + "/control.sock"
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: local)) != config.controlSocketPath {
            unlink(local)
            try? FileManager.default.createSymbolicLink(atPath: local, withDestinationPath: config.controlSocketPath)
        }
    }

    // @port-skip linux-only: see setUpRemoteAccess
    static func linkRemoteDirectory(state: String, runtime: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if (try? fm.destinationOfSymbolicLink(atPath: runtime)) == state { return }
        // A real directory left from before (keys made there): keep its
        // files unless the state dir has them already.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: runtime, isDirectory: &isDir), isDir.boolValue {
            for f in (try? fm.contentsOfDirectory(atPath: runtime)) ?? [] where !fm.fileExists(atPath: state + "/" + f) {
                try? fm.moveItem(atPath: runtime + "/" + f, toPath: state + "/" + f)
            }
        }
        try? fm.removeItem(atPath: runtime)
        try? fm.createSymbolicLink(atPath: runtime, withDestinationPath: state)
    }

    /// `POST /remote/code {"minutes"?}`: a one-time enrollment code a fat
    /// client can log in with instead of the account password (Linux).
    // @port-skip linux-only: macOS enrolls with the Mac account password
    func remoteCode(_ body: JSONValue) -> ControlResponse {
        let minutes = min(60, max(1, Int(body["minutes"]?.numberValue ?? 10)))
        do {
            let code = try EnrollmentCodes.create(lifetime: .seconds(minutes * 60))
            return ControlResponse(200, ["code": .string(code), "minutes": .number(Double(minutes)), "user": .string(NSUserName())])
        } catch { return .error(500, "\(error)") }
    }

    // MARK: the multi-user gateway's routes (it does auth and bytes; this
    // daemon, its user's, does the policy)

    /// `GET /remote/authorized-keys`: the account's key lines, for the
    /// gateway's public-key check.
    // @port-skip linux-only: multi-user gateway support
    func remoteAuthorizedKeys() async -> ControlResponse {
        let path = await MainActor.run { RemoteAccessServer.Paths.default.authKeys.path }
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return ControlResponse(200, ["keys": .array(lines.map(JSONValue.string))])
    }

    /// `POST /remote/code/check {"code"}`: consumes a live enrollment code.
    /// Same answer shape for any code; whether the account exists is the
    /// gateway's to hide.
    // @port-skip linux-only: multi-user gateway support
    func remoteCodeCheck(_ body: JSONValue) -> ControlResponse {
        ControlResponse(200, ["ok": .bool(EnrollmentCodes.consume(body["code"]?.stringValue ?? ""))])
    }

    /// `POST /fatclient/browser-mcp {"vm"}`: the gateway's `browser-mcp`,
    /// through this daemon. The connection becomes the VM's browser-MCP
    /// stream (its agents relayed to the client); 404 when no VM of this
    /// user with that id is running.
    // @port-skip linux-only: multi-user gateway support (macOS resolves browser-mcp in-process)
    func fatclientBrowserMCP(_ body: JSONValue) async -> ControlResponse {
        guard let vm = body["vm"]?.stringValue else { return .error(400, "Missing 'vm'") }
        let fd = await browserMCPFD(vm: vm)
        guard fd >= 0 else { return .error(404, "No running VM \(vm)") }
        return .streaming { client in await Self.pump(client, fd) }
    }

    /// `POST /fatclient/forward {"ip", "port" | "udp": true}`: the gateway's
    /// `forward` / `forward-udp`, through this daemon. The connection becomes
    /// the stream to the guest's loopback relay; 404 when no running VM of
    /// this user has that address.
    // @port-skip linux-only: multi-user gateway support (macOS resolves forwards in-process)
    func fatclientForward(_ body: JSONValue) async -> ControlResponse {
        guard let ip = body["ip"]?.stringValue else { return .error(400, "Missing 'ip'") }
        let header: String
        if body["udp"] == .bool(true) { header = "UDP\n" }
        else if let p = body["port"]?.numberValue, p > 0, p < 65536 { header = "\(Int(p))\n" }
        else { return .error(400, "Missing 'port' (or 'udp': true)") }
        let fd = await relayFD(ip: ip, header: header)
        guard fd >= 0 else { return .error(404, "No running VM at \(ip)") }
        // Counted while open: a sign-in VM's teardown waits for its
        // callback relay to drain (hasActiveLoopbackRelays).
        activeRelays[ip, default: 0] += 1
        return .streaming { [weak self] client in
            await Self.pump(client, fd)
            await self?.relayEnded(ip)
        }
    }

    /// Bytes both ways between a control stream and `fd` until both sides
    /// are done; each side's end half-closes the other.
    // @port-skip linux-only: multi-user gateway support
    static func pump(_ client: ControlStream, _ fd: Int32) async {
        let conn: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            conn = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .withConnectedSocket(fd) { ch in
                    ch.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: ch,
                            configuration: .init(isOutboundHalfClosureEnabled: true))
                    }
                }
        } catch {
            close(fd)
            return
        }
        try? await conn.executeThenClose { inbound, outbound in
            await withTaskGroup(of: Void.self) { g in
                g.addTask {
                    for await b in client.inbound { try? await outbound.write(b) }
                    outbound.finish()
                }
                g.addTask {
                    do { for try await b in inbound { try await client.write(b) } } catch {}
                }
            }
        }
    }

    /// `GET /remote`: what macOS's remoteAccessStatus returns.
    // @port ACAppDelegate.remoteAccessStatus() h=b15b5034f2d2161f @f127f8ab
    func remoteStatus() async -> ControlResponse {
        let s = RemoteSettings.load(remoteSettingsPath)
        let (running, fp, keys, keysProblem) = await MainActor.run {
            (RemoteAccessServer.shared.isRunning, RemoteAccessServer.shared.hostKeyFingerprint(),
             RemoteAccessServer.shared.listAuthorizedKeys(), RemoteAccessServer.shared.authorizedKeysProblem)
        }
        let user = NSUserName()
        let host = s.bindAddress == "0.0.0.0" ? (Self.primaryIPv4() ?? "<this-host-ip>") : s.bindAddress
        return ControlResponse(200, [
            "enabled": .bool(s.enabled), "running": .bool(running), "port": .number(Double(s.port)),
            "bindAddress": .string(s.bindAddress), "passwordAuth": .bool(s.passwordAuth), "pubkeyAuth": .bool(s.pubkeyAuth),
            "allowAccountPassword": .bool(s.allowAccountPassword),
            "fingerprint": .string(fp ?? "(not generated yet)"), "user": .string(user),
            "connect": .string("ssh -p \(s.port) \(user)@\(host)"),
            "authorizedKeys": .array(keys.map { ["type": .string($0.type), "comment": .string($0.comment),
                                                 "fingerprint": .string($0.fingerprint)] }),
            // Why the list may be empty when it isn't: authorized_keys unreadable.
            "authorizedKeysProblem": .string(keysProblem ?? ""),
        ])
    }

    /// `POST /remote`: port, bindAddress, passwordAuth, pubkeyAuth, enabled.
    // partial: no P2P advertising, no base-image-install guard (the daemon has no install step)
    // @port ACAppDelegate.remoteAccessApply(_: [String:Any]) h=3a0c28ae8f0a1d24 @7dd92fdf
    func remoteApply(_ spec: JSONValue) async -> ControlResponse {
        var s = RemoteSettings.load(remoteSettingsPath)
        if let p = spec["port"]?.numberValue {
            guard p > 0, p < 65536 else { return .error(400, "port must be in 1..65535") }
            guard p >= 1024 else { return .error(400, "port must be ≥ 1024 (non-root can't bind privileged ports)") }
            s.port = Int(p)
        }
        if let b = spec["bindAddress"]?.stringValue, !b.isEmpty { s.bindAddress = b }
        if case .bool(let v)? = spec["passwordAuth"] { s.passwordAuth = v }
        if case .bool(let v)? = spec["pubkeyAuth"] { s.pubkeyAuth = v }
        if case .bool(let v)? = spec["allowAccountPassword"] { s.allowAccountPassword = v }
        if case .bool(let enabled)? = spec["enabled"] {
            guard s.passwordAuth || s.pubkeyAuth else { return .error(400, "Enable at least one of password / public-key auth.") }
            s.enabled = enabled
        }
        do { try s.save(remoteSettingsPath) } catch { return .error(500, "\(error)") }
        LinuxAccountPassword.allowPAM.withLockedValue { $0 = s.allowAccountPassword }
        let cfg = s.serverConfig, enabled = s.enabled
        do {
            try await MainActor.run {
                if enabled { try RemoteAccessServer.shared.start(cfg) } else { RemoteAccessServer.shared.stop() }
            }
        } catch { return .error(400, "\(error)") }
        // The broker follows the front door (and a port change).
        await refreshP2PServing()
        return await remoteStatus()
    }

    /// `POST /remote/keys {"key": "<openssh public key line>"}`.
    // @port ACAppDelegate.remoteAccessAddKey(_: String) h=9d3ad0a2961c4ba1 @7dd92fdf
    func remoteAddKey(_ body: JSONValue) async -> ControlResponse {
        let key = body["key"]?.stringValue ?? ""
        do {
            let fp = try await MainActor.run { () throws -> String in
                try RemoteAccessServer.shared.addAuthorizedKey(key)
                return RemoteAccessServer.shared.listAuthorizedKeys().last?.fingerprint ?? "ok"
            }
            return ControlResponse(200, ["ok": true, "fingerprint": .string(fp)])
        } catch { return .error(400, "\(error)") }
    }

    /// `DELETE /remote/keys/{fingerprint|comment}`.
    // @port ACAppDelegate.remoteAccessRemoveKey(_: String) h=5684b894512fbf80 @7dd92fdf
    func remoteRemoveKey(_ selector: String) async -> ControlResponse {
        do {
            try await MainActor.run { try RemoteAccessServer.shared.removeAuthorizedKey(selector) }
            return ControlResponse(200, ["ok": true])
        } catch { return .error(400, "\(error)") }
    }

    /// A fat client's `browser-mcp` channel for VM `vm` (its id, any case):
    /// the VM's browser bridge takes one end of a socketpair and relays its
    /// agents over it; the SSH channel gets the other.
    // @port ACAppDelegate.resolveBrowserMCP(vm: String, completion: @escaping@Sendable(Int32)->Void) h=2551198a14f37e59 @7dd92fdf
    func browserMCPFD(vm: String) async -> Int32 {
        guard let l = live.first(where: { $0.key.caseInsensitiveCompare(vm) == .orderedSame })?.value,
              let browser = l.browser else {
            FatClientLog.log("browser-mcp-resolver: no running VM with a browser MCP: \(vm)")
            return -1
        }
        var sp: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &sp) == 0 else { return -1 }
        await MainActor.run { [browser, fd = sp[0]] in browser.attachRemote(fd: fd) }
        FatClientLog.log("browser-mcp-resolver: \(vm) attached")
        return sp[1]
    }

    /// A stream to the guest loopback relay (vsock 5010) of the VM leased
    /// `ip`, `header` already sent: what a fat client's forward rides on.
    /// -1 when no running VM has that address (relaying through another VM,
    /// as macOS does for LoadBalancer addresses, isn't here yet).
    // partial: only the VM's own address (no relay VM for LoadBalancer addresses); TCP and UDP share it
    // @port ACAppDelegate.resolveFatClientForward(ip: String, port: Int, completion: @escaping@Sendable(Int32)->Void) h=52e22521fc27c675 @7dd92fdf
    // @port ACAppDelegate.resolveFatClientForwardUDP(ip: String, completion: @escaping@Sendable(Int32)->Void) h=9665f79520e2f22d @7dd92fdf
    func relayFD(ip: String, header: String) async -> Int32 {
        guard let rec = registry.records.first(where: { $0.state == .running && sw.dhcp.leasedIP(for: $0.mac) == ip }),
              let l = live[rec.id] else {
            FatClientLog.log("forward-resolver: no running VM at \(ip)")
            return -1
        }
        let fd = await l.config.dialGuest(port: 5010)
        guard fd >= 0 else { FatClientLog.log("forward-resolver: dial \(ip) vsock 5010 failed (\(-fd))"); return -1 }
        let ok = header.utf8CString.withUnsafeBufferPointer { b in write(fd, b.baseAddress, b.count - 1) == b.count - 1 }
        guard ok else { close(fd); return -1 }
        relayOpened[ip] = Date()
        return fd
    }

    /// A /fatclient/forward relay closed.
    // @port-skip linux-only: LoopbackCallbackForwarder.activeRelays' count, over /fatclient/forward
    func relayEnded(_ ip: String) {
        let n = (activeRelays[ip] ?? 1) - 1
        activeRelays[ip] = n > 0 ? n : nil
    }



    /// The host's address on its default route (the `connect` hint).
    // @port-skip linux-only: HostNetwork.primaryIPv4 on macOS
    static func primaryIPv4() -> String? {
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(53).bigEndian
        a.sin_addr.s_addr = inet_addr("192.0.2.1")      // TEST-NET: connect() sends nothing
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard ok else { return nil }
        var local = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        var buf = [CChar](repeating: 0, count: 16)
        guard inet_ntop(AF_INET, &local.sin_addr, &buf, 16) != nil else { return nil }
        return String(cString: buf)
    }
}

/// Resolvers outlive nothing: they reach the daemon weakly.
// @port-skip linux-only: plumbing
final class WeakDaemon: Sendable {
    nonisolated(unsafe) weak var daemon: Daemon?
    // @port-skip linux-only: plumbing
    init(_ d: Daemon) { daemon = d }
}
