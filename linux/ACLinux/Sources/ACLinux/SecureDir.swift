import Foundation

/// Directories a Linux server's processes trust: opened without following a
/// link, owned by this user (root's by root), and writable by nobody else,
/// each step from a directory fd so nothing can be swapped in between. The
/// runtime dir's fallback is under /tmp (`/tmp/bromure-ac-<uid>/bromure-ac`),
/// where another local user could create the parent first.
// @port-skip linux-only: a shared server's /tmp fallback (macOS keeps its sockets under ~/Library)
enum SecureDir {
    struct Untrusted: Error, CustomStringConvertible {
        let path: String, why: String
        // @port-skip linux-only: see SecureDir
        var description: String { "refusing \(path): \(why)" }
    }

    /// An open fd of directory `path` (made 0700 when `create` and missing;
    /// its own parents too, unchecked), checked.
    // @port-skip linux-only: see SecureDir
    static func open(_ path: String, create: Bool) throws -> Int32 {
        if create, access(path, F_OK) != 0 {
            let parent = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            if mkdir(path, 0o700) != 0 && errno != EEXIST { throw Untrusted(path: path, why: String(cString: strerror(errno))) }
        }
        let fd = Glibc.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Untrusted(path: path, why: errno == ELOOP ? "a symbolic link" : String(cString: strerror(errno))) }
        do { try check(fd, path) } catch { close(fd); throw error }
        return fd
    }

    /// `name` inside the checked directory `dir` (made 0700 when `create`).
    // @port-skip linux-only: see SecureDir
    static func openAt(_ dir: Int32, _ name: String, create: Bool, path: String) throws -> Int32 {
        if create, mkdirat(dir, name, 0o700) != 0, errno != EEXIST {
            throw Untrusted(path: path, why: String(cString: strerror(errno)))
        }
        let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Untrusted(path: path, why: errno == ELOOP ? "a symbolic link" : String(cString: strerror(errno))) }
        do { try check(fd, path) } catch { close(fd); throw error }
        return fd
    }

    // @port-skip linux-only: see SecureDir
    static func check(_ fd: Int32, _ path: String) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Untrusted(path: path, why: String(cString: strerror(errno))) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Untrusted(path: path, why: "not a directory") }
        guard st.st_uid == getuid() else { throw Untrusted(path: path, why: "owned by uid \(st.st_uid), not this user") }
        guard st.st_mode & 0o022 == 0 else {
            throw Untrusted(path: path, why: "writable by its group or others (mode \(String(st.st_mode & 0o7777, radix: 8)))")
        }
    }

    /// The runtime dir, from its parent (XDG_RUNTIME_DIR, or the /tmp
    /// fallback) down: an fd of `runtimeDir`, both levels checked.
    // @port-skip linux-only: see SecureDir
    static func runtime(_ runtimeDir: String, create: Bool) throws -> Int32 {
        let parent = (runtimeDir as NSString).deletingLastPathComponent
        let p = try open(parent, create: create)
        defer { close(p) }
        return try openAt(p, (runtimeDir as NSString).lastPathComponent, create: create, path: runtimeDir)
    }

    /// Runs `body` on a thread of its own (blocking work off the cooperative pool).
    // @port-skip linux-only: Linux daemon plumbing
    static func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in
            let t = Thread { c.resume(returning: body()) }
            t.stackSize = 1 << 20
            t.start()
        }
    }
}
