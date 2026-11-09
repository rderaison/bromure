import Foundation

/// Pages a workspace's guest opened, for the user's own clients (linux-port:
/// a macOS server opens them on its own screen, a Linux server has none).
/// Published in /state as `guestLinks`, per workspace, until a client marks
/// one handled (`POST /guest-links/<id>/done`) or it expires: at most
/// `maxPerWorkspace` a workspace (the oldest dropped), a URL already waiting
/// not added twice, each kept `ttl`. A page on a local or private host never
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

    /// A page the guest of `profileID` opened; false when it isn't kept
    /// (refused, or already waiting).
    // @port-skip linux-only: see GuestLinkRelay
    @discardableResult
    func add(_ url: URL, profileID: UUID, workspace: String, now: Date = Date()) -> Bool {
        prune(now)
        guard GuestURLGate.disposition(for: url) != .refuse else { return false }
        let s = url.absoluteString
        guard s.utf8.count <= 8 << 10, !links.contains(where: { $0.profileID == profileID && $0.url == s }) else { return false }
        links.append(Link(id: UUID(), profileID: profileID, workspace: workspace, url: s, at: now))
        let mine = links.filter { $0.profileID == profileID }
        if mine.count > Self.maxPerWorkspace, let oldest = mine.first { links.removeAll { $0.id == oldest.id } }
        StateGeneration.noteMutation()
        return true
    }

    /// A link a client handled (opened, or the user declined it).
    // @port-skip linux-only: see GuestLinkRelay
    func done(_ id: UUID) -> Bool {
        let before = links.count
        links.removeAll { $0.id == id }
        return links.count < before
    }

    /// A workspace's links go with it (its VM stopped or removed).
    // @port-skip linux-only: see GuestLinkRelay
    func clear(_ profileID: UUID) {
        guard links.contains(where: { $0.profileID == profileID }) else { return }
        links.removeAll { $0.profileID == profileID }
        StateGeneration.noteMutation()
    }

    // @port-skip linux-only: see GuestLinkRelay
    func prune(_ now: Date = Date()) { links.removeAll { now.timeIntervalSince($0.at) > Self.ttl } }

    /// `/state`'s `guestLinks`.
    // @port-skip linux-only: see GuestLinkRelay
    func stateEntries(_ now: Date = Date()) -> [String: JSONValue] {
        prune(now)
        return ["guestLinks": .array(links.map {
            .object(["id": .string($0.id.uuidString), "profileID": .string($0.profileID.uuidString),
                     "workspace": .string($0.workspace), "url": .string($0.url)])
        })]
    }
}
