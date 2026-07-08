import Foundation

/// Per-request supply-chain enforcement entry point. Lives between
/// the MITM proxy's guardrails block and its upstream forward; called
/// once per intercepted HTTPS request to decide whether to forward
/// untouched, transform the response on the way through, or block
/// outright with a 451.
///
/// **Ecosystem coverage** (see `Registry` for the URL recognisers):
///   - npm (registry.npmjs.org): metadata age-gate + tarball script-
///     strip + OSV + socket.dev + lockfile-pinned consent.
///   - PyPI (pypi.org + files.pythonhosted.org): metadata age-gate +
///     OSV. (Script-strip is impractical for sdist because setup.py
///     is Turing-complete; we'd instead steer pip to wheels in a
///     later iteration.)
///   - Cargo (crates.io + index.crates.io): metadata age-gate + OSV.
///   - RubyGems (rubygems.org): metadata age-gate + OSV.
///   - Maven Central (repo1.maven.org / search.maven.org): metadata
///     age-gate + OSV.
///   - NuGet (api.nuget.org): metadata age-gate + OSV.
///   - Go modules (proxy.golang.org): metadata age-gate + OSV.
///   - Packagist (repo.packagist.org + packagist.org): metadata
///     age-gate + OSV.
///
/// **Block response shape** — 451 Unavailable For Legal Reasons with
/// a plaintext body that the agent's package manager surfaces in its
/// error message. Mirrors the guardrails 403 pattern but uses a
/// distinct status code so the user (and the agent in its retry
/// logic) can tell supply-chain blocks from guardrails blocks at a
/// glance.
public struct SupplyChainEnforcer {
    public enum Ecosystem: String, Sendable {
        case npm
        case pypi
        case cargo
        case rubygems
        case maven
        case nuget
        case goModules = "go"
        case packagist
    }

    /// Classification of an intercepted request — what kind of
    /// registry call this is, plus the ecosystem-scoped package
    /// identifier when we can resolve one.
    public enum RequestKind: Sendable {
        /// Package metadata listing — JSON/XML index of all versions
        /// for a single package. The age-gate filters this.
        case metadata(ecosystem: Ecosystem, packageName: String)
        /// A single artifact (tarball / wheel / .crate / .gem / …)
        /// for one specific version. The age-gate uses the cached
        /// (pkg, version) → publish-time map as a backstop here;
        /// npm script-strip rewrites these.
        case artifact(ecosystem: Ecosystem, packageName: String, version: String)
        /// Any other registry call we recognise but don't transform
        /// (e.g. search, auth) — passed through untouched.
        case passthrough
    }

    /// What the enforcer decided. The proxy interprets each case.
    public enum Decision: Sendable {
        /// Forward the request unchanged. Equivalent to "no policy
        /// applies" / "policy allows".
        case allow
        /// Block before forwarding. Proxy writes a 451 with the
        /// given reason.
        case block(reason: String)
        /// Forward the request, then run the response through
        /// `transform` before writing back to the client.
        case forwardAndTransform(transform: @Sendable (Data) -> Data)
    }

    public static let blockStatusCode: Int = 451

    /// Body of the 451 response we send when a supply-chain check
    /// fires. The agent's package manager surfaces this string in
    /// its error output (`apt`, `npm`, `pip`, etc. all forward the
    /// text body when they see a non-2xx response).
    public static func blockBody(reason: String) -> String {
        "Bromure Supply-Chain Security blocked this request:\n\(reason)\n"
    }

    /// HTTP response bytes for a supply-chain block, ready to write
    /// to the TLS-server stream. Connection: close so the client
    /// doesn't try to reuse the tunnel.
    public static func blockResponse(reason: String) -> Data {
        let body = blockBody(reason: reason)
        var resp = "HTTP/1.1 \(blockStatusCode) Unavailable For Legal Reasons\r\n"
        resp += "Content-Type: text/plain; charset=utf-8\r\n"
        resp += "X-Bromure-Block: supply-chain\r\n"
        resp += "Content-Length: \(body.utf8.count)\r\n"
        resp += "Connection: close\r\n\r\n"
        resp += body
        return Data(resp.utf8)
    }
}

/// Per-ecosystem URL recognisers + JSON schema knowledge. Each entry
/// classifies a (host, path) into a `RequestKind` so the enforcer
/// knows what kind of transform to apply.
public enum SupplyChainRegistry {

    /// Classify a request based on (host, path). Returns nil when
    /// the URL doesn't belong to any recognised registry.
    public static func classify(host: String, path: String)
            -> SupplyChainEnforcer.RequestKind? {
        let h = host.lowercased()
        let p = stripQuery(path)

        // npm — registry.npmjs.org, plus Delpi's npm-compatible
        // registry: it mirrors npm's paths at its root AND rewrites
        // packument tarball URLs to point at itself, so the guest's
        // artifact fetches arrive addressed to the Delpi host.
        //   GET /<scoped-or-unscoped-pkg>                  → metadata
        //   GET /<pkg>/-/<file>-<version>.tgz              → artifact
        if h == "registry.npmjs.org" || h.hasSuffix(".npmjs.org")
            || h == DelpiRegistry.host {
            if let v = npmArtifact(path: p) {
                return .artifact(ecosystem: .npm,
                                 packageName: v.pkg, version: v.version)
            }
            if let pkg = npmMetadataPackage(path: p) {
                return .metadata(ecosystem: .npm, packageName: pkg)
            }
            return .passthrough
        }

        // PyPI — pypi.org (JSON API) + files.pythonhosted.org (artifacts).
        //   GET /pypi/<pkg>/json                           → metadata
        //   GET /simple/<pkg>/                             → metadata (legacy HTML / "simple" format)
        //   GET /packages/<sha>/<pkg>-<version>-…          → artifact
        if h == "pypi.org" {
            if let pkg = pypiJSONMetadata(path: p) ?? pypiSimpleMetadata(path: p) {
                return .metadata(ecosystem: .pypi, packageName: pkg)
            }
            return .passthrough
        }
        if h == "files.pythonhosted.org" {
            // Artifact URLs are content-addressed; the (pkg, version)
            // pair lives in the filename, e.g.
            //   /packages/<hash>/<hash>/<pkg>-<version>.tar.gz
            //   /packages/<hash>/<hash>/<pkg>-<version>-<py>-<abi>-<plat>.whl
            if let v = pypiArtifact(path: p) {
                return .artifact(ecosystem: .pypi,
                                 packageName: v.pkg, version: v.version)
            }
            return .passthrough
        }

        // Cargo (Rust). The sparse index is `index.crates.io` (Cargo
        // 1.70+), the older git-based index isn't HTTPS to us. crates
        // metadata + downloads route via `crates.io` + `static.crates.io`.
        if h == "index.crates.io" {
            // /<2 chars>/<2 chars>/<crate>   → JSON-Lines per crate
            if let pkg = cargoSparseIndex(path: p) {
                return .metadata(ecosystem: .cargo, packageName: pkg)
            }
            return .passthrough
        }
        if h == "crates.io" || h == "static.crates.io" {
            // /api/v1/crates/<crate>                       → JSON metadata
            // /api/v1/crates/<crate>/<version>/download    → artifact redirect / .crate
            if let pkg = cargoAPIMetadata(path: p) {
                return .metadata(ecosystem: .cargo, packageName: pkg)
            }
            if let v = cargoArtifact(path: p) {
                return .artifact(ecosystem: .cargo,
                                 packageName: v.pkg, version: v.version)
            }
            return .passthrough
        }

        // RubyGems.
        //   GET /api/v1/versions/<pkg>.json               → metadata
        //   GET /gems/<pkg>-<version>.gem                 → artifact
        if h == "rubygems.org" {
            if let pkg = rubygemsMetadata(path: p) {
                return .metadata(ecosystem: .rubygems, packageName: pkg)
            }
            if let v = rubygemsArtifact(path: p) {
                return .artifact(ecosystem: .rubygems,
                                 packageName: v.pkg, version: v.version)
            }
            return .passthrough
        }

        // Maven Central.
        //   GET .../<group>/<artifact>/maven-metadata.xml → metadata
        //   GET .../<group>/<artifact>/<version>/<art>-<ver>.<ext> → artifact
        if h == "repo1.maven.org" || h == "repo.maven.apache.org"
            || h == "search.maven.org" {
            if let pkg = mavenMetadata(path: p) {
                return .metadata(ecosystem: .maven, packageName: pkg)
            }
            if let v = mavenArtifact(path: p) {
                return .artifact(ecosystem: .maven,
                                 packageName: v.pkg, version: v.version)
            }
            return .passthrough
        }

        // NuGet (api.nuget.org).
        //   GET /v3-flatcontainer/<lc-id>/index.json      → version list
        //   GET /v3-flatcontainer/<lc-id>/<ver>/<lc-id>.<ver>.nupkg → artifact
        if h == "api.nuget.org" || h.hasSuffix(".nuget.org") {
            if let v = nugetArtifact(path: p) {
                return .artifact(ecosystem: .nuget,
                                 packageName: v.pkg, version: v.version)
            }
            if let pkg = nugetMetadata(path: p) {
                return .metadata(ecosystem: .nuget, packageName: pkg)
            }
            return .passthrough
        }

        // Go modules (proxy.golang.org).
        //   GET /<module>/@v/list                         → version list
        //   GET /<module>/@v/<version>.info               → version-meta
        //   GET /<module>/@v/<version>.zip                → artifact
        if h == "proxy.golang.org" {
            if let v = goArtifact(path: p) {
                return .artifact(ecosystem: .goModules,
                                 packageName: v.pkg, version: v.version)
            }
            if let pkg = goMetadata(path: p) {
                return .metadata(ecosystem: .goModules, packageName: pkg)
            }
            return .passthrough
        }

        // Packagist (PHP / Composer).
        //   GET /p2/<vendor>/<pkg>.json                   → metadata
        //   GET /downloads/<vendor>/<pkg>/<version>.zip   → artifact (sometimes redirected)
        if h == "repo.packagist.org" || h == "packagist.org" {
            if let pkg = packagistMetadata(path: p) {
                return .metadata(ecosystem: .packagist, packageName: pkg)
            }
            return .passthrough
        }

        return nil
    }

    private static func stripQuery(_ path: String) -> String {
        if let q = path.firstIndex(of: "?") { return String(path[..<q]) }
        return path
    }

    // MARK: - npm path parsers

    /// `/<pkg>` or `/@scope/pkg` — metadata.
    /// We deliberately reject paths that look like a sub-resource
    /// (e.g. `/<pkg>/-/...` artifact paths, `/<pkg>/<version>`
    /// per-version metadata) — only the bare manifest is "metadata"
    /// for age-gate purposes.
    private static func npmMetadataPackage(path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        // npm addresses scoped-package metadata with the slash
        // percent-encoded (`GET /@scope%2fpkg`). Decode just that sequence so
        // the scope split below sees a normal two-segment path; otherwise
        // `@scope%2fpkg` parses as a single `@`-prefixed blob, returns nil →
        // `.passthrough`, and the package skips the age gate entirely.
        let decoded = path.replacingOccurrences(of: "%2F", with: "/")
                          .replacingOccurrences(of: "%2f", with: "/")
        let trimmed = String(decoded.dropFirst())
        if trimmed.isEmpty { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        if parts.count == 1 {
            // /<pkg>
            return parts[0].hasPrefix("@") ? nil : parts[0]
        }
        if parts.count == 2, parts[0].hasPrefix("@") {
            // /@scope/pkg
            return parts.joined(separator: "/")
        }
        return nil
    }

    /// `/<pkg>/-/<file>-<version>.tgz` (or scoped equivalent).
    /// Returns (pkg, version) on match.
    private static func npmArtifact(path: String) -> (pkg: String, version: String)? {
        guard path.hasPrefix("/"), path.hasSuffix(".tgz") else { return nil }
        let parts = path.dropFirst().split(separator: "/").map(String.init)
        guard parts.contains("-") else { return nil }
        guard let dashIdx = parts.firstIndex(of: "-") else { return nil }
        let pkgParts = parts[..<dashIdx]
        let pkg: String
        if pkgParts.count == 1 {
            pkg = pkgParts[0]
        } else if pkgParts.count == 2, pkgParts[0].hasPrefix("@") {
            pkg = pkgParts.joined(separator: "/")
        } else {
            return nil
        }
        // Filename: `<basename>-<version>.tgz`. For scoped packages
        // the basename is the unscoped part.
        let unscopedBasename: String = {
            if pkg.hasPrefix("@"), let slash = pkg.firstIndex(of: "/") {
                return String(pkg[pkg.index(after: slash)...])
            }
            return pkg
        }()
        guard let filename = parts.last else { return nil }
        // filename = "<unscopedBasename>-<version>.tgz"
        let withoutExt = String(filename.dropLast(".tgz".count))
        let prefix = unscopedBasename + "-"
        guard withoutExt.hasPrefix(prefix) else { return nil }
        let version = String(withoutExt.dropFirst(prefix.count))
        if version.isEmpty { return nil }
        return (pkg, version)
    }

    // MARK: - PyPI

    /// `/pypi/<pkg>/json` — the JSON API.
    private static func pypiJSONMetadata(path: String) -> String? {
        guard path.hasPrefix("/pypi/"), path.hasSuffix("/json") else { return nil }
        let inner = String(path.dropFirst("/pypi/".count).dropLast("/json".count))
        if inner.isEmpty { return nil }
        // Could be `<pkg>` or `<pkg>/<version>` — for metadata we
        // only care about the bare-package form.
        return inner.contains("/") ? nil : inner
    }

    /// `/simple/<pkg>/` — the legacy HTML index. Also used by pip
    /// in PEP 503 / 691 modes.
    private static func pypiSimpleMetadata(path: String) -> String? {
        guard path.hasPrefix("/simple/") else { return nil }
        let inner = path.dropFirst("/simple/".count)
        let trimmed = inner.hasSuffix("/")
            ? String(inner.dropLast()) : String(inner)
        if trimmed.isEmpty || trimmed.contains("/") { return nil }
        return trimmed
    }

    /// `/packages/<hash>/<hash>/<filename>` artifact paths.
    /// Filename: `<pkg>-<version>.{tar.gz|whl|…}` — we only need
    /// the (pkg, version) pair.
    private static func pypiArtifact(path: String) -> (pkg: String, version: String)? {
        guard path.hasPrefix("/packages/") else { return nil }
        let parts = path.dropFirst().split(separator: "/").map(String.init)
        guard let filename = parts.last else { return nil }
        // Try wheel filename first: <distribution>-<version>(-<build>)?-<python>-<abi>-<platform>.whl
        if filename.hasSuffix(".whl") {
            let stem = String(filename.dropLast(".whl".count))
            let segs = stem.split(separator: "-").map(String.init)
            // wheel: at least 5 segments: pkg, version, py, abi, plat
            if segs.count >= 5 {
                return (segs[0], segs[1])
            }
            if segs.count >= 2 { return (segs[0], segs[1]) }
            return nil
        }
        // sdist: <pkg>-<version>.tar.gz / .zip
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".zip", ".tgz"] {
            if filename.hasSuffix(ext) {
                let stem = String(filename.dropLast(ext.count))
                // Split on the LAST hyphen to handle pkg-names containing hyphens.
                guard let lastDash = stem.lastIndex(of: "-") else { return nil }
                let pkg = String(stem[..<lastDash])
                let version = String(stem[stem.index(after: lastDash)...])
                if pkg.isEmpty || version.isEmpty { return nil }
                return (pkg, version)
            }
        }
        return nil
    }

    // MARK: - Cargo

    private static func cargoSparseIndex(path: String) -> String? {
        // /<aa>/<bb>/<crate>   (lowercased lookup directories)
        guard path.hasPrefix("/") else { return nil }
        let parts = path.dropFirst().split(separator: "/").map(String.init)
        if parts.count == 3, parts[0].count <= 2, parts[1].count <= 2 {
            return parts[2]
        }
        return nil
    }
    private static func cargoAPIMetadata(path: String) -> String? {
        guard path.hasPrefix("/api/v1/crates/") else { return nil }
        let rest = String(path.dropFirst("/api/v1/crates/".count))
        // /api/v1/crates/<crate>  (no trailing path) → metadata
        return rest.contains("/") ? nil : rest.isEmpty ? nil : rest
    }
    private static func cargoArtifact(path: String) -> (pkg: String, version: String)? {
        // /api/v1/crates/<crate>/<version>/download
        guard path.hasPrefix("/api/v1/crates/"), path.hasSuffix("/download") else {
            return nil
        }
        let stripped = path.dropFirst("/api/v1/crates/".count)
                            .dropLast("/download".count)
        let segs = stripped.split(separator: "/").map(String.init)
        if segs.count == 2 { return (segs[0], segs[1]) }
        return nil
    }

    // MARK: - RubyGems

    private static func rubygemsMetadata(path: String) -> String? {
        guard path.hasPrefix("/api/v1/versions/"), path.hasSuffix(".json") else { return nil }
        let stripped = String(path.dropFirst("/api/v1/versions/".count)
                                .dropLast(".json".count))
        return stripped.isEmpty || stripped.contains("/") ? nil : stripped
    }
    private static func rubygemsArtifact(path: String) -> (pkg: String, version: String)? {
        guard path.hasPrefix("/gems/"), path.hasSuffix(".gem") else { return nil }
        let stem = String(path.dropFirst("/gems/".count).dropLast(".gem".count))
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let pkg = String(stem[..<dash])
        let version = String(stem[stem.index(after: dash)...])
        if pkg.isEmpty || version.isEmpty { return nil }
        return (pkg, version)
    }

    // MARK: - Maven

    private static func mavenMetadata(path: String) -> String? {
        // /maven2/<group/with/slashes>/<artifact>/maven-metadata.xml
        guard path.hasSuffix("/maven-metadata.xml") else { return nil }
        let stripped = path.dropLast("/maven-metadata.xml".count)
        let parts = stripped.split(separator: "/").map(String.init)
        if parts.count < 2 { return nil }
        // Drop any leading routing segment ("maven2"); everything
        // else up to the last component is the group, the last
        // component is the artifact.
        let trimmed = parts.first == "maven2" ? Array(parts.dropFirst()) : parts
        if trimmed.count < 2 { return nil }
        let group = trimmed.dropLast().joined(separator: ".")
        let artifact = trimmed.last!
        return "\(group):\(artifact)"
    }
    private static func mavenArtifact(path: String) -> (pkg: String, version: String)? {
        // /maven2/<group/with/slashes>/<artifact>/<version>/<file>
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 5 else { return nil }
        let trimmed = parts.first == "maven2" ? Array(parts.dropFirst()) : parts
        if trimmed.count < 4 { return nil }
        let version = trimmed[trimmed.count - 2]
        let artifact = trimmed[trimmed.count - 3]
        let group = trimmed.dropLast(3).joined(separator: ".")
        if group.isEmpty || artifact.isEmpty || version.isEmpty { return nil }
        return ("\(group):\(artifact)", version)
    }

    // MARK: - NuGet

    private static func nugetMetadata(path: String) -> String? {
        // /v3-flatcontainer/<lower-id>/index.json
        guard path.hasPrefix("/v3-flatcontainer/"),
              path.hasSuffix("/index.json") else { return nil }
        let stripped = String(path.dropFirst("/v3-flatcontainer/".count)
                                .dropLast("/index.json".count))
        return stripped.isEmpty || stripped.contains("/") ? nil : stripped
    }
    private static func nugetArtifact(path: String) -> (pkg: String, version: String)? {
        // /v3-flatcontainer/<lower-id>/<lower-version>/<lower-id>.<lower-version>.nupkg
        guard path.hasPrefix("/v3-flatcontainer/"), path.hasSuffix(".nupkg") else {
            return nil
        }
        let parts = path.dropFirst("/v3-flatcontainer/".count)
                       .split(separator: "/").map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1])
    }

    // MARK: - Go modules

    private static func goMetadata(path: String) -> String? {
        // /<module>/@v/list  OR  /<module>/@v/<version>.info / .mod / .ziphash
        guard let atV = path.range(of: "/@v/") else { return nil }
        let module = String(path[path.startIndex..<atV.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if module.isEmpty { return nil }
        let rest = String(path[atV.upperBound...])
        if rest == "list" || rest.hasSuffix(".info") || rest.hasSuffix(".mod") {
            return module
        }
        return nil
    }
    private static func goArtifact(path: String) -> (pkg: String, version: String)? {
        guard let atV = path.range(of: "/@v/"), path.hasSuffix(".zip") else {
            return nil
        }
        let module = String(path[path.startIndex..<atV.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rest = String(path[atV.upperBound...])
        let version = String(rest.dropLast(".zip".count))
        if module.isEmpty || version.isEmpty { return nil }
        return (module, version)
    }

    // MARK: - Packagist

    private static func packagistMetadata(path: String) -> String? {
        // /p2/<vendor>/<package>.json
        // /p2/<vendor>/<package>~dev.json (dev branches)
        guard path.hasPrefix("/p2/"), path.hasSuffix(".json") else { return nil }
        let stripped = String(path.dropFirst("/p2/".count).dropLast(".json".count))
            .replacingOccurrences(of: "~dev", with: "")
        let parts = stripped.split(separator: "/").map(String.init)
        if parts.count == 2 {
            return parts.joined(separator: "/")
        }
        return nil
    }
}
