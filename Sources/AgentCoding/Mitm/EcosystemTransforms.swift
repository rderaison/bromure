import Foundation

/// Per-ecosystem age-gate metadata transforms. The npm path lives in
/// `NPMRegistryTransforms.swift` and does an additional tarball
/// rewrite; the ecosystems here only need the metadata filter
/// (timestamps live in their metadata responses, no tarball
/// rewriting is in scope — sdist setup.py / Maven `<exec>` /
/// arbitrary code execution at install is best handled by other
/// layers, not by us mucking with content-addressable artifacts).
///
/// Each `filter*Metadata` function:
///   - parses the upstream HTTP response,
///   - records every (version, publishedAt) pair into the shared
///     `PublishTimeCache` (used by the tarball backstop),
///   - drops versions younger than the cutoff and rewrites any
///     `latest`-style fields,
///   - re-serialises and rebuilds the HTTP response with a fresh
///     `Content-Length`.
///
/// Each returns the original response untouched if the policy
/// can't be applied (parse failure, allowlisted package, no
/// per-version timestamps in this particular response shape).
public enum EcosystemTransforms {

    // MARK: - PyPI JSON API (`/pypi/<pkg>/json`)

    /// PyPI's JSON metadata: `{"info":{"version":"1.2.3", ...},
    /// "releases": {"1.2.3": [{"upload_time":"...","filename":"...",
    /// "url":"..."}], ...}}`.
    ///
    /// We drop too-fresh release keys + their file lists, then
    /// recompute `info.version` to be the newest remaining release
    /// (matches pip's "give me the latest" resolution).
    public static func filterPyPIJSON(rawResponse: Data,
                                       packageName: String,
                                       allowedAfter cutoff: Date,
                                       allowlistedPackage: Bool,
                                       publishTimeCache: PublishTimeCache?) async -> Data {
        guard let parts = splitHTTPResponse(rawResponse) else { return rawResponse }
        let (head, body) = parts
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return rawResponse
        }
        var manifest = json

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]

        var versionPubTimes: [(String, Date)] = []

        if var releases = manifest["releases"] as? [String: Any] {
            var dropped: Set<String> = []
            for (version, fileArr) in releases {
                // Each version maps to an array of file dicts. The
                // earliest upload_time wins as the "publish time"
                // for this version.
                guard let files = fileArr as? [[String: Any]] else { continue }
                var earliest: Date?
                for f in files {
                    guard let t = f["upload_time"] as? String
                            ?? f["upload_time_iso_8601"] as? String else { continue }
                    let parsed = iso.date(from: t) ?? isoNoFraction.date(from: t)
                    if let d = parsed {
                        if earliest == nil || d < earliest! { earliest = d }
                    }
                }
                if let d = earliest {
                    versionPubTimes.append((version, d))
                    if !allowlistedPackage && d > cutoff {
                        dropped.insert(version)
                    }
                }
            }
            for v in dropped { releases.removeValue(forKey: v) }
            manifest["releases"] = releases

            if !dropped.isEmpty, var info = manifest["info"] as? [String: Any] {
                // Rewrite `info.version` to newest remaining release.
                let remaining = releases.keys.sorted(by: compareSemverLoose)
                if let newest = remaining.last {
                    info["version"] = newest
                }
                manifest["info"] = info
                // urls{} represents the current `info.version`'s
                // file list — drop it; pip can re-fetch the right
                // one via the metadata for the version it picks.
                manifest.removeValue(forKey: "urls")
            }
        }

        if let cache = publishTimeCache, !versionPubTimes.isEmpty {
            await cache.record(ecosystem: "pypi", name: packageName,
                               versions: versionPubTimes)
        }

        guard let newBody = try? JSONSerialization.data(withJSONObject: manifest,
                                                        options: [.sortedKeys]) else {
            return rawResponse
        }
        return rebuildHTTPResponse(originalHead: head, newBody: newBody)
    }

    // MARK: - Cargo (crates.io API)

    /// `https://crates.io/api/v1/crates/<crate>` returns
    /// `{"crate": {...}, "versions": [{"num":"1.0.0","created_at":"...","yanked":false, ...}, ...]}`.
    /// We drop too-fresh entries from `versions` and `crate.max_stable_version`
    /// gets re-aimed at the newest remaining `num`.
    public static func filterCargoAPI(rawResponse: Data,
                                       packageName: String,
                                       allowedAfter cutoff: Date,
                                       allowlistedPackage: Bool,
                                       publishTimeCache: PublishTimeCache?) async -> Data {
        guard let parts = splitHTTPResponse(rawResponse) else { return rawResponse }
        let (head, body) = parts
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return rawResponse
        }
        var manifest = json

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]

        var versionPubTimes: [(String, Date)] = []
        var keptVersions: [[String: Any]] = []
        if let versions = manifest["versions"] as? [[String: Any]] {
            for entry in versions {
                let num = (entry["num"] as? String) ?? ""
                guard !num.isEmpty else { keptVersions.append(entry); continue }
                let timeStr = (entry["created_at"] as? String) ?? ""
                let parsed = iso.date(from: timeStr) ?? isoNoFraction.date(from: timeStr)
                if let d = parsed {
                    versionPubTimes.append((num, d))
                    if !allowlistedPackage && d > cutoff { continue }
                }
                keptVersions.append(entry)
            }
            manifest["versions"] = keptVersions
        }

        if var crate = manifest["crate"] as? [String: Any] {
            let nums = keptVersions.compactMap { $0["num"] as? String }
            let newest = nums.max(by: compareSemverLoose) ?? ""
            // Rewrite both common "newest" fields if present.
            if crate["max_version"] is String, !newest.isEmpty {
                crate["max_version"] = newest
            }
            if crate["max_stable_version"] is String, !newest.isEmpty {
                crate["max_stable_version"] = newest
            }
            if crate["newest_version"] is String, !newest.isEmpty {
                crate["newest_version"] = newest
            }
            manifest["crate"] = crate
        }

        if let cache = publishTimeCache, !versionPubTimes.isEmpty {
            await cache.record(ecosystem: "cargo", name: packageName,
                               versions: versionPubTimes)
        }

        guard let newBody = try? JSONSerialization.data(withJSONObject: manifest,
                                                        options: [.sortedKeys]) else {
            return rawResponse
        }
        return rebuildHTTPResponse(originalHead: head, newBody: newBody)
    }

    // MARK: - RubyGems

    /// `https://rubygems.org/api/v1/versions/<pkg>.json` returns
    /// `[{"number":"1.0.0","created_at":"...","prerelease":false, ...}, ...]`.
    public static func filterRubyGems(rawResponse: Data,
                                       packageName: String,
                                       allowedAfter cutoff: Date,
                                       allowlistedPackage: Bool,
                                       publishTimeCache: PublishTimeCache?) async -> Data {
        guard let parts = splitHTTPResponse(rawResponse) else { return rawResponse }
        let (head, body) = parts
        guard let arr = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            return rawResponse
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]

        var versionPubTimes: [(String, Date)] = []
        var kept: [[String: Any]] = []
        for entry in arr {
            let num = (entry["number"] as? String) ?? ""
            guard !num.isEmpty else { kept.append(entry); continue }
            let timeStr = (entry["created_at"] as? String) ?? ""
            let parsed = iso.date(from: timeStr) ?? isoNoFraction.date(from: timeStr)
            if let d = parsed {
                versionPubTimes.append((num, d))
                if !allowlistedPackage && d > cutoff { continue }
            }
            kept.append(entry)
        }

        if let cache = publishTimeCache, !versionPubTimes.isEmpty {
            await cache.record(ecosystem: "rubygems", name: packageName,
                               versions: versionPubTimes)
        }
        guard let newBody = try? JSONSerialization.data(withJSONObject: kept,
                                                        options: [.sortedKeys]) else {
            return rawResponse
        }
        return rebuildHTTPResponse(originalHead: head, newBody: newBody)
    }

    // MARK: - Packagist

    /// `https://repo.packagist.org/p2/<vendor>/<pkg>.json` returns
    /// `{"packages":{"<vendor>/<pkg>": [{"version":"1.0.0","time":"...", ...}, ...]}}`.
    public static func filterPackagist(rawResponse: Data,
                                        packageName: String,
                                        allowedAfter cutoff: Date,
                                        allowlistedPackage: Bool,
                                        publishTimeCache: PublishTimeCache?) async -> Data {
        guard let parts = splitHTTPResponse(rawResponse) else { return rawResponse }
        let (head, body) = parts
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return rawResponse
        }
        var manifest = json
        var versionPubTimes: [(String, Date)] = []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]

        if var packages = manifest["packages"] as? [String: Any] {
            for (key, value) in packages {
                guard let versions = value as? [[String: Any]] else { continue }
                var kept: [[String: Any]] = []
                for entry in versions {
                    let v = (entry["version"] as? String) ?? ""
                    guard !v.isEmpty else { kept.append(entry); continue }
                    let timeStr = (entry["time"] as? String) ?? ""
                    let parsed = iso.date(from: timeStr) ?? isoNoFraction.date(from: timeStr)
                    if let d = parsed {
                        versionPubTimes.append((v, d))
                        if !allowlistedPackage && d > cutoff { continue }
                    }
                    kept.append(entry)
                }
                packages[key] = kept
            }
            manifest["packages"] = packages
        }

        if let cache = publishTimeCache, !versionPubTimes.isEmpty {
            await cache.record(ecosystem: "packagist", name: packageName,
                               versions: versionPubTimes)
        }
        guard let newBody = try? JSONSerialization.data(withJSONObject: manifest,
                                                        options: [.sortedKeys]) else {
            return rawResponse
        }
        return rebuildHTTPResponse(originalHead: head, newBody: newBody)
    }

    // MARK: - Shared helpers (kept private to this file — npm has
    //         its own copies because the HTTP rebuild adds an
    //         npm-specific `X-Bromure-Rewritten` header that gets
    //         set here too for consistency).

    private static func splitHTTPResponse(_ raw: Data) -> (head: String, body: Data)? {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = raw.subdata(in: 0..<sep.lowerBound)
        let body     = raw.subdata(in: sep.upperBound..<raw.count)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        return (head, body)
    }

    private static func rebuildHTTPResponse(originalHead: String, newBody: Data) -> Data {
        var lines = originalHead.components(separatedBy: "\r\n")
        lines.removeAll { line in
            let lower = line.lowercased()
            return lower.hasPrefix("content-length:")
                || lower.hasPrefix("transfer-encoding:")
                || lower.hasPrefix("content-encoding:")
        }
        // See NPMRegistryTransforms.rebuildHTTPResponse for rationale —
        // marker goes right after the status line.
        if !lines.isEmpty {
            lines.insert("X-Bromure-Rewritten: supply-chain", at: 1)
        } else {
            lines.append("X-Bromure-Rewritten: supply-chain")
        }
        lines.append("Content-Length: \(newBody.count)")
        var head = lines.joined(separator: "\r\n")
        head += "\r\n\r\n"
        var out = Data(head.utf8)
        out.append(newBody)
        return out
    }

    /// Tolerant lexicographic-by-component compare used to pick
    /// the newest version when a metadata response forces us to
    /// rewrite a "latest"-style field.
    private static func compareSemverLoose(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<min(pa.count, pb.count) {
            if pa[i] != pb[i] { return pa[i] < pb[i] }
        }
        return pa.count < pb.count
    }
}
