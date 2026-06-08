import Foundation

/// In-memory `(ecosystem, package, version) → publishedAt` cache.
/// Populated as a side-effect of `*Transforms.filterMetadata()` —
/// every per-version timestamp the proxy sees in a registry's
/// metadata response gets pinned here so the artifact-fetch backstop
/// can look it up without re-fetching metadata.
///
/// Caches are bounded by entry count rather than TTL — registry
/// timestamps are immutable so there's no staleness to chase.
/// The bound exists only to keep memory from growing unboundedly
/// across a long session.
public actor PublishTimeCache {
    private struct Key: Hashable {
        let ecosystem: String
        let name: String
        let version: String
    }

    private var entries: [Key: Date] = [:]
    private static let maxEntries = 50_000

    public init() {}

    public func record(ecosystem: String, name: String,
                       versions: [(version: String, publishedAt: Date)]) {
        let lowerName = name.lowercased()
        for (version, time) in versions {
            entries[Key(ecosystem: ecosystem, name: lowerName, version: version)] = time
        }
        // Simple cap — drop arbitrary entries if we sail over the limit.
        // Real LRU is overkill here; the metadata is cheap to refetch.
        if entries.count > Self.maxEntries {
            let toDrop = entries.count - Self.maxEntries
            for key in entries.keys.prefix(toDrop) {
                entries.removeValue(forKey: key)
            }
        }
    }

    public func publishedAt(ecosystem: String, name: String,
                            version: String) -> Date? {
        entries[Key(ecosystem: ecosystem,
                    name: name.lowercased(),
                    version: version)]
    }
}
