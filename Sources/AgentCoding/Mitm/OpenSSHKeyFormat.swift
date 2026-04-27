import Foundation

/// Encoder for the OpenSSH unencrypted ed25519 private-key format.
///
/// We hand the bytes directly to `ssh-add -` (reads from stdin) at
/// session launch so the per-profile bromure key lives in bromure's
/// private ssh-agent for the duration of the session — without ever
/// touching disk in OpenSSH form.
///
/// File layout (unencrypted, single-key):
///   "openssh-key-v1\0"
///   ssh-string("none")          // cipher
///   ssh-string("none")          // kdf
///   ssh-string("")              // kdf options
///   uint32(1)                   // number of keys
///   ssh-string(public-key-blob)
///   ssh-string(private-section-padded-to-block-size)
///
/// public-key-blob:
///   ssh-string("ssh-ed25519")
///   ssh-string(32-byte public key)
///
/// private-section (before padding):
///   uint32 check
///   uint32 check (same)         // sanity check after decrypt
///   ssh-string("ssh-ed25519")
///   ssh-string(32-byte public key)
///   ssh-string(64-byte expanded private = seed || public)
///   ssh-string(comment)
///
/// Cipher block size for "none" is 8, so the section is padded to a
/// multiple of 8 with bytes 0x01, 0x02, ... per the spec.
enum OpenSSHKeyFormat {

    static func ed25519PEM(seed: Data, publicKey: Data, comment: String) -> Data {
        precondition(seed.count == 32, "ed25519 seed must be 32 bytes")
        precondition(publicKey.count == 32, "ed25519 public must be 32 bytes")

        // Public-key blob.
        var pubBlob = Data()
        pubBlob.append(sshString("ssh-ed25519"))
        pubBlob.append(sshString(publicKey))

        // Private section.
        var priv = Data()
        let check = Data(randomBytes(4))
        priv.append(check)              // 4 bytes
        priv.append(check)              // repeated for integrity check
        priv.append(sshString("ssh-ed25519"))
        priv.append(sshString(publicKey))
        // Expanded private = seed || public (64 bytes total).
        var expanded = Data()
        expanded.append(seed)
        expanded.append(publicKey)
        priv.append(sshString(expanded))
        priv.append(sshString(comment))
        // Pad to multiple of 8 with 0x01, 0x02, … When the section is
        // already aligned no padding is added (the `for i in 1...0`
        // I had earlier traps).
        let padBlock = 8
        let padNeeded = (padBlock - priv.count % padBlock) % padBlock
        if padNeeded > 0 {
            for i in 1...padNeeded { priv.append(UInt8(i)) }
        }

        // Outer file.
        var blob = Data()
        blob.append(Data("openssh-key-v1".utf8))
        blob.append(0)                  // null terminator after magic
        blob.append(sshString("none"))  // cipher
        blob.append(sshString("none"))  // kdf
        blob.append(sshString(""))      // kdf options
        blob.append(uint32be(1))        // num keys
        blob.append(sshString(pubBlob))
        blob.append(sshString(priv))

        // PEM wrap with 70-char base64 lines.
        let b64 = blob.base64EncodedString()
        var pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let next = b64.index(idx, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            pem += b64[idx..<next] + "\n"
            idx = next
        }
        pem += "-----END OPENSSH PRIVATE KEY-----\n"
        return Data(pem.utf8)
    }

    /// Public-key blob in the format ssh-add reports / ssh-agent
    /// keys-by-blob lookups use. Same as the inner pubBlob above.
    static func ed25519PublicBlob(publicKey: Data) -> Data {
        var blob = Data()
        blob.append(sshString("ssh-ed25519"))
        blob.append(sshString(publicKey))
        return blob
    }

    // MARK: - SSH wire helpers (length-prefixed strings, big-endian u32)

    private static func sshString(_ s: String) -> Data {
        sshString(Data(s.utf8))
    }

    private static func sshString(_ d: Data) -> Data {
        var out = uint32be(UInt32(d.count))
        out.append(d)
        return out
    }

    private static func uint32be(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }
}
