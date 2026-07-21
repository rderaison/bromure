import AppKit
import Foundation

extension Notification.Name {
    /// Posted when this Mac's bromure.io device identity changes (enrolled or
    /// signed out) so open windows refresh.
    static let p2pIdentityChanged = Notification.Name("io.bromure.p2pIdentityChanged")
}

/// The single owner of this Mac's bromure.io identity. Enterprise installs
/// already have one (the managed enrollment) and reuse it — no sign-in. Only a
/// personal account with no enrollment at all needs the browser sign-in, which
/// this coordinates: it holds the enroll nonce and the one `bromure://enroll`
/// deep-link callback completes it.
///
/// Roles are independent: any identity can dial (client); Remote Access makes
/// this Mac a server. So there is no "sign in as a server/client" — you sign in
/// once, then the Remote Access switch decides reachability.
@MainActor
@Observable
final class P2PEnrollmentCoordinator {
    static let shared = P2PEnrollmentCoordinator()

    private(set) var identity: P2PIdentity?
    private(set) var busy = false
    var error: String?

    /// The nonce of an in-flight browser sign-in; the callback is only honored
    /// when it echoes this exact value, so an unsolicited `bromure://enroll`
    /// link can't enroll this Mac into an attacker's workspace.
    private var pendingState: String?

    init() { identity = P2PIdentity.current() }

    var signedIn: Bool { identity != nil }
    var accountLabel: String? { identity?.orgSlug ?? (signedIn ? "bromure.io" : nil) }
    /// True when the identity is the managed enterprise enrollment (reused) —
    /// which the user can't "sign out" of from here.
    var isEnterprise: Bool { identity?.source == .enterprise }

    /// Re-read the identity (e.g. when a window appears).
    func refresh() { identity = P2PIdentity.current() }

    /// Open the browser to the bromure.io enrollment handoff. Only used when
    /// there's no existing identity (a personal account). Enrollment just
    /// registers the device; server reachability is the Remote Access switch.
    func signIn() {
        let state = UUID().uuidString
        pendingState = state
        error = nil
        var comps = URLComponents(string: "https://bromure.io/app/enroll")!
        comps.queryItems = [
            URLQueryItem(name: "capability", value: "client"),
            URLQueryItem(name: "state", value: state),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    /// Complete a browser sign-in from the deep-link callback. No-op unless
    /// `state` matches the in-flight sign-in.
    func complete(_ link: EnrollLink, state: String?) {
        guard let pending = pendingState, let state, state == pending else { return }
        pendingState = nil
        busy = true; error = nil
        Task {
            let result = await P2PEnroll.enroll(link: link, deviceName: Host.current().localizedName)
            busy = false
            switch result {
            case .success:
                identity = P2PIdentity.current()
                // If Remote Access is already on, advertise as a server now.
                if P2PBroker.remoteAccessEnabled {
                    P2PBroker.shared.startServing(sshPort: P2PBroker.configuredSSHPort())
                }
                NotificationCenter.default.post(name: .p2pIdentityChanged, object: nil)
            case .failure(let e):
                error = Self.describe(e)
            }
        }
    }

    /// Forget a browser-enrolled identity locally (server-side revoke is an
    /// admin action). No-op for the enterprise enrollment — that's owned by the
    /// managed-enrollment lifecycle, not this window.
    func signOut() {
        guard !isEnterprise else { return }
        DeviceIdentityStore.erase()
        P2PBroker.shared.stopServing()
        identity = P2PIdentity.current()   // may fall back to enterprise if present
        NotificationCenter.default.post(name: .p2pIdentityChanged, object: nil)
    }

    static func describe(_ e: P2PEnroll.EnrollError) -> String {
        switch e {
        case .badCode: return "The enrollment code is malformed."
        case .keychainWriteFailed: return "Couldn't save the device identity to the keychain."
        case .signingFailed: return "Couldn't sign the enrollment challenge."
        case .control(let c):
            switch c {
            case .badBase(let b): return "Bad control-plane URL: \(b)"
            case .http(let status, _):
                if status == 404 { return "This authorization is invalid or already used." }
                if status == 410 { return "This authorization expired — sign in again." }
                return "Enrollment failed (HTTP \(status))."
            case .decode: return "The server sent an unexpected response."
            case .turnUnavailable: return "Relay is unavailable."
            case .transport(let m): return "Couldn't reach bromure.io: \(m)"
            }
        }
    }
}
