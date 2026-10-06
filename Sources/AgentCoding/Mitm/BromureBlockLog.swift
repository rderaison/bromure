import Foundation

/// The proxy's own record of the requests it refused with a 451, per
/// workspace — so the chat can name the block even when the agent's error
/// text doesn't. Grok reports only the canonical status line ("API error
/// (status 451 Unavailable For Legal Reasons): Request failed (HTTP…") — not
/// the reason phrase or body Bromure wrote — and its error card read
/// "Blocked by Bromure · API error…" instead of "Blocked by Bromure — prompt
/// injection". A 451 from an agent's AI host is only ever Bromure's.
/// Memory only: a restart forgets (an older error then reads "Blocked by
/// Bromure", still right).
final class BromureBlockLog: @unchecked Sendable {
    static let shared = BromureBlockLog()

    struct Entry: Equatable { let time: Date; let kind: BromureBlock }

    private let lock = NSLock()
    private var entries: [UUID: [Entry]] = [:]
    private static let perWorkspace = 64

    func record(_ kind: BromureBlock, profileID: UUID, at time: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var list = entries[profileID, default: []]
        list.append(Entry(time: time, kind: kind))
        if list.count > Self.perWorkspace { list.removeFirst(list.count - Self.perWorkspace) }
        entries[profileID] = list
    }

    /// The block behind an error at `time` (the nearest within two minutes),
    /// or — when the agent recorded no time — the workspace's latest within
    /// the last half hour.
    func kind(profileID: UUID, near time: Date?, now: Date = Date()) -> BromureBlock? {
        let list: [Entry] = { lock.lock(); defer { lock.unlock() }; return entries[profileID] ?? [] }()
        if let time {
            return list.filter { abs($0.time.timeIntervalSince(time)) <= 120 }
                .min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }?.kind
        }
        return list.last { now.timeIntervalSince($0.time) <= 30 * 60 }?.kind
    }

    func reset(profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries[profileID] = nil
    }

    /// Bromure's own words for a block, as `BromureBlock.of` reads them.
    static func marker(_ kind: BromureBlock) -> String? {
        switch kind {
        case .promptInjection: "Bromure blocked: possible prompt injection"
        case .rulesInjection: "Bromure blocked: possible rogue instructions"
        case .credentialLeak: "Bromure: outbound request blocked — leaked credential to non-designated host"
        case .supplyChain: "Bromure supply-chain security blocked this request"
        case .clientCertificate: "Bromure: client-certificate use denied"
        case .unknown: nil
        }
    }

    /// `items` with each Bromure-blocked error whose text doesn't say which
    /// engine (a bare 451) completed from this workspace's record.
    func annotate(_ items: [TranscriptItem], profileID: UUID?) -> [TranscriptItem] {
        guard let profileID else { return items }
        var out = items
        for (i, item) in items.enumerated() {
            guard case .agentError(let e) = item.kind, e.kind == .blocked,
                  BromureBlock.of(e.message) == nil,
                  let kind = kind(profileID: profileID, near: item.timestamp),
                  let marker = Self.marker(kind) else { continue }
            let message = e.message.isEmpty ? marker : e.message + "\n" + marker
            out[i] = TranscriptItem(id: item.id, kind: .agentError(AgentAPIError(kind: e.kind, status: e.status, message: message)),
                                    timestamp: item.timestamp)
        }
        return out
    }
}
