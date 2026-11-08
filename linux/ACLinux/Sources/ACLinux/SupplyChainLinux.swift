import Foundation

extension RequestReader {
    /// What the supply-chain step decided for a request.
    enum SupplyChainPlan {
        /// Not a package fetch the policy touches: on as it is.
        case none
        /// Refused before anything goes upstream (a 451).
        case answer(Data)
        /// Forwarded as `request`, its reply read whole and rewritten
        /// (the metadata age gate, an npm tarball's script strip); `done`
        /// runs once it's been answered.
        case rewrite(request: Data, (Data) -> Data, done: @Sendable () -> Void)
    }

    /// The supply-chain policy on a request (macOS: driveTLS's supply-chain
    /// block, its steps in SupplyChainProxy): every .deb, package metadata
    /// fetch and artifact recorded; with the policy on, metadata age-gated
    /// (and npm's integrity stripped), an artifact checked before it's
    /// fetched (publish-time backstop, OSV, socket.dev, the fail-closed hold,
    /// npm ci's bypass), and an npm tarball's install scripts stripped.
    /// `depiKey`: the request was re-routed to Depi (depiRoute) with this
    /// key: Depi's auth failures are answered, and a reply the policy
    /// doesn't otherwise rewrite is still read whole for that.
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's supply-chain block, on the Linux request chain
    static func supplyChainStep(_ request: Data, proxy: MitmProxy, profileID: UUID, host: String,
                                method: String, path: String, depiKey: String? = nil) async -> SupplyChainPlan {
        let plan = await policyStep(request, proxy: proxy, profileID: profileID, host: host, method: method,
                                    path: path, depiKey: depiKey)
        // Depi-routed traffic goes through a read-whole reply so a 401 can be
        // swapped for a self-explanatory error before any byte reaches the
        // guest (driveTLS's buffered relay for it).
        if case .none = plan, let depiKey {
            return .rewrite(request: request, { raw in
                SupplyChainProxy.depiResponseGate(raw: raw, apiKey: depiKey, profileID: profileID, path: path) ?? raw
            }, done: {})
        }
        return plan
    }

    /// Depi's secure-registry re-route (driveTLS's): with Depi as the
    /// workspace's package filter, an npm registry request is redialled to
    /// Depi with the key as its Bearer token (any guest Authorization
    /// replaced: the key never enters the VM); one addressed to Depi only
    /// needs the key. The key when re-routed (`request` rewritten), else nil;
    /// a partly configured Depi says why it didn't re-route.
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's Depi re-route, on the Linux request chain
    static func depiRoute(_ request: inout Data, proxy: MitmProxy, profileID: UUID, host: String,
                          method: String, path: String) -> String? {
        let scPolicy = proxy.supplyChainPolicy(for: profileID)
        if let p = scPolicy, p.depiActive, DepiRegistry.shouldRoute(host: host) {
            // Depi's name as the Host (macOS's URLSession sends the URL's).
            request = HTTPRequestFraming.replacingHeaders(DepiRegistry.authorize(rawRequest: request, apiKey: p.depiAPIKey),
                                                          drop: ["host"], add: "Host: \(DepiRegistry.host)")
            SupplyChainLog.shared.record("[depi] \(method) \(host)\(path) → https://\(DepiRegistry.host)")
            return p.depiAPIKey
        } else if DepiRegistry.shouldRoute(host: host),
                  scPolicy?.packageFilter == .depi || !(scPolicy?.depiAPIKey ?? "").isEmpty {
            let why = scPolicy == nil ? "no supply-chain policy on this workspace"
                : scPolicy?.packageFilter != .depi ? "package filter isn't set to Depi"
                : "no Depi API key entered"
            SupplyChainLog.shared.record("[depi] \(method) \(host)\(path) NOT re-routed — \(why)")
        }
        return nil
    }

    // @port-skip linux-only: see supplyChainStep
    private static func policyStep(_ request: Data, proxy: MitmProxy, profileID: UUID, host: String,
                                   method: String, path: String, depiKey: String?) async -> SupplyChainPlan {
        let scPolicy = proxy.supplyChainPolicy(for: profileID)
        let enforce = scPolicy?.isActive ?? false
        // apt: observe-only, but every .deb an agent installs is recorded.
        if method == "GET", let deb = SupplyChainRegistry.debPackage(path: path) {
            SupplyChainProxy.emitFetch(profileID: profileID, ecosystem: "apt", package: deb.name,
                                       version: deb.version, kind: "artifact", outcome: "allowed")
        }
        guard let kind = SupplyChainRegistry.classify(host: host, path: path) else { return .none }
        // An all-off stand-in when there's only observing to do.
        let policy = scPolicy ?? SupplyChainPolicy(ageGateEnabled: false)
        let cutoff = Date().addingTimeInterval(-Double(policy.ageGateDays) * 86400)
        switch kind {
        case .metadata(let ecosystem, let pkg):
            guard enforce else {
                SupplyChainProxy.emitFetch(profileID: profileID, ecosystem: ecosystem.rawValue, package: pkg,
                                           version: nil, kind: "metadata", outcome: "allowed")
                return .none
            }
            let allowlisted = policy.ageGateAllows(ecosystem: ecosystem.rawValue, name: pkg)
            let stripIntegrity = ecosystem == .npm && policy.stripInstallScripts
                && !policy.scriptStripAllows(ecosystem: ecosystem.rawValue, name: pkg)
            let ageOn = policy.ageGateEnabled
            let outcome = (allowlisted && !stripIntegrity) ? "allowed" : "rewritten"
            let rewrite = SupplyChainProxy.metadataRewrite(
                ecosystem: ecosystem, pkg: pkg, path: path, depiRouted: depiKey != nil, depiKey: depiKey ?? "",
                profileID: profileID, ageOn: ageOn, cutoff: cutoff, allowlisted: allowlisted,
                stripIntegrity: stripIntegrity, cache: proxy.publishTimeCache)
            // npm: the full packument, so the age gate sees publish times.
            let forward = ecosystem == .npm ? SupplyChainProxy.forceFullNpmPackument(request) : request
            return .rewrite(request: forward, rewrite, done: {
                SupplyChainProxy.emitFetch(profileID: profileID, ecosystem: ecosystem.rawValue, package: pkg,
                                           version: nil, kind: "metadata", outcome: outcome)
            })
        case .artifact(let ecosystem, let pkg, let version):
            guard enforce else {
                SupplyChainProxy.emitFetch(profileID: profileID, ecosystem: ecosystem.rawValue, package: pkg,
                                           version: version, kind: "artifact", outcome: "allowed")
                return .none
            }
            SupplyChainLog.shared.record("[supply-chain] inspecting \(ecosystem.rawValue)/\(pkg)@\(version)")
            var record = SupplyChainProxy.FetchRecord()
            func emit(_ r: SupplyChainProxy.FetchRecord) {
                SupplyChainProxy.emitFetch(profileID: profileID, ecosystem: ecosystem.rawValue, package: pkg,
                                           version: version, kind: "artifact", outcome: r.outcome,
                                           reasonKind: r.reasonKind, reason: r.reason, overridable: r.overridable)
            }
            if let answer = await SupplyChainProxy.artifactChecks(
                ecosystem: ecosystem, pkg: pkg, version: version, policy: policy, cutoff: cutoff,
                request: request, profileID: profileID, publishTimeCache: proxy.publishTimeCache,
                osvClient: proxy.osvClient, socketClient: proxy.socketClient,
                broker: proxy.supplyChainConsent, record: &record) {
                emit(record)
                return .answer(answer)
            }
            guard ecosystem == .npm, policy.stripInstallScripts,
                  !policy.scriptStripAllows(ecosystem: ecosystem.rawValue, name: pkg) else {
                emit(record)
                return .none
            }
            let result = TarballStripBox()
            let rewrite = SupplyChainProxy.tarballRewrite(
                pkg: pkg, version: version, path: path, depiRouted: depiKey != nil, depiKey: depiKey ?? "",
                profileID: profileID, onResult: { result.set($0) })
            let checked = record
            return .rewrite(request: request, rewrite, done: {
                var r = checked
                switch result.get() {
                case .stripped:
                    r.outcome = "stripped"
                    r.reasonKind = "scripts_stripped"
                case .failed(let why):
                    r.outcome = "unchecked"
                    r.reasonKind = "scripts_unchecked"
                    r.reason = why
                case .noScripts, .notApplicable:
                    break
                }
                emit(r)
            })
        case .passthrough:
            return .none
        }
    }

    /// A read-whole reply as macOS's buffered relay hands it to a rewrite
    /// (relayUpstreamCollecting): the final response, whole, its body
    /// decoded (every Content-Encoding line counts, as for a request's body),
    /// its head without the codings and framing it no longer has, a fresh
    /// length and `Connection: close`. nil (a 502, as URLSession throws on
    /// macOS) when it isn't whole: cut short of its Content-Length or its
    /// last chunk, read up to a close that wasn't clean (`cleanClose`), or
    /// framed or coded in a way that can't be read.
    // @port-skip linux-only: relayUpstreamCollecting's normalization, on the Linux relay's raw reply
    static func supplyChainPlain(_ final: Data, cleanClose: Bool) -> Data? {
        guard let sep = final.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: final[final.startIndex..<sep.lowerBound], encoding: .isoLatin1) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        func values(_ name: String) -> [String] {
            lines.dropFirst().flatMap { line -> [String] in
                guard let colon = line.firstIndex(of: ":"),
                      line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name else { return [] }
                return line[line.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            }
        }
        var body = Data(final[sep.upperBound...])
        let transfer = values("transfer-encoding"), lengths = values("content-length")
        if !transfer.isEmpty {
            guard transfer == ["chunked"], let b = HTTPRequestFraming.dechunkedBody(body) else { return nil }
            body = b
        } else if !lengths.isEmpty {
            guard lengths.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }),
                  Set(lengths).count == 1, let n = Int(lengths[0]), body.count >= n else { return nil }
            body = body.prefix(n)
        } else {
            guard cleanClose else { return nil }
        }
        let framing: Set<String> = ["content-length", "transfer-encoding"]
        let unframed = lines.filter { line in
            guard let colon = line.firstIndex(of: ":") else { return true }
            return !framing.contains(line[..<colon].trimmingCharacters(in: .whitespaces).lowercased())
        }.joined(separator: "\r\n") + "\r\n\r\n"
        let whole = (unframed.data(using: .isoLatin1) ?? Data(unframed.utf8)) + body
        let decoded: Data
        switch decodeRequestContentEncoding(whole) {
        case .identity: decoded = whole
        case .decoded(let d): decoded = d
        case .undecodable: return nil
        }
        return HTTPRequestFraming.replacingHeaders(
            Self.withDecodedBodyLength(decoded),
            drop: ["connection", "keep-alive", "proxy-connection", "te", "trailer", "upgrade"],
            add: "Connection: close")
    }

    /// `raw` with a Content-Length for its body (one only).
    // @port-skip linux-only: see supplyChainPlain
    private static func withDecodedBodyLength(_ raw: Data) -> Data {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return raw }
        let n = raw.distance(from: sep.upperBound, to: raw.endIndex)
        return HTTPRequestFraming.replacingHeaders(raw, drop: ["content-length"], add: "Content-Length: \(n)")
    }
}

/// A package reply the supply-chain policy rewrites (read whole), and what
/// runs once it's gone (its supply_chain.fetch event): when it's released,
/// whichever way the request ended (rewritten, refused later in the chain,
/// its upstream unreachable), as macOS's defer emits it.
// @port-skip linux-only: relayUpstreamBuffered's rewrite, carried to the Linux relay
final class SupplyChainRewrite {
    let rewrite: (Data) -> Data
    private let done: @Sendable () -> Void
    // @port-skip linux-only: see SupplyChainRewrite
    init(rewrite: @escaping (Data) -> Data, done: @escaping @Sendable () -> Void) {
        self.rewrite = rewrite
        self.done = done
    }
    // @port-skip linux-only: see SupplyChainRewrite
    deinit { done() }
}

/// The tarball inspection's result, set inside the rewrite and read after.
// @port-skip linux-only: see supplyChainStep
final class TarballStripBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NPMRegistryTransforms.TarballStrip = .notApplicable
    // @port-skip linux-only: see TarballStripBox
    func set(_ v: NPMRegistryTransforms.TarballStrip) { lock.lock(); value = v; lock.unlock() }
    // @port-skip linux-only: see TarballStripBox
    func get() -> NPMRegistryTransforms.TarballStrip { lock.lock(); defer { lock.unlock() }; return value }
}
