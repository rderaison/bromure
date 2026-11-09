import Foundation

/// Pages a workspace's guest opened, for the user's own clients (linux-port:
/// a macOS server opens them on its own screen, a Linux server has none).
/// Published in /state as `guestLinks`, per workspace, until a client marks
/// one handled (`POST /guest-links/<id>/done`) or it expires: at most
/// `maxPerWorkspace` a workspace (the oldest dropped), a URL already waiting
/// not added twice nor again within a minute of being handled, one new link
/// a workspace every 2 s, each kept `ttl`. A page on a local or private host never
/// gets here (GuestURLGate refuses it); the client applies the same
/// disposition again before opening anything. The daemon serves its own
/// user only, so only that user's clients see them.
// @port-skip linux-only: the guest-link relay to a server's clients (no macOS counterpart: a Mac opens them itself)
@MainActor
final class GuestLinkRelay {
    static let shared = GuestLinkRelay()
    static let maxPerWorkspace = 8
    static let ttl: TimeInterval = 300

    struct Link: Equatable {
        let id: UUID
        let profileID: UUID
        let workspace: String
        let url: String
        let at: Date
    }
    private(set) var links: [Link] = []
    /// Links clients handled, recently (`maxDone`, `ttl`): published as
    /// `guestLinksDone`, so a client takes down its sheet for one only when
    /// it was handled, never because it was evicted or expired.
    private(set) var handled: [(id: UUID, profileID: UUID, url: String, at: Date)] = []
    /// When each workspace last had a link added (one every `addInterval`).
    private var lastAdded: [UUID: Date] = [:]
    static let maxDone = 32
    /// A URL just handled isn't relayed again for this long.
    static let doneCooldown: TimeInterval = 60
    static let addInterval: TimeInterval = 2

    /// A page the guest of `profileID` opened; false when it isn't kept
    /// (refused, already waiting, handled within `doneCooldown`, or the
    /// workspace's last link came under `addInterval` ago).
    // @port-skip linux-only: see GuestLinkRelay
    @discardableResult
    func add(_ url: URL, profileID: UUID, workspace: String, now: Date = Date()) -> Bool {
        prune(now)
        guard GuestURLGate.disposition(for: url) != .refuse else { return false }
        let s = url.absoluteString
        guard s.utf8.count <= 8 << 10, !links.contains(where: { $0.profileID == profileID && $0.url == s }),
              !handled.contains(where: { $0.profileID == profileID && $0.url == s && now.timeIntervalSince($0.at) < Self.doneCooldown }),
              lastAdded[profileID].map({ now.timeIntervalSince($0) >= Self.addInterval }) ?? true else { return false }
        lastAdded[profileID] = now
        links.append(Link(id: UUID(), profileID: profileID, workspace: workspace, url: s, at: now))
        let mine = links.filter { $0.profileID == profileID }
        if mine.count > Self.maxPerWorkspace, let oldest = mine.first { links.removeAll { $0.id == oldest.id } }
        StateGeneration.noteMutation()
        return true
    }

    /// A link a client handled (opened, or the user declined it).
    // @port-skip linux-only: see GuestLinkRelay
    func done(_ id: UUID, now: Date = Date()) -> Bool {
        guard let link = links.first(where: { $0.id == id }) else { return false }
        links.removeAll { $0.id == id }
        handled.append((id, link.profileID, link.url, now))
        if handled.count > Self.maxDone { handled.removeFirst(handled.count - Self.maxDone) }
        StateGeneration.noteMutation()
        return true
    }

    /// A workspace's links go with it (its VM stopped or removed).
    // @port-skip linux-only: see GuestLinkRelay
    func clear(_ profileID: UUID) {
        lastAdded[profileID] = nil
        guard links.contains(where: { $0.profileID == profileID }) else { return }
        links.removeAll { $0.profileID == profileID }
        StateGeneration.noteMutation()
    }

    // @port-skip linux-only: see GuestLinkRelay
    func prune(_ now: Date = Date()) {
        let before = links.count
        links.removeAll { now.timeIntervalSince($0.at) > Self.ttl }
        handled.removeAll { now.timeIntervalSince($0.at) > Self.ttl }
        if links.count < before { StateGeneration.noteMutation() }
    }

    /// `/state`'s `guestLinks`, and `guestLinksDone`: the ids handled lately.
    // @port-skip linux-only: see GuestLinkRelay
    func stateEntries(_ now: Date = Date()) -> [String: JSONValue] {
        prune(now)
        return ["guestLinks": .array(links.map {
            .object(["id": .string($0.id.uuidString), "profileID": .string($0.profileID.uuidString),
                     "workspace": .string($0.workspace), "url": .string($0.url)])
        }), "guestLinksDone": .array(handled.map { .string($0.id.uuidString) })]
    }
}
