#if os(macOS)
import AppKit
#else
import UIKit
import AuthenticationServices
#endif
import Foundation

extension Notification.Name {
    /// Posted when this Mac's bromure.io device identity changes (enrolled or
    /// signed out) so open windows refresh.
    static let p2pIdentityChanged = Notification.Name("io.bromure.p2pIdentityChanged")
}

#if os(iOS)
/// Anchors the in-app sign-in web sheet to the app's foreground window.
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}
#endif

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

    /// The bearer (fingerprint) whose refused sign-out was already explained:
    /// the next sign-out with it forgets the identity locally
    /// (`signOutRevoking`). In memory only, so a relaunch explains again.
    private var refusalShownFor: String?

#if os(iOS)
    /// Retained while the in-app sign-in web sheet is on screen; the callback
    /// (a `bromure://enroll` redirect) is captured by the session itself.
    private var webAuthSession: ASWebAuthenticationSession?
    private let webAuthPresenter = WebAuthPresenter()
#endif

#if os(visionOS)
    /// An in-flight in-app sign-in: the enroll page the embedded web sheet
    /// loads. `RootView` presents `SignInWebSheet` while this is non-nil.
    struct WebSignIn: Identifiable {
        let state: String
        let url: URL
        var id: String { state }
    }
    var webSignIn: WebSignIn?
#endif

    init() {
        identity = P2PIdentity.current()
        // The device channel found the bearer refused (P2PBroker): explain,
        // and let the next Sign Out forget it on this device.
        NotificationCenter.default.addObserver(forName: .p2pCredentialRefused, object: nil, queue: .main) { note in
            guard let bearer = note.userInfo?["bearer"] as? String else { return }
            MainActor.assumeIsolated {
                let me = P2PEnrollmentCoordinator.shared
                guard ControlPlaneClient.current()?.1 == bearer else { return }
                me.noteCredentialRefused(bearer: bearer)
                me.error = Self.directoryRefusedMessage
            }
        }
    }

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
#if os(visionOS)
        // Name the device class (the web view's UA reads as a Mac) and flag
        // the embedded sheet so the login page hides its passkey button —
        // WebAuthn is unavailable inside WKWebView.
        comps.queryItems?.append(contentsOf: [
            URLQueryItem(name: "platform", value: "vision"),
            URLQueryItem(name: "embedded", value: "1"),
        ])
#endif
        if let url = comps.url {
#if os(macOS)
            NSWorkspace.shared.open(url)
#elseif os(visionOS)
            // Embedded WKWebView sheet (SignInWebSheet), not
            // ASWebAuthenticationSession: its visionOS presentation is a fixed
            // compact browser card that clips the login form, with no sizing
            // API. Not Safari-in-the-room either — App Review rejects sign-in
            // that bounces out of the app, and the deep-link round-trip lost
            // users who never found their way back. The sheet intercepts the
            // same `bromure://enroll` redirect the iOS session captures.
            webSignIn = WebSignIn(state: state, url: url)
#else
            startWebAuth(url: url)
#endif
        }
    }

#if os(iOS)
    /// iOS sign-in in an in-app web sheet (ASWebAuthenticationSession) rather
    /// than kicking out to Safari. It shares Safari's cookies (so an existing
    /// bromure.io login carries over) and intercepts the `bromure://enroll`
    /// redirect itself — feeding the same `complete(_:state:)` path the deep
    /// link used, no app round-trip.
    private func startWebAuth(url: URL) {
        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: "bromure") { [weak self] callbackURL, err in
            guard let self else { return }
            self.webAuthSession = nil
            if let callbackURL, let link = EnrollLink(parsing: callbackURL.absoluteString) {
                let state = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value
                self.complete(link, state: state)
            } else if let authErr = err as? ASWebAuthenticationSessionError,
                      authErr.code == .canceledLogin {
                // Dismissed by the user — leave the sheet closed, no error.
            } else if err != nil {
                self.error = "Sign-in didn’t complete. Please try again."
            }
        }
        session.presentationContextProvider = webAuthPresenter
        // Reuse the system Safari cookie jar so an existing bromure.io session
        // signs in without re-entering credentials.
        session.prefersEphemeralWebBrowserSession = false
        webAuthSession = session
        if !session.start() {
            error = "Couldn’t open the sign-in page."
        }
    }
#endif

#if os(visionOS)
    /// The embedded sheet caught the `bromure://enroll` redirect: dismiss it
    /// and feed the same completion path the iOS web sheet and the macOS
    /// deep link use.
    func completeWebSignIn(_ callbackURL: URL) {
        webSignIn = nil
        guard let link = EnrollLink(parsing: callbackURL.absoluteString) else { return }
        let state = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value
        complete(link, state: state)
    }

    /// The sheet was dismissed without completing — forget the nonce so a
    /// stray later `bromure://enroll` link can't ride the dead attempt.
    func cancelWebSignIn() {
        webSignIn = nil
        pendingState = nil
    }
#endif

    /// Complete a browser sign-in from the deep-link callback. No-op unless
    /// `state` matches the in-flight sign-in.
    func complete(_ link: EnrollLink, state: String?) {
        guard let pending = pendingState, let state, state == pending else { return }
        pendingState = nil
        busy = true; error = nil
        Task {
            let result = await P2PEnroll.enroll(link: link, deviceName: platformDeviceName())
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
    /// The user's sign-out: retire this device on bromure.io (which revokes
    /// its token and drops its SSH key from the user's servers), and only once
    /// bromure.io confirmed it, forget the identity locally. Erasing it first
    /// would leave the token live on bromure.io with nothing left to retry the
    /// revoke with (CWE-613). On failure the identity is kept, `error` says
    /// why, and the user can try again. Returns whether it signed out.
    /// `beforeErase` runs once the revoke is done, before the identity is
    /// forgotten (the log-out panel unenrolls there, so the identity doesn't
    /// fall back to that enrollment's).
    ///
    /// A credential bromure.io refuses for good (`.refused`) is NOT a
    /// confirmed revoke: its 401 is the same for a revoked device and for a
    /// token that merely expired, with the device and its SSH key still live
    /// (CWE-613). The first such sign-out explains and keeps the identity; the
    /// next one (or one after `noteCredentialRefused`) forgets it on this Mac
    /// only, saying the device may still be listed on bromure.io.
    @discardableResult
    func signOutRevoking(beforeErase: (() async -> Void)? = nil) async -> Bool {
        guard !isEnterprise, !busy else { return false }
        var localOnly = false
        if let (client, bearer) = ControlPlaneClient.current() {
            busy = true; error = nil
            // Decided now, not when bromure.io answers: the explanation must
            // have been shown before this sign-out was asked for. A refusal
            // noted while it's in flight (the directory, the device channel)
            // isn't one the user has seen yet (CWE-362).
            let warned = refusalShownFor == AcceptedCredential.fingerprint(bearer)
            var record: DeviceRecord?
            if case .found(let r) = DeviceIdentityStore.load() { record = r }
            let final = AcceptedCredential.refusalIsFinal(bearer: bearer, record: record)
            let outcome = await Self.revokeForSignOut(final: final) {
                try await client.selfRevoke(bearer: bearer)
            }
            busy = false
            switch outcome {
            case .done:
                break
            case .failed(let failure):
                error = failure
                return false
            case .refused:
                guard warned else {
                    refusalShownFor = AcceptedCredential.fingerprint(bearer)
                    error = Self.refusedMessage
                    return false
                }
                localOnly = true
            }
        }
        await beforeErase?()
        signOut()
        if localOnly {
            error = "Signed out on this device only. If bromure.io still lists it under your devices, revoke it there."
        }
        return true
    }

    static let refusedMessage = "bromure.io no longer accepts this device’s credentials — they expired, or the device was revoked, and bromure.io doesn’t say which, so this device may still be registered there. Sign Out again to forget it on this device only, and if it is still listed under your devices on bromure.io, revoke it there."

    /// Something other than sign-out (the directory) found bromure.io
    /// refusing `bearer` for good and explained it (`directoryRefusedMessage`):
    /// the next sign-out may forget the identity locally without asking again.
    func noteCredentialRefused(bearer: String) {
        refusalShownFor = AcceptedCredential.fingerprint(bearer)
    }

    static let directoryRefusedMessage = "bromure.io no longer accepts this device’s credentials — they expired, or the device was revoked, and bromure.io doesn’t say which. Sign Out to forget it on this device, and if it is still listed under your devices on bromure.io, revoke it there."


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
    /// apart, as the directory's first load does), then reported. Erasing the
    /// identity then would lose the only bearer that can revoke a device that
    /// is still live, SSH key included.
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

    /// Forget the identity locally. The user's sign-out goes through
    /// `signOutRevoking()`, which decides when that is safe.
    func signOut() {
        guard !isEnterprise else { return }
        refusalShownFor = nil
        DeviceIdentityStore.erase()
        AcceptedCredential.forget()
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
