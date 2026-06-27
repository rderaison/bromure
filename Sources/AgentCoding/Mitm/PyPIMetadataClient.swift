import Foundation

/// On-demand lookup of a PyPI release's publish time, used as the
/// artifact-fetch age-gate backstop for pip.
///
/// The metadata transforms populate `PublishTimeCache` as a side
/// effect of rewriting a registry's package listing — but pip's
/// default path is the PEP 503 *HTML* simple index, which carries no
/// timestamps, and an agent can also replay a version list it cached
/// before the proxy was in the loop. In both cases the cache misses
/// at artifact-fetch time, so the backstop has nothing to enforce on.
///
/// This client closes that hole: given `(package, version)` it fetches
/// `https://pypi.org/pypi/<pkg>/<version>/json` (the per-release JSON,
/// which always carries `upload_time_iso_8601` on every file) and
/// returns the earliest upload time across the release's files. Results
/// — including "not found" — are memoised so a fan-out `pip install`
/// hits the network at most once per `(pkg, version)`.
public actor PyPIMetadataClient {
    public static let shared = PyPIMetadataClient()

    private struct Key: Hashable { let name: String; let version: String }
    // `.some(nil)` caches a definitive "no publish time" so we don't
    // re-hit the network for the same release on every file fetch.
    private var cache: [Key: Date?] = [:]
    private static let maxEntries = 20_000

    // Self-throttle parallel lookups the same way OSVClient does, so a
    // big install graph doesn't fan out hundreds of concurrent GETs.
    private static let maxParallel = 16
    private static let maxRetries = 3
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
    }

    private func acquireSlot() async {
        while inFlight >= Self.maxParallel {
            await withCheckedContinuation { c in waiters.append(c) }
        }
        inFlight += 1
    }

    private func releaseSlot() {
        inFlight -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// Earliest `upload_time` across `package@version`'s files, or nil
    /// when PyPI has no such release / the lookup fails (fail-open: a
    /// network miss must not wedge installs).
    public func publishTime(package: String, version: String) async -> Date? {
        let key = Key(name: package.lowercased(), version: version)
        if let cached = cache[key] { return cached }

        let pkgEnc = package.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? package
        let verEnc = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? version
        guard let url = URL(string: "https://pypi.org/pypi/\(pkgEnc)/\(verEnc)/json") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("bromure-ac/2.0", forHTTPHeaderField: "User-Agent")

        await acquireSlot()
        defer { releaseSlot() }
        // Another waiter may have populated the cache while we queued.
        if let cached = cache[key] { return cached }

        // `gotResponse` distinguishes a definitive HTTP outcome (200 /
        // 404 / etc.) from a pure network failure. We only memoise the
        // former — caching a transient timeout as a permanent "no
        // publish time" would fail-open the age gate for the rest of
        // the session.
        var data: Data?
        var gotResponse = false
        for attempt in 1...Self.maxRetries {
            do {
                let (d, resp) = try await session.data(for: req)
                gotResponse = true
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { data = d }
                // 404 / other → definitive miss, don't retry.
                break
            } catch {
                let retriable = (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                     .dnsLookupFailed].contains($0.code)
                } ?? false
                if !retriable || attempt == Self.maxRetries { break }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
            }
        }

        let result = data.flatMap { Self.earliestUploadTime(in: $0) }
        if gotResponse { store(key, result) }
        if result == nil {
            SupplyChainLog.shared.record(
                "[pypi-meta] no publish time for \(package)@\(version) "
                + (gotResponse ? "(lookup miss)" : "(network error, uncached)"))
        }
        return result
    }

    private func store(_ key: Key, _ value: Date?) {
        cache[key] = .some(value)
        if cache.count > Self.maxEntries {
            for k in cache.keys.prefix(cache.count - Self.maxEntries) {
                cache.removeValue(forKey: k)
            }
        }
    }

    /// Parse the earliest `upload_time_iso_8601` (fallback
    /// `upload_time`) across the `urls` array of a PyPI per-release
    /// JSON payload.
    static func earliestUploadTime(in body: Data) -> Date? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let urls = json["urls"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]
        var earliest: Date?
        for f in urls {
            guard let t = f["upload_time_iso_8601"] as? String
                    ?? f["upload_time"] as? String,
                  let d = iso.date(from: t) ?? isoNoFraction.date(from: t) else { continue }
            if earliest == nil || d < earliest! { earliest = d }
        }
        return earliest
    }
}
