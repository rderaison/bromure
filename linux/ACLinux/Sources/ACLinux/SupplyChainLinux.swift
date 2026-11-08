import Foundation
import NIOConcurrencyHelpers

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
        // guest (driveTLS's buffered relay for it); a tarball nothing strips
        // streams, as before the re-route (not held under the 64 MiB cap).
        if case .none = plan, let depiKey {
            if case .artifact? = SupplyChainRegistry.classify(host: host, path: path) { return plan }
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
    /// What the re-route decided.
    enum DepiRoute {
        case none
        /// Re-routed with this key (`request` rewritten).
        case routed(String)
        /// Refused: under an OpenShell policy a request goes nowhere but its
        /// own pinned destination (macOS's dialer has nothing else to dial).
        case refused(Data)
    }

    // @port-skip linux-only: HTTPMitmConnection.driveTLS's Depi re-route, on the Linux request chain
    static func depiRoute(_ request: inout Data, proxy: MitmProxy, profileID: UUID, host: String,
                          method: String, path: String) -> DepiRoute {
        let scPolicy = proxy.supplyChainPolicy(for: profileID)
        if let p = scPolicy, p.depiActive, DepiRegistry.shouldRoute(host: host),
           proxy.guardrailsConfig(for: profileID)?.egressPolicy?.openShell != nil {
            SupplyChainLog.shared.record("[depi] \(method) \(host)\(path) NOT re-routed — an OpenShell policy pins every request to its own destination")
            return .refused(RequestReader.simple(502, "Bad Gateway",
                body: "Bromure: Depi's re-route is refused under this workspace's OpenShell policy (requests go only to their own destination).\n"))
        }
        if let p = scPolicy, p.depiActive, DepiRegistry.shouldRoute(host: host),
           !DepiRegistry.isReadOnlyLookup(method: method, path: path) {
            // Not a lookup (a publish, a login, a token…): neither the key
            // nor the re-route — it goes where the guest sent it.
            SupplyChainLog.shared.record("[depi] \(method) \(host)\(path) NOT re-routed — not a read-only lookup (no Depi key)")
        } else if let p = scPolicy, p.depiActive, DepiRegistry.shouldRoute(host: host) {
            // Depi's name as the Host (macOS's URLSession sends the URL's).
            request = HTTPRequestFraming.replacingHeaders(DepiRegistry.authorize(rawRequest: request, apiKey: p.depiAPIKey),
                                                          drop: ["host"], add: "Host: \(DepiRegistry.host)")
            SupplyChainLog.shared.record("[depi] \(method) \(host)\(path) → https://\(DepiRegistry.host)")
            return .routed(p.depiAPIKey)
        } else if DepiRegistry.shouldRoute(host: host),
                  scPolicy?.packageFilter == .depi || !(scPolicy?.depiAPIKey ?? "").isEmpty {
            let why = scPolicy == nil ? "no supply-chain policy on this workspace"
                : scPolicy?.packageFilter != .depi ? "package filter isn't set to Depi"
                : "no Depi API key entered"
            SupplyChainLog.shared.record("[depi] \(method) \(host)\(path) NOT re-routed — \(why)")
        }
        return .none
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
    /// What a read-whole reply is for the rewrite.
    enum SupplyChainReply {
        /// Whole: its normalized form, for the rewrite.
        case whole(Data)
        /// Without a body (HEAD's, 204, 304): on as it is, not rewritten.
        case bodiless(Data)
    }

    // @port-skip linux-only: relayUpstreamCollecting's normalization, on the Linux relay's raw reply
    static func supplyChainPlain(_ final: Data, cleanClose: Bool, head isHead: Bool = false) -> SupplyChainReply? {
        guard let sep = final.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: final[final.startIndex..<sep.lowerBound], encoding: .isoLatin1) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first.flatMap { Int($0.split(separator: " ").dropFirst().first ?? "") } ?? 0
        if isHead || status == 204 || status == 304 {
            return .bodiless(HTTPRequestFraming.replacingHeaders(Data(final[final.startIndex..<sep.upperBound]),
                                                                 drop: ["connection", "keep-alive", "proxy-connection"],
                                                                 add: "Connection: close"))
        }
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
        let headData = unframed.data(using: .isoLatin1) ?? Data(unframed.utf8)
        var whole = headData + body
        body = Data()
        // An empty body has nothing to decode, whatever its coding says.
        if whole.count > headData.count {
            switch decodeRequestContentEncoding(whole) {
            case .identity: break
            case .decoded(let d): whole = d
            case .undecodable: return nil
            }
        } else {
            whole = HTTPRequestFraming.replacingHeaders(whole, drop: ["content-encoding"], add: "Content-Length: 0")
        }
        return .whole(HTTPRequestFraming.replacingHeaders(
            Self.withDecodedBodyLength(whole),
            drop: ["connection", "keep-alive", "proxy-connection", "te", "trailer", "upgrade"],
            add: "Connection: close"))
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
final class SupplyChainRewrite: @unchecked Sendable {
    let rewrite: (Data) -> Data
    /// A HEAD request's: its reply has no body to rewrite.
    let bodiless: Bool
    private let done: @Sendable () -> Void
    // @port-skip linux-only: see SupplyChainRewrite
    init(rewrite: @escaping (Data) -> Data, bodiless: Bool = false, done: @escaping @Sendable () -> Void) {
        self.rewrite = rewrite
        self.bodiless = bodiless
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

/// What the daemon's package replies being read whole hold at once
/// (ResponseRelay's): their raw bytes, and the decoded and rewritten
/// copies the rewrite makes. Room goes in line: a reply that found none
/// waits, and none behind it in line takes room before it. Only the head
/// of the line (the oldest reply in it) gets room past the limit, so the
/// replies in it never all wait on each other: it finishes, gives its
/// share back, and the next goes on.
// @port-skip linux-only: the Linux relay's read-whole budget
final class SupplyChainBudget: @unchecked Sendable {
    private let lock = NIOLock()
    private var limitBytes: Int
    private var held = 0
    private var holders: [UInt64: Int] = [:]
    private var waiters: Set<UInt64> = []
    private var nextTicket: UInt64 = 0
    /// When room last came back, or the head of the line last got some:
    /// progress for the replies waiting (a younger reply's trickle isn't).
    private var lastActivity = Date()
    /// Rewrites queued or running: the budget isn't idle meanwhile.
    private var rewrites = 0

    // @port-skip linux-only: see SupplyChainBudget
    init(limit: Int) { limitBytes = limit }

    /// The limit (tests lower it).
    // @port-skip linux-only: see SupplyChainBudget
    var limit: Int {
        get { lock.withLock { limitBytes } }
        set { lock.withLock { limitBytes = newValue } }
    }

    /// What's held, by every reply.
    // @port-skip linux-only: see SupplyChainBudget
    var total: Int { lock.withLock { held } }

    /// A reply's place in line: an earlier one is older.
    // @port-skip linux-only: see SupplyChainBudget
    func ticket() -> UInt64 { lock.withLock { nextTicket += 1; return nextTicket } }

    /// `n` more bytes for the reply `t`: if it's the head of the line, or
    /// they fit and no reply before it waits. Refused, it waits in line.
    // @port-skip linux-only: see SupplyChainBudget
    func reserve(_ n: Int, for t: UInt64) -> Bool {
        lock.withLock {
            // The head: the oldest reply holding some or waiting for room.
            let head = [holders.keys.min(), waiters.min(), t].compactMap { $0 }.min() == t
            let ahead = waiters.contains { $0 < t }
            guard head || (held + n <= limitBytes && !ahead) else {
                waiters.insert(t)
                return false
            }
            waiters.remove(t)
            held += n
            holders[t, default: 0] += n
            if head { lastActivity = Date() }
            return true
        }
    }

    // @port-skip linux-only: see SupplyChainBudget
    func release(_ n: Int, for t: UInt64) {
        guard n > 0 else { return }
        lock.withLock {
            held -= n
            let left = (holders[t] ?? 0) - n
            holders[t] = left > 0 ? left : nil
            lastActivity = Date()
        }
    }

    /// The reply `t` is done: what it still holds goes back, and it leaves
    /// the line.
    // @port-skip linux-only: see SupplyChainBudget
    func finish(_ t: UInt64) {
        lock.withLock {
            held -= holders.removeValue(forKey: t) ?? 0
            waiters.remove(t)
            lastActivity = Date()
        }
    }

    /// `n` more bytes for the reply `t` already in memory (a decoded copy
    /// past its estimate, a cut reply's waiting chunks): counted, whatever
    /// the room.
    // @port-skip linux-only: see SupplyChainBudget
    func add(_ n: Int, for t: UInt64) {
        guard n > 0 else { return }
        lock.withLock {
            held += n
            holders[t, default: 0] += n
        }
    }

    /// What the reply `t` holds, set to `n` (a copy made, the one before it
    /// dropped): counted, whatever the room.
    // @port-skip linux-only: see SupplyChainBudget
    func hold(_ n: Int, for t: UInt64) {
        let h = holding(t)
        if n > h { add(n - h, for: t) } else { release(h - n, for: t) }
    }

    /// What the reply `t` holds.
    // @port-skip linux-only: see SupplyChainBudget
    func holding(_ t: UInt64) -> Int { lock.withLock { holders[t] ?? 0 } }

    /// A rewrite queued (`true`) or handed to the guest (`false`).
    // @port-skip linux-only: see SupplyChainBudget
    func rewriting(_ on: Bool) { lock.withLock { rewrites += on ? 1 : -1 } }

    /// How long nothing was got or given back and no rewrite was under way,
    /// counted from `since` at the earliest: a reply waits while the others
    /// make progress.
    // @port-skip linux-only: see SupplyChainBudget
    func idle(since: Date, now: Date = Date()) -> TimeInterval {
        lock.withLock { rewrites > 0 ? 0 : now.timeIntervalSince(max(since, lastActivity)) }
    }
}
