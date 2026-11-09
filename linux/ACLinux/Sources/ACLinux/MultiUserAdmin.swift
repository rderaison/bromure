import Foundation

/// `bromure-ac admin`: the multi-user server's users (root only). A Bromure
/// user is a Unix account with its own daemon, `bromure-ac@<name>`, started
/// on demand by its socket unit; the gateway reaches it by name.
// @port-skip linux-only: multi-user Linux server administration
public enum MultiUserAdmin {
    public static let socketDir = "/run/bromure-ac/sock"
    public static let stateRoot = "/var/lib/bromure-ac"

    public enum AdminError: Error, CustomStringConvertible {
        case notRoot, badName(String), noAccount(String), failed(String)
        // @port-skip linux-only: admin errors
        public var description: String {
            switch self {
            case .notRoot: return "bromure-ac admin must run as root"
            case .badName(let n): return "'\(n)' is not a valid account name (a-z, 0-9, _ and -, at most 32, not starting with -)"
            case .noAccount(let n): return "no Unix account '\(n)' (add it without --existing to create one)"
            case .failed(let m): return m
            }
        }
    }

    // @port-skip linux-only: admin
    public static func validName(_ n: String) -> Bool {
        // Not "sock": /run/bromure-ac/<name> is its runtime dir, and that one
        // holds every user's control socket.
        !n.isEmpty && n.count <= 32 && !n.hasPrefix("-") && n != "bromure" && n != "root" && n != "sock"
            && n.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }
    }

    // @port-skip linux-only: admin
    static func run(_ argv: [String]) async throws {
        do { try await ChildProcess.run(argv[0], Array(argv.dropFirst())) }
        catch { throw AdminError.failed("\(argv.joined(separator: " ")): \(error)") }
    }

    /// Adds `name`: a new system account (no login, no home of its own: its
    /// daemon's state is in /var/lib/bromure-ac/<name>), or an existing
    /// login account with `existing`; in group kvm; its socket unit enabled.
    // @port-skip linux-only: admin
    public static func add(_ name: String, existing: Bool) async throws -> String {
        guard getuid() == 0 else { throw AdminError.notRoot }
        guard validName(name) else { throw AdminError.badName(name) }
        if existing {
            guard getpwnam(name) != nil else { throw AdminError.noAccount(name) }
        } else if getpwnam(name) == nil {
            try await run(["/usr/sbin/useradd", "--system", "--user-group", "--no-create-home",
                           "--home-dir", stateRoot + "/" + name, "--shell", "/usr/sbin/nologin",
                           "--comment", "Bromure user " + name, name])
        }
        try await run(["/usr/sbin/usermod", "--append", "--groups", "kvm", name])
        try await run(["/usr/bin/systemctl", "enable", "--now", "bromure-ac@\(name).socket"])
        return "added \(name)\(existing ? " (existing account)" : ""): \(socketDir)/\(name).sock"
    }

    /// Stops and disables `name`'s daemon (its VMs with it). Its state stays
    /// unless `purge`; its account stays unless `deleteAccount`.
    // @port-skip linux-only: admin
    public static func remove(_ name: String, purge: Bool, deleteAccount: Bool) async throws -> String {
        guard getuid() == 0 else { throw AdminError.notRoot }
        guard validName(name) else { throw AdminError.badName(name) }
        try? await run(["/usr/bin/systemctl", "disable", "--now", "bromure-ac@\(name).socket", "bromure-ac@\(name).service"])
        // systemd leaves the socket file behind; the gateway reads its
        // presence as "this account exists".
        unlink(socketDir + "/" + name + ".sock")
        // Its runtime dir outlives a stop (RuntimeDirectoryPreserve=yes: the
        // boot-at-startup marker, serial logs, editor files): gone with the
        // daemon. systemd's own clean, else removed here (symlinks inside
        // are removed, not followed).
        try? await run(["/usr/bin/systemctl", "clean", "--what=runtime", "bromure-ac@\(name).service"])
        let runtime = "/run/bromure-ac/" + name
        if FileManager.default.fileExists(atPath: runtime) { try? FileManager.default.removeItem(atPath: runtime) }
        if purge { try? FileManager.default.removeItem(atPath: stateRoot + "/" + name) }
        if deleteAccount, getpwnam(name) != nil { try await run(["/usr/sbin/userdel", name]) }
        return "removed \(name)\(purge ? ", state deleted" : "")\(deleteAccount ? ", account deleted" : "")"
    }

    /// The users with a socket unit enabled.
    // @port-skip linux-only: admin
    public static func users() -> [String] {
        let wants = "/etc/systemd/system/sockets.target.wants"
        return ((try? FileManager.default.contentsOfDirectory(atPath: wants)) ?? [])
            .filter { $0.hasPrefix("bromure-ac@") && $0.hasSuffix(".socket") }
            .map { String($0.dropFirst("bromure-ac@".count).dropLast(".socket".count)) }.sorted()
    }

    /// One user's daemon over its socket (root is one of its allowed peers).
    // @port-skip linux-only: admin
    public static func request(_ name: String, _ method: String, _ path: String, _ body: JSONValue? = nil) throws -> JSONValue? {
        let r = try FirecrackerAPI.exchange(socketDir + "/" + name + ".sock", method, path, body, timeoutMs: 15_000)
        guard r.ok else { throw AdminError.failed("\(name): \(r.fault)") }
        return r.body
    }
}
