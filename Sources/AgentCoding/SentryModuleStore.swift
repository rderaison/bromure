import CryptoKit
import Foundation
import SandboxEngine

/// The kernel sentry module catalog published by Jenkinsfile.sentry at
/// `https://dl.bromure.io/sentry/<sourceHash>/catalog.json`: every kernel the
/// module source has a prebuilt `.ko` for. Signed with the Sparkle ed25519 key
/// (SUPublicEDKey); a module loads into the guest kernel as root, so the
/// signature covers every field the host trusts — kernel, object path, sha256
/// and size.
public struct SentryModuleCatalog: Codable, Equatable, Sendable {
    public struct Module: Codable, Equatable, Sendable {
        public var kernel: String
        /// Object key under the public base, e.g.
        /// `sentry/<hash>/<kernel>/bromure_sentry-<kernel>-<sha12>.ko`.
        public var path: String
        public var sha256: String
        public var bytes: Int
        /// Informational (unsigned): the headers package it was built against.
        public var headers: String?
        public var builtAt: String?
        /// base64 ed25519 over `moduleSigningPayload` (Sparkle key): the
        /// module's own signature, so it verifies without trusting whichever
        /// catalog listed it.
        public var signature: String?
    }

    /// Domain separator for a module's own signature. Never sign raw `.ko`
    /// bytes with this key: Sparkle signs raw update archives, so that would
    /// let a module pass for a signed update.
    public static let moduleMagic = "bromure-sentry-module-v1"

    /// tools/make-sentry-catalog.mjs `moduleSigningPayload`, byte for byte.
    public static func moduleSigningPayload(sourceHash: String, _ m: Module) -> Data {
        Data([moduleMagic, "sourceHash=\(sourceHash)", "kernel=\(m.kernel)",
              "sha256=\(m.sha256.lowercased())", "bytes=\(m.bytes)"].joined(separator: "\n").utf8)
    }

    public func isModuleSignatureValid(_ m: Module, publicKeyBase64: String) -> Bool {
        guard let s = m.signature, let sig = Data(base64Encoded: s),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sig, for: Self.moduleSigningPayload(sourceHash: sourceHash, m))
    }

    public struct Signature: Codable, Equatable, Sendable {
        /// ISO-8601; also the rollback guard (never adopt an older catalog).
        public var signedAt: String
        public var edSignature: String
    }

    public var formatVersion: Int
    public var sourceHash: String
    public var modules: [Module]
    public var signature: Signature?

    /// Domain separator: the same key signs image catalogs and app updates.
    public static let magic = "bromure-sentry-modules-v1"

    /// The bytes the signature covers. tools/make-sentry-catalog.mjs builds
    /// the IDENTICAL string; change both or neither (and bump the magic).
    public func signingPayload(signedAt: String) -> Data {
        var lines = [Self.magic, "signedAt=\(signedAt)", "formatVersion=\(formatVersion)",
                     "sourceHash=\(sourceHash)"]
        for m in modules.sorted(by: { $0.kernel < $1.kernel }) {
            lines.append("module.\(m.kernel).path=\(m.path)")
            lines.append("module.\(m.kernel).sha256=\(m.sha256.lowercased())")
            lines.append("module.\(m.kernel).bytes=\(m.bytes)")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    public func isSignatureValid(publicKeyBase64: String) -> Bool {
        guard let sig = signature,
              let sigData = Data(base64Encoded: sig.edSignature),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(sigData, for: signingPayload(signedAt: sig.signedAt))
    }

    static func isKernelName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, CharacterSet.decimalDigits.contains(first), s.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+~-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Shape checks independent of the signature: a well-signed catalog
    /// still can't point outside its own source's prefix or name a kernel
    /// that would escape a file name.
    public func isWellFormed(for hash: String) -> Bool {
        guard formatVersion == 1, sourceHash == hash else { return false }
        let prefix = "sentry/\(hash)/"
        return modules.allSatisfy { m in
            Self.isKernelName(m.kernel) && m.path.hasPrefix(prefix) && !m.path.contains("..")
                && m.sha256.count == 64 && m.sha256.allSatisfy(\.isHexDigit)
                && m.bytes > 0 && m.bytes < 64 << 20
        }
    }

    public func module(for kernel: String) -> Module? { modules.first { $0.kernel == kernel } }
}

/// Downloads, verifies, caches and stages kernel sentry modules.
///
/// The guest loads `$META/sentry/bromure_sentry-$(uname -r).ko`. The host
/// can't know a workspace's kernel before it has booted once, so it learns
/// them from the guest's sandbox status (`sentry_kernel`, `installed_kernels`)
/// and keeps them per workspace. Before each boot it stages the cached module
/// of every known kernel; when the guest says it's waiting for one it doesn't
/// have (a first boot, or a kernel it just `apt upgrade`d into), the host
/// fetches it and drops it into the running VM's meta share, where the guest
/// picks it up within its wait window.
///
/// Trust: the catalog must verify against the pinned SUPublicEDKey and name
/// only this source's objects; every module is re-hashed against the catalog
/// before it is staged, so a file edited in the cache is never loaded.
public final class SentryModuleStore: @unchecked Sendable {
    public static let shared = SentryModuleStore()

    public static let defaultBase = URL(string: "https://dl.bromure.io/")!

    /// `BROMURE_SENTRY_CATALOG_BASE` points the store at a test server; like
    /// `BROMURE_IMAGE_CATALOG_BASE`, an override accepts unsigned catalogs.
    static var overrideBase: URL? {
        guard let raw = ProcessInfo.processInfo.environment["BROMURE_SENTRY_CATALOG_BASE"], !raw.isEmpty
        else { return nil }
        return URL(string: raw.hasSuffix("/") ? raw : raw + "/")
    }

    let root: URL
    let base: URL
    let requireSignature: Bool
    let publicKeyBase64: String
    private let session: URLSession
    private let fm = FileManager.default
    private let lock = NSLock()
    private var catalogs: [String: SentryModuleCatalog] = [:]
    private var inflight: [String: Task<Failure?, Never>] = [:]

    /// Why a module isn't cached. `definitive`: it won't change this boot —
    /// the signed catalog has no module for the kernel, or no trusted one —
    /// so a waiting guest is told to stop. Otherwise (offline, a failed or
    /// corrupted download, a cache write) it may on the next try.
    public struct Failure: Sendable, Equatable {
        public let reason: String
        public let definitive: Bool
    }
    private var catalogFetchedAt: [String: Date] = [:]
    /// When a fetched catalog was last accepted (cached as current).
    private var catalogAcceptedAt: [String: Date] = [:]

    public init(root: URL? = nil, base: URL? = nil, requireSignature: Bool? = nil,
                publicKeyBase64: String = ImageCatalogStore.pinnedPublicKeyBase64,
                session: URLSession = .shared) {
        let support = ACSupportDir.url
        self.root = root ?? support.appendingPathComponent("sentry-modules", isDirectory: true)
        self.base = base ?? Self.overrideBase ?? Self.defaultBase
        self.requireSignature = requireSignature ?? (Self.overrideBase == nil)
        self.publicKeyBase64 = publicKeyBase64
        self.session = session
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    // MARK: Source identity

    /// sha256 over Makefile, bromure_sentry.c, bromure_sentry.h (sorted), each
    /// as `name\n<length>\n<bytes>`. scripts/openshell-guest/sentry/source-hash.sh
    /// computes the identical value.
    public static func sourceHash(of dir: URL) -> String? {
        var hasher = SHA256()
        for name in ["Makefile", "bromure_sentry.c", "bromure_sentry.h"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            hasher.update(data: Data("\(name)\n\(data.count)\n".utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let sha256Cache = NSCache<NSURL, NSString>()
    /// The hash of the source the app ships (`vm-setup/sentry-dist/src`).
    public static func shippedSourceHash(setupDir: URL) -> String? {
        let dir = setupDir.appendingPathComponent("sentry-dist/src", isDirectory: true)
        if let hit = sha256Cache.object(forKey: dir as NSURL) { return hit as String }
        guard let h = sourceHash(of: dir) else { return nil }
        sha256Cache.setObject(h as NSString, forKey: dir as NSURL)
        return h
    }

    // MARK: Catalog

    private func catalogFile(_ hash: String) -> URL {
        root.appendingPathComponent(hash, isDirectory: true).appendingPathComponent("catalog.json")
    }

    /// The catalog's signature doesn't cover the per-module signatures, so
    /// whoever can write the bucket could strip them (and leave the catalog
    /// signature valid): every module then read as unsigned and the guest
    /// gave up on its sentry. A catalog is taken only when every module's own
    /// signature verifies too; anything less keeps the one already cached.
    private func accept(_ c: SentryModuleCatalog, for hash: String) -> Bool {
        guard c.isWellFormed(for: hash) else { return false }
        guard requireSignature else { return true }
        return c.isSignatureValid(publicKeyBase64: publicKeyBase64)
            && c.modules.allSatisfy { c.isModuleSignatureValid($0, publicKeyBase64: publicKeyBase64) }
    }

    /// The last verified catalog for `hash` (memory, else disk, re-verified:
    /// the cache is user-writable).
    public func cachedCatalog(_ hash: String) -> SentryModuleCatalog? {
        lock.lock()
        if let c = catalogs[hash] { lock.unlock(); return c }
        lock.unlock()
        guard let data = try? Data(contentsOf: catalogFile(hash)),
              let c = try? JSONDecoder().decode(SentryModuleCatalog.self, from: data),
              accept(c, for: hash) else { return nil }
        lock.lock(); catalogs[hash] = c; lock.unlock()
        return c
    }

    /// Fetch the published catalog (at most once a minute unless `force`);
    /// falls back to the cached one when offline or when the fetched one
    /// doesn't verify or is older than what's cached.
    @discardableResult
    public func refreshCatalog(_ hash: String, force: Bool = false) async -> SentryModuleCatalog? {
        await fetchCatalog(hash, force: force).catalog
    }

    /// `refreshCatalog`, saying whether the catalog returned is one the
    /// server just served and this store accepted (`fresh`) — or the cached
    /// one it fell back to (offline, non-200, undecodable, rejected, older).
    /// Only a fresh catalog proves what isn't published (Finding CWE-670, "A
    /// failed sentry-catalog refresh is treated as proof the kernel was never
    /// published").
    private func fetchCatalog(_ hash: String, force: Bool) async -> (catalog: SentryModuleCatalog?, fresh: Bool) {
        lock.lock()
        let recent = catalogFetchedAt[hash].map { Date().timeIntervalSince($0) < 60 } ?? false
        let acceptedRecently = catalogAcceptedAt[hash].map { Date().timeIntervalSince($0) < 60 } ?? false
        lock.unlock()
        let cached = cachedCatalog(hash)
        if recent && !force { return (cached, acceptedRecently && cached != nil) }
        let url = base.appendingPathComponent("sentry/\(hash)/catalog.json")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fetched = try? JSONDecoder().decode(SentryModuleCatalog.self, from: data)
        else {
            Self.log("catalog for source \(hash.prefix(12)) unavailable from \(url.host ?? "?"); using \(cached == nil ? "nothing" : "the cached one")")
            return (cached, false)
        }
        lock.lock(); catalogFetchedAt[hash] = Date(); lock.unlock()
        guard accept(fetched, for: hash) else {
            Self.log("REJECTED the catalog for source \(hash.prefix(12)): bad signature or shape")
            return (cached, false)
        }
        if let old = cached?.signature?.signedAt, let new = fetched.signature?.signedAt, new < old {
            Self.log("ignored a catalog signed \(new), older than the cached \(old)")
            return (cached, false)
        }
        try? fm.createDirectory(at: catalogFile(hash).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: catalogFile(hash), options: .atomic)
        lock.lock(); catalogs[hash] = fetched; catalogAcceptedAt[hash] = Date(); lock.unlock()
        return (fetched, true)
    }

    // MARK: Modules

    private func cacheFile(_ kernel: String, _ hash: String) -> URL {
        root.appendingPathComponent(hash, isDirectory: true).appendingPathComponent("bromure_sentry-\(kernel).ko")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The cached module for `kernel`, only if it still matches the catalog.
    public func verifiedModule(kernel: String, hash: String) -> Data? {
        guard SentryModuleCatalog.isKernelName(kernel),
              let catalog = cachedCatalog(hash), let entry = catalog.module(for: kernel),
              moduleTrusted(entry, in: catalog),
              let data = try? Data(contentsOf: cacheFile(kernel, hash)),
              data.count == entry.bytes, Self.sha256Hex(data) == entry.sha256.lowercased()
        else { return nil }
        return data
    }

    /// A module must carry its own valid signature (production); test
    /// servers (`BROMURE_SENTRY_CATALOG_BASE`) may serve unsigned ones.
    private func moduleTrusted(_ m: SentryModuleCatalog.Module, in c: SentryModuleCatalog) -> Bool {
        !requireSignature || c.isModuleSignatureValid(m, publicKeyBase64: publicKeyBase64)
    }

    /// Make sure `kernel`'s module is cached. Returns nil on success, else why
    /// not (one line, for the log and the guest-facing reason).
    public func ensure(kernel: String, hash: String) async -> String? {
        await ensureOutcome(kernel: kernel, hash: hash)?.reason
    }

    /// `ensure`, saying whether the failure is definitive.
    public func ensureOutcome(kernel: String, hash: String) async -> Failure? {
        guard SentryModuleCatalog.isKernelName(kernel) else {
            return Failure(reason: "not a kernel release: \(kernel)", definitive: true)
        }
        if verifiedModule(kernel: kernel, hash: hash) != nil { return nil }
        let key = "\(hash)|\(kernel)"
        lock.lock()
        if let t = inflight[key] { lock.unlock(); return await t.value }
        let task = Task<Failure?, Never> { [weak self] in
            guard let self else { return Failure(reason: "store gone", definitive: false) }
            return await self.download(kernel: kernel, hash: hash)
        }
        inflight[key] = task
        lock.unlock()
        let result = await task.value
        lock.lock(); inflight[key] = nil; lock.unlock()
        return result
    }

    private func download(kernel: String, hash: String) async -> Failure? {
        func transient(_ r: String) -> Failure { Failure(reason: r, definitive: false) }
        func definitive(_ r: String) -> Failure { Failure(reason: r, definitive: true) }
        var catalog = cachedCatalog(hash)
        var fresh = false
        if catalog?.module(for: kernel) == nil {
            // A new kernel may have been published since the cached catalog.
            // Always fetched: the guest's wait paces these retries, and a
            // rejected first fetch mustn't skip the network for a minute.
            (catalog, fresh) = await fetchCatalog(hash, force: true)
        }
        guard let catalog else { return transient("no module catalog for this Bromure version (offline?)") }
        guard let entry = catalog.module(for: kernel) else {
            // Only the server's current catalog says it isn't published: the
            // cached one we fell back to may simply predate it.
            return fresh ? definitive("no module published for \(kernel) yet")
                         : transient("couldn't refresh the module catalog to look for \(kernel)")
        }
        guard moduleTrusted(entry, in: catalog) else {
            Self.log("REJECTED the \(kernel) module: missing or invalid module signature")
            return definitive("the \(kernel) module isn't signed by Bromure")
        }
        let url = base.appendingPathComponent(entry.path)
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return transient("download of the \(kernel) module failed")
        }
        guard data.count == entry.bytes, Self.sha256Hex(data) == entry.sha256.lowercased() else {
            Self.log("REJECTED the \(kernel) module: sha256/size don't match the signed catalog")
            return transient("the downloaded \(kernel) module didn't match its signed checksum")
        }
        let dest = cacheFile(kernel, hash)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: dest, options: .atomic) } catch { return transient("couldn't cache the module: \(error.localizedDescription)") }
        Self.log("cached the sentry module for \(kernel) (source \(hash.prefix(12)))")
        return nil
    }

    /// Copy the verified cached module of each kernel into `dir` (the meta
    /// share's `sentry/`), atomically: the guest may be polling for it.
    /// Returns the kernels staged.
    @discardableResult
    public func stage(kernels: [String], hash: String, into dir: URL) -> [String] {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var staged: [String] = []
        for kernel in Set(kernels) {
            guard let data = verifiedModule(kernel: kernel, hash: hash) else { continue }
            let dest = dir.appendingPathComponent("bromure_sentry-\(kernel).ko")
            if (try? Data(contentsOf: dest)) != data {
                let tmp = dir.appendingPathComponent(".bromure_sentry-\(kernel).ko.\(UUID().uuidString.prefix(8))")
                do {
                    try data.write(to: tmp)
                    try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: tmp.path)
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.moveItem(at: tmp, to: dest)
                } catch {
                    try? fm.removeItem(at: tmp)
                    continue
                }
            }
            try? fm.removeItem(at: dir.appendingPathComponent("bromure_sentry-\(kernel).unavailable"))
            staged.append(kernel)
        }
        return staged.sorted()
    }

    /// How long a guest waits for its module at boot (bromure-sentryd's
    /// BROMURE_SENTRY_WAIT_S), and how often a transient failure is retried
    /// within it.
    public static let guestWait: TimeInterval = 45
    public static let retryInterval: TimeInterval = 5

    /// `bromure_sentry-<kernel>.unavailable` (one line: the host's reason)
    /// beside where the module would be: a guest waiting for that kernel
    /// stops at once instead of timing out. Removed when a module is staged.
    public func markUnavailable(_ reasons: [String: String], in dir: URL) {
        for (kernel, why) in reasons where SentryModuleCatalog.isKernelName(kernel) {
            let marker = dir.appendingPathComponent("bromure_sentry-\(kernel).unavailable")
            try? Data((why + "\n").utf8).write(to: marker, options: .atomic)
        }
    }

    // MARK: Kernels per workspace

    private var kernelsFile: URL { root.appendingPathComponent("kernels.json") }

    public func knownKernels(for profileID: UUID) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: kernelsFile),
              let all = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [] }
        return all[profileID.uuidString] ?? []
    }

    /// Remember the kernels a workspace has (the running one first). Returns
    /// true when the set changed.
    @discardableResult
    public func record(kernels: [String], for profileID: UUID) -> Bool {
        let clean = kernels.filter(SentryModuleCatalog.isKernelName)
        guard !clean.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        var all = (try? Data(contentsOf: kernelsFile)).flatMap {
            try? JSONDecoder().decode([String: [String]].self, from: $0)
        } ?? [:]
        var seen = Set<String>()
        let merged = clean.filter { seen.insert($0).inserted }
        guard all[profileID.uuidString] != merged else { return false }
        all[profileID.uuidString] = merged
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: kernelsFile, options: .atomic) }
        return true
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data("[sentry-modules] \(s)\n".utf8))
    }
}
