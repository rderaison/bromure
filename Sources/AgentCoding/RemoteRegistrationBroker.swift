import Foundation

/// A registration started by a REMOTE client (the macOS fat client). The
/// throwaway VM and the credential store live here on the host, but the human
/// is at the other end of the tunnel — so instead of opening the provider's
/// sign-in page in this Mac's browser, we publish it for the client to open in
/// ITS browser. The OAuth callback comes back through the client's existing
/// `forward <ip> <port>` tunnel, which already reaches a guest's loopback via
/// the vsock relay on port 5010 (the same path LoopbackCallbackForwarder uses
/// locally), so no new SSH verb is needed.
@MainActor
final class RemoteRegistrationBroker {
    static let shared = RemoteRegistrationBroker()

    struct Pending {
        /// Names this run, so a client can tell its own end from another's.
        let id = UUID()
        let provider: String
        /// The provider's sign-in URL, for the client's browser.
        var url: String?
        /// The throwaway VM's guest IP + the loopback port its CLI is waiting
        /// on. The client needs both to point its local listener at the VM.
        var vmIP: String?
        var callbackPort: Int?
        /// Set when the flow finished (captured or cancelled) so the client
        /// can tear its listener down.
        var finished = false
    }

    private(set) var pending: Pending?

    /// How the last run ended, kept a while after `pending` is gone: the
    /// client polls, and a run refused within a poll would otherwise just
    /// vanish from /state with no reason given.
    struct Ended: Equatable {
        let id: UUID
        let success: Bool
        let message: String?
        let at: Date
    }
    /// The recent ends, oldest first: one slot let the next run's end
    /// overwrite one a client hadn't read yet (asleep, link down).
    private(set) var endedRuns: [Ended] = []
    var ended: Ended? { endedRuns.last }
    /// Longer than a fat client's whole wait for a run
    /// (`RemoteHostController.registrationWaitBudget`).
    static let endedKeptFor: TimeInterval = 15 * 60
    static let endedKeptMax = 16

    @discardableResult
    func begin(provider: String) -> UUID {
        let p = Pending(provider: provider)
        pending = p
        return p.id
    }
    func publish(url: String, callbackPort: Int) {
        pending?.url = url
        pending?.callbackPort = callbackPort
    }
    func publish(vmIP: String) { pending?.vmIP = vmIP }
    func finish(success: Bool = false, message: String? = nil, now: Date = Date()) {
        if let p = pending {
            endedRuns.removeAll { now.timeIntervalSince($0.at) >= Self.endedKeptFor }
            endedRuns.append(Ended(id: p.id, success: success, message: message, at: now))
            if endedRuns.count > Self.endedKeptMax { endedRuns.removeFirst(endedRuns.count - Self.endedKeptMax) }
        }
        pending = nil
    }

    /// `/state` payload — nil until a remote registration is in flight.
    func stateDict() -> [String: Any]? {
        guard let p = pending else { return nil }
        var d: [String: Any] = ["id": p.id.uuidString, "provider": p.provider]
        if let u = p.url { d["url"] = u }
        if let ip = p.vmIP { d["vmIP"] = ip }
        if let port = p.callbackPort { d["callbackPort"] = port }
        return d
    }

    /// `/state`'s `registrationEnded`: the last run's outcome, for a while.
    func endedDict(now: Date = Date()) -> [String: Any]? {
        guard let e = ended, now.timeIntervalSince(e.at) < Self.endedKeptFor else { return nil }
        return Self.dict(e)
    }

    /// `/state`'s `registrationsEnded`: every recent run's outcome, so a
    /// client that missed a few polls still finds its own.
    func endedList(now: Date = Date()) -> [[String: Any]] {
        endedRuns.filter { now.timeIntervalSince($0.at) < Self.endedKeptFor }.map(Self.dict)
    }

    private static func dict(_ e: Ended) -> [String: Any] {
        var d: [String: Any] = ["id": e.id.uuidString, "success": e.success]
        if let m = e.message { d["message"] = m }
        return d
    }
}
