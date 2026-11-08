import Foundation
import Testing
@testable import bromure_ac

/// The account's device keys are written into authorized_keys next to the
/// user's own. Whatever the control plane sends, that write adds one key per
/// device, tagged, and never loses a manual key.
@Suite("Account-managed authorized_keys")
@MainActor
struct ManagedKeysTests {
    private static let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    private static let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGtsTzvvQ5FeJcp8ImC9WVt7ivsLX9ocPyXR7VfmE/3T"
    private static let manual = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFtJ0lcLfEdBz2C1wJrrq0VTW4Y8UbH5LXqQqyVJ5Ok/ me@laptop"

    private func server() throws -> (RemoteAccessServer, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (RemoteAccessServer(paths: .init(dir: dir)), dir.appendingPathComponent("authorized_keys"))
    }

    @Test("a device id can't break the comment into a second key")
    func deviceIDSanitized() {
        let evil = ControlPlaneClient.DeviceSSHKey(id: "x\n\(Self.keyB) pwn", name: nil,
                                                   sshPublicKey: Self.keyA, capability: nil)
        #expect(evil.authorizedKeysComment == "bromure-account:x_ssh-ed25519_AAAAC3NzaC1lZDI1NTE5AAAAIGtsTzvvQ5FeJcp8ImC9WVt7ivsLX9ocPyXR7VfmE_3T_pwn")
        let host = ControlPlaneClient.DeviceSSHKey(id: "3F2A-b.c_d", name: nil, sshPublicKey: Self.keyA, capability: "agent-host")
        #expect(host.authorizedKeysComment == "bromure-account:machine:3F2A-b.c_d")
    }

    @Test("a managed line with a line break or control character is never written")
    func lineBreaksRefused() throws {
        let (srv, file) = try server()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try (Self.manual + "\n").write(to: file, atomically: true, encoding: .utf8)
        for sep in ["\n", "\r", "\u{2028}", "\u{85}", "\u{0B}", "\u{00}"] {
            srv.setManagedKeys(marker: "bromure-account:",
                               lines: ["\(Self.keyA) bromure-account:x\(sep)\(Self.keyB) pwn"])
            let body = try String(contentsOf: file, encoding: .utf8)
            #expect(!body.contains(Self.keyB), "separator \(sep.unicodeScalars.first!.value)")
            #expect(body.contains(Self.manual))
        }
        srv.setManagedKeys(marker: "bromure-account:", lines: ["\(Self.keyA) bromure-account:dev1"])
        let body = try String(contentsOf: file, encoding: .utf8)
        #expect(body == Self.manual + "\n" + Self.keyA + " bromure-account:dev1\n")
    }

    @Test("an authorized_keys that can't be read is left alone, manual keys and all")
    func unreadableFileKept() throws {
        let (srv, file) = try server()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var bytes = Data((Self.manual + " caf").utf8)
        bytes.append(0xE9)   // Latin-1 é: not UTF-8
        bytes.append(Data("\n".utf8))
        try bytes.write(to: file)
        srv.setManagedKeys(marker: "bromure-account:", lines: ["\(Self.keyA) bromure-account:dev1"])
        #expect(try Data(contentsOf: file) == bytes)
        // Nor rewritten from nothing by a manual add or remove.
        #expect(throws: RemoteAccessServer.RemoteError.self) { try srv.addAuthorizedKey(Self.keyB) }
        #expect(throws: RemoteAccessServer.RemoteError.self) { try srv.removeAuthorizedKey("1") }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(srv.authorizedKeysProblem?.contains("can't be read") == true)
    }

    /// The finding (CWE-863): when authorized_keys stopped being readable, the
    /// sync left the file alone but skipped the live listener's reload too, so
    /// it kept the keys it had read before: a device taken off the account
    /// could still sign in, until a restart.
    @Test("a running listener lets no key in it can't read, and takes the file back once fixed")
    func liveFailsClosed() throws {
        let (srv, file) = try server()
        defer { srv.stop(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try (Self.manual + "\n" + Self.keyA + " bromure-account:dev1\n").write(to: file, atomically: true, encoding: .utf8)
        var started = false
        for _ in 0..<5 where !started {
            started = (try? srv.start(.init(port: Int.random(in: 40_000...60_000), bindAddress: "127.0.0.1",
                                            passwordAuth: false, pubkeyAuth: true))) != nil
        }
        try #require(started)
        #expect(srv.liveAuthorizedKeys.count == 2)

        // The file goes bad, then the account drops dev1.
        var bytes = try Data(contentsOf: file)
        bytes.append(0xE9)
        try bytes.write(to: file)
        srv.setManagedKeys(marker: "bromure-account:", lines: [])
        #expect(srv.liveAuthorizedKeys.isEmpty, "a revoked device's key still lets it in")
        #expect(try Data(contentsOf: file) == bytes)   // left for the user to fix
        #expect(srv.authorizedKeysProblem != nil)

        // Fixed, the account's keys unchanged: the listener takes it back.
        try (Self.manual + "\n" + Self.keyA + " bromure-account:dev1\n").write(to: file, atomically: true, encoding: .utf8)
        srv.setManagedKeys(marker: "bromure-account:", lines: ["\(Self.keyA) bromure-account:dev1"])
        #expect(srv.liveAuthorizedKeys.count == 2)
        bytes = try Data(contentsOf: file); bytes.append(0xE9); try bytes.write(to: file)
        srv.setManagedKeys(marker: "bromure-account:", lines: [])
        #expect(srv.liveAuthorizedKeys.isEmpty)

        // Fixed: the next sync reconciles it, and the manual key is back.
        try (Self.manual + "\n" + Self.keyA + " bromure-account:dev1\n").write(to: file, atomically: true, encoding: .utf8)
        srv.setManagedKeys(marker: "bromure-account:", lines: [])
        #expect(srv.liveAuthorizedKeys.count == 1)
        #expect(srv.authorizedKeysProblem == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == Self.manual + "\n")

        // A (re)start says so too: on a bad file, and clears it on a good one.
        var bad = try Data(contentsOf: file); bad.append(0xE9); try bad.write(to: file)
        let port = Int.random(in: 40_000...60_000)
        try? srv.start(.init(port: port, bindAddress: "127.0.0.1", passwordAuth: false, pubkeyAuth: true))
        #expect(srv.authorizedKeysProblem != nil)
        try (Self.manual + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? srv.start(.init(port: port + 1, bindAddress: "127.0.0.1", passwordAuth: false, pubkeyAuth: true))
        #expect(srv.authorizedKeysProblem == nil)
    }
}
