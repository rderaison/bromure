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
            // a plain write's mode (0644 under the usual umask).
            _ = chmod(staged, 0o644)
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

    /// The open file's mode when it has set-user-ID / set-group-ID bits —
    /// what a write by a user who isn't root strips (macOS, as Linux) —
    /// read before the write; nil when there are none to keep.
    static func setIDMode(_ fd: Int32) -> mode_t? {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & 0o6000 != 0 else { return nil }
        return st.st_mode & 0o7777
    }

    /// Put back the set-id bits the write stripped, through the same
    /// descriptor. nil when the file has its mode again; otherwise why not:
    /// the bytes are in, but it isn't the file it was (CWE-732), so the
    /// upload says so rather than succeed.
    static func restoreSetID(_ fd: Int32, _ kept: mode_t?, path: String) -> String? {
        guard let kept else { return nil }
        var st = stat()
        if fstat(fd, &st) == 0, st.st_mode & 0o7777 == kept { return nil }
        _ = fchmod(fd, kept)
        if fstat(fd, &st) == 0, st.st_mode & 0o7777 == kept { return nil }
        return "\(path) was written, but its set-user-ID/set-group-ID permissions were cleared and could not be restored"
    }

    private static func writeInPlace(_ staged: String, into dest: String, create: Bool = false) -> String? {
        if create, !FileManager.default.fileExists(atPath: dest) {
            FileManager.default.createFile(atPath: dest, contents: nil)
        }
        guard let src = FileHandle(forReadingAtPath: staged),
              let out = FileHandle(forUpdatingAtPath: dest) else { return String(cString: strerror(errno)) }
        defer { try? src.close(); try? out.close() }
        let kept = setIDMode(out.fileDescriptor)
        do {
            while let chunk = try src.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try out.truncate(atOffset: try out.offset())
            try out.synchronize()
        } catch {
            return error.localizedDescription
        }
        if let failure = restoreSetID(out.fileDescriptor, kept, path: dest) { return failure }
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
