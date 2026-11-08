import Foundation

// The proxy's supply-chain steps (HTTPMitmConnection.driveTLS's), shared with
// the Linux proxy: the metadata and tarball rewrites, the artifact
// pre-flight checks, and the fetch event. driveTLS keeps the flow (which
// request is buffered, what goes upstream) and calls these.

/// The answers the artifact checks ask for (SupplyChainConsentBroker on
/// macOS).
protocol SupplyChainConsenting: Sendable {
    func consent(profileID: UUID, scope: String, scopeDisplayName: String, detail: String) async -> Bool
    func consentOverride(profileID: UUID, ecosystem: String, name: String, version: String,
                         reason: String) async -> Bool
    func consentUnverified(profileID: UUID, ecosystem: String, name: String, version: String,
                           why: String) async -> Bool
}

enum SupplyChainProxy {
    /// What a fetch's `supply_chain.fetch` event says (the checks set it).
    struct FetchRecord {
        var outcome = "allowed"
        var reasonKind: String?
        var reason: String?
        var overridable = false
    }

    /// Fire-and-forget supply-chain event to the workspace backend. Emits
    /// one `supply_chain.fetch` row per package fetch the MITM intercepts.
    /// `BACEventEmitter.shared.emitDetached` already gates on enrollment
    /// (no install identity → no-op) and per-profile private mode, so this
    /// is safe to call from every supply-chain branch unconditionally.
    ///
    /// Event shape consumed by `ac_events.event_data`:
    ///   { ecosystem, package, version?, kind, outcome,
    ///     reason_kind?, reason? }
    static func emitFetch(profileID: UUID,
                          ecosystem: String,
                          package: String,
                          version: String?,
                          kind: String,
                          outcome: String,
                          reasonKind: String? = nil,
                          reason: String? = nil,
                          overridable: Bool = false) {
        var data: [String: AnyJSON] = [
            "ecosystem": .string(ecosystem),
            "package": .string(package),
            "kind": .string(kind),
            "outcome": .string(outcome),
        ]
        if let version { data["version"] = .string(version) }
        if let reasonKind { data["reason_kind"] = .string(reasonKind) }
        if let reason { data["reason"] = .string(reason) }
        if overridable { data["overridable"] = .bool(true) }
        BACEventEmitter.shared.emitDetached(
            profileID: profileID,
            eventType: "supply_chain.fetch",
            eventData: data)
    }

    /// Downgrade an npm packument request's `Accept` to plain JSON.
    ///
    /// `npm install` asks for the abbreviated "corgi" packument
    /// (`Accept: application/vnd.npm.install-v1+json`), which the registry
    /// returns WITHOUT the `time` map. The age gate keys every drop/record
    /// decision off `time`, so on the exact path it's meant to protect it
    /// silently no-ops — a normal install of a brand-new (or just-published,
    /// likely-malicious) version sails straight through. Forcing the full
    /// packument restores `time`, so `filterMetadata` records publish times
    /// AND filters too-fresh versions out of what npm resolves against. npm
    /// accepts the full document fine; the only cost is a larger response.
    static func forceFullNpmPackument(_ rawRequest: Data) -> Data {
        guard let headerEnd = rawRequest.range(of: Data("\r\n\r\n".utf8)),
              var header = String(data: rawRequest.subdata(in: rawRequest.startIndex..<headerEnd.lowerBound),
                                  encoding: .isoLatin1),
              header.lowercased().contains("vnd.npm.install") else { return rawRequest }
        var lines = header.components(separatedBy: "\r\n")
        for idx in lines.indices where lines[idx].lowercased().hasPrefix("accept:") {
            lines[idx] = "Accept: application/json"
        }
        header = lines.joined(separator: "\r\n")
        var out = Data(header.utf8)
        out.append(rawRequest.subdata(in: headerEnd.lowerBound..<rawRequest.endIndex))
        return out
    }

    /// Inspect a Depi-routed response before it reaches the guest.
    /// 401 = our API key was rejected: surface it host-side (Security
    /// Log + one-shot alert) and substitute a plaintext body npm
    /// prints verbatim, so both sides of the glass see the real
    /// cause. 403 is logged but passed through — Depi is a
    /// *filtering* registry, so a 403 may be it blocking a package,
    /// and its own body is the more accurate message. Returns nil
    /// when the response should pass through unchanged.
    static func depiResponseGate(raw: Data, apiKey: String,
                                          profileID: UUID, path: String) -> Data? {
        switch HTTPFrames.parseStatusCode(raw) {
        case 401:
            DepiRegistry.reportAuthFailure(status: 401, apiKey: apiKey,
                                            profileID: profileID, path: path)
            return DepiRegistry.authFailureResponse(status: 401)
        case 403:
            var preview = ""
            if let sep = raw.range(of: Data("\r\n\r\n".utf8)) {
                let end = min(sep.upperBound + 200, raw.endIndex)
                preview = String(data: raw.subdata(in: sep.upperBound..<end),
                                 encoding: .utf8) ?? ""
            }
            SupplyChainLog.shared.record(
                "[depi] ✗ HTTP 403 from \(DepiRegistry.host)\(path) — " +
                "package blocked by Depi or key not authorized: \(preview)")
            return nil
        default:
            // Depi served the request (didn't block). Log it so it's visible
            // that Depi WAS consulted and chose to allow — e.g. a package the
            // user expected to be flagged that Depi's policy permits.
            SupplyChainLog.shared.record(
                "[depi] \(HTTPFrames.parseStatusCode(raw)) from \(DepiRegistry.host)\(path) — served (Depi did not block)")
            return nil
        }
    }

    /// A package's metadata response rewritten for the policy: the age gate
    /// (and, for npm, the integrity strip), publish times recorded; Depi's
    /// auth failures answered.
    static func metadataRewrite(ecosystem: SupplyChainEnforcer.Ecosystem, pkg: String, path reqPath: String,
                                depiRouted: Bool, depiKey: String, profileID: UUID, ageOn: Bool,
                                cutoff: Date, allowlisted: Bool, stripIntegrity: Bool,
                                cache: PublishTimeCache) -> (Data) -> Data {
        return { raw in
            if depiRouted,
               let substitute = depiResponseGate(
                    raw: raw, apiKey: depiKey,
                    profileID: profileID, path: reqPath) {
                return substitute
            }
            switch ecosystem {
            case .npm:
                var times: [(String, Date)] = []
                let out = NPMRegistryTransforms.filterMetadata(
                    rawResponse: raw,
                    packageName: pkg,
                    allowedAfter: ageOn ? cutoff : .distantPast,
                    allowlistedPackage: allowlisted || !ageOn,
                    stripIntegrity: stripIntegrity,
                    publishTimes: &times)
                if !times.isEmpty {
                    Task.detached { await cache.record(
                        ecosystem: ecosystem.rawValue,
                        name: pkg, versions: times) }
                }
                return out
            case .pypi, .cargo, .rubygems, .packagist:
                // These four record publish times +
                // age-gate via async ecosystem-specific
                // transforms. The transforms are async
                // because they record into the cache
                // actor inline (one fewer round-trip
                // than detaching).
                //
                // Wrap into a blocking semaphore — we're
                // already on a per-request task, this is
                // fine to block here.
                let sem = DispatchSemaphore(value: 0)
                var result: Data = raw
                Task {
                    if !ageOn && !stripIntegrity {
                        result = raw   // policy disabled; passthrough
                        sem.signal(); return
                    }
                    let allowed = ageOn ? cutoff : .distantPast
                    switch ecosystem {
                    case .pypi:
                        // pip's default is the `/simple/`
                        // index (HTML or PEP 691 JSON), not
                        // the `/pypi/<pkg>/json` API — they
                        // have different shapes, so route by
                        // path.
                        if reqPath.hasPrefix("/simple/") {
                            result = await EcosystemTransforms.filterPyPISimple(
                                rawResponse: raw,
                                packageName: pkg,
                                allowedAfter: allowed,
                                allowlistedPackage: allowlisted || !ageOn,
                                publishTimeCache: cache)
                        } else {
                            result = await EcosystemTransforms.filterPyPIJSON(
                                rawResponse: raw,
                                packageName: pkg,
                                allowedAfter: allowed,
                                allowlistedPackage: allowlisted || !ageOn,
                                publishTimeCache: cache)
                        }
                    case .cargo:
                        result = await EcosystemTransforms.filterCargoAPI(
                            rawResponse: raw,
                            packageName: pkg,
                            allowedAfter: allowed,
                            allowlistedPackage: allowlisted || !ageOn,
                            publishTimeCache: cache)
                    case .rubygems:
                        result = await EcosystemTransforms.filterRubyGems(
                            rawResponse: raw,
                            packageName: pkg,
                            allowedAfter: allowed,
                            allowlistedPackage: allowlisted || !ageOn,
                            publishTimeCache: cache)
                    case .packagist:
                        result = await EcosystemTransforms.filterPackagist(
                            rawResponse: raw,
                            packageName: pkg,
                            allowedAfter: allowed,
                            allowlistedPackage: allowlisted || !ageOn,
                            publishTimeCache: cache)
                    default:
                        result = raw
                    }
                    sem.signal()
                }
                sem.wait()
                return result
            default:
                // Maven / NuGet / Go modules don't ship
                // per-version timestamps in their
                // standard metadata response shapes —
                // we'd need per-version sub-fetches.
                // Passthrough for now; OSV/socket.dev
                // still apply at artifact-fetch time.
                return raw
            }
        }
    }

    /// The artifact pre-flight checks: the publish-time backstop, OSV,
    /// socket.dev (and the user's override), the fail-closed hold for a
    /// package with no verdict, and npm ci's bypass prompt. The answer
    /// (a 451) to send instead of forwarding, or nil to go on; `record` says
    /// what happened.
    static func artifactChecks(ecosystem: SupplyChainEnforcer.Ecosystem, pkg: String, version: String,
                               policy: SupplyChainPolicy, cutoff: Date, request: Data, profileID: UUID,
                               publishTimeCache: PublishTimeCache, osvClient: OSVClient,
                               socketClient: SocketDevClient, broker: any SupplyChainConsenting,
                               record: inout FetchRecord) async -> Data? {
        // 1. Publish-time backstop. Catches "agent has
        //    cached metadata from before age gate was on
        //    and is fetching a too-fresh version directly".
        if policy.ageGateEnabled,
           !policy.ageGateAllows(ecosystem: ecosystem.rawValue, name: pkg) {
            var pub = await publishTimeCache.publishedAt(
                ecosystem: ecosystem.rawValue, name: pkg, version: version)
            // pip's default (HTML simple index) and any agent
            // replaying a pre-cached version list never populate
            // the cache — without an on-demand lookup the pip
            // age gate silently no-ops. Fetch the per-release
            // JSON directly, then pin it for the rest of this
            // install burst.
            if pub == nil, ecosystem == .pypi {
                pub = await PyPIMetadataClient.shared.publishTime(
                    package: pkg, version: version)
                if let p = pub {
                    await publishTimeCache.record(
                        ecosystem: "pypi", name: pkg,
                        versions: [(version, p)])
                }
            }
            if let pub, pub > cutoff {
                let age = Date().timeIntervalSince(pub)
                let ageDesc: String
                if age < 3600 { ageDesc = "\(Int(age / 60)) minutes" }
                else if age < 86400 { ageDesc = "\(Int(age / 3600)) hours" }
                else { ageDesc = String(format: "%.1f days", age / 86400) }
                let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) " +
                    "published \(ageDesc) ago — " +
                    "policy requires \(policy.ageGateDays) days minimum"
                let answer = SupplyChainEnforcer.blockResponse(reason: reason)
                SupplyChainLog.shared.record(
                    "[supply-chain] age-gate 451: \(pkg)@\(version) — \(ageDesc) old, requires \(policy.ageGateDays)d")
                record.outcome = "blocked"
                record.reasonKind = "age_gate"
                record.reason = reason
                return answer
            }
        }

        // Accumulates the enabled reputation sources we couldn't reach
        // for this package — drives the fail-closed hold below.
        var verifyGaps: [String] = []
        // Why each gave no verdict, in the words the prompt shows.
        var verifyWhy: [String] = []
        // What the reputation checks (OSV, socket.dev) found: the
        // first block, applied after both ran unless the user
        // overrides it (GitHub issue #54). A socket.dev malware
        // verdict can't be overridden and wins over anything else.
        var reputationBlock: (reason: String, kind: String, log: String, overridable: Bool)?

        // 2. OSV check (free, no key, off by default).
        if policy.osvEnabled {
            if let result = await osvClient.check(
                    ecosystem: ecosystem.rawValue, name: pkg, version: version) {
                let blocking = result.vulnerabilities.filter {
                    $0.severity.rank >= OSVClient.Severity(rawValue: policy.osvSeverity.rawValue)!.rank
                }
                if let v = blocking.first {
                    let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) " +
                        "has \(blocking.count) vulnerabilit\(blocking.count == 1 ? "y" : "ies") " +
                        "at \(policy.osvSeverity.displayName.lowercased()): " +
                        "\(v.id) — \(v.summary)"
                    reputationBlock = (reason, "osv", "OSV 451: \(pkg)@\(version) → \(v.id)", true)
                }
            } else {
                // Lookup failed (network error, non-200, 429 rate-limit,
                // parse error). No verdict — don't silently allow.
                verifyGaps.append("the OSV vulnerability database")
                verifyWhy.append(NSLocalizedString("the OSV vulnerability database didn't answer.",
                                                   comment: "supply chain: why a package has no verdict"))
            }
        }

        // 3. socket.dev check (BYO key).
        if policy.socketActive {
          let socketLookup = await socketClient.lookup(
                ecosystem: ecosystem.rawValue, name: pkg, version: version,
                apiKey: policy.socketAPIKey)
          if case .success(let result) = socketLookup {
            if policy.socketBlockCompromised,
               let bad = SocketDevClient.blockingIssue(result.compromised) {
                let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) " +
                    "flagged by socket.dev (\(bad.severity.rawValue)): " +
                    "\(bad.type) — \(bad.summary)"
                let malware = SocketDevClient.isMalwareVerdict(bad.type)
                if reputationBlock == nil || malware {
                    reputationBlock = (reason, "socket_compromised",
                                       "socket.dev compromised 451: \(pkg)@\(version) → \(bad.type) [\(bad.severity.rawValue)]",
                                       !malware)
                }
            }
            if policy.socketBlockCVE, reputationBlock == nil {
                let threshold = SocketDevClient.Severity.from(string: policy.socketCVESeverity.rawValue)
                let bad = result.vulnerabilities.first { $0.severity.rank >= threshold.rank }
                if let v = bad {
                    let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) " +
                        "has known CVE per socket.dev (\(v.severity.rawValue)): " +
                        "\(v.type) — \(v.summary)"
                    reputationBlock = (reason, "socket_cve",
                                       "socket.dev CVE 451: \(pkg)@\(version) → \(v.type) [\(v.severity.rawValue)]", true)
                }
            }
          } else if case .failure(let why) = socketLookup {
            // socket.dev unreachable / non-200 / 429 / auth failure /
            // parse error / not analysed → no verdict. Don't silently allow.
            verifyGaps.append("socket.dev")
            verifyWhy.append(why.reason.explanation)
          }
        }

        // 3a. The reputation verdict: blocked, unless the package is
        //     on the workspace's override list or the user lets it
        //     through now (malware verdicts never are).
        if let block = reputationBlock {
            var allowed = false
            if block.overridable {
                if policy.reputationAllows(ecosystem: ecosystem.rawValue, name: pkg) {
                    allowed = true
                } else {
                    allowed = await broker.consentOverride(
                        profileID: profileID, ecosystem: ecosystem.rawValue, name: pkg,
                        version: version, reason: block.reason)
                }
            }
            if !allowed {
                let answer = SupplyChainEnforcer.blockResponse(reason: block.reason)
                SupplyChainLog.shared.record("[supply-chain] \(block.log)")
                record.outcome = "blocked"
                record.reasonKind = block.kind
                record.reason = block.reason
                record.overridable = block.overridable
                return answer
            }
            SupplyChainLog.shared.record(
                "[supply-chain] overridden by the user: \(ecosystem.rawValue) \(pkg)@\(version) — \(block.reason)")
            record.outcome = "overridden"
            record.reasonKind = block.kind
            record.reason = block.reason
        }

        // 3b. Fail closed. An enabled reputation check couldn't reach
        //     its source, so this package has NO verdict — and a
        //     compromised agent can *induce* that (flood OSV / socket.dev
        //     with a large install graph until they rate-limit). Rather
        //     than the documented fail-open, hold the install and ask
        //     the host user; deny (incl. no GUI / timeout) blocks. Keyed
        //     per package@version so one approval can't blanket the
        //     whole dependency graph.
        if !verifyGaps.isEmpty {
            let gaps = verifyGaps.joined(separator: " and ")
            SupplyChainLog.shared.record(
                "[supply-chain] unverified: \(ecosystem.rawValue) \(pkg)@\(version) — \(verifyWhy.joined(separator: " "))")
            let allowed = await broker.consentUnverified(
                profileID: profileID, ecosystem: ecosystem.rawValue, name: pkg, version: version,
                why: verifyWhy.joined(separator: " "))
            if !allowed {
                let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) blocked — " +
                    "reputation lookup unavailable (\(gaps)); user denied the unverified install"
                let answer = SupplyChainEnforcer.blockResponse(reason: reason)
                SupplyChainLog.shared.record(
                    "[supply-chain] verify-unavailable 451: \(pkg)@\(version) — \(gaps)")
                record.outcome = "blocked"
                record.reasonKind = "verify_unavailable"
                record.reason = reason
                return answer
            }
        }

        // 4. Lockfile-pinned bypass prompt — for npm,
        //    look for the `npm-command: ci` header the
        //    npm client sets on `npm ci` traffic. If the
        //    prompt is on, ask once per (profile, ecosystem)
        //    burst; pass through if allowed.
        if ecosystem == .npm, policy.lockfilePrompt,
           SubscriptionAuthRewrite.headerValue("npm-command", inHeaderSection: String(
                decoding: request.prefix(min(request.count, 4096)),
                as: UTF8.self))?.lowercased() == "ci" {
            let scope = "lockfile:npm"
            let allowed = await broker.consent(
                profileID: profileID,
                scope: scope,
                scopeDisplayName: NSLocalizedString(
                    "npm ci (lockfile-pinned install)", comment: ""),
                detail: NSLocalizedString(
                    "An agent is running `npm ci` — package tarballs come pre-pinned with cryptographic integrity hashes, so Bromure can't strip install scripts or age-filter them without breaking npm's verification.\n\nPass these tarballs through unmodified?",
                    comment: ""))
            if !allowed {
                let reason = "\(ecosystem.rawValue) lockfile-pinned install (`npm ci`) " +
                    "blocked — user denied bypass via Bromure consent prompt"
                let answer = SupplyChainEnforcer.blockResponse(reason: reason)
                SupplyChainLog.shared.record(
                    "[supply-chain] lockfile-pinned 451: \(pkg)@\(version) — user denied bypass")
                record.outcome = "blocked"
                record.reasonKind = "lockfile_denied"
                record.reason = reason
                return answer
            }
        }
        return nil
    }

    /// An npm tarball with its install scripts stripped (Depi's auth
    /// failures answered); `onResult` gets what the inspection found.
    static func tarballRewrite(pkg: String, version: String, path reqPath: String, depiRouted: Bool,
                               depiKey: String, profileID: UUID,
                               onResult: @escaping (NPMRegistryTransforms.TarballStrip) -> Void) -> (Data) -> Data {
        return { raw in
            if depiRouted,
               let substitute = depiResponseGate(
                    raw: raw, apiKey: depiKey,
                    profileID: profileID, path: reqPath) {
                return substitute
            }
            let (out, result) = NPMRegistryTransforms.inspectTarball(rawResponse: raw)
            onResult(result)
            switch result {
            case .stripped:
                SupplyChainLog.shared.record(
                    "[supply-chain] stripped install scripts from \(pkg)@\(version)")
            case .noScripts:
                SupplyChainLog.shared.record(
                    "[supply-chain] \(pkg)@\(version): no install scripts")
            case .failed(let why):
                // Never silent: the tarball went through as-is.
                SupplyChainLog.shared.record(
                    "[supply-chain] could NOT inspect \(pkg)@\(version) (\(why)) — install scripts NOT removed")
            case .notApplicable:
                break
            }
            return out
        }
    }
}
