import Foundation
import Darwin

/// Why a subscription store refused to read or write. Every case is a HARD
/// error: a store that can't be read is never overwritten (that would wipe
/// the other slots), and a rotated token that couldn't be written is never
/// kept only in memory (the disk would hold a spent token nobody can use).
public enum SubscriptionStoreError: Error, CustomStringConvertible {
    /// The file exists but couldn't be decrypted / decoded (a keychain
    /// hiccup, a vault-key mismatch, a corrupt file). A copy was kept next
    /// to it; the store refuses to write until it reads again.
    case unreadable(String)
    /// Encrypting or writing the file failed; nothing changed.
    case writeFailed(String)
    /// Another process held the store's refresh lock for too long.
    case lockTimeout(String)

    public var description: String {
        switch self {
        case .unreadable(let f): return "login store unreadable (\(f)); not overwriting it"
        case .writeFailed(let d): return "couldn't save the login store: \(d)"
        case .lockTimeout(let f): return "timed out waiting for the login store's refresh lock (\(f))"
        }
    }
}

/// What `/state` and Settings › Models show about one login — no token data.
public struct SubscriptionLoginHealth: Equatable, Sendable {
    /// When the HOST last refreshed the real grant (nil: not since sign-in).
    public var lastRefreshedAt: Date?
    /// When the real access token expires.
    public var accessExpiresAt: Date?
    /// Set when the provider rejected the grant; only a new sign-in clears it.
    public var reauthRequiredAt: Date?
    /// The store's file exists but can't be read: every login in it is hidden
    /// and nothing is written until it reads again.
    public var storeUnreadable: Bool

    public init(lastRefreshedAt: Date?, accessExpiresAt: Date?,
                reauthRequiredAt: Date?, storeUnreadable: Bool) {
        self.lastRefreshedAt = lastRefreshedAt
        self.accessExpiresAt = accessExpiresAt
        self.reauthRequiredAt = reauthRequiredAt
        self.storeUnreadable = storeUnreadable
    }

    /// `/state` shape (seconds since 1970; absent = unknown / not set).
    public var stateJSON: [String: Any] {
        var d: [String: Any] = [:]
        if let lastRefreshedAt { d["lastRefreshedAt"] = lastRefreshedAt.timeIntervalSince1970 }
        if let accessExpiresAt { d["accessExpiresAt"] = accessExpiresAt.timeIntervalSince1970 }
        if let reauthRequiredAt { d["reauthRequiredAt"] = reauthRequiredAt.timeIntervalSince1970 }
        if storeUnreadable { d["storeUnreadable"] = true }
        return d
    }

    public init?(stateJSON d: [String: Any]) {
        func date(_ k: String) -> Date? { (d[k] as? Double).map(Date.init(timeIntervalSince1970:)) }
        guard d["lastRefreshedAt"] != nil || d["accessExpiresAt"] != nil
                || d["storeUnreadable"] != nil else { return nil }
        self.init(lastRefreshedAt: date("lastRefreshedAt"), accessExpiresAt: date("accessExpiresAt"),
                  reauthRequiredAt: date("reauthRequiredAt"),
                  storeUnreadable: (d["storeUnreadable"] as? Bool) ?? false)
    }
}

/// The at-rest half every subscription store (Claude, Codex, Grok, Kimi)
/// shares: one encrypted JSON file, safe against a second process (the CLI,
/// a fat client, a second app instance) using the same file.
///
///   * Reads re-validate the in-memory copy against the file's identity
///     (device, inode, size, mtime) and reload when another process
///     replaced it — a rotated token written elsewhere is seen at once.
///   * Read-modify-write runs under an advisory `flock` on a sidecar lock
///     file (`mutate`), and refreshes take a second, longer-lived lock
///     (`withRefreshLock`) so two processes never spend the same rotating
///     refresh token.
///   * A file that exists but can't be read is never overwritten: writes
///     throw ``SubscriptionStoreError/unreadable``, a copy is kept beside it,
///     and the condition is surfaced (``isUnreadable``).
///   * A write goes to disk first (temp file, 0600, fsync, rename); the
///     in-memory copy changes only once it landed.
///
/// Not thread-safe by itself: the owning store calls it under its own lock.
final class SubscriptionStoreFile<File: Codable> {
    let fileURL: URL
    private let tag: String
    private let makeEmpty: () -> File

    private struct Stamp: Equatable {
        var dev: Int64, ino: UInt64, size: Int64, mtimeSec: Int, mtimeNsec: Int
    }
    private var cache: File?
    private var stamp: Stamp?
    /// Set while the file exists but can't be read.
    private(set) var unreadableSince: Date?
    private var backedUp: Stamp?

    /// Test seam: fail the next writes (simulates a full / read-only disk).
    var failWritesForTesting = false

    init(fileURL: URL, tag: String, empty: @escaping () -> File) {
        self.fileURL = fileURL
        self.tag = tag
        self.makeEmpty = empty
    }

    var isUnreadable: Bool { unreadableSince != nil }

    private var lockURL: URL { fileURL.appendingPathExtension("lock") }
    var refreshLockURL: URL { fileURL.appendingPathExtension("refresh-lock") }

    // MARK: Read

    /// The current contents for a READ: reloaded when the file changed on
    /// disk. An unreadable file yields the last good copy this process saw
    /// (or empty) — never cached as empty.
    func read() -> File {
        (try? load()) ?? cache ?? makeEmpty()
    }

    /// The current contents for a WRITE: throws when the file can't be read,
    /// so the caller never replaces a store it couldn't see.
    func load() throws -> File {
        let fd = open(fileURL.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT {
                // No file (yet, or another process forgot the last login).
                if stamp != nil || cache == nil { cache = makeEmpty() }
                stamp = nil
                unreadableSince = nil
                return cache!
            }
            markUnreadable(nil, reason: String(cString: strerror(errno)))
            throw SubscriptionStoreError.unreadable(fileURL.lastPathComponent)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            markUnreadable(nil, reason: "fstat failed")
            throw SubscriptionStoreError.unreadable(fileURL.lastPathComponent)
        }
        let current = Self.stamp(st)
        if let cache, current == stamp { return cache }
        let blob = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard let plain = try? SecretsVault.decrypt(blob),
              let file = try? JSONDecoder().decode(File.self, from: plain)
        else {
            markUnreadable(current, reason: "couldn't decrypt or decode")
            throw SubscriptionStoreError.unreadable(fileURL.lastPathComponent)
        }
        cache = file
        stamp = current
        if unreadableSince != nil {
            FileHandle.standardError.write(Data(
                "[\(tag)] \(fileURL.lastPathComponent) readable again\n".utf8))
        }
        unreadableSince = nil
        return file
    }

    private func markUnreadable(_ at: Stamp?, reason: String) {
        if unreadableSince == nil {
            unreadableSince = Date()
            FileHandle.standardError.write(Data(
                "[\(tag)] login store \(fileURL.lastPathComponent) unreadable (\(reason)); logins hidden, writes refused until it reads again\n".utf8))
        }
        // Keep one copy of each unreadable version beside it, so a later
        // repair (or the right vault key) can still recover the logins.
        guard let at, backedUp != at else { return }
        backedUp = at
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let copy = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).unreadable-\(f.string(from: Date()))")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.copyItem(at: fileURL, to: copy)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: copy.path)
        }
    }

    private static func stamp(_ st: stat) -> Stamp {
        Stamp(dev: Int64(st.st_dev), ino: UInt64(st.st_ino), size: Int64(st.st_size),
              mtimeSec: st.st_mtimespec.tv_sec, mtimeNsec: st.st_mtimespec.tv_nsec)
    }

    // MARK: Write

    /// Read-modify-write under the cross-process file lock, against the
    /// file's CURRENT contents (another process's write is never lost).
    /// `body` returns false to skip the write. Returns what `body` returned.
    @discardableResult
    func mutate(_ body: (inout File) throws -> Bool) throws -> Bool {
        try withFileLock {
            var file = try load()
            guard try body(&file) else { return false }
            try persist(file)
            return true
        }
    }

    /// Encrypt + write to disk (temp file, 0600, fsync, rename), THEN adopt
    /// it in memory. Throws without touching the in-memory copy on failure.
    private func persist(_ file: File) throws {
        if failWritesForTesting { throw SubscriptionStoreError.writeFailed("simulated") }
        let blob: Data
        do {
            blob = try SecretsVault.encrypt(try JSONEncoder().encode(file))
        } catch { throw SubscriptionStoreError.writeFailed("\(error)") }
        let dir = fileURL.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw SubscriptionStoreError.writeFailed("\(error)") }
        let tmp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(getpid())-\(UUID().uuidString.prefix(8))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw SubscriptionStoreError.writeFailed(String(cString: strerror(errno)))
        }
        var ok = blob.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        let writeErr = String(cString: strerror(errno))
        close(fd)
        guard ok, rename(tmp.path, fileURL.path) == 0 else {
            let err = ok ? String(cString: strerror(errno)) : writeErr
            unlink(tmp.path)
            throw SubscriptionStoreError.writeFailed(err)
        }
        cache = file
        var st = stat()
        stamp = stat(fileURL.path, &st) == 0 ? Self.stamp(st) : nil
        unreadableSince = nil
    }

    /// Short critical section across processes (read-modify-write).
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            // Can't create the lock file (read-only dir…): the write below
            // will fail the same way and say so.
            return try body()
        }
        defer { close(fd) }   // closing drops the lock too
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// The cross-process lock a refresher holds around read → refresh → write
/// (a network round-trip, so it's polled, not blocked on).
enum SubscriptionRefreshLock {
    /// Default wait: longer than one refresh's network timeout (30 s).
    static let defaultTimeout: TimeInterval = 40

    /// Returns the held lock's descriptor; pass it to ``release(_:)``.
    static func acquire(_ url: URL, timeout: TimeInterval = defaultTimeout) async throws -> Int32 {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return -1 }   // no lock possible; proceed unlocked
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { close(fd); return -1 }
            if Date() >= deadline {
                close(fd)
                throw SubscriptionStoreError.lockTimeout(url.lastPathComponent)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return fd
    }

    static func release(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }
}
