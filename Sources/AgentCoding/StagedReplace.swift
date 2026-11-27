#if os(macOS)
import Foundation
import Darwin

/// An upload's last step on a Mac (HostExec's file op `rename`, the twin of
/// bromure-agentd.py's `_replace_staged`): put the complete file `staged`
/// (beside `dest`, same volume) in place of `dest`.
///
/// A new destination is a rename. An existing one is too, once the staged
/// file carries everything the file had besides its bytes: owner and group,
/// mode, ACL and every extended attribute (copyfile's COPYFILE_SECURITY |
/// COPYFILE_XATTR). Where that can't be reproduced (an owner this user can't
/// give), the rename is refused (an ACL that denies deleting the file) or the
/// file has other hard links, a rename would change it or can't, so its
/// own inode gets the new bytes instead: its metadata and its links stay as
/// they are, the upload no longer atomic there (the staged copy is complete
/// and local, so only a full disk can stop it part-way).
enum StagedReplace {
    /// nil when `dest` holds the new contents, otherwise why not.
    static func replace(_ staged: String, onto dest: String) -> String? {
        var st = stat()
        guard stat(dest, &st) == 0 else {
            // The staged file is owner-only while it fills: a new file gets
            // a plain write's mode — the process's umask, not the usual one
            // assumed (CWE-732: under umask 077 that was world-readable).
            _ = chmod(staged, newFileMode(in: (dest as NSString).deletingLastPathComponent))
            if Darwin.rename(staged, dest) == 0 { return nil }
            // A dangling symlink into another volume (EXDEV), or a busy
            // target: write it through, as a plain write did.
            let e = errno
            guard e == EXDEV || e == EBUSY else { return String(cString: strerror(e)) }
            return writeInPlace(staged, into: dest, create: true)
        }
        if st.st_nlink > 1 || !copyMetadata(from: dest, to: staged, expected: st) {
            return writeInPlace(staged, into: dest)
        }
        if Darwin.rename(staged, dest) == 0 { return nil }
        // Refused (an ACL that denies deleting the file, say): the file's own
        // permissions may still allow writing it, as a plain write did. So
        // too a symlink's target on another volume (EXDEV) or a busy file,
        // which can't be renamed onto from beside the link.
        let e = errno
        guard e == EACCES || e == EPERM || e == EXDEV || e == EBUSY else { return String(cString: strerror(e)) }
        return writeInPlace(staged, into: dest)
    }

    /// The mode a plain write would give a new file in `dir`: a probe file
    /// created there the normal way (0666 and the umask; there is no call
    /// that reads the umask without setting it, under other threads), then
    /// removed. Owner-only when no file can be made there.
    static func newFileMode(in dir: String) -> mode_t {
        let probe = (dir as NSString).appendingPathComponent(".bromure-\(UUID().uuidString).mode")
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { return 0o600 }
        defer { close(fd); unlink(probe) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return 0o600 }
        return st.st_mode & 0o777
    }

    private static func copyMetadata(from src: String, to dst: String, expected st: stat) -> Bool {
        // The staged file's own attributes go first: the result is exactly
        // the destination's set.
        let size = listxattr(dst, nil, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            let n = listxattr(dst, &buf, size, XATTR_NOFOLLOW)
            if n > 0 {
                for name in String(decoding: buf[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    .split(separator: "\0") {
                    _ = removexattr(dst, String(name), XATTR_NOFOLLOW)
                }
            }
        }
        guard copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR)) == 0 else { return false }
        // copyfile doesn't fail when it can't give the owner: check.
        var got = stat()
        guard stat(dst, &got) == 0 else { return false }
        return got.st_uid == st.st_uid && got.st_gid == st.st_gid
            && (got.st_mode & 0o7777) == (st.st_mode & 0o7777)
    }

    private static func writeInPlace(_ staged: String, into dest: String, create: Bool = false) -> String? {
        if create, !FileManager.default.fileExists(atPath: dest) {
            FileManager.default.createFile(atPath: dest, contents: nil)
        }
        guard let src = FileHandle(forReadingAtPath: staged),
              let out = FileHandle(forUpdatingAtPath: dest) else { return String(cString: strerror(errno)) }
        defer { try? src.close(); try? out.close() }
        do {
            while let chunk = try src.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try out.truncate(atOffset: try out.offset())
            try out.synchronize()
        } catch {
            return error.localizedDescription
        }
        // The staged copy may carry the destination's ACL by now (copied
        // before a refused rename), one that denies deleting it: drop it.
        if let empty = acl_init(0) {
            _ = acl_set_file(staged, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        unlink(staged)
        return nil
    }
}
#endif
