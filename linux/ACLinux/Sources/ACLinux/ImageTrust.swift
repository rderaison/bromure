import CACLinuxShims
import Foundation
import Glibc

/// An image's files as they're booted: each resolved, each checked.
// @port-skip linux-only: the Linux daemon's image trust check
public struct CheckedImage: Sendable, Equatable {
    public let dir: String
    public let kernel: String
    public let initrd: String
    public let baseImage: String
    public let cmdline: String
    public let kernelRelease: String
}

/// Whether an image dir only root or this user could have written, judged
/// on what would boot: the dir and each file by real path (a link's
/// target; one that can't be resolved refused), it and every directory
/// above it owned by root or this user, writable by no group and no one
/// else, with no POSIX ACL. A sticky root dir such as /tmp above it may be
/// writable by others (its entries are still ours or root's), but what's
/// under it must be on its file system (not a mount someone put there). A
/// file that isn't there is left to the boot to say so. A user's own image
/// is kept that way by the bake and the daemon (InterimBake
/// .clearSharedWrite, DaemonConfig.secureOwnImageDir), not let through.
// @port-skip linux-only: the Linux daemon's image trust check
public enum ImageTrust {
    // @port-skip linux-only: see ImageTrust
    public struct Problem: Error, Equatable, Sendable {
        public let path: String
        public let why: String
        /// What the user can do themselves, when the path is theirs.
        public let fix: String?
    }

    static let files = ["base.img", "vmlinuz", "initrd.img", "cmdline", "kernel-release"]

    // @port-skip linux-only: see ImageTrust
    public static func check(_ dir: String, uid: uid_t = getuid()) -> Result<CheckedImage, Problem> {
        guard let realDir = realPath(dir) else {
            return .failure(Problem(path: dir, why: "\(dir) can't be resolved (\(String(cString: strerror(errno))))", fix: nil))
        }
        if let p = judge(realDir, uid: uid) ?? ancestors(of: realDir, uid: uid) { return .failure(p) }
        var resolved: [String: String] = [:]
        for f in files {
            let path = realDir + "/" + f
            var st = stat()
            guard lstat(path, &st) == 0 else {
                if errno == ENOENT { resolved[f] = path; continue }   // missing: the boot says so
                return .failure(Problem(path: path, why: "\(path) can't be read (\(String(cString: strerror(errno))))", fix: nil))
            }
            guard let real = realPath(path) else {
                let why = errno == ENOENT ? "\(path) is a link to nothing" : "\(path) can't be resolved (\(String(cString: strerror(errno))))"
                return .failure(Problem(path: path, why: why, fix: st.st_uid == uid ? "replace the link \(path)" : nil))
            }
            if let p = judge(real, uid: uid) ?? ancestors(of: real, uid: uid) { return .failure(p) }
            resolved[f] = real
        }
        return .success(CheckedImage(dir: realDir, kernel: resolved["vmlinuz"]!, initrd: resolved["initrd.img"]!,
                                     baseImage: resolved["base.img"]!, cmdline: resolved["cmdline"]!,
                                     kernelRelease: resolved["kernel-release"]!))
    }

    /// One path: root's or this user's, writable by no group and no one
    /// else, no POSIX ACL.
    // @port-skip linux-only: see ImageTrust
    static func judge(_ path: String, uid: uid_t) -> Problem? {
        var st = stat()
        guard stat(path, &st) == 0 else {
            return Problem(path: path, why: "\(path) can't be read (\(String(cString: strerror(errno))))", fix: nil)
        }
        if st.st_uid != 0, st.st_uid != uid { return Problem(path: path, why: "\(path) belongs to uid \(st.st_uid)", fix: nil) }
        let mine = st.st_uid == uid
        if st.st_mode & 0o022 != 0 {
            return Problem(path: path, why: "\(path) is writable by its group or others", fix: mine ? "chmod go-w \(path)" : nil)
        }
        if hasACL(path) {
            return Problem(path: path, why: "\(path) has a POSIX ACL", fix: mine ? "setfacl -b \(path)" : nil)
        }
        return nil
    }

    /// Every directory above `path`, up to /: as `judge`, except that a
    /// sticky dir owned by root (/tmp) may be writable by others, so long
    /// as what's under it is on its file system.
    // @port-skip linux-only: see ImageTrust
    static func ancestors(of path: String, uid: uid_t) -> Problem? {
        var below = path
        var dir = (path as NSString).deletingLastPathComponent
        while true {
            var st = stat()
            guard stat(dir, &st) == 0 else {
                return Problem(path: dir, why: "\(dir) can't be read (\(String(cString: strerror(errno))))", fix: nil)
            }
            if st.st_uid == 0, st.st_mode & S_ISVTX != 0 {
                var child = stat()
                guard stat(below, &child) == 0, child.st_dev == st.st_dev else {
                    return Problem(path: below, why: "\(below) is another file system mounted under \(dir)", fix: nil)
                }
            } else if let p = judge(dir, uid: uid) {
                return p
            }
            if dir == "/" || dir.isEmpty { return nil }
            below = dir
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    /// Whether `path` carries a POSIX access ACL (named users or groups,
    /// or a mask: the group bits then aren't the group's); one that can't
    /// be read counts as one.
    // @port-skip linux-only: see ImageTrust
    static func hasACL(_ path: String) -> Bool {
        acl_has_access_acl(path) != 0
    }

    // @port-skip linux-only: see ImageTrust
    static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}
