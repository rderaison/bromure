import Foundation

/// Directories a Linux server's processes trust: opened without following a
/// link, owned by this user (root's by root), and writable by nobody else
/// (one of ours only its group could write, from an earlier daemon's umask,
/// is made 0700 once nothing planted is found in it),
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
    static func check(_ fd: Int32, _ path: String, owner: uid_t = getuid()) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Untrusted(path: path, why: String(cString: strerror(errno))) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Untrusted(path: path, why: "not a directory") }
        guard st.st_uid == owner else { throw Untrusted(path: path, why: "owned by uid \(st.st_uid), not this user") }
        let mode = String(st.st_mode & 0o7777, radix: 8)
        // Anyone could have planted anything: refused.
        guard st.st_mode & 0o002 == 0 else { throw Untrusted(path: path, why: "writable by others (mode \(mode))") }
        // Only the group could write it (made by an earlier daemon under a
        // 0002 umask): taken back to 0700, then trusted only if nothing in
        // it was planted -- every entry this user's and none a link (inside
        // ssh-agents/ and vms/ too). Nothing is removed: adopted VMs may be
        // using it.
        if st.st_mode & 0o020 != 0 {
            guard fchmod(fd, 0o700) == 0 else {
                throw Untrusted(path: path, why: "writable by its group (mode \(mode)) and can't be made 0700: \(String(cString: strerror(errno)))")
            }
            do {
                try audit(fd, path, owner: owner, depth: 0)
            } catch {
                // Its mode back: the next start finds it as it was, and checks again.
                _ = fchmod(fd, st.st_mode & 0o7777)
                throw error
            }
            FileHandle.standardError.write(Data("bromure-ac: \(path) was mode \(mode); made 0700 (its entries checked)\n".utf8))
        }
    }

    /// Every entry of directory `fd` (made 0700 by the caller, so nothing can
    /// be added meanwhile): this user's, not a link, and no longer writable
    /// by its group or others; every subdirectory, locked the same way
    /// before its own entries are checked (an fd to it someone kept open
    /// can't plant anything after that).
    // @port-skip linux-only: see SecureDir
    static func audit(_ fd: Int32, _ path: String, owner: uid_t, depth: Int) throws {
        guard depth < 16 else { throw Untrusted(path: path, why: "nested too deep to check") }
        let dup = Glibc.dup(fd)
        guard dup >= 0, let d = fdopendir(dup) else {
            if dup >= 0 { close(dup) }
            throw Untrusted(path: path, why: "can't list it to check its entries")
        }
        defer { closedir(d) }
        while true {
            errno = 0
            guard let e = readdir(d) else {
                if errno != 0 { throw Untrusted(path: path, why: "listing it failed: \(String(cString: strerror(errno)))") }
                break
            }
            let name = withUnsafePointer(to: e.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            if name == "." || name == ".." { continue }
            let entry = path + "/" + name
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }   // gone meanwhile
                throw Untrusted(path: entry, why: String(cString: strerror(errno)))
            }
            let kind = st.st_mode & S_IFMT
            guard kind != S_IFLNK else { throw Untrusted(path: entry, why: "a symbolic link, in a directory others could write") }
            guard st.st_uid == owner else { throw Untrusted(path: entry, why: "owned by uid \(st.st_uid), in a directory others could write") }
            if kind == S_IFDIR {
                let sub = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard sub >= 0 else { throw Untrusted(path: entry, why: String(cString: strerror(errno))) }
                defer { close(sub) }
                // Owner-only, as the daemon makes its own (0700).
                if st.st_mode & 0o077 != 0, fchmod(sub, st.st_mode & 0o7700) != 0 {
                    throw Untrusted(path: entry, why: "writable by its group or others and can't be fixed: \(String(cString: strerror(errno)))")
                }
                try audit(sub, entry, owner: owner, depth: depth + 1)
            } else if st.st_mode & 0o022 != 0 {
                // Its directory is ours alone now: the name can't be swapped.
                if fchmodat(fd, name, st.st_mode & 0o7755, 0) != 0 {
                    throw Untrusted(path: entry, why: "writable by its group or others and can't be fixed: \(String(cString: strerror(errno)))")
                }
            }
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
