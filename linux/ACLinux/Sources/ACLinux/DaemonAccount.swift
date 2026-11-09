import Foundation
import NIOConcurrencyHelpers

/// Where the shared code's file-backed stores keep their files on Linux
/// (DeviceIdentityStore's device-record.json): the daemon's state dir.
// @port-skip linux-only: Linux daemon layout
enum BromureLinuxPaths {
    static let stateDir = NIOLockedValueBox<String?>(nil)
    // @port-skip linux-only: Linux daemon layout
    static var state: URL {
        URL(fileURLWithPath: stateDir.withLockedValue { $0 } ?? DaemonConfig.fromEnvironment().stateDir, isDirectory: true)
    }
}

/// This server's bromure.io account: the user signs in once (a code from
/// bromure.io, `bromure-ac account sign-in`), and the server keeps the
/// user's other devices' SSH keys in authorized_keys, so each of them
/// connects with no password and no `remote add-key`. An agent host's key is
/// tagged so it can only attach its machine (the gateway and the shared
/// server read the tag).
@MainActor
final class LinuxAccountKeys {
    static let shared = LinuxAccountKeys()

    /// The authorized_keys comment prefix of an account-managed key
    /// (macOS: ACAppDelegate.accountKeyMarker).
    static let marker = "bromure-account:"

    struct LastSync: Equatable { var at: Date; var keys: Int; var machineKeys: Int; var error: String? }
    private(set) var last: LastSync?
    private var ticker: Task<Void, Never>?
    private var inFlight = false
    /// A sign-in is under way (the daemon is an actor, and enrolling awaits
    /// bromure.io twice: a second one would enroll this server twice).
    private var signingIn = false

    /// Pull the owner's devices' SSH keys into authorized_keys. No-op unless
    /// signed in. A failed pull keeps the keys there are (as macOS does).
    // partial: pulls the keys only: no key of its own to publish (no fat-client key), no server-mode advertising, no keysChanged push (the 180 s tick)
    // @port ACAppDelegate.syncAccountSSHKeys() h=f4e5a1dafde3ef96 @d2db8346
    func sync() async {
        guard !inFlight, let (client, bearer) = ControlPlaneClient.current() else { return }
        inFlight = true; defer { inFlight = false }
        let keys: [ControlPlaneClient.DeviceSSHKey]
        do { keys = try await client.listSSHKeys(bearer: bearer) } catch {
            last = LastSync(at: Date(), keys: last?.keys ?? 0, machineKeys: last?.machineKeys ?? 0, error: Self.describe(error))
            return
        }
        // Re-tag each key's comment with the marker + device id, so the
        // reconcile prunes only account keys and never manual ones.
        let lines: [String] = keys.compactMap { k in
            let p = k.sshPublicKey.split(separator: " ").map(String.init)
            guard p.count >= 2 else { return nil }
            return "\(p[0]) \(p[1]) \(k.authorizedKeysComment)"
        }
        RemoteAccessServer.shared.setManagedKeys(marker: Self.marker, lines: lines)
        // What's there now (a malformed key, or one a manual key already
        // covers, isn't).
        let managed = RemoteAccessServer.shared.listAuthorizedKeys().filter { $0.comment.hasPrefix(Self.marker) }
        last = LastSync(at: Date(), keys: managed.count,
                        machineKeys: managed.filter { $0.comment.hasPrefix(RemoteAccessServer.machineKeyMarker) }.count, error: nil)
    }

    /// Sync now and every few minutes, so a device enrolled later is
    /// authorized without a restart (the reconcile only rewrites on a change).
    /// Each wait is the interval ±10%, so many servers that started together
    /// don't all ask bromure.io at once.
    // @port ACAppDelegate.startAccountKeySync() h=28b067a8cf48e804 @d2db8346
    func start(every interval: TimeInterval = 180) {
        Task { await sync() }
        guard ticker == nil else { return }
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.jittered(interval)))
                if Task.isCancelled { break }
                await LinuxAccountKeys.shared.sync()
            }
        }
    }

    // @port-skip linux-only: the 180 s tick's jitter (macOS: a plain Timer)
    nonisolated static func jittered(_ interval: TimeInterval) -> TimeInterval {
        interval * Double.random(in: 0.9...1.1)
    }

    /// Whether the periodic pull is running (tests).
    // @port-skip linux-only: test hook
    var isTicking: Bool { ticker != nil }

    // @port ACAppDelegate.stopAccountKeySync() h=5fc6970b829fd009 @d2db8346
    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// Claim the one sign-in: false when one is under way or this server is
    /// signed in already (both asked here, on the main actor, together).
    // @port-skip linux-only: the daemon's reentrancy guard
    func beginSignIn() -> String? {
        if signingIn { return "A sign-in is already under way" }
        if case .found = DeviceIdentityStore.load() { return "Already signed in; sign out first" }
        signingIn = true
        return nil
    }

    // @port-skip linux-only: the daemon's reentrancy guard
    func endSignIn() { signingIn = false }

    /// Signed out: no more pulls. The keys it brought in stay, as on macOS.
    // @port-skip linux-only: status line
    func signedOut() {
        stop()
        last = nil
    }

    // @port-skip linux-only: status line
    nonisolated static func describe(_ e: Error) -> String {
        switch e as? ControlPlaneError {
        case .http(let status, let code)?: return "bromure.io answered HTTP \(status)" + (code.map { " (\($0))" } ?? "")
        case .transport(let m)?: return "couldn't reach bromure.io: \(m)"
        case .decode?: return "bromure.io sent an unexpected response"
        default: return "\(e)"
        }
    }
}

// MARK: - The daemon's /account routes

extension Daemon {
    /// `GET /account`: signed in or not, and the last key sync. Never the token.
    // @port-skip linux-only: macOS shows this in Settings
    func accountStatus() async -> ControlResponse {
        await MainActor.run {
            var o: [String: JSONValue] = ["signedIn": .bool(false)]
            if let id = P2PIdentity.current() {
                o["signedIn"] = .bool(true)
                o["deviceId"] = .string(id.installId)
                o["apiBase"] = .string(id.apiBase)
                o["source"] = .string(id.source == .device ? "device" : "enterprise")
                if let s = id.orgSlug { o["org"] = .string(s) }
            }
            if let l = LinuxAccountKeys.shared.last {
                var s: [String: JSONValue] = ["at": .string(ISO8601DateFormatter().string(from: l.at)),
                                              "keys": .number(Double(l.keys)), "machineKeys": .number(Double(l.machineKeys))]
                if let e = l.error { s["error"] = .string(e) }
                o["lastSync"] = .object(s)
            }
            return ControlResponse(200, .object(o))
        }
    }

    /// `POST /account/sign-in {"link"}`: redeem a bromure.io enrollment code
    /// (or its bromure://enroll link) and start the key sync. The code is
    /// never logged or echoed back.
    // @port P2PEnrollmentCoordinator.complete(_: EnrollLink, state: String?) h=995666e611256eb7 @0151db9d
    func accountSignIn(_ body: JSONValue) async -> ControlResponse {
        guard let raw = body["link"]?.stringValue, let link = EnrollLink(parsing: raw) else {
            return .error(400, "That isn't a bromure.io enrollment code or link")
        }
        if let busy = await MainActor.run(body: { LinuxAccountKeys.shared.beginSignIn() }) { return .error(409, busy) }
        let name = ProcessInfo.processInfo.hostName
        let result = await P2PEnroll.enroll(link: link, deviceName: name)
        await MainActor.run { LinuxAccountKeys.shared.endSignIn() }
        switch result {
        case .success(let r):
            await MainActor.run { LinuxAccountKeys.shared.start() }
            await refreshP2PServing()
            var o: [String: JSONValue] = ["ok": .bool(true), "deviceId": .string(r.record.deviceId)]
            if let s = r.record.orgSlug { o["org"] = .string(s) }
            return ControlResponse(200, .object(o))
        case .failure(let e):
            return .error(e == .keychainWriteFailed ? 500 : 400, Self.describeEnroll(e))
        }
    }

    /// `POST /account/sign-out`: forget the identity here; the keys it
    /// brought in stay, as on macOS. Refused for an enterprise (managed)
    /// enrollment.
    // @port P2PEnrollmentCoordinator.signOut() h=1773e2f113bc7f8c @0151db9d
    func accountSignOut() async -> ControlResponse {
        guard case .found = DeviceIdentityStore.load() else {
            return P2PIdentity.current() == nil ? .error(409, "Not signed in")
                : .error(409, "This server's account is its managed enrollment; it can't sign out here")
        }
        DeviceIdentityStore.erase()
        await MainActor.run {
            // A managed (enterprise) enrollment is the identity now, as on
            // macOS (P2PIdentity falls back to it): the pulls go on under it.
            if P2PIdentity.current() != nil { LinuxAccountKeys.shared.start() } else { LinuxAccountKeys.shared.signedOut() }
        }
        await refreshP2PServing()
        return ControlResponse(200, ["ok": .bool(true)])
    }

    /// (P2PEnrollmentCoordinator.describe, which lives with the app's UI.)
    // @port-skip linux-only: CLI text
    static func describeEnroll(_ e: P2PEnroll.EnrollError) -> String {
        switch e {
        case .badCode: return "The enrollment code is malformed."
        case .keychainWriteFailed: return "Couldn't save the device identity in the state dir."
        case .signingFailed: return "Couldn't sign the enrollment challenge."
        case .control(.http(404, _)): return "This code is invalid or already used."
        case .control(.http(410, _)): return "This code expired; get a new one."
        case .control(let c): return LinuxAccountKeys.describe(c)
        }
    }

    /// `POST /account/sync`: pull the keys now.
    // @port-skip linux-only: CLI
    func accountSync() async -> ControlResponse {
        guard P2PIdentity.current() != nil else { return .error(409, "Not signed in") }
        await LinuxAccountKeys.shared.sync()
        return await accountStatus()
    }
}
