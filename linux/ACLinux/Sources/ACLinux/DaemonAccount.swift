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
    /// A sign-out is under way (its revoke awaits bromure.io).
    private var signingOut = false
    /// The bearer (fingerprint) whose refusal by bromure.io was already
    /// explained: the next sign-out with it forgets the identity here
    /// (`Daemon.accountSignOut`). In memory only, so a restart explains again.
    private var refusalShownFor: String?
    /// bromure.io refuses this server's credentials (the device channel
    /// found out): what `account status` says, until it signs out.
    private(set) var credentialProblem: String?
    private var refusalObserver: NSObjectProtocol?

    /// The device channel found the bearer refused (P2PBroker): explain, and
    /// let the next sign-out forget it on this server (macOS:
    /// P2PEnrollmentCoordinator's observer).
    // @port-skip linux-only: P2PEnrollmentCoordinator.init's observer, on the daemon's account state
    private init() {
        refusalObserver = NotificationCenter.default.addObserver(forName: .p2pCredentialRefused, object: nil, queue: nil) { note in
            guard let bearer = note.userInfo?["bearer"] as? String else { return }
            Task { @MainActor in
                guard ControlPlaneClient.current()?.1 == bearer else { return }
                LinuxAccountKeys.shared.noteCredentialRefused(bearer: bearer, problem: Daemon.credentialRefusedMessage)
            }
        }
    }

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

    /// Claim the one sign-out: nil when one is under way (macOS: `busy`).
    /// Otherwise whether bromure.io's refusal of `bearer` was already
    /// explained -- decided now, not when bromure.io answers: a refusal noted
    /// while this sign-out is in flight isn't one the user has seen (CWE-362).
    // @port-skip linux-only: the daemon's reentrancy guard
    func beginSignOut(bearer: String?) -> Bool? {
        if signingOut { return nil }
        signingOut = true
        return bearer.map { refusalShownFor == AcceptedCredential.fingerprint($0) } ?? false
    }

    // @port-skip linux-only: the daemon's reentrancy guard
    func endSignOut() { signingOut = false }

    /// bromure.io refuses `bearer` for good, and that was explained (a
    /// refused sign-out's reply, or `problem` in `account status`): the next
    /// sign-out may forget the identity here without asking again.
    // @port P2PEnrollmentCoordinator.noteCredentialRefused(bearer: String) h=d92012c99a2ea343 @656c9eecd
    func noteCredentialRefused(bearer: String, problem: String? = nil) {
        refusalShownFor = AcceptedCredential.fingerprint(bearer)
        if let problem { credentialProblem = problem }
    }

    /// The identity is gone from here: what was said about it too.
    // @port-skip linux-only: status line
    func forgetRefusal() {
        refusalShownFor = nil
        credentialProblem = nil
    }

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
    // partial: signedIn in GET /account
    // @port P2PEnrollmentCoordinator.var signedIn h=8858a5516f5fbaa8 @0151db9d
    // partial: org slug in GET /account (no "bromure.io" label)
    // @port P2PEnrollmentCoordinator.var accountLabel h=0437a4c26888d9c7 @0151db9d
    // partial: source device/enterprise in GET /account; sign-out refuses enterprise
    // @port P2PEnrollmentCoordinator.var isEnterprise h=9ff78a75310483b6 @0151db9d
    // partial: re-reads P2PIdentity on every call
    // @port P2PEnrollmentCoordinator.refresh() h=3e5d79c020e42307 @0151db9d
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
            if let p = LinuxAccountKeys.shared.credentialProblem, o["signedIn"] == .bool(true) { o["problem"] = .string(p) }
            return ControlResponse(200, .object(o))
        }
    }

    /// `POST /account/sign-in {"link"}`: redeem a bromure.io enrollment code
    /// (or its bromure://enroll link) and start the key sync. The code is
    /// never logged or echoed back.
    // @port P2PEnrollmentCoordinator.complete(_: EnrollLink, state: String?) h=995666e611256eb7 @0151db9d
    // partial: no browser on a server; user pastes the enrollment code/link (POST /account/sign-in)
    // @port P2PEnrollmentCoordinator.signIn() h=3c5e2d83b9522d43 @0151db9d
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

    /// `POST /account/sign-out`: retire this server's device on bromure.io
    /// (which revokes its token), and only once bromure.io confirmed it,
    /// forget the identity here. Erasing it first would leave the token live
    /// on bromure.io with nothing left to retry the revoke with (CWE-613). On
    /// failure the identity is kept and the reply says why (502): sign out
    /// again. The keys it brought in stay, as on macOS. Refused for an
    /// enterprise (managed) enrollment.
    ///
    /// A credential bromure.io refuses for good is NOT a confirmed revoke:
    /// its 401 is the same for a revoked device and for a token that merely
    /// expired, with the device still live (CWE-613). The first such sign-out
    /// explains and keeps the identity (409); the next one (or one after the
    /// device channel reported the refusal, `account status`'s problem)
    /// forgets it on this server only, and says so (`localOnly`).
    // partial: no beforeErase (no log-out panel); the outcome is the route's reply rather than `error`
    // @port P2PEnrollmentCoordinator.signOutRevoking(beforeErase: (()async->Void)?) h=30867a2057bb8098 @656c9eecd
    // partial: the forgetting half of accountSignOut
    // @port P2PEnrollmentCoordinator.signOut() h=e16e9a7209c4490c @656c9eecd
    func accountSignOut(retryDelay: UInt64 = 2_000_000_000) async -> ControlResponse {
        guard case .found(let record) = DeviceIdentityStore.load() else {
            return P2PIdentity.current() == nil ? .error(409, "Not signed in")
                : .error(409, "This server's account is its managed enrollment; it can't sign out here")
        }
        let current = ControlPlaneClient.current()
        guard let warned = await MainActor.run(body: { LinuxAccountKeys.shared.beginSignOut(bearer: current?.bearer) }) else {
            return .error(409, "A sign-out is already under way")
        }
        var localOnly = false
        if let (client, bearer) = current {
            let final = AcceptedCredential.refusalIsFinal(bearer: bearer, record: record)
            let outcome = await Self.revokeForSignOut(final: final, retryDelay: retryDelay) {
                try await client.selfRevoke(bearer: bearer)
            }
            switch outcome {
            case .done:
                break
            case .failed(let failure):
                await MainActor.run { LinuxAccountKeys.shared.endSignOut() }
                return .error(502, failure)
            case .refused:
                guard warned else {
                    await MainActor.run {
                        LinuxAccountKeys.shared.noteCredentialRefused(bearer: bearer)
                        LinuxAccountKeys.shared.endSignOut()
                    }
                    return .error(409, Self.signOutRefusedMessage)
                }
                localOnly = true
            }
        }
        DeviceIdentityStore.erase()
        AcceptedCredential.forget()
        await MainActor.run {
            LinuxAccountKeys.shared.forgetRefusal()
            LinuxAccountKeys.shared.endSignOut()
            // A managed (enterprise) enrollment is the identity now, as on
            // macOS (P2PIdentity falls back to it): the pulls go on under it.
            if P2PIdentity.current() != nil { LinuxAccountKeys.shared.start() } else { LinuxAccountKeys.shared.signedOut() }
        }
        await refreshP2PServing()
        var o: [String: JSONValue] = ["ok": .bool(true)]
        if localOnly {
            o["localOnly"] = .bool(true)
            o["note"] = .string("Signed out on this server only. If bromure.io still lists it under your devices, revoke it there.")
        }
        return ControlResponse(200, .object(o))
    }

    static let signOutRefusedMessage = "bromure.io no longer accepts this server’s credentials — they expired, or the device was revoked, and bromure.io doesn’t say which, so this server may still be registered there. Sign out again to forget it on this server only, and if it is still listed under your devices on bromure.io, revoke it there."

    /// What `account status` says once the device channel found the
    /// credentials refused (macOS: directoryRefusedMessage).
    static let credentialRefusedMessage = "bromure.io no longer accepts this server’s credentials — they expired, or the device was revoked, and bromure.io doesn’t say which. Sign out to forget it on this server, and if it is still listed under your devices on bromure.io, revoke it there."

    // @port-skip linux-only: revokeForSignOut's result (macOS: P2PEnrollmentCoordinator.RevokeOutcome)
    enum RevokeOutcome: Equatable {
        /// bromure.io confirmed the revoke.
        case done
        /// bromure.io refuses the credential for good (`final` 401): revoked,
        /// or only expired -- unknown, so not a confirmed revoke.
        case refused
        /// Not confirmed; the message to show.
        case failed(String)
    }

    /// Run a sign-out revoke. Only a 2xx confirms it (`.done`). A 401 never
    /// does (CWE-613): for a credential whose refusal is final (`final`:
    /// AcceptedCredential.refusalIsFinal -- accepted before, expired, or past
    /// propagation) it's `.refused`, since bromure.io answers the same 401 for
    /// a revoked device and for an expired token.
    ///
    /// A 401 for a credential bromure.io never accepted may be propagation lag
    /// right after enrollment: it's retried (`retries` times, `retryDelay`
    /// apart), then reported. Erasing the identity then would lose the only
    /// bearer that can revoke a device that is still live.
    // @port P2PEnrollmentCoordinator.static revokeForSignOut(final: Bool, retries: Int, retryDelay: UInt64, _: ()asyncthrows->Void) h=dbe08893e0dab58b @656c9eecd
    nonisolated static func revokeForSignOut(final: Bool, retries: Int = 3,
                                             retryDelay: UInt64 = 2_000_000_000,
                                             _ revoke: () async throws -> Void) async -> RevokeOutcome {
        var attempt = 0
        while true {
            do {
                try await revoke()
                return .done
            } catch ControlPlaneError.http(status: 401, _) {
                if final { return .refused }
                if attempt < retries {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: retryDelay)
                    continue
                }
                return .failed("Couldn’t sign out of bromure.io: it doesn’t recognize this device’s credentials yet, so the sign-out couldn’t be confirmed. This device may still be registered there — try again in a moment.")
            } catch {
                let why: String
                switch error as? ControlPlaneError {
                case .transport(let m)?: why = m
                case .http(let status, _)?: why = "HTTP \(status)"
                case .decode?: why = "unexpected response"
                default: why = error.localizedDescription
                }
                return .failed("Couldn’t sign out of bromure.io (\(why)). This device is still registered there — check your connection and try again.")
            }
        }
    }

    /// (P2PEnrollmentCoordinator.describe, which lives with the app's UI.)
    // @port P2PEnrollmentCoordinator.static describe(_: P2PEnroll.EnrollError) h=3f4bb27e3371f968 @0151db9d
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

/// Where a person gets this server's enrollment code: bromure.io's page for
/// a Linux machine (capability=server, os=linux). Signed in there, they
/// authorize it and copy the one-time code (10 minutes, one use) into
/// `account sign-in`. No `state`: the code is pasted, not handed back.
// @port-skip linux-only: macOS opens /app/enroll in the browser and takes the bromure:// handoff
public enum AccountEnrollPage {
    // @port-skip linux-only: see AccountEnrollPage
    public static func url(host: String = ProcessInfo.processInfo.hostName) -> String {
        var c = URLComponents(string: "https://bromure.io/app/enroll")!
        c.queryItems = [URLQueryItem(name: "capability", value: "server"), URLQueryItem(name: "os", value: "linux")]
        let name = String(host.prefix(64))
        if !name.isEmpty { c.queryItems?.append(URLQueryItem(name: "host", value: name)) }
        return c.url?.absoluteString ?? "https://bromure.io/app/enroll?capability=server&os=linux"
    }
}
