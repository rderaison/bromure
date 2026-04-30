import Foundation

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

        public init(fake: String, real: String, host: String? = nil,
                    header: Header = .authorization,
                    body: Bool = false,
                    acceptSiblings: Bool = false,
                    consentCredentialID: String? = nil,
                    consentDisplayName: String? = nil) {
            self.fake = fake
            self.real = real
            self.host = host
            self.header = header
            self.body = body
            self.acceptSiblings = acceptSiblings
            self.consentCredentialID = consentCredentialID
            self.consentDisplayName = consentDisplayName
        }
    }

    public var entries: [Entry]

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
    public func swap(rawRequest: Data, host: String, profileID: UUID) async -> SwapResult {
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

        guard var headerStr = String(data: headerBytes, encoding: .ascii) else {
            return SwapResult(modified: rawRequest, swaps: [])
        }

        var swaps: [SwapRecord] = []
        var newBody = bodyBytes
        var bodyDirty = false
        for entry in map.entries {
            if let h = entry.host, !h.isEmpty {
                let matched = entry.acceptSiblings
                    ? Self.hostMatchesScopeFamily(host: host, scope: h)
                    : Self.hostMatchesScope(host: host, scope: h)
                if !matched { continue }
            }

            let inHeader = (headerStr.range(of: entry.fake) != nil)
            // Body sweep is only attempted for entries that opted in
            // (refresh tokens, etc.). Cheap pre-check on raw bytes so
            // we don't run the consent broker for non-matching entries.
            let fakeData = Data(entry.fake.utf8)
            let inBody: Bool = entry.body
                ? (newBody.range(of: fakeData) != nil)
                : false
            guard inHeader || inBody else { continue }

            // Gate on consent if the entry is flagged.
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
        // body changed; otherwise the original request bytes are
        // shipped verbatim (header-only swaps preserve length because
        // fake and real are length-matched).
        if bodyDirty {
            headerStr = Self.replaceContentLength(headerStr, newLength: newBody.count)
        }
        headerBytes = Data(headerStr.utf8)
        var out = Data()
        out.reserveCapacity(headerBytes.count + newBody.count)
        out.append(headerBytes)
        out.append(newBody)
        return SwapResult(modified: out, swaps: swaps)
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
              let headerStr = String(data: rawRequest.subdata(in: 0..<headerEndIdx), encoding: .ascii)
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

    /// Look for a Claude subscription OAuth access token in the
    /// outgoing request's `Authorization: Bearer …` header. Returns
    /// the cleartext token if it matches `sk-ant-oat01-…` AND is not
    /// already a fake (`sk-ant-oat01-brm-…`) AND is not already
    /// registered in the profile's swap map. Used by the consent flow
    /// to decide whether to prompt the user once on first detection.
    /// Caller is responsible for redacting / dropping the result if
    /// they don't act on it — this method intentionally returns the
    /// real value, since the coordinator needs it to mint a fake.
    public func detectSubscriptionAccessToken(in rawRequest: Data,
                                              profileID: UUID) -> String? {
        lock.lock()
        let knownFakes: Set<String> = Set(maps[profileID]?.entries.map { $0.fake } ?? [])
        let knownReals: Set<String> = Set(maps[profileID]?.entries.map { $0.real } ?? [])
        lock.unlock()

        guard let headerEndIdx = rawRequest.range(of: Data("\r\n\r\n".utf8))?.lowerBound,
              let headerStr = String(data: rawRequest.subdata(in: 0..<headerEndIdx),
                                     encoding: .ascii)
        else { return nil }

        for line in headerStr.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "authorization" else { continue }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "bearer" else { continue }
            let tok = String(parts[1])
            guard tok.hasPrefix("sk-ant-oat01-") else { continue }
            // Skip fakes (already swapped) and already-registered reals
            // (we'll re-prompt only when a brand-new clean token shows
            // up — covers the post-decline-Not-Now retry path).
            if tok.hasPrefix("sk-ant-oat01-brm-") { continue }
            if knownFakes.contains(tok) || knownReals.contains(tok) { continue }
            return tok
        }
        return nil
    }

    /// Look for a Codex / ChatGPT subscription OAuth access token in
    /// the outgoing request's `Authorization: Bearer …` header.
    /// Returns the cleartext token if it looks JWT-shaped (`eyJ…`),
    /// is NOT a brm-fake (the host's coordinator gives fakes a
    /// distinctive base64url prefix that decodes to "brm-cdX-acc"),
    /// and is not already registered in the profile's swap map.
    /// Caller is expected to have already gated on the host being
    /// chatgpt.com / openai.com / auth.openai.com.
    public func detectCodexAccessToken(in rawRequest: Data,
                                        profileID: UUID) -> String? {
        lock.lock()
        let knownFakes: Set<String> = Set(maps[profileID]?.entries.map { $0.fake } ?? [])
        let knownReals: Set<String> = Set(maps[profileID]?.entries.map { $0.real } ?? [])
        lock.unlock()

        guard let headerEndIdx = rawRequest.range(of: Data("\r\n\r\n".utf8))?.lowerBound,
              let headerStr = String(data: rawRequest.subdata(in: 0..<headerEndIdx),
                                     encoding: .ascii)
        else { return nil }

        for line in headerStr.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "authorization" else { continue }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "bearer" else { continue }
            let tok = String(parts[1])
            // Codex tokens are JWTs. Bail out fast on anything that
            // doesn't carry the `eyJ` (header `{"…"}`) prefix — keeps
            // us from prompting on regular OpenAI API keys, which
            // start with `sk-`.
            guard tok.hasPrefix("eyJ"), tok.count >= 32 else { continue }
            // Skip our own minted fakes — the swap path keeps the
            // real header + payload and replaces only the signature
            // segment with a `brm-cdX-sig`-prefixed marker.
            if SubscriptionFakeMint.isJWTFake(tok) { continue }
            if knownFakes.contains(tok) || knownReals.contains(tok) { continue }
            return tok
        }
        return nil
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

        let matches = scanner.scan(rawRequest)
        if matches.isEmpty { return [] }

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
            let matched = entry.acceptSiblings
                ? Self.hostMatchesScopeFamily(host: host, scope: scope)
                : Self.hostMatchesScope(host: host, scope: scope)
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

    static func preview(_ s: String) -> String {
        guard s.count > 8 else { return "***" }
        return String(s.prefix(4)) + "…" + String(s.suffix(4))
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
    public let modified: Data
    public let swaps: [SwapRecord]
}

public struct SwapRecord: Sendable {
    public let fakePreview: String
    public let realPreview: String
    public let host: String
}
