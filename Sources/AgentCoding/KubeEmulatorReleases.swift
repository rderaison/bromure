import Foundation

/// Which release of each floci emulator a cluster gets: the newest one on
/// Docker Hub when the cluster is set up, so bromure pins nothing itself.
/// The owner can pin a version per cluster instead
/// (`KubeClusterSpec.emulatorVersions`); when the lookup fails (offline,
/// rate-limited) the engine falls back to the `latest` tag.
@MainActor
enum KubeEmulatorReleases {
    /// Answers remembered for an hour: a retry after a failed provisioning
    /// shouldn't hit Docker Hub again.
    private static var cache: [KubeCloudEmulator: (tag: String, at: Date)] = [:]

    /// The newest release tag ("2.1.0") of the emulator's image on Docker
    /// Hub, nil when the lookup fails.
    static func latestTag(for kind: KubeCloudEmulator) async -> String? {
        if let hit = cache[kind], Date().timeIntervalSince(hit.at) < 3600 { return hit.tag }
        // Newest pushes first; nightlies are pushed daily, releases every
        // couple of weeks, so two pages of a hundred cover months.
        var url = URL(string: "https://hub.docker.com/v2/repositories/\(kind.repository)/tags?page_size=100&ordering=last_updated")
        var tags: [String] = []
        for _ in 0..<2 {
            guard let u = url else { break }
            var req = URLRequest(url: u, timeoutInterval: 15)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            tags += ((obj["results"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            url = (obj["next"] as? String).flatMap { URL(string: $0) }
        }
        guard let tag = latestRelease(among: tags) else { return nil }
        cache[kind] = (tag, Date())
        return tag
    }

    /// The highest plain release among `tags` — "2.1.0" beats "2.0.9" and
    /// "2.10.0" beats "2.9.0"; "latest", nightlies, "-compat" variants and
    /// pre-releases don't count. Returned as tagged (a leading "v" kept).
    nonisolated static func latestRelease(among tags: [String]) -> String? {
        func parts(_ tag: String) -> [Int]? {
            let body = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let p = body.split(separator: ".", omittingEmptySubsequences: false)
            guard p.count == 3 else { return nil }
            var out: [Int] = []
            for s in p {
                guard !s.isEmpty, s.allSatisfy(\.isNumber), let n = Int(s) else { return nil }
                out.append(n)
            }
            return out
        }
        return tags.compactMap { t in parts(t).map { (t, $0) } }
            .max { $0.1.lexicographicallyPrecedes($1.1) }?.0
    }
}
