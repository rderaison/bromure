import CryptoKit
import Foundation

/// Every saved version of a workspace's OpenShell policy, like OpenShell's
/// gateway revision store: saving an identical policy keeps the current
/// version; any change appends a numbered revision with its hash, time and
/// source. Kept next to the workspace (`policy-history.json`).
public final class PolicyHistory: @unchecked Sendable {
    public static let shared = PolicyHistory()
    /// How many revisions a workspace keeps (the oldest are dropped; version
    /// numbers keep counting).
    static let cap = 200
    static let fileName = "policy-history.json"

    public struct Revision: Codable, Equatable, Sendable {
        public let version: Int
        /// sha256 of the policy text, hex.
        public let hash: String
        public let savedAt: Date
        /// Who saved it: `user` (the editor), `advisor` (an approved
        /// proposal), `api` (the control socket / CLI), or `restore`.
        public let source: String
        public let policy: String
    }

    private let lock = NSLock()

    public static func hash(_ policy: String) -> String {
        SHA256.hash(data: Data(policy.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func revisions(in directory: URL) -> [Revision] {
        lock.lock(); defer { lock.unlock() }
        return load(directory)
    }

    /// Record `policy` as the workspace's current version. Returns the
    /// revision that is now current (a new one, or the unchanged latest).
    @discardableResult
    public func record(policy: String, source: String, in directory: URL, now: Date = Date()) -> Revision {
        lock.lock(); defer { lock.unlock() }
        var all = load(directory)
        let h = Self.hash(policy)
        if let last = all.last, last.hash == h { return last }
        let rev = Revision(version: (all.last?.version ?? 0) + 1, hash: h, savedAt: now, source: source, policy: policy)
        all.append(rev)
        if all.count > Self.cap { all.removeFirst(all.count - Self.cap) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(all) {
            try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
        }
        return rev
    }

    private func load(_ directory: URL) -> [Revision] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.fileName)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Revision].self, from: data)) ?? []
    }
}
