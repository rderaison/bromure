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
    /// `across`: a target on another volume may be staged again over
    /// there (never twice).
    static func replace(_ staged: String, onto dest: String, across: Bool = true) -> String? {
        var st = stat()
        guard stat(dest, &st) == 0 else {
            // The staged file is owner-only while it fills: a new file gets
            // a plain write's mode (0644 under the usual umask).
            _ = chmod(staged, 0o644)
            if Darwin.rename(staged, dest) == 0 { return nil }
            // A dangling symlink into another volume (EXDEV): staged again
            // over there, then renamed. A busy target: written through, as
            // a plain write did.
            let e = errno
            guard e == EXDEV || e == EBUSY else { return String(cString: strerror(e)) }
            if e == EXDEV, across, let done = replaceAcross(staged, onto: dest) { return done.failure }
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
        // Across volumes: staged again on the target's own, so it still
        // lands in one step (CWE-459).
        if e == EXDEV, across, let done = replaceAcross(staged, onto: dest) { return done.failure }
        return writeInPlace(staged, into: dest)
    }

    /// The outcome of a step that ran: nil `failure` when it worked.
    struct Done { var failure: String? }

    /// `dest` is on another volume than `staged` (a symlink's target): copy
    /// `staged` to a fresh file beside `dest`, on its volume, and replace
    /// `dest` from there — in one step, as on the same volume. A copy that
    /// fails (a full disk, a read error) leaves `dest` untouched (CWE-459).
    /// nil when no file can be made there (the folder isn't writable): the
    /// caller writes in place, with a backup.
    private static func replaceAcross(_ staged: String, onto dest: String) -> Done? {
        let tmp = ((dest as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".bromure-\(UUID().uuidString).part")
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let copied = copyAll(from: staged, to: out)
        try? out.close()
        if let copied { unlink(tmp); return Done(failure: copied) }
        if let failure = replace(tmp, onto: dest, across: false) {
            unlink(tmp)
            return Done(failure: failure)
        }
        unlink(staged)
        return Done(failure: nil)
    }

    /// `src`'s bytes, written from `out`'s offset on; nil when all went.
    private static func copyAll(from src: String, to out: FileHandle) -> String? {
        guard let input = FileHandle(forReadingAtPath: src) else { return String(cString: strerror(errno)) }
        defer { try? input.close() }
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
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

    /// Write `staged`'s bytes into `dest` itself (its inode, links and
    /// metadata stay). Not atomic, so never destructive either: a new file
    /// that fails part-way is removed again, and an existing one gets its
    /// old bytes back from a copy taken first (CWE-459) — a full disk, a
    /// refused write, a read error on `staged` leave `dest` as it was. The
    /// copy is owner-only, beside `staged`; if even putting it back fails,
    /// it is kept and the error names it.
    private static func writeInPlace(_ staged: String, into dest: String, create: Bool = false) -> String? {
        if create {
            let fd = open(dest, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            if fd >= 0 {
                let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                let failure = copyAll(from: staged, to: out)
                try? out.close()
                if let failure { unlink(dest); return failure }
                unlink(staged)
                return nil
            }
            guard errno == EEXIST else { return String(cString: strerror(errno)) }
        }
        guard let out = FileHandle(forUpdatingAtPath: dest) else { return String(cString: strerror(errno)) }
        defer { try? out.close() }
        let backup = ((staged as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".bromure-\(UUID().uuidString).old")
        let bfd = open(backup, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard bfd >= 0 else { return String(cString: strerror(errno)) }
        let old = FileHandle(fileDescriptor: bfd, closeOnDealloc: true)
        defer { try? old.close() }
        if let failure = copyAll(from: dest, to: old) { unlink(backup); return failure }
        func fill(_ from: String) -> String? {
            do {
                try out.seek(toOffset: 0)
                if let failure = copyAll(from: from, to: out) { return failure }
                try out.truncate(atOffset: try out.offset())
                try out.synchronize()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if let failure = fill(staged) {
            if let again = fill(backup) {
                return "\(dest): the write failed (\(failure)) and its old contents couldn't be put back (\(again)); they are saved in \(backup)"
            }
            unlink(backup)
            return failure
        }
        unlink(backup)
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
