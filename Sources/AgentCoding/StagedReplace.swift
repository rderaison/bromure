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
            // a plain write's mode — the process's umask, not the usual one
            // assumed (CWE-732: under umask 077 that was world-readable).
            _ = chmod(staged, newFileMode(in: (dest as NSString).deletingLastPathComponent))
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
        makeReadable(staged)
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

    /// Write `staged`'s bytes into `dest` itself (its inode, links and
    /// metadata stay). It needs only what a plain upload needs, write access
    /// to `dest` (CWE-732): the staged file — this user's own — is made
    /// readable first, and `dest` is opened write-only. And it is never
    /// destructive (CWE-459): a new file that fails part-way is removed
    /// again, an existing one gets its old bytes back from a copy taken
    /// first (owner-only, beside `staged`; kept and named in the error if
    /// even that fails). A `dest` this user may not read (write-only 0200)
    /// can't be copied aside: it is written as a plain upload would, without.
    private static func writeInPlace(_ staged: String, into dest: String, create: Bool = false) -> String? {
        makeReadable(staged)
        if create {
            let fd = open(dest, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            if fd >= 0 {
                var ours = stat()
                let known = fstat(fd, &ours) == 0
                let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                let failure = copyAll(from: staged, to: out)
                try? out.close()
                if let failure {
                    if known { unlinkIfOurs(dest, ours) }
                    return failure
                }
                unlink(staged)
                return nil
            }
            guard errno == EEXIST else { return String(cString: strerror(errno)) }
        }
        let fd = open(dest, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? out.close() }
        // Set-id bits a write strips: read now, put back after (CWE-732).
        let kept = setIDMode(fd)
        var backup: String?
        let rfd = open(dest, O_RDONLY | O_CLOEXEC)
        if rfd >= 0 {
            close(rfd)
            let path = ((staged as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(".bromure-\(UUID().uuidString).old")
            let bfd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard bfd >= 0 else { return String(cString: strerror(errno)) }
            let old = FileHandle(fileDescriptor: bfd, closeOnDealloc: true)
            let copied = copyAll(from: dest, to: old)
            try? old.close()
            if let copied { unlink(path); return copied }
            backup = path
        } else if errno != EACCES && errno != EPERM {
            return String(cString: strerror(errno))
        }
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
            guard let backup else { return failure }
            if let again = fill(backup) {
                return "\(dest): the write failed (\(failure)) and its old contents couldn't be put back (\(again)); they are saved in \(backup)"
            }
            _ = restoreSetID(fd, kept, path: dest)   // the write's own error is the one to report
            unlink(backup)
            return failure
        }
        if let backup { unlink(backup) }
        if let failure = restoreSetID(fd, kept, path: dest) { return failure }
        unlink(staged)
        return nil
    }

    /// Remove `path` only while it is still the file this upload created
    /// (`ours`, that file's fstat): another writer may have put a file of
    /// its own at that name since — a rename lands there whatever we hold
    /// open — and that one isn't ours to delete (CWE-362).
    static func unlinkIfOurs(_ path: String, _ ours: stat) {
        var now = stat()
        guard lstat(path, &now) == 0, now.st_dev == ours.st_dev, now.st_ino == ours.st_ino else { return }
        unlink(path)
    }

    /// The staged file is this user's own, but may carry `dest`'s mode and
    /// ACL by now (`copyMetadata`, before a refused rename): write-only
    /// 0200, an ACL denying reading or deleting it. Readable and removable
    /// again, before it is read.
    private static func makeReadable(_ staged: String) {
        if let empty = acl_init(0) {
            _ = acl_set_file(staged, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        _ = chmod(staged, 0o600)
    }
}
#endif
