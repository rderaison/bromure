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
    }
}
