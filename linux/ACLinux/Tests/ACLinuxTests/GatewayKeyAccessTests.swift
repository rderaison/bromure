import Foundation
import NIOSSH
import Testing
@testable import ACLinux

/// The multi-user gateway's key check: one snapshot of an account's keys
/// answers both "may it log in" and "only to attach its machine", so a
/// refetch that fails or no longer lists the key refuses it, never lets a
/// machine-only key in as a full one.
@Suite("Gateway key access", .serialized)
struct GatewayKeyAccessTests {
    static let full = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    static let machine = NIOSSHPrivateKey(ed25519Key: .init()).publicKey

    static func line(_ k: NIOSSHPublicKey, _ comment: String) -> String { String(openSSHPublicKey: k) + " " + comment }

    /// A stand-in daemon on `<dir>/<user>.sock` answering /remote/authorized-keys
    /// with whatever `keys` holds now (nil: an error reply).
    final class Keys: @unchecked Sendable {
        let lock = NSLock(); var lines: [String]?
        init(_ l: [String]?) { lines = l }
        var now: [String]? { lock.lock(); defer { lock.unlock() }; return lines }
        func set(_ l: [String]?) { lock.lock(); lines = l; lock.unlock() }
    }
    static func daemon(_ dir: String, _ user: String, _ keys: Keys) async throws -> ControlServer {
        try await ControlServer.start(path: dir + "/" + user + ".sock") { req in
            guard req.path == "/remote/authorized-keys", let l = keys.now else { return .error(500, "no keys") }
            return ControlResponse(200, ["keys": .array(l.map(JSONValue.string))])
        }
    }

    @Test func aFullKeyAndAMachineOnlyKeyFromOneLookup() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let keys = Keys([Self.line(Self.full, "bromure-account:devA"), Self.line(Self.machine, "bromure-account:machine:devM")])
        let srv = try await Self.daemon(dir, "alice", keys)
        let r = GatewayRouter(socketDir: dir)
        #expect(r.keyAccess(user: "alice", key: Self.full) == .full)
        #expect(r.keyAccess(user: "alice", key: Self.machine) == .machineOnly(device: "devM"))
        #expect(r.keyAccess(user: "alice", key: NIOSSHPrivateKey(ed25519Key: .init()).publicKey) == nil, "not one of its keys")
        #expect(r.keyAccess(user: "bob", key: Self.full) == nil, "no such account")
        await srv.close()
    }

    /// The fail-open the review found: the keys answered once, then the
    /// refetch (after the 3 s cache) fails, or no longer lists the key.
    @Test func aRefetchThatFailsOrDropsTheKeyRefusesIt() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let keys = Keys([Self.line(Self.machine, "bromure-account:machine:devM")])
        let srv = try await Self.daemon(dir, "alice", keys)
        let r = GatewayRouter(socketDir: dir)
        #expect(r.keyAccess(user: "alice", key: Self.machine) == .machineOnly(device: "devM"))
        keys.set(nil)                                   // the daemon now errors
        try await Task.sleep(for: .milliseconds(3300))  // past the cache
        #expect(r.keyAccess(user: "alice", key: Self.machine) == nil, "a failed refetch refuses, not .full")
        keys.set([Self.line(Self.full, "bromure-account:devA")])   // listed no more
        try await Task.sleep(for: .milliseconds(3300))
        #expect(r.keyAccess(user: "alice", key: Self.machine) == nil)
        #expect(r.keyAccess(user: "alice", key: Self.full) == .full)
        await srv.close()
        try await Task.sleep(for: .milliseconds(3300))
        #expect(r.keyAccess(user: "alice", key: Self.full) == nil, "no daemon answering: refused")
    }
}
