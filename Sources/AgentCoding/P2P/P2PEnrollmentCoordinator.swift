import AppKit
import Foundation

extension Notification.Name {
    /// Posted when this Mac's bromure.io device identity changes (enrolled or
    /// signed out) so open windows refresh.
    static let p2pIdentityChanged = Notification.Name("io.bromure.p2pIdentityChanged")
}

/// The single owner of this Mac's bromure.io sign-in. Both the merged connect
/// window (enrolling as a *client* to browse servers) and Remote Access
/// settings (registering this Mac as a *server*) drive it, and the one
/// `bromure://enroll` deep-link callback completes whichever sign-in is
/// pending — so there's exactly one place that holds the enroll nonce and one
/// place that writes the device identity.
@MainActor
@Observable
final class P2PEnrollmentCoordinator {
    static let shared = P2PEnrollmentCoordinator()

    private(set) var record: DeviceRecord?
    private(set) var busy = false
    var error: String?

    /// The nonce of an in-flight browser sign-in; the callback is only honored
    /// when it echoes this exact value, so an unsolicited `bromure://enroll`
    /// link can't enroll this Mac into an attacker's workspace.
    private var pendingState: String?

    init() { record = P2PBroker.shared.currentRecord() }

    var signedIn: Bool { record != nil }
    var accountLabel: String? { record.map { $0.orgSlug ?? "bromure.io" } }
    var capability: String? { record?.capability }

    /// Re-read the identity from the keychain (e.g. when a window appears).
    func refresh() { record = P2PBroker.shared.currentRecord() }

    /// Open the browser to the bromure.io enrollment handoff. `asServer` picks
    /// the device capability: a server is reachable by the workspace's clients;
    /// a client browses and mirrors servers.
    func signIn(asServer: Bool) {
        let state = UUID().uuidString
        pendingState = state
        error = nil
        var comps = URLComponents(string: "https://bromure.io/app/enroll")!
        comps.queryItems = [
            URLQueryItem(name: "capability", value: asServer ? "server" : "client"),
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
            case .success(let r):
                record = r.record
                if r.record.isServer, P2PBroker.remoteAccessEnabled {
                    P2PBroker.shared.startServing(sshPort: P2PBroker.configuredSSHPort())
                }
                NotificationCenter.default.post(name: .p2pIdentityChanged, object: nil)
            case .failure(let e):
                error = Self.describe(e)
            }
        }
    }

    /// Forget this Mac's identity locally (server-side revoke is an admin action).
    func signOut() {
        DeviceIdentityStore.erase()
        P2PBroker.shared.stopServing()
        record = nil
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
