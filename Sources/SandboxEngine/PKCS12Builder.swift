import CommonCrypto
import Crypto
import Foundation
import Security

/// In-memory builder for a minimal PKCS#12 (PFX) blob carrying a single
/// cert + matching PKCS#8 private key, in a form that Apple's
/// `SecPKCS12Import` accepts and — crucially — from which it synthesizes
/// a `SecIdentity`.
///
/// The private key is shrouded in a `pkcs8ShroudedKeyBag` using
/// PBES2/PBKDF2-HMAC-SHA256/AES-256-CBC. (A plain `keyBag` is valid per
/// RFC 7292 but `SecPKCS12Import` won't build an identity from one —
/// it only returns a cert chain. Shrouding is required for identity
/// synthesis on macOS.)
///
/// The blob is generated, round-tripped through `SecPKCS12Import`, and
/// discarded in the same function call — it never touches disk, never
/// leaves the process, never crosses a trust boundary — so the
/// cryptographic protection on the key bag is incidental. The outer
/// HMAC-SHA1 MAC (which `SecPKCS12Import` also requires) is keyed
/// through the PKCS#12-specific KDF from RFC 7292 Appendix B.
///
/// References:
///   - RFC 7292 (PKCS#12 v1.1)
///   - RFC 5208 (PKCS#8 PrivateKeyInfo, used as the plaintext for the
///               shrouded key bag)
///   - RFC 8018 (PBES2/PBKDF2)
public enum PKCS12Builder {
    /// Build a PFX from DER-encoded cert + PKCS#8 private key. The
    /// password is only used as input to the MAC key derivation; it
    /// never protects confidentiality because nothing here is encrypted.
    public static func build(
        certDER: Data,
        privateKeyDER: Data,
        password: String,
        iterations: Int = 2048,
    ) -> Data {
        // Both the keyBag and the certBag need a matching `localKeyID`
        // (PKCS#9) attribute — that's what SecPKCS12Import uses to pair
        // the cert with its private key into a SecIdentity. The value
        // itself is opaque; any bytes will do as long as both bags agree.
        let localKeyID = randomBytes(20)
        let bagAttrs = set([
            seq([
                oid(OID.pkcs9LocalKeyID),
                set([octetString(Data(localKeyID))]),
            ])
        ])

        // --- PKCS8ShroudedKeyBag
        // Apple's SecPKCS12Import only synthesizes a SecIdentity when
        // the private key is in a shrouded bag, so we encrypt the
        // PKCS#8 plaintext with PBES2 (PBKDF2-HMAC-SHA256 + AES-256-CBC).
        // PBES2 expects the password as a plain octet string — modern
        // convention (RFC 7292 erratum, openssl 3.x) is UTF-8.
        let passwordUTF8 = Array(password.utf8)
        let shroudedBagValue = shroudPKCS8(
            pkcs8: privateKeyDER, passwordUTF8: passwordUTF8, iterations: iterations)
        // The outer HMAC-SHA1 MAC on the AuthenticatedSafe still uses the
        // PKCS#12-specific BMPString convention (UCS-2 BE + NUL terminator).
        let passwordBMP = bmpPassword(password)
        let keyBag = seq([
            oid(OID.pkcs8ShroudedKeyBag),
            ctx0(shroudedBagValue),
            bagAttrs,
        ])

        let certBagInner = seq([
            oid(OID.x509Certificate),
            ctx0(octetString(certDER)),
        ])
        let certBag = seq([
            oid(OID.certBag),
            ctx0(certBagInner),
            bagAttrs,
        ])

        // Apple's SecPKCS12Import pairs a cert + key into a SecIdentity
        // only when the keyBag and certBag sit in **separate** SafeContents
        // blocks inside the AuthenticatedSafe (matching the convention
        // openssl emits). Put each in its own id-data ContentInfo.
        let certSafeContents = seq([certBag])
        let keySafeContents = seq([keyBag])

        let certContentInfo = seq([
            oid(OID.pkcs7Data),
            ctx0(octetString(certSafeContents)),
        ])
        let keyContentInfo = seq([
            oid(OID.pkcs7Data),
            ctx0(octetString(keySafeContents)),
        ])
        let authSafe = seq([certContentInfo, keyContentInfo])

        // --- MAC over DER(AuthenticatedSafe)
        let macSalt = randomBytes(20)
        let macKey = pkcs12KDF(
            password: passwordBMP, salt: macSalt,
            iterations: iterations, id: 3, keyLength: 20)
        let mac = hmacSHA1(key: macKey, message: authSafe)

        let digestInfo = seq([
            seq([oid(OID.sha1), nullValue()]),
            octetString(mac),
        ])
        let macData = seq([
            digestInfo,
            octetString(Data(macSalt)),
            integer(iterations),
        ])

        // --- PFX
        let outerContentInfo = seq([
            oid(OID.pkcs7Data),
            ctx0(octetString(authSafe)),
        ])
        return seq([
            integer(3),
            outerContentInfo,
            macData,
        ])
    }

    // MARK: - DER primitives

    private static func tlv(_ tag: UInt8, _ contents: Data) -> Data {
        var out = Data()
        out.append(tag)
        out.append(derLength(contents.count))
        out.append(contents)
        return out
    }

    private static func derLength(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        if n < 0x100 { return Data([0x81, UInt8(n)]) }
        if n < 0x10000 {
            return Data([0x82, UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        }
        precondition(n < 0x1000000, "PKCS#12 payload too large")
        return Data([
            0x83,
            UInt8((n >> 16) & 0xFF),
            UInt8((n >> 8) & 0xFF),
            UInt8(n & 0xFF),
        ])
    }

    private static func seq(_ parts: [Data]) -> Data {
        var body = Data()
        for p in parts { body.append(p) }
        return tlv(0x30, body)
    }

    private static func octetString(_ bytes: Data) -> Data { tlv(0x04, bytes) }
    private static func oid(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    private static func nullValue() -> Data { Data([0x05, 0x00]) }
    private static func ctx0(_ inner: Data) -> Data { tlv(0xA0, inner) }

    private static func set(_ parts: [Data]) -> Data {
        var body = Data()
        for p in parts { body.append(p) }
        return tlv(0x31, body)
    }

    private static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var v = value
        if v == 0 {
            bytes = [0]
        } else {
            while v > 0 {
                bytes.insert(UInt8(v & 0xFF), at: 0)
                v >>= 8
            }
            // Prepend 0x00 if the high bit would make this look negative.
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        }
        return tlv(0x02, Data(bytes))
    }

    // MARK: - OIDs (DER content bytes, without tag / length)

    private enum OID {
        static let pkcs7Data: [UInt8] =
            [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        static let pkcs8ShroudedKeyBag: [UInt8] =
            [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x02]
        static let certBag: [UInt8] =
            [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03]
        static let x509Certificate: [UInt8] =
            [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x16, 0x01]
        static let sha1: [UInt8] = [0x2B, 0x0E, 0x03, 0x02, 0x1A]
        static let pkcs9LocalKeyID: [UInt8] =
            [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x15]
        static let pbes2: [UInt8] =
            [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D]
        static let pbkdf2: [UInt8] =
            [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C]
        static let aes256CBC: [UInt8] =
            [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A]
        static let hmacWithSHA256: [UInt8] =
            [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09]
    }

    // MARK: - PBES2 shrouding (PBKDF2-HMAC-SHA256 + AES-256-CBC)

    /// Produce the `EncryptedPrivateKeyInfo` value (the bagValue of a
    /// `pkcs8ShroudedKeyBag`) by encrypting the PKCS#8 plaintext under
    /// PBES2 with our random salt + IV. Returns the DER-encoded
    /// `SEQUENCE { algorithmIdentifier, encryptedData }`.
    private static func shroudPKCS8(
        pkcs8: Data, passwordUTF8: [UInt8], iterations: Int,
    ) -> Data {
        let salt = randomBytes(16)
        let iv = randomBytes(16)
        let keyBytes = pbkdf2HMACSHA256(
            password: passwordUTF8, salt: salt,
            iterations: iterations, outputLength: 32)
        let ciphertext = aes256CBCEncrypt(key: keyBytes, iv: iv, plaintext: pkcs8)

        let pbkdf2Params = seq([
            octetString(Data(salt)),
            integer(iterations),
            seq([oid(OID.hmacWithSHA256), nullValue()]),
        ])
        let pbkdf2Alg = seq([oid(OID.pbkdf2), pbkdf2Params])
        let aesAlg = seq([oid(OID.aes256CBC), octetString(Data(iv))])
        let pbes2Params = seq([pbkdf2Alg, aesAlg])
        let pbes2Alg = seq([oid(OID.pbes2), pbes2Params])

        return seq([pbes2Alg, octetString(ciphertext)])
    }

    private static func pbkdf2HMACSHA256(
        password: [UInt8], salt: [UInt8], iterations: Int, outputLength: Int,
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: outputLength)
        let status = password.withUnsafeBufferPointer { pwd in
            salt.withUnsafeBufferPointer { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwd.baseAddress?.withMemoryRebound(to: Int8.self, capacity: pwd.count) { $0 },
                    pwd.count,
                    saltBuf.baseAddress, saltBuf.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &out, out.count,
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return out
    }

    private static func aes256CBCEncrypt(
        key: [UInt8], iv: [UInt8], plaintext: Data,
    ) -> Data {
        // CBC + PKCS#7 padding: output ≤ input + one block.
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var produced = 0
        let status = plaintext.withUnsafeBytes { ptBuf in
            iv.withUnsafeBufferPointer { ivBuf in
                key.withUnsafeBufferPointer { keyBuf in
                    out.withUnsafeMutableBytes { outBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            ptBuf.baseAddress, plaintext.count,
                            outBuf.baseAddress, outBuf.count,
                            &produced,
                        )
                    }
                }
            }
        }
        precondition(status == kCCSuccess, "AES-CBC encrypt failed: \(status)")
        out.count = produced
        return out
    }

    // MARK: - PKCS#12 BMPString password encoding (UCS-2 BE + NUL terminator)

    private static func bmpPassword(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        // Each Unicode scalar → big-endian UCS-2. Our inputs are base64
        // ASCII, so every scalar fits in U+0000…U+FFFF.
        for scalar in s.unicodeScalars {
            let v = scalar.value
            out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8(v & 0xFF))
        }
        out.append(0)
        out.append(0)
        return out
    }

    // MARK: - PKCS#12 KDF (RFC 7292 Appendix B)

    /// `id` selects the KDF purpose: 1 = encryption key, 2 = IV, 3 = MAC key.
    private static func pkcs12KDF(
        password: [UInt8], salt: [UInt8],
        iterations: Int, id: UInt8, keyLength: Int,
    ) -> [UInt8] {
        let u = 20  // SHA-1 output length
        let v = 64  // SHA-1 block length

        let D = [UInt8](repeating: id, count: v)

        let sBlocks = (salt.count + v - 1) / v
        var S = [UInt8]()
        S.reserveCapacity(sBlocks * v)
        for i in 0..<(sBlocks * v) { S.append(salt[i % salt.count]) }

        var P = [UInt8]()
        if !password.isEmpty {
            let pBlocks = (password.count + v - 1) / v
            P.reserveCapacity(pBlocks * v)
            for i in 0..<(pBlocks * v) { P.append(password[i % password.count]) }
        }

        var I = S + P
        var output = [UInt8]()
        let c = (keyLength + u - 1) / u

        for _ in 0..<c {
            // A = H^iterations(D || I)
            var A = sha1(D + I)
            for _ in 1..<iterations { A = sha1(A) }
            output.append(contentsOf: A)
            if output.count >= keyLength { break }

            // B = A repeated to v bytes
            var B = [UInt8](repeating: 0, count: v)
            for i in 0..<v { B[i] = A[i % u] }

            // Compute B + 1 (big-endian, v-byte big int)
            var Bplus1 = B
            var carry: UInt16 = 1
            for i in stride(from: v - 1, through: 0, by: -1) {
                let sum = UInt16(Bplus1[i]) + carry
                Bplus1[i] = UInt8(sum & 0xFF)
                carry = sum >> 8
            }

            // For each v-byte block of I, replace block_j ← (block_j + Bplus1) mod 2^(8v)
            let blocks = I.count / v
            for j in 0..<blocks {
                let off = j * v
                var c2: UInt16 = 0
                for i in stride(from: v - 1, through: 0, by: -1) {
                    let sum = UInt16(I[off + i]) + UInt16(Bplus1[i]) + c2
                    I[off + i] = UInt8(sum & 0xFF)
                    c2 = sum >> 8
                }
            }
        }

        return Array(output.prefix(keyLength))
    }

    // MARK: - Crypto primitives

    private static func sha1(_ data: [UInt8]) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: data))
    }

    private static func hmacSHA1(key: [UInt8], message: Data) -> Data {
        let sym = SymmetricKey(data: key)
        var hmac = HMAC<Insecure.SHA1>(key: sym)
        hmac.update(data: message)
        return Data(hmac.finalize())
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &buf)
        return buf
    }
}
