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
            try audit(fd, path, owner: owner, depth: 0)
            FileHandle.standardError.write(Data("bromure-ac: \(path) was mode \(mode); made 0700 (its entries checked)\n".utf8))
        }
    }

    /// Every entry of directory `fd`: this user's and not a link; the
    /// entries under ssh-agents/ and vms/ (and theirs) too.
    // @port-skip linux-only: see SecureDir
    static func audit(_ fd: Int32, _ path: String, owner: uid_t, depth: Int) throws {
        guard depth < 8 else { throw Untrusted(path: path, why: "nested too deep to check") }
        let dup = Glibc.dup(fd)
        guard dup >= 0, let d = fdopendir(dup) else {
            if dup >= 0 { close(dup) }
            throw Untrusted(path: path, why: "can't list it to check its entries")
        }
        defer { closedir(d) }
        while let e = readdir(d) {
            let name = withUnsafePointer(to: e.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }   // gone meanwhile
            let entry = path + "/" + name
            guard (st.st_mode & S_IFMT) != S_IFLNK else { throw Untrusted(path: entry, why: "a symbolic link, in a directory others could write") }
            guard st.st_uid == owner else { throw Untrusted(path: entry, why: "owned by uid \(st.st_uid), in a directory others could write") }
            if (st.st_mode & S_IFMT) == S_IFDIR, depth > 0 || name == "ssh-agents" || name == "vms" {
                let sub = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard sub >= 0 else { throw Untrusted(path: entry, why: String(cString: strerror(errno))) }
                defer { close(sub) }
                try audit(sub, entry, owner: owner, depth: depth + 1)
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
