import Foundation

/// Parser for `~/.docker/config.json`. Extracts each `auths.<key>.auth`
/// entry, decodes the base64 (`base64("<user>:<password>")`), and turns
/// the JSON key back into a hostname so we can populate the editor's
/// Docker registries section.
///
/// Entries that delegate to a credential store (`credsStore` /
/// `credHelpers`) carry no `auth` field — the password lives in the
/// host's OS keychain and isn't accessible from the file alone. Those
/// are counted as skipped so the UI can tell the user.
enum DockerConfigImport {
    struct Entry {
        let host: String
        let username: String
        let password: String
    }

    struct Result {
        let entries: [Entry]
        let skippedHelper: Int
    }

    enum Error: LocalizedError {
        case malformedJSON
        case missingAuthsSection

        var errorDescription: String? {
            switch self {
            case .malformedJSON:
                return NSLocalizedString(
                    "The file isn't valid JSON.", comment: "")
            case .missingAuthsSection:
                return NSLocalizedString(
                    "No `auths` object found at the top level.", comment: "")
            }
        }
    }

    static func parse(_ data: Data) throws -> Result {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw Error.malformedJSON
        }
        guard let root = raw as? [String: Any] else {
            throw Error.malformedJSON
        }

        // Treat a missing `auths` section as a zero-entry result rather
        // than an error — config.json files do exist that only carry
        // credsStore / credHelpers / unrelated config.
        guard let auths = root["auths"] as? [String: Any] else {
            // But if `credHelpers` or `credsStore` is the only thing, we
            // still want to surface "skipped N" rather than an error.
            let helperCount = countHelperEntries(root: root)
            if helperCount > 0 {
                return Result(entries: [], skippedHelper: helperCount)
            }
            throw Error.missingAuthsSection
        }

        // For helper-managed entries we look at credHelpers (per-host
        // dict) — they don't appear under `auths` since their auth
        // material is fetched on demand from the helper binary.
        let helperCountFromHelpers = countHelperEntries(root: root)

        var out: [Entry] = []
        var skipped = helperCountFromHelpers
        for (key, value) in auths {
            guard let dict = value as? [String: Any] else { continue }
            guard let auth = dict["auth"] as? String, !auth.isEmpty else {
                // Some entries are present in `auths` but defer to a
                // helper (empty `auth` field). Count those too.
                skipped += 1
                continue
            }
            guard let decoded = decodeAuth(auth) else { continue }
            out.append(Entry(
                host: hostnameFromKey(key),
                username: decoded.user,
                password: decoded.password))
        }
        return Result(entries: out, skippedHelper: skipped)
    }

    /// Decode `base64("<user>:<password>")`. Returns nil if the bytes
    /// aren't valid base64 or the decoded value lacks the `:` separator.
    private static func decodeAuth(_ b64: String) -> (user: String, password: String)? {
        // Docker writes standard base64 (with padding); be permissive
        // and trim whitespace before decoding.
        let trimmed = b64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let user = String(s[..<colon])
        let pass = String(s[s.index(after: colon)...])
        if user.isEmpty || pass.isEmpty { return nil }
        return (user, pass)
    }

    /// Translate the JSON key Docker uses to a bare hostname:
    ///   "https://index.docker.io/v1/"  → "docker.io"
    ///   "https://ghcr.io"              → "ghcr.io"
    ///   "myregistry.example.com:5000"  → "myregistry.example.com"
    ///   "ghcr.io"                       → "ghcr.io"
    private static func hostnameFromKey(_ key: String) -> String {
        var s = key
        if let scheme = s.range(of: "://") {
            s = String(s[scheme.upperBound...])
        }
        // Strip trailing path.
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        // Strip port.
        if let colon = s.firstIndex(of: ":") {
            s = String(s[..<colon])
        }
        let lower = s.lowercased()
        // Canonical alias → "docker.io" so it matches what we'd write
        // back out for Docker Hub.
        if lower == "index.docker.io" || lower == "registry-1.docker.io" {
            return "docker.io"
        }
        return s
    }

    private static func countHelperEntries(root: [String: Any]) -> Int {
        if let helpers = root["credHelpers"] as? [String: Any] {
            return helpers.count
        }
        return 0
    }
}
