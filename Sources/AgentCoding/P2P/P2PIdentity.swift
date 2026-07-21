import Foundation

/// The control-plane identity the P2P layer authenticates with. It comes from
/// EITHER of two enrollments, so an already-enrolled install is never asked to
/// enroll again:
///
///  - `.device` — a browser-enrolled P2P device record (individual accounts).
///  - `.enterprise` — the existing managed enrollment (`BACEnrollment`). An
///    enterprise install already holds an `installs` row + bearer token + the
///    enrolling user's id on bromure.io, and the control plane accepts that
///    bearer on the P2P endpoints unchanged — so it reuses that identity rather
///    than minting a second one.
///
/// Client capability is implicit in either enrollment (any agentic-coding
/// install may dial). Being a *server* is separate — gated by Remote Access via
/// `P2PBroker`/`server-mode` — so one install can be both.
struct P2PIdentity: Equatable {
    enum Source: Equatable { case device, enterprise }

    let apiBase: String
    let bearer: String
    let installId: String
    /// The enrolling user (present for enterprise; the control plane scopes the
    /// server directory to it). Nil for a browser-enrolled device — the server
    /// derives the user from the token there.
    let userId: String?
    let orgSlug: String?
    let orgKind: String?
    let source: Source

    /// Per-session telemetry is organization-only; personal accounts record
    /// nothing. An enterprise (managed) enrollment is inherently an org.
    var recordsSessionTelemetry: Bool { orgKind == "organization" }

    /// Resolve the current identity. A browser-enrolled P2P device wins; else
    /// the enterprise managed enrollment; else nil (not enrolled at all).
    ///
    /// A transient keychain failure on the device record returns nil rather
    /// than falling back to the enterprise identity — the two are different
    /// installs and must never be confused (same discipline as
    /// `FatClientKeyStore`).
    static func current() -> P2PIdentity? {
        switch DeviceIdentityStore.load() {
        case .found(let rec):
            return P2PIdentity(apiBase: rec.apiBase, bearer: rec.deviceToken,
                               installId: rec.deviceId, userId: nil,
                               orgSlug: rec.orgSlug, orgKind: rec.orgKind, source: .device)
        case .unavailable:
            return nil
        case .notEnrolled:
            break
        }
        if let inst = BACEnrollmentStore.load(), let token = BACEnrollmentStore.loadInstallToken() {
            return P2PIdentity(apiBase: inst.serverURL.absoluteString, bearer: token,
                               installId: inst.installId, userId: inst.userId,
                               orgSlug: inst.orgSlug, orgKind: "organization", source: .enterprise)
        }
        return nil
    }
}
