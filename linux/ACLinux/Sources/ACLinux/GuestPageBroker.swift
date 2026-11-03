import Foundation

/// Pages the guests open (bromure-open, xdg-open) on a Linux server, which
/// has no browser: published in /state (`guestPages`) for a fat client to
/// open in its own (macOS opens them in the Mac's, ACAppDelegate's
/// openGuestRelayedURL). GuestURLGate decides as on macOS: a local/private
/// host is never published; a page that may reach the client's network is
/// published as `ask` (the client asks before opening it). Kept a while, a
/// few at most; a client dismisses the one it handled.
// @port-skip linux-only: the server half of a guest-page relay to the fat client (macOS opens pages on its own screen)
@MainActor
final class GuestPageBroker {
    static let shared = GuestPageBroker()
    static let keptFor: TimeInterval = 10 * 60
    static let keptMax = 8

    struct Page: Equatable {
        let id = UUID()
        let profileID: UUID
        let workspace: String
        let url: URL
        let ask: Bool
        let at: Date
    }
    private(set) var pages: [Page] = []

    /// A page the guest opened; nil when it was refused (local/private host).
    // @port-skip linux-only: guest-page relay
    @discardableResult
    func publish(_ url: URL, profileID: UUID, workspace: String, now: Date = Date()) -> Page? {
        let ask: Bool
        switch GuestURLGate.disposition(for: url) {
        case .refuse:
            FileHandle.standardError.write(Data("bromure-ac daemon: refused to publish a guest page with a local/private host: \(url.host ?? "?")\n".utf8))
            return nil
        case .open: ask = false
        case .ask: ask = true
        }
        prune(now)
        let p = Page(profileID: profileID, workspace: workspace, url: url, ask: ask, at: now)
        pages.append(p)
        if pages.count > Self.keptMax { pages.removeFirst(pages.count - Self.keptMax) }
        return p
    }

    /// A client handled (or declined) the page: it's no longer offered.
    // @port-skip linux-only: guest-page relay
    func dismiss(_ id: UUID) -> Bool {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return false }
        pages.remove(at: i)
        return true
    }

    // @port-skip linux-only: guest-page relay
    private func prune(_ now: Date) {
        pages.removeAll { now.timeIntervalSince($0.at) >= Self.keptFor }
    }

    /// `/state`'s `guestPages`, oldest first.
    // @port-skip linux-only: guest-page relay
    func stateList(now: Date = Date()) -> [JSONValue] {
        prune(now)
        let iso = ISO8601DateFormatter()
        return pages.map { p in
            .object([
                "id": .string(p.id.uuidString), "profile": .string(p.profileID.uuidString),
                "workspace": .string(p.workspace), "url": .string(p.url.absoluteString),
                "disposition": .string(p.ask ? "ask" : "open"), "at": .string(iso.string(from: p.at)),
            ])
        }
    }
}

extension Daemon {
    /// `POST /guest-pages/<id>/dismiss {action: opened|declined|ignored}`:
    /// a client handled the page; the first dismiss wins, a later one is 404.
    // @port-skip linux-only: the guest-page relay's dismiss
    func dismissGuestPage(_ raw: String, _ body: JSONValue) async -> ControlResponse {
        guard let id = UUID(uuidString: raw.removingPercentEncoding ?? raw) else { return .error(400, "Bad page id") }
        let action = body["action"]?.stringValue ?? "opened"
        let ok = await MainActor.run { GuestPageBroker.shared.dismiss(id) }
        guard ok else { return .error(404, "No such page") }
        FileHandle.standardError.write(Data("bromure-ac daemon: guest page \(id.uuidString.prefix(8)) \(action) by the client\n".utf8))
        return ControlResponse(200, ["ok": true])
    }
}
