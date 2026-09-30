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
    private var inflight: [String: Task<String?, Never>] = [:]
    private var catalogFetchedAt: [String: Date] = [:]

    public init(root: URL? = nil, base: URL? = nil, requireSignature: Bool? = nil,
                publicKeyBase64: String = ImageCatalogStore.pinnedPublicKeyBase64,
                session: URLSession = .shared) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BromureAC", isDirectory: true)
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

    private func accept(_ c: SentryModuleCatalog, for hash: String) -> Bool {
        c.isWellFormed(for: hash) && (!requireSignature || c.isSignatureValid(publicKeyBase64: publicKeyBase64))
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
        lock.lock()
        let recent = catalogFetchedAt[hash].map { Date().timeIntervalSince($0) < 60 } ?? false
        lock.unlock()
        let cached = cachedCatalog(hash)
        if recent && !force { return cached }
        let url = base.appendingPathComponent("sentry/\(hash)/catalog.json")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fetched = try? JSONDecoder().decode(SentryModuleCatalog.self, from: data)
        else {
            Self.log("catalog for source \(hash.prefix(12)) unavailable from \(url.host ?? "?"); using \(cached == nil ? "nothing" : "the cached one")")
            return cached
        }
        lock.lock(); catalogFetchedAt[hash] = Date(); lock.unlock()
        guard accept(fetched, for: hash) else {
            Self.log("REJECTED the catalog for source \(hash.prefix(12)): bad signature or shape")
            return cached
        }
        if let old = cached?.signature?.signedAt, let new = fetched.signature?.signedAt, new < old {
            Self.log("ignored a catalog signed \(new), older than the cached \(old)")
            return cached
        }
        try? fm.createDirectory(at: catalogFile(hash).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: catalogFile(hash), options: .atomic)
        lock.lock(); catalogs[hash] = fetched; lock.unlock()
        return fetched
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
              let entry = cachedCatalog(hash)?.module(for: kernel),
              let data = try? Data(contentsOf: cacheFile(kernel, hash)),
              data.count == entry.bytes, Self.sha256Hex(data) == entry.sha256.lowercased()
        else { return nil }
        return data
    }

    /// Make sure `kernel`'s module is cached. Returns nil on success, else why
    /// not (one line, for the log and the guest-facing reason).
    public func ensure(kernel: String, hash: String) async -> String? {
        guard SentryModuleCatalog.isKernelName(kernel) else { return "not a kernel release: \(kernel)" }
        if verifiedModule(kernel: kernel, hash: hash) != nil { return nil }
        let key = "\(hash)|\(kernel)"
        lock.lock()
        if let t = inflight[key] { lock.unlock(); return await t.value }
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return "store gone" }
            return await self.download(kernel: kernel, hash: hash)
        }
        inflight[key] = task
        lock.unlock()
        let result = await task.value
        lock.lock(); inflight[key] = nil; lock.unlock()
        return result
    }

    private func download(kernel: String, hash: String) async -> String? {
        var catalog = cachedCatalog(hash)
        if catalog?.module(for: kernel) == nil {
            // A new kernel may have been published since the cached catalog.
            catalog = await refreshCatalog(hash, force: catalog != nil)
        }
        guard let catalog else { return "no module catalog for this Bromure version (offline?)" }
        guard let entry = catalog.module(for: kernel) else {
            return "no module published for \(kernel) yet"
        }
        let url = base.appendingPathComponent(entry.path)
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return "download of the \(kernel) module failed"
        }
        guard data.count == entry.bytes, Self.sha256Hex(data) == entry.sha256.lowercased() else {
            Self.log("REJECTED the \(kernel) module: sha256/size don't match the signed catalog")
            return "the downloaded \(kernel) module didn't match its signed checksum"
        }
        let dest = cacheFile(kernel, hash)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: dest, options: .atomic) } catch { return "couldn't cache the module: \(error.localizedDescription)" }
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
