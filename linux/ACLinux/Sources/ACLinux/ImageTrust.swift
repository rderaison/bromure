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
/// on what would boot: each file's real path (a link's target; a dangling
/// link refused), the file and every directory above it owned by root or
/// this user and writable by no one else. Two exceptions: a group that's
/// the owner's alone (a user private group, Ubuntu's umask 002), and a
/// sticky root dir such as /tmp above it (the files are still ours or
/// root's). A file that isn't there is left to the boot to say so.
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
        var resolved: [String: String] = [:]
        guard let realDir = realPath(dir) else {
            return .success(CheckedImage(dir: dir, kernel: dir + "/vmlinuz", initrd: dir + "/initrd.img",
                                         baseImage: dir + "/base.img", cmdline: dir + "/cmdline",
                                         kernelRelease: dir + "/kernel-release"))
        }
        if let p = judge(realDir, uid: uid) ?? ancestors(of: realDir, uid: uid) { return .failure(p) }
        for f in files {
            let path = realDir + "/" + f
            var st = stat()
            guard lstat(path, &st) == 0 else { resolved[f] = path; continue }   // missing: the boot says so
            guard let real = realPath(path) else {
                return .failure(Problem(path: path, why: "\(path) is a link to nothing", fix: st.st_uid == uid ? "replace the link \(path)" : nil))
            }
            if let p = judge(real, uid: uid) ?? ancestors(of: real, uid: uid) { return .failure(p) }
            resolved[f] = real
        }
        return .success(CheckedImage(dir: realDir, kernel: resolved["vmlinuz"]!, initrd: resolved["initrd.img"]!,
                                     baseImage: resolved["base.img"]!, cmdline: resolved["cmdline"]!,
                                     kernelRelease: resolved["kernel-release"]!))
    }

    /// One path: root's or this user's, writable by no one else.
    // @port-skip linux-only: see ImageTrust
    static func judge(_ path: String, uid: uid_t, stickyAbove: Bool = false) -> Problem? {
        var st = stat()
        guard stat(path, &st) == 0 else { return Problem(path: path, why: "\(path) can't be read", fix: nil) }
        if st.st_uid != 0, st.st_uid != uid { return Problem(path: path, why: "\(path) belongs to uid \(st.st_uid)", fix: nil) }
        let mine = st.st_uid == uid
        if st.st_mode & 0o002 != 0 {
            return Problem(path: path, why: "\(path) is world-writable", fix: mine ? "chmod o-w \(path)" : nil)
        }
        if st.st_mode & 0o020 != 0, !privateGroup(gid: st.st_gid, owner: st.st_uid) {
            return Problem(path: path, why: "\(path) is writable by group \(st.st_gid)", fix: mine ? "chmod g-w \(path)" : nil)
        }
        return nil
    }

    /// Every directory above `path`, up to /: as `judge`, except that a
    /// sticky dir owned by root (/tmp) may be writable by others.
    // @port-skip linux-only: see ImageTrust
    static func ancestors(of path: String, uid: uid_t) -> Problem? {
        var dir = (path as NSString).deletingLastPathComponent
        while true {
            var st = stat()
            guard stat(dir, &st) == 0 else { return Problem(path: dir, why: "\(dir) can't be read", fix: nil) }
            let stickyRoot = st.st_uid == 0 && st.st_mode & S_ISVTX != 0
            if !stickyRoot, let p = judge(dir, uid: uid) { return p }
            if dir == "/" || dir.isEmpty { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    /// Whether `gid` is `owner`'s alone: their primary group, with no
    /// listed members but them, and no other user's primary group either
    /// (a getpwent scan). Only when the passwd database is local files
    /// (nsswitch): users from LDAP and the like can't be listed, so their
    /// groups aren't private.
    // @port-skip linux-only: see ImageTrust
    static func privateGroup(gid: gid_t, owner: uid_t) -> Bool {
        guard localUsersOnly(), let pw = getpwuid(owner), pw.pointee.pw_gid == gid, let gr = getgrgid(gid) else { return false }
        let name = String(cString: pw.pointee.pw_name)
        var m = gr.pointee.gr_mem
        while let p = m?.pointee {
            if String(cString: p) != name { return false }
            m = m?.advanced(by: 1)
        }
        setpwent()
        defer { endpwent() }
        while let other = getpwent() {
            if other.pointee.pw_gid == gid, other.pointee.pw_uid != owner { return false }
        }
        return true
    }

    /// Whether every passwd source nsswitch names is local (files, or
    /// systemd's dynamic users), so getpwent lists every user.
    // @port-skip linux-only: see ImageTrust
    static func localUsersOnly(nsswitch: String = "/etc/nsswitch.conf") -> Bool {
        guard let text = try? String(contentsOfFile: nsswitch, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n") {
            let l = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let parts = l.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "passwd" else { continue }
            let sources = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.hasPrefix("[") }
            return !sources.isEmpty && sources.allSatisfy { ["files", "systemd", "compat"].contains(String($0)) }
        }
        return false
    }

    // @port-skip linux-only: see ImageTrust
    static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}
