import Crypto
import Foundation
import Testing
@testable import bromure_ac

// The PEM decoder is the migration hinge: every Mac paired before the fat
// client moved to the in-process NIOSSH dialer has its enrolled identity
// stored as an OpenSSH PEM (minted by ssh-keygen). If this can't recover the
// seed, that Mac silently loses its identity and has to password-re-pair.
@Suite("OpenSSH ed25519 key format")
struct OpenSSHKeyFormatTests {

    @Test("encode → decode round-trips the seed")
    func roundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pem = OpenSSHKeyFormat.ed25519PEM(seed: key.rawRepresentation,
                                              publicKey: key.publicKey.rawRepresentation,
                                              comment: "bromure-ac-fatclient")
        let seed = try #require(OpenSSHKeyFormat.ed25519Seed(
            fromPEM: String(decoding: pem, as: UTF8.self)))
        #expect(seed == key.rawRepresentation)
        // And the recovered key really is the same identity.
        let restored = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        #expect(restored.publicKey.rawRepresentation == key.publicKey.rawRepresentation)
    }

    @Test("decodes a real ssh-keygen key, and its public line matches")
    func decodesSSHKeygenKey() throws {
        // The actual on-disk format of every pre-existing fat-client identity.
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: "/usr/bin/ssh-keygen") else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bromure-keytest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("id_ed25519")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-t", "ed25519", "-N", "", "-C", "bromure-ac-fatclient", "-f", path.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return }

        let pem = try String(contentsOf: path, encoding: .utf8)
        let seed = try #require(OpenSSHKeyFormat.ed25519Seed(fromPEM: pem),
                                "could not decode an ssh-keygen ed25519 key")
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)

        // The public half we derive must equal what ssh-keygen wrote — this is
        // what the remote has in authorized_keys.
        let expected = try String(contentsOf: path.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ours = SSHKeyWire.opensshPublicLine(key.publicKey, comment: "bromure-ac-fatclient")
        #expect(ours == expected)
        // Fingerprints agree too (the unpair selector).
        #expect(SSHKeyWire.fingerprint(ofPublicLine: ours)
                == SSHKeyWire.fingerprint(ofPublicLine: expected))
    }

    @Test("rejects garbage and encrypted keys instead of returning junk")
    func rejectsBadInput() {
        #expect(OpenSSHKeyFormat.ed25519Seed(fromPEM: "") == nil)
        #expect(OpenSSHKeyFormat.ed25519Seed(fromPEM: "not a key at all") == nil)
        // Valid base64, wrong magic.
        let bogus = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + Data("totally-not-openssh".utf8).base64EncodedString()
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
        #expect(OpenSSHKeyFormat.ed25519Seed(fromPEM: bogus) == nil)
        // A passphrase-protected key: right magic, but the private section is
        // ciphertext — there is no seed to recover, so it must not guess.
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen") else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bromure-keytest-enc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("id_ed25519")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-t", "ed25519", "-N", "hunter2", "-f", path.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        if let pem = try? String(contentsOf: path, encoding: .utf8) {
            #expect(OpenSSHKeyFormat.ed25519Seed(fromPEM: pem) == nil)
        }
    }
}
