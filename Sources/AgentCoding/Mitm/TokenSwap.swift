import Foundation
#if canImport(SandboxEngine)
import SandboxEngine
#endif

/// Per-profile fake→real token map. Built each time a session is
/// launched from the profile's saved tools + git creds + (later)
/// manual entries. Lives only in memory on the host — the VM never
/// sees the real values.
public struct TokenMap: Sendable {
    public struct Entry: Sendable {
        public let fake: String
        public let real: String
        /// Optional host scope. Empty/nil = swap on any host.
        ///
        /// **Matching is exact-or-subdomain**: `host == scope` OR
        /// `host.hasSuffix("." + scope)`. NOT substring — substring
        /// matching would be a security hole, since a malicious
        /// VM-internal client could `CONNECT openai.com.evil.com:443`
        /// and the proxy would happily swap the real OpenAI key into
        /// the request. The check is also case-insensitive.
        public let host: String?
        /// Header to swap in. Default `Authorization` (Bearer prefix).
        public let header: Header
        /// Stable ID consulted by `ConsentBroker` when this entry
        /// requires user approval. nil = approval not gated.
        public let consentCredentialID: String?
        /// Display name shown in the consent prompt.
        public let consentDisplayName: String?

        public enum Header: String, Sendable {
            case authorization     // Authorization: Bearer <token>
            case xApiKey           // x-api-key: <token>
            case anthropicApiKey   // x-api-key: <token> (Anthropic uses this)
            case openaiApiKey      // Authorization: Bearer <token> (OpenAI)
        }

        /// When true, the swapper also sweeps the request *body* for
        /// `fake` (in addition to the header section) and substitutes
        /// it with `real`. Off by default — the swap path is
        /// header-scoped to keep multipart/binary uploads
        /// untouchable. Turn on for OAuth refresh tokens that ride
        /// in the JSON body of `POST /oauth/token`.
        public let body: Bool

        /// When true, the swap also fires on hosts that share the
        /// registered domain with `host` (cookie-style sibling match,
        /// see `TokenSwapper.hostMatchesScopeFamily`). Off by default;
        /// only opt in for first-party providers that fan a single
        /// auth credential across multiple subdomains (Claude /
        /// Codex). AWS, kubeconfigs, manual tokens, etc. stay on
        /// strict `hostMatchesScope` so a token minted for `s3` can
        /// never be injected into a `lambda` call.
        public let acceptSiblings: Bool

        /// Request-path selectors (OpenShell endpoint `path` syntax) the swap
        /// is limited to; empty = any path. A fake on a bound host but another
        /// path goes out unswapped (the upstream sees a useless placeholder),
        /// exactly like an OpenShell placeholder outside its endpoint binding.
        public let paths: [String]

        /// The 1Password reference `real` was resolved from (the refresher
        /// sets it; on a blank too, which `isPlaceholder` still marks as
        /// unresolved), nil for a value given as is. A live refresh carries a
        /// resolved secret only to the same reference: a placeholder fake
        /// (`openshell:resolve:env:VAR`) stays the same whatever the secret.
        public let resolvedFrom: String?

        public init(fake: String, real: String, host: String? = nil,
                    header: Header = .authorization,
                    body: Bool = false,
                    acceptSiblings: Bool = false,
                    consentCredentialID: String? = nil,
                    consentDisplayName: String? = nil,
                    paths: [String] = [],
                    resolvedFrom: String? = nil) {
            self.resolvedFrom = resolvedFrom
            self.paths = paths
            self.fake = fake
            self.real = real
            self.host = host
            self.header = header
            self.body = body
            self.acceptSiblings = acceptSiblings
            self.consentCredentialID = consentCredentialID
            self.consentDisplayName = consentDisplayName
        }

        /// This entry with another real value (resolved from `resolvedFrom`,
        /// if a 1Password reference), everything else kept.
        public func withReal(_ real: String, resolvedFrom: String? = nil) -> Entry {
            Entry(fake: fake, real: real, host: host, header: header, body: body,
                  acceptSiblings: acceptSiblings, consentCredentialID: consentCredentialID,
                  consentDisplayName: consentDisplayName, paths: paths, resolvedFrom: resolvedFrom)
        }

        /// A real value a refresher fills in later: an exec plugin's
        /// (empty until it first runs) or a 1Password reference.
        var isPlaceholder: Bool { real.isEmpty || OnePasswordCLI.reference(in: real) != nil }
    }

    public var entries: [Entry]

    /// A live refresh's map: `fresh` (re-minted from the profile) merged
    /// over `current` (what the proxy holds). A fresh entry whose real is
    /// still a placeholder takes the real value `current` already has for
    /// that fake and host -- the exec poller or 1Password loop resolved it
    /// -- instead of publishing the placeholder: an empty bearer to the
    /// cluster (or the `op://` literal) until the refresher next ran
    /// (Finding CWE-670, "Live refresh publishes an empty Kubernetes exec
    /// token before the plugin runs"). Its consent metadata is the fresh
    /// one's. Entries whose fakes weren't reissued stay, so a process still
    /// holding an old fake finishes its work.
    /// A 1Password reference takes only the secret resolved from that same
    /// reference: a fake that doesn't change with the secret (an OpenShell
    /// placeholder) kept the old secret when the credential became a new
    /// `op://` value (Finding CWE-670, "Live merge keeps the previous secret
    /// when a credential becomes an op:// reference"). An exec placeholder's
    /// fake is reused only for the same plugin and host, so it carries.
    public static func liveMerge(fresh: [Entry], current: [Entry]) -> TokenMap {
        let freshFakes = Set(fresh.map(\.fake))
        let carried = fresh.map { e -> Entry in
            guard e.isPlaceholder else { return e }
            if let ref = OnePasswordCLI.reference(in: e.real) {
                // This reference's own resolved secret, not the first entry
                // that shares the fake (another credential's, under an
                // OpenShell placeholder).
                guard let held = current.first(where: {
                    $0.fake == e.fake && $0.host == e.host && !$0.isPlaceholder && $0.resolvedFrom == ref
                }) else { return e }
                return e.withReal(held.real, resolvedFrom: ref)
            }
            guard let held = current.first(where: { $0.fake == e.fake && $0.host == e.host && !$0.isPlaceholder })
            else { return e }
            return e.withReal(held.real, resolvedFrom: held.resolvedFrom)
        }
        return TokenMap(entries: carried + current.filter { !freshFakes.contains($0.fake) })
    }

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
}

/// HTTP request inspector + token swapper. Operates on a request as
/// raw bytes (header section + body) to keep things zero-copy and
/// preserve byte-for-byte semantics of unrelated headers.
public final class TokenSwapper: @unchecked Sendable {
    public typealias CompromiseHandler = @Sendable (CompromiseEvent) -> Void

    private var maps: [UUID: TokenMap] = [:]
    /// One Aho-Corasick automaton per profile, rebuilt on `setMap`.
    /// Used by `detectCompromise` to scan an outbound request for any
    /// fake token in the map in O(n) — important because we scan both
    /// headers AND body on every request and don't want to do
    /// `entries.count` substring searches per call.
    private var scanners: [UUID: AhoCorasick] = [:]
    /// Hosts the user explicitly authorized as extra swap destinations for a
    /// session, via the "Allow" button on the compromise alert. When a fake
    /// token is seen heading to one of these, it's no longer flagged as a
    /// leak AND the swap fires there (so the real credential actually reaches
    /// the user-approved host). Session-scoped: cleared by `clearMap` on VM
    /// teardown, exactly like the per-session consent grants.
    private var sessionAllowedHosts: [UUID: Set<String>] = [:]
    private let lock = NSLock()
    private let consent: ConsentBroker
    /// Single host-side hook the proxy fires when a fake token is
    /// observed leaving the VM bound for a host outside its declared
    /// scope. Set once by the engine wiring code.
    private var compromiseHandler: CompromiseHandler?

    public init(consent: ConsentBroker) {
        self.consent = consent
    }

    /// Replace the token map for a profile. Called by the host each
    /// time a session launches (and on profile edit while running, if
    /// we ever wire that).
    public func setMap(_ map: TokenMap, for profileID: UUID) {
        // Build the AC outside the critical section — scanner construction
        // is O(total-pattern-length) and we don't want to block other
        // proxy connections behind it.
        let scanner = AhoCorasick(patterns: map.entries.map { Array($0.fake.utf8) })
        lock.lock(); defer { lock.unlock() }
        maps[profileID] = map
        scanners[profileID] = scanner
    }

    public func clearMap(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        maps.removeValue(forKey: profileID)
        scanners.removeValue(forKey: profileID)
        sessionAllowedHosts.removeValue(forKey: profileID)
    }

    /// Authorize `hosts` as extra swap destinations for this session (the
    /// compromise alert's "Allow"). Stored lowercased; matched exact-or-
    /// subdomain like every other host scope. Cleared on VM teardown.
    public func allowSessionHosts(_ hosts: [String], for profileID: UUID) {
        let cleaned = hosts.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        sessionAllowedHosts[profileID, default: []].formUnion(cleaned)
    }

    /// Whether `host` is a session-allowed swap destination for this profile
    /// (equal to, or a subdomain of, any host the user approved via "Allow").
    private func sessionHostAllowed(_ host: String, profileID: UUID) -> Bool {
        lock.lock(); let allowed = sessionAllowedHosts[profileID] ?? []; lock.unlock()
        guard !allowed.isEmpty else { return false }
        return allowed.contains { Self.hostMatchesScope(host: host, scope: $0) }
    }

    /// Append new entries to the profile's map without clobbering the
    /// ones we already registered (kubeconfigs, manual tokens, etc.).
    /// Used by the subscription-token coordinator and the OAuth
    /// rotation rewriter — both stream new fake↔real pairs into the
    /// map after the initial session-prep call to `setMap`.
    public func appendEntries(_ entries: [TokenMap.Entry], for profileID: UUID) {
        let existing = (snapshotMap(for: profileID)?.entries) ?? []
        let merged = TokenMap(entries: existing + entries)
        setMap(merged, for: profileID)
    }

    /// Install the host-side compromise handler. Called by ACAppDelegate
    /// once the engine is up; the handler's `Sendable` closure body
    /// hops to MainActor to suspend the VM and present the alert.
    public func setCompromiseHandler(_ handler: CompromiseHandler?) {
        lock.lock(); defer { lock.unlock() }
        self.compromiseHandler = handler
    }

    /// Raise the compromise alert for an event detected outside the swap map
    /// (strict credential mode).
    public func raiseCompromise(_ event: CompromiseEvent) {
        lock.lock(); let handler = compromiseHandler; lock.unlock()
        handler?(event)
    }

    /// Snapshot of the current entries for a profile. Used by the
    /// exec-credential poller to mutate a single entry without
    /// rebuilding the whole map from scratch.
    public func entries(for profileID: UUID) -> [TokenMap.Entry] {
        lock.lock(); defer { lock.unlock() }
        return maps[profileID]?.entries ?? []
    }

    /// Synchronous helper used by the async `swap` to grab the map
    /// without holding NSLock across an await (Swift 6 forbids it).
    private func snapshotMap(for profileID: UUID) -> TokenMap? {
        lock.lock(); defer { lock.unlock() }
        return maps[profileID]
    }

    /// Returns the (modified bytes, swap report) for the given raw
    /// request. If no swap applied, the original buffer is returned
    /// untouched.
    ///
    /// Async because entries flagged for user approval await the
    /// consent broker before substitution; the proxy hot path holds
    /// the connection until the user (or a live grant) decides.
    static let openShellPlaceholderPrefix = "openshell:resolve:env:"

    public func swap(rawRequest: Data, host: String, port: Int? = nil, profileID: UUID,
                     placeholderBody: Bool = false) async -> SwapResult {
        // Read the map through a non-async helper so NSLock never sits
        // across an `await` (Swift 6 forbids it).
        let map = snapshotMap(for: profileID)
        guard let map, !map.isEmpty else { return SwapResult(modified: rawRequest, swaps: []) }

        // Find header section end. HTTP delimits headers from body
        // with CRLFCRLF. Anything past that is the body — never touch.
        guard let headerEndIdx = rawRequest.range(of: Data("\r\n\r\n".utf8))?.lowerBound else {
            return SwapResult(modified: rawRequest, swaps: [])
        }

        var headerBytes = rawRequest.subdata(in: 0..<headerEndIdx)
        let bodyBytes   = rawRequest.subdata(in: headerEndIdx..<rawRequest.count)

        // Latin-1 maps every byte, so a non-ASCII header value can't make the
        // whole swap silently no-op (it's re-encoded as Latin-1 below).
        guard var headerStr = String(data: headerBytes, encoding: .isoLatin1) else {
            return SwapResult(modified: rawRequest, swaps: [])
        }

        var swaps: [SwapRecord] = []
        var newBody = bodyBytes
        var bodyDirty = false
        // The user may have authorized this host as an extra destination via
        // the compromise alert's "Allow" — if so, a scoped entry's fake is
        // swapped here too, so the real credential reaches the approved host.
        let sessionAllowed = sessionHostAllowed(host, profileID: profileID)
        for entry in map.entries {
            if let h = entry.host, !h.isEmpty {
                let matched = entry.acceptSiblings
                    ? Self.hostMatchesScopeFamily(host: host, scope: h)
                    : Self.hostMatchesScope(host: host, port: port, scope: h)
                if !matched && !sessionAllowed { continue }
            }

            if !entry.paths.isEmpty {
                #if canImport(SandboxEngine)
                let target = headerStr.prefix { $0 != "\r" }.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                guard let path = OpenShellPolicy.canonicalPath(ofTarget: target),
                      entry.paths.contains(where: { OpenShellPolicy.pathSelector($0, matches: path) }) else { continue }
                #endif
            }

            let inHeader = (headerStr.range(of: entry.fake) != nil)
            // `curl -u user:$SECRET` (any HTTP Basic client) sends the fake
            // base64-encoded: look inside the Basic credentials too.
            let inBasic = !inHeader && Self.basicCredentialsContain(headerStr, entry.fake)
            // Body sweep is only attempted for entries that opted in
            // (refresh tokens, etc.). Cheap pre-check on raw bytes so
            // we don't run the consent broker for non-matching entries.
            let fakeData = Data(entry.fake.utf8)
            // OpenShell credential placeholders are resolved in a body only
            // where the policy endpoint opts in (`request_body_credential_rewrite`).
            let bodySweep = entry.body
                || (placeholderBody && entry.fake.hasPrefix(Self.openShellPlaceholderPrefix))
            let inBody: Bool = bodySweep
                ? (newBody.range(of: fakeData) != nil)
                : false
            guard inHeader || inBasic || inBody else { continue }

            // Gate on consent if the entry is flagged. An entry is flagged
            // (consentCredentialID set) exactly when the user opted into
            // approval (manual token `requireApproval`, kubeconfig gate, etc.).
            // We deliberately do NOT force a prompt on unscoped-but-unflagged
            // entries: a blank host filter with approval off is an explicit
            // "inject everywhere, don't ask" choice, and overriding it breaks
            // legitimate always-on credentials (MCP bearers, env-wide tokens).
            // A user who wants an unscoped secret gated sets `requireApproval`
            // on it (or gives it a host filter); that is the supported control.
            if let credID = entry.consentCredentialID {
                FileHandle.standardError.write(Data(
                    "[mitm] swap candidate on \(host) gated → consent \(credID)\n".utf8))
                let allowed = await consent.consent(
                    profileID: profileID,
                    credentialID: credID,
                    credentialDisplayName: entry.consentDisplayName ?? credID,
                    scopeHint: entry.host.map { String(format: NSLocalizedString(
                        "for any *.%@ request", comment: ""), $0) }
                        ?? NSLocalizedString("for outbound requests", comment: ""))
                if !allowed { continue }
            }

            // Sweep all token positions — the same fake might appear in
            // multiple headers (rare but possible).
            while let r = headerStr.range(of: entry.fake) {
                headerStr.replaceSubrange(r, with: entry.real)
                swaps.append(SwapRecord(
                    fakePreview: Self.preview(entry.fake),
                    realPreview: Self.preview(entry.real),
                    host: host
                ))
            }

            for _ in 0..<Self.swapBasicCredentials(&headerStr, fake: entry.fake, real: entry.real) {
                swaps.append(SwapRecord(
                    fakePreview: Self.preview(entry.fake),
                    realPreview: Self.preview(entry.real),
                    host: host
                ))
            }

            if inBody {
                let realData = Data(entry.real.utf8)
                while let r = newBody.range(of: fakeData) {
                    newBody.replaceSubrange(r, with: realData)
                    bodyDirty = true
                    swaps.append(SwapRecord(
                        fakePreview: Self.preview(entry.fake),
                        realPreview: Self.preview(entry.real),
                        host: host
                    ))
                }
            }
        }

        // No-op if no swap actually fired — return the original buffer.
        if swaps.isEmpty {
            return SwapResult(modified: rawRequest, swaps: [])
        }

        // Body-mutated requests need Content-Length patched if the
        // header was present; a stale length truncates the upstream's
        // view of the body and breaks JSON parsing on the OAuth
        // endpoint. We re-derive the length unconditionally when the
        // body changed. A header-only swap (one inside Basic credentials
        // included) may change the header's length, never the body's.
        if bodyDirty {
            headerStr = Self.replaceContentLength(headerStr, newLength: newBody.count)
        }
        headerBytes = headerStr.data(using: .isoLatin1) ?? Data(headerStr.utf8)
        var out = Data()
        out.reserveCapacity(headerBytes.count + newBody.count)
        out.append(headerBytes)
        out.append(newBody)
        return SwapResult(modified: out, swaps: swaps)
    }

    /// The `Authorization` / `Proxy-Authorization` header lines carrying
    /// HTTP Basic credentials: (line range, decoded `user:password` bytes).
    private static func basicCredentialLines(_ headerStr: String) -> [(Range<String.Index>, Data)] {
        var out: [(Range<String.Index>, Data)] = []
        var lineStart = headerStr.startIndex
        while lineStart < headerStr.endIndex {
            // ("\r\n" is ONE Character in Swift: step past its range.)
            let crlf = headerStr.range(of: "\r\n", range: lineStart..<headerStr.endIndex)
            let lineEnd = crlf?.lowerBound ?? headerStr.endIndex
            let line = headerStr[lineStart..<lineEnd]
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let parts = value.split(separator: " ", maxSplits: 1)
                if name == "authorization" || name == "proxy-authorization",
                   parts.count == 2, parts[0].lowercased() == "basic",
                   let decoded = decodeBase64(parts[1].trimmingCharacters(in: .whitespaces)) {
                    out.append((lineStart..<lineEnd, decoded))
                }
            }
            lineStart = crlf?.upperBound ?? headerStr.endIndex
        }
        return out
    }

    /// Decoded Basic credentials of a header block (compromise scan).
    static func basicCredentials(in headerStr: String) -> [Data] {
        basicCredentialLines(headerStr).map(\.1)
    }

    static func basicCredentialsContain(_ headerStr: String, _ fake: String) -> Bool {
        let f = Data(fake.utf8)
        return basicCredentialLines(headerStr).contains { $0.1.range(of: f) != nil }
    }

    /// Swap `fake` for `real` inside every Basic credential that holds
    /// it, re-encoded; the header keeps its name and scheme. Returns the
    /// number of substitutions.
    static func swapBasicCredentials(_ headerStr: inout String, fake: String, real: String) -> Int {
        let f = Data(fake.utf8), r = Data(real.utf8)
        var count = 0
        // Last line first: earlier ranges stay valid while later ones change.
        for (range, decoded) in basicCredentialLines(headerStr).reversed() {
            var creds = decoded
            var n = 0
            var from = creds.startIndex
            while let hit = creds.range(of: f, in: from..<creds.endIndex) {
                creds.replaceSubrange(hit, with: r)
                from = hit.lowerBound + r.count
                n += 1
            }
            guard n > 0 else { continue }
            let line = headerStr[range]
            let name = line[..<line.firstIndex(of: ":")!]
            let scheme = line[line.index(after: line.firstIndex(of: ":")!)...]
                .trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "Basic"
            headerStr.replaceSubrange(range, with: "\(name): \(scheme) \(creds.base64EncodedString())")
            count += n
        }
        return count
    }

    /// Standard base64, padding optional (some clients drop it).
    private static func decodeBase64(_ s: String) -> Data? {
        guard !s.isEmpty else { return nil }
        let padded = s + String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    /// Patch the `Content-Length` header in a CRLF-delimited HTTP
    /// header block. Idempotent — adds a header when none was
    /// present (rare for POST bodies, but handles HTTP/1.0 clients
    /// that omit it).
    private static func replaceContentLength(_ headerStr: String,
                                              newLength: Int) -> String {
        var lines = headerStr.components(separatedBy: "\r\n")
        var saw = false
        for i in lines.indices {
            if lines[i].lowercased().hasPrefix("content-length:") {
                lines[i] = "Content-Length: \(newLength)"
                saw = true
            }
        }
        if !saw {
            // Insert before the trailing empty line (if any) so we
            // don't push the header/body delimiter.
            if let last = lines.last, last.isEmpty {
                lines.insert("Content-Length: \(newLength)", at: lines.count - 1)
            } else {
                lines.append("Content-Length: \(newLength)")
            }
        }
        return lines.joined(separator: "\r\n")
    }

    /// Scan a pre-swap request for `Authorization: Bearer …` and
    /// `*-api-key: …` values that **aren't** in the profile's fake
    /// map. Each returned `LeakEntry` is a credential-shaped value
    /// the proxy did NOT swap — i.e. either a real secret the user
    /// pasted directly into the VM (bypassing bromure's vault) or
    /// some other opaque token bromure doesn't manage. The Trace
    /// Inspector flags these prominently.
    public func detectLeaks(in rawRequest: Data, profileID: UUID) -> [LeakEntry] {
        lock.lock()
        let knownFakes: Set<String> = Set(maps[profileID]?.entries.map { $0.fake } ?? [])
        lock.unlock()

        guard let headerEndIdx = rawRequest.range(of: Data("\r\n\r\n".utf8))?.lowerBound,
              let headerStr = String(data: rawRequest.subdata(in: 0..<headerEndIdx), encoding: .isoLatin1)
        else { return [] }

        var leaks: [LeakEntry] = []
        for line in headerStr.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let lname = name.lowercased()

            // Only inspect headers that conventionally carry credentials.
            let token: String?
            if lname == "authorization" {
                let parts = value.split(separator: " ", maxSplits: 1)
                if parts.count == 2,
                   parts[0].lowercased() == "bearer" || parts[0].lowercased() == "token" {
                    token = String(parts[1])
                } else {
                    token = nil
                }
            } else if lname == "x-api-key"
                   || lname.hasSuffix("-api-key")
                   || lname == "api-key" {
                token = value
            } else {
                token = nil
            }
            guard let tok = token, !tok.isEmpty else { continue }

            // If the token is one of our minted fakes, the swap will
            // fire — not a leak.
            if knownFakes.contains(tok) { continue }

            // The on-host inference engine's own per-session key (`brk-…`,
            // sent as Bearer to the local engine) is ours, not a leaked
            // credential — never flag it.
            if tok.hasPrefix("brk-") { continue }

            // Public client-side SDK keys are designed to ship inside apps
            // and carry no authority — not a secret escaping the vault.
            if Self.isPublicClientKey(header: lname, token: tok) { continue }

            // Heuristic: known secret prefixes are almost certainly
            // real credentials.
            let knownPrefixes = ["sk-ant-", "sk-", "ghp_", "ghu_", "ghs_", "gho_",
                                 "github_pat_", "glpat-", "xoxp-", "xoxb-",
                                 "AIza", "AKIA"]
            let lowerTok = tok.lowercased()
            if knownPrefixes.contains(where: { lowerTok.hasPrefix($0.lowercased()) }) {
                leaks.append(LeakEntry(
                    header: name,
                    valuePreview: Self.preview(tok),
                    suspicion: .knownPrefix))
                continue
            }
            // Otherwise: opaque token in an auth header, ≥20 chars
            // is suspicious enough to flag.
            if tok.count >= 20 {
                leaks.append(LeakEntry(
                    header: name,
                    valuePreview: Self.preview(tok),
                    suspicion: .opaqueToken))
            }
        }
        return leaks
    }

    /// Scan the entire raw outgoing request (headers + body) for any
    /// fake token in the profile's swap map. Returns one
    /// `CompromiseLeak` per fake observed bound for a host outside
    /// the scope the fake was minted for.
    ///
    /// A fake with an empty / nil host scope is "any host" by design
    /// (manual entries the user didn't pin) — those can't leak and
    /// are skipped here. Everything else has a designated domain; a
    /// token landing on any other host is the signature of a VM that's
    /// trying to exfiltrate credentials it shouldn't even know about.
    ///
    /// Side effect: when leaks are non-empty, the registered
    /// `compromiseHandler` is fired synchronously with the event. The
    /// proxy then aborts the upstream call so the malicious destination
    /// never sees a single byte.
    public func detectCompromise(rawRequest: Data,
                                  host: String,
                                  profileID: UUID) -> [CompromiseLeak] {
        // Snapshot under lock so we don't hold it across the scan.
        lock.lock()
        let scanner = scanners[profileID]
        let entries = maps[profileID]?.entries ?? []
        let handler = compromiseHandler
        lock.unlock()

        guard let scanner, scanner.patternCount > 0, !entries.isEmpty else {
            return []
        }

        // A fake inside Basic credentials is base64 on the wire: scan the
        // decoded credentials as well.
        var scanned = rawRequest
        if let end = rawRequest.range(of: Data("\r\n\r\n".utf8))?.lowerBound,
           let head = String(data: rawRequest.subdata(in: 0..<end), encoding: .isoLatin1) {
            for decoded in Self.basicCredentials(in: head) {
                scanned.append(Data("\n".utf8)); scanned.append(decoded)
            }
        }
        let matches = scanner.scan(scanned)
        if matches.isEmpty { return [] }

        // The user authorized this host for the session via the alert's
        // "Allow" — the fake is expected here now, not exfiltration.
        if sessionHostAllowed(host, profileID: profileID) { return [] }

        var leaks: [CompromiseLeak] = []
        for idx in matches {
            guard idx < entries.count else { continue }
            let entry = entries[idx]
            // No declared scope = "swap on any host" — by definition
            // this fake isn't tied to a domain so leaving the VM is
            // expected. Skip.
            guard let scope = entry.host, !scope.isEmpty else { continue }
            // The fake landed on the host it was scoped for — this is
            // the swap path firing in normal operation, not exfil.
            // Mirror the swap's matching policy: entries flagged
            // `acceptSiblings` (Claude / Codex) use the relaxed
            // family match so a token minted for `api.anthropic.com`
            // doesn't trip a compromise alert when it appears on
            // `mcp-tools.anthropic.com`. Everything else stays strict.
            // A port-scoped fake (a kube API on :6443) on its own host but
            // another port goes out unswapped: useless there, not a leak.
            let scopeHost = Self.splitScope(scope).host
            let matched = entry.acceptSiblings
                ? Self.hostMatchesScopeFamily(host: host, scope: scopeHost)
                : Self.hostMatchesScope(host: host, scope: scopeHost)
            if matched { continue }
            leaks.append(CompromiseLeak(
                fakeTokenPreview: Self.preview(entry.fake),
                credentialDisplayName: entry.consentDisplayName ?? "session token",
                declaredHost: scope,
                observedHost: host
            ))
        }

        if !leaks.isEmpty, let handler {
            handler(CompromiseEvent(
                profileID: profileID,
                observedHost: host,
                leaks: leaks,
                timestamp: Date()))
        }
        return leaks
    }

    /// Public client SDK keys sent from inside apps (telemetry / feature
    /// flags). They're meant to be embedded in shipped binaries and grant no
    /// access, so flagging them as a LEAK is pure noise (B51: Codex sends its
    /// Statsig `client-…` key to ab.chatgpt.com on every run).
    static func isPublicClientKey(header lname: String, token: String) -> Bool {
        // Statsig: client SDK keys are `client-…` (server secrets are
        // `secret-…`, which stay flagged).
        if lname == "statsig-api-key", token.hasPrefix("client-") { return true }
        return false
    }

    /// How a token is named in logs, traces and the Security Timeline: its
    /// kind and a keyed fingerprint — never any of its characters.
    static func preview(_ s: String) -> String {
        SecretFingerprint.label(s)
    }

    /// Cookie-style domain match: `host` belongs to `scope` if it equals
    /// `scope` or is a proper subdomain (`host.hasSuffix("." + scope)`).
    /// Case-insensitive. Substring matching is intentionally NOT used —
    /// see the security note on `TokenMap.Entry.host`.
    static func hostMatchesScope(host: String, scope: String) -> Bool {
        let h = host.lowercased()
        let s = scope.lowercased()
        return h == s || h.hasSuffix("." + s)
    }

    /// The swap's match: a `host:port` scope (a kubeconfig server, a docker
    /// registry) names its host and the port the connection must be dialed
    /// on -- the proxy's host is a bare name (CONNECT's host before the port,
    /// or the SNI), so comparing it with the whole scope never matched and
    /// the fake went upstream (Finding CWE-670, "Kube bearer and exec tokens
    /// are scoped to host:port, so the proxy never injects them"). Two
    /// contexts on one name and different ports keep their own tokens. An
    /// unknown port matches no port-scoped entry; a bare scope, any port.
    static func hostMatchesScope(host: String, port: Int?, scope: String) -> Bool {
        let (scopeHost, scopePort) = splitScope(scope)
        if let scopePort, scopePort != port { return false }
        return hostMatchesScope(host: host, scope: scopeHost)
    }

    /// `host:port` → (host, port); a bare host, or an IPv6 literal's colons,
    /// → (scope, nil).
    static func splitScope(_ scope: String) -> (host: String, port: Int?) {
        guard let colon = scope.lastIndex(of: ":"), !scope[..<colon].contains(":"),
              let port = Int(scope[scope.index(after: colon)...]), (1...65535).contains(port)
        else { return (scope, nil) }
        return (String(scope[..<colon]), port)
    }

    /// Relaxed `hostMatchesScope` for compromise detection only.
    /// Returns true when `host` is a sibling of `scope` under the same
    /// registered domain (e.g. `mcp-tools.anthropic.com` is a sibling
    /// of `api.anthropic.com`). Strips one leading label off `scope`
    /// to derive the parent and re-runs the suffix match. Refuses to
    /// strip below three labels so `example.com` → `com` doesn't match
    /// every `.com` host.
    ///
    /// **Only** used by `detectCompromise`. The swap path still calls
    /// the strict `hostMatchesScope`, so the real token never gets
    /// injected into a sibling host's request.
    static func hostMatchesScopeFamily(host: String, scope: String) -> Bool {
        if hostMatchesScope(host: host, scope: scope) { return true }
        let labels = scope.lowercased().split(separator: ".")
        guard labels.count >= 3 else { return false }
        let parent = labels.dropFirst().joined(separator: ".")
        let h = host.lowercased()
        return h == parent || h.hasSuffix("." + parent)
    }
}

public struct SwapResult: Sendable {
    public var modified: Data
    public let swaps: [SwapRecord]
}

public struct SwapRecord: Sendable {
    public let fakePreview: String
    public let realPreview: String
    public let host: String
}
