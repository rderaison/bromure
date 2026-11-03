import CACLinuxShims
import Crypto
import Foundation

/// The Linux side of the shared SSH server's password check
/// (SystemPassword.verify in _shared/RemoteSSHHandlers.swift): a fat client
/// that has no enrolled key yet logs in once with a password, then enrolls its
/// key over the control API. Accepted:
/// - a one-time enrollment code (`bromure-ac remote code`): shown on the
///   server, single use, short-lived, kept only as a hash;
/// - the account password of the user running the daemon, through PAM
///   (service `bromure-ac`; without /etc/pam.d/bromure-ac PAM uses "other").
///   An unprivileged process can check its own user's password: pam_unix
///   asks the setuid unix_chkpwd helper.
// @port-skip linux-only: macOS verifies against OpenDirectory (SystemPassword)
enum LinuxAccountPassword {
    // @port-skip linux-only: password check
    static func verify(user: String, password: String) -> Bool {
        if EnrollmentCodes.consume(password) { return true }
        return acl_pam_check("bromure-ac", user, password) == 0
    }
}

/// One-time enrollment codes in `<remote dir>/enroll-codes`: one
/// `<sha256 hex> <expiry unix time>` per line, 0600, rewritten under flock.
// @port-skip linux-only: enrollment codes stand in for the Mac account password
enum EnrollmentCodes {
    /// No 0/O, 1/I/L: read off a screen and typed on a phone.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    // @port-skip linux-only: enrollment codes
    static var defaultPath: String {
        RemoteAccessServer.Paths.default.dir.appendingPathComponent("enroll-codes").path
    }

    /// A new code valid for `lifetime`, e.g. `K7QM-2HXP-9TRA-WD4N` (80 bits).
    // @port-skip linux-only: enrollment codes
    static func create(lifetime: Duration = .seconds(600), path: String = defaultPath,
                       now: Date = Date()) throws -> String {
        var rng = SystemRandomNumberGenerator()
        let raw = (0..<16).map { _ in alphabet[Int(rng.next(upperBound: UInt32(alphabet.count)))] }
        let code = stride(from: 0, to: 16, by: 4).map { String(raw[$0..<$0 + 4]) }.joined(separator: "-")
        let expiry = now.timeIntervalSince1970 + Double(lifetime.components.seconds)
        try update(path) { lines in
            lines.append("\(hash(code)) \(Int(expiry))")
        }
        return code
    }

    /// Whether `candidate` is a live code; if so it is used up. Expired
    /// codes are dropped on the way.
    // @port-skip linux-only: enrollment codes
    static func consume(_ candidate: String, path: String = defaultPath, now: Date = Date()) -> Bool {
        let h = hash(normalize(candidate))
        var found = false
        guard FileManager.default.fileExists(atPath: path) else { return false }
        try? update(path) { lines in
            lines = lines.filter { line in
                let f = line.split(separator: " ")
                guard f.count == 2, let exp = Double(f[1]), exp > now.timeIntervalSince1970 else { return false }
                if !found && constantTimeEqual(String(f[0]), h) { found = true; return false }
                return true
            }
        }
        return found
    }

    /// Case and dashes don't matter; a phone keyboard capitalizes or not.
    // @port-skip linux-only: enrollment codes
    static func normalize(_ s: String) -> String {
        let c = s.uppercased().filter { $0 != "-" && $0 != " " }
        guard c.count == 16 else { return c }
        let a = Array(c)
        return stride(from: 0, to: 16, by: 4).map { String(a[$0..<$0 + 4]) }.joined(separator: "-")
    }

    // @port-skip linux-only: enrollment codes
    static func hash(_ code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // @port-skip linux-only: enrollment codes
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Read-modify-write of the code file under an exclusive flock.
    // @port-skip linux-only: enrollment codes
    static func update(_ path: String, _ body: (inout [String]) -> Void) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MachineError.io("open \(path)", errno) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MachineError.io("flock \(path)", errno) }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var lines = String(decoding: try fh.readToEnd() ?? Data(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        body(&lines)
        let out = Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else { throw MachineError.io("rewrite \(path)", errno) }
        try fh.write(contentsOf: out)
    }
}
