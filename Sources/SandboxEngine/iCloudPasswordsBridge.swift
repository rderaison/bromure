import AppKit
import BigInt
import CommonCrypto
import CryptoKit
import Foundation

private let icpDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG_KEYCHAIN"] != nil

// MARK: - SRP-6a Client (RFC 5054, 3072-bit group, SHA-256)

/// Clean-room SRP-6a client using attaswift/BigInt for reliable 3072-bit arithmetic.
/// All big-integer hash inputs are padded to 384 bytes (the modulus length) to ensure
/// byte-aligned SHA-256, matching the wire protocol behavior.
final class SRPClient {

    // RFC 5054 / RFC 3526 3072-bit safe prime (96 × 32-bit words = 768 hex chars)
    // sjcl.keyexchange.srp.knownGroup(3072).N — NOT the same as RFC 3526 group 15
    static let N: BigUInt = BigUInt("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF", radix: 16)!
    static let g: BigUInt = 5
    static let modulusLen = 384  // bytes (3072 / 8)

    let identity: Data       // Random 128-bit TID
    let a: BigUInt           // Client private ephemeral
    let A: BigUInt           // Client public ephemeral = g^a mod N

    var shouldUseBase64 = false
    var protocolVersion = 0
    var pin: String?

    var encKey: SymmetricKey?
    var hamk: Data?

    init() {
        var identityBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &identityBytes)
        self.identity = Data(identityBytes)

        var aBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &aBytes)
        self.a = BigUInt(Data(aBytes))
        self.A = Self.g.power(self.a, modulus: Self.N)
    }

    /// Test-friendly initializer with known values.
    init(identity: Data, a: BigUInt) {
        self.identity = identity
        self.a = a
        self.A = Self.g.power(a, modulus: Self.N)
    }

    // MARK: - Encoding helpers

    var identityString: String {
        shouldUseBase64 ? identity.base64EncodedString() : "0x" + identity.hexString
    }

    /// Pad a BigUInt to exactly 384 bytes (modulus length) for hashing.
    func pad(_ n: BigUInt) -> Data {
        var data = n.serialize()
        if data.count < Self.modulusLen {
            data = Data(repeating: 0, count: Self.modulusLen - data.count) + data
        }
        return data
    }

    /// SHA-256 of concatenated data items.
    func H(_ items: Data...) -> Data {
        var hasher = SHA256()
        for item in items { hasher.update(data: item) }
        return Data(hasher.finalize())
    }

    func encodeForWire(_ n: BigUInt) -> String {
        let data = n.serialize()
        return shouldUseBase64 ? data.base64EncodedString() : "0x" + data.hexString
    }

    func decodeFromWire(_ str: String) -> Data {
        if shouldUseBase64 { return Data(base64Encoded: str) ?? Data() }
        let hex = str.hasPrefix("0x") ? String(str.dropFirst(2)) : str
        return Data(hexString: hex)
    }

    // MARK: - Protocol messages

    func initialMessage() -> String {
        // Build JSON manually to match extension's exact key order: TID, MSG, A, VER, PROTO
        let tid = identityString
        let aVal = encodeForWire(A)
        let jsonStr = "{\"TID\":\"\(tid)\",\"MSG\":0,\"A\":\"\(aVal)\",\"VER\":\"1.0\",\"PROTO\":[0,1]}"
        return Data(jsonStr.utf8).base64EncodedString()
    }

    func processMessage1(_ msg: [String: Any]) throws -> String {
        guard let sStr = msg["s"] as? String,
              let bStr = msg["B"] as? String else {
            throw SRPError.invalidMessage("Missing s or B in message 1")
        }
        if let proto = msg["PROTO"] as? Int { protocolVersion = proto }
        guard let pin else { throw SRPError.invalidMessage("PIN not set") }

        let salt = decodeFromWire(sStr)
        let B = BigUInt(decodeFromWire(bStr))
        guard B % Self.N != 0 else { throw SRPError.invalidMessage("B mod N == 0") }

        // x = H(salt || H(identity_string + ":" + pin))
        let xInput = identityString + ":" + pin
        let inner = H(Data(xInput.utf8))
        let x = BigUInt(H(salt, inner))

        // v = g^x mod N
        let v = Self.g.power(x, modulus: Self.N)

        // u = H(pad(A) || pad(B))
        let padA = pad(A)
        let padB = pad(B)
        let u = BigUInt(H(padA, padB))

        // k = H(N || pad(g))
        let k = BigUInt(H(pad(Self.N), pad(Self.g)))

        // S = (B - k*v)^(a + u*x) mod N
        let kv = (k * v) % Self.N
        let base = B >= kv ? (B - kv) % Self.N : (B + Self.N - kv) % Self.N
        let exp = a + u * x
        let S = base.power(exp, modulus: Self.N)

        // session_key = H(S) — minimal representation, NOT padded (matches sjcl S.toBits())
        let sessionKey = H(S.serialize())
        self.encKey = SymmetricKey(data: sessionKey.prefix(16))

        // Build MSG 2
        switch protocolVersion {
        case 1: // RFC verification
            // H(N) and H(pad(g)) — N is already 384 bytes; g is padded via _padToModulusLength
            let hN = H(Self.N.serialize())
            let hg = H(pad(Self.g))
            var xorNg = Data(count: 32)
            for i in 0..<32 { xorNg[i] = hN[i] ^ hg[i] }
            let hI = H(Data(identityString.utf8))

            // M uses minimal (unpadded) A, B — matches sjcl A.toBits(), B.toBits()
            let M = H(xorNg, hI, salt, A.serialize(), B.serialize(), sessionKey)
            self.hamk = H(A.serialize(), M, sessionKey)

            // Build JSON manually with extension's key order: TID, MSG, M
            let mStr = shouldUseBase64 ? M.base64EncodedString() : M.hexString
            let jsonStr = "{\"TID\":\"\(identityString)\",\"MSG\":2,\"M\":\"\(mStr)\"}"
            return Data(jsonStr.utf8).base64EncodedString()
        case 0: // Old verification
            let vBytes = shouldUseBase64 ? v.serialize() : Data(v.serialize().hexString.utf8)
            let encrypted = try encrypt(vBytes)
            let vStr = shouldUseBase64 ? encrypted.base64EncodedString() : encrypted.hexString
            let jsonStr = "{\"TID\":\"\(identityString)\",\"MSG\":2,\"v\":\"\(vStr)\"}"
            return Data(jsonStr.utf8).base64EncodedString()
        default:
            throw SRPError.invalidMessage("Unknown protocol version \(protocolVersion)")
        }
    }

    func processMessage3(_ msg: [String: Any]) throws {
        if let errCode = msg["ErrCode"] as? Int, errCode != 0 {
            throw SRPError.authenticationFailed("Server returned error \(errCode)")
        }
        if protocolVersion == 1 {
            guard let hamkStr = msg["HAMK"] as? String else {
                throw SRPError.authenticationFailed("Missing HAMK in message 3")
            }
            let serverHamk = decodeFromWire(hamkStr)
            guard let expected = self.hamk, serverHamk == expected else {
                throw SRPError.authenticationFailed("HAMK verification failed")
            }
        }
    }

    // MARK: - AES-128-GCM (sjcl-compatible with 128-bit IV support)

    /// sjcl GCM wire format:
    ///   encrypt output: ciphertext || tag(16) || iv(16)
    ///   decrypt input:  iv(16) || ciphertext || tag(16)
    /// sjcl uses 128-bit (16-byte) random IVs, requiring GHASH derivation of J0.
    func encrypt(_ plaintext: Data) throws -> Data {
        guard let encKey else { throw SRPError.noSessionKey }
        let keyData = encKey.withUnsafeBytes { Data($0) }

        // 16-byte random IV (matching sjcl's _randomWords(4) = 128 bits)
        var iv = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &iv)

        // Derive J0 via GHASH for 128-bit IV
        let H = Self.aesEncryptBlock(key: keyData, block: Data(repeating: 0, count: 16))
        var ghashInput = Data(iv)
        ghashInput.append(Data(repeating: 0, count: 8))
        var lenBits = UInt64(16 * 8).bigEndian
        ghashInput.append(Data(bytes: &lenBits, count: 8))
        let j0 = Array(Self.ghash(H: H, data: ghashInput))

        // Encrypt: CTR mode starting from inc32(J0)
        var ciphertext = Data()
        var counter = j0
        for blockStart in stride(from: 0, to: plaintext.count, by: 16) {
            Self.incrementCounter(&counter)
            let keystream = Self.aesEncryptBlock(key: keyData, block: Data(counter))
            let blockEnd = min(blockStart + 16, plaintext.count)
            for i in blockStart..<blockEnd {
                ciphertext.append(plaintext[i] ^ keystream[i - blockStart])
            }
        }

        // Compute tag: GHASH(AAD || C || len(AAD) || len(C)) XOR AES(K, J0)
        var tagInput = Data(ciphertext)
        let cPad = (16 - (ciphertext.count % 16)) % 16
        tagInput.append(Data(repeating: 0, count: cPad))
        var aadLenBits: UInt64 = 0
        tagInput.append(Data(bytes: &aadLenBits, count: 8))
        var cLenBits = UInt64(ciphertext.count * 8).bigEndian
        tagInput.append(Data(bytes: &cLenBits, count: 8))
        let ghashTag = Self.ghash(H: H, data: tagInput)
        let j0Block = Self.aesEncryptBlock(key: keyData, block: Data(j0))
        var tag = Data(count: 16)
        for i in 0..<16 { tag[i] = ghashTag[i] ^ j0Block[i] }

        // Wire format: ciphertext || tag(16) || iv(16)
        return ciphertext + tag + Data(iv)
    }

    func decrypt(_ data: Data) throws -> Data {
        guard let encKey else { throw SRPError.noSessionKey }
        guard data.count > 32 else { throw SRPError.invalidMessage("Data too short") }
        // Wire format: iv(16) || ciphertext || tag(16)
        let ivData = data.prefix(16)
        let rest = data.dropFirst(16)
        let ciphertext = rest.prefix(rest.count - 16)
        let tag = rest.suffix(16)

        // Check if the IV is effectively 96-bit (last 4 bytes zero)
        let nonce: AES.GCM.Nonce
        if ivData.suffix(4).allSatisfy({ $0 == 0 }) {
            nonce = try AES.GCM.Nonce(data: ivData.prefix(12))
        } else {
            // 128-bit IV: derive 96-bit J0 via GHASH (NIST SP 800-38D §7.1)
            // J0 = GHASH_H(IV || 0^64 || [len(IV)]_64) then take first 12 bytes as nonce
            // H = AES_K(0^128)
            let keyData = encKey.withUnsafeBytes { Data($0) }
            let H = Self.aesEncryptBlock(key: keyData, block: Data(repeating: 0, count: 16))
            // GHASH input: IV(16 bytes) || 0x00(8 bytes) || len_in_bits(8 bytes big-endian)
            var ghashInput = Data(ivData)
            ghashInput.append(contentsOf: [UInt8](repeating: 0, count: 8))
            var lenBits = UInt64(ivData.count * 8).bigEndian
            ghashInput.append(Data(bytes: &lenBits, count: 8))
            _ = Self.ghash(H: H, data: ghashInput)
            // Use first 12 bytes of J0 as nonce (the 13th-16th bytes form the counter)
            // Actually, J0 IS the full 16-byte initial counter. For CryptoKit we need a
            // 12-byte nonce where the counter starts at the value in bytes 12-15 of J0.
            // CryptoKit's GCM uses nonce || counter(4 bytes starting at 1).
            // J0 = nonce_equivalent || initial_counter.
            // We pass the first 12 bytes as nonce; CryptoKit will set counter to 1 for
            // encryption, but J0's counter is bytes 12-15. This only works if J0's last
            // 4 bytes happen to be the counter CryptoKit expects.
            // Since this is complex, use a raw implementation for non-96-bit IVs.
            return try decryptGCM128(key: keyData, iv: Data(ivData),
                                     ciphertext: Data(ciphertext), tag: Data(tag))
        }

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: encKey)
    }

    /// Raw AES single-block encryption (ECB, for GHASH subkey derivation).
    static func aesEncryptBlock(key: Data, block: Data) -> Data {
        // Use CryptoKit's AES-GCM with known nonce to encrypt a zero block
        // Actually, just use the low-level: encrypt block = AES_ECB(key, block)
        var result = [UInt8](repeating: 0, count: block.count + 16)  // kCCBlockSizeAES128 padding
        var outLen = 0
        _ = block.withUnsafeBytes { blockPtr in
            key.withUnsafeBytes { keyPtr in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode), keyPtr.baseAddress, key.count,
                        nil, blockPtr.baseAddress, block.count, &result, result.count, &outLen)
            }
        }
        return Data(result.prefix(16))
    }

    /// GHASH: multiply and accumulate in GF(2^128).
    static func ghash(H: Data, data: Data) -> Data {
        var y = [UInt8](repeating: 0, count: 16)
        let h = Array(H)
        // Process 16-byte blocks
        for blockStart in stride(from: 0, to: data.count, by: 16) {
            let blockEnd = min(blockStart + 16, data.count)
            let block = Array(data[blockStart..<blockEnd]) + [UInt8](repeating: 0, count: max(0, 16 - (blockEnd - blockStart)))
            // XOR
            for i in 0..<16 { y[i] ^= block[i] }
            // Multiply y by H in GF(2^128)
            y = gfMul128(y, h)
        }
        return Data(y)
    }

    /// Multiplication in GF(2^128) with the irreducible polynomial x^128 + x^7 + x^2 + x + 1.
    static func gfMul128(_ x: [UInt8], _ y: [UInt8]) -> [UInt8] {
        var z = [UInt8](repeating: 0, count: 16)
        var v = y
        for i in 0..<128 {
            let byteIdx = i / 8
            let bitIdx = 7 - (i % 8)
            if (x[byteIdx] >> bitIdx) & 1 == 1 {
                for j in 0..<16 { z[j] ^= v[j] }
            }
            // Shift V right by 1 in GF(2^128)
            let lsb = v[15] & 1
            for j in (1..<16).reversed() {
                v[j] = (v[j] >> 1) | (v[j - 1] << 7)
            }
            v[0] >>= 1
            if lsb == 1 { v[0] ^= 0xE1 }  // R = 0xE1 << 120
        }
        return z
    }

    /// Full GCM decrypt with 128-bit IV (for sjcl compatibility).
    func decryptGCM128(key: Data, iv: Data, ciphertext: Data, tag: Data) throws -> Data {
        // Derive J0 via GHASH
        let H = Self.aesEncryptBlock(key: key, block: Data(repeating: 0, count: 16))
        var ghashInput = Data(iv)
        ghashInput.append(Data(repeating: 0, count: 8))
        var lenBits = UInt64(iv.count * 8).bigEndian
        ghashInput.append(Data(bytes: &lenBits, count: 8))
        let j0 = Array(Self.ghash(H: H, data: ghashInput))

        // Decrypt: for each 16-byte block, XOR with AES(K, inc32(J0, i+1))
        var plaintext = Data()
        var counter = j0
        for blockStart in stride(from: 0, to: ciphertext.count, by: 16) {
            // Increment 32-bit counter (last 4 bytes of J0)
            Self.incrementCounter(&counter)
            let keystream = Self.aesEncryptBlock(key: key, block: Data(counter))
            let blockEnd = min(blockStart + 16, ciphertext.count)
            let block = ciphertext[blockStart..<blockEnd]
            for (i, byte) in block.enumerated() {
                plaintext.append(byte ^ keystream[i])
            }
        }

        // Verify tag: GHASH(H, AAD || C || len(AAD) || len(C)) XOR AES(K, J0)
        var tagInput = Data()
        // No AAD, so just ciphertext padded to 16-byte boundary
        tagInput.append(ciphertext)
        let cPad = (16 - (ciphertext.count % 16)) % 16
        tagInput.append(Data(repeating: 0, count: cPad))
        // len(AAD) in bits (0) || len(C) in bits
        var aadLenBits: UInt64 = 0
        tagInput.append(Data(bytes: &aadLenBits, count: 8))
        var cLenBits = UInt64(ciphertext.count * 8).bigEndian
        tagInput.append(Data(bytes: &cLenBits, count: 8))
        let ghashTag = Self.ghash(H: H, data: tagInput)
        let j0Block = Self.aesEncryptBlock(key: key, block: Data(j0))
        var computedTag = Data(count: 16)
        for i in 0..<16 { computedTag[i] = ghashTag[i] ^ j0Block[i] }

        guard computedTag == tag else {
            throw SRPError.invalidMessage("AES-GCM tag verification failed")
        }

        return plaintext
    }

    static func incrementCounter(_ counter: inout [UInt8]) {
        for i in (12..<16).reversed() {
            counter[i] &+= 1
            if counter[i] != 0 { break }
        }
    }

    func createSMSG(_ payload: String) throws -> String {
        let encrypted = try encrypt(Data(payload.utf8))
        let sdata = shouldUseBase64 ? encrypted.base64EncodedString() : encrypted.hexString
        let envelope: [String: String] = ["TID": identityString, "SDATA": sdata]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        return (String(data: json, encoding: .utf8) ?? "").replacingOccurrences(of: "\\/", with: "/")
    }

    func parseSMSG(_ envelope: String) throws -> String {
        guard let data = envelope.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let sdata = obj["SDATA"] else {
            throw SRPError.invalidMessage("Invalid SMSG format")
        }
        let encrypted = shouldUseBase64 ? (Data(base64Encoded: sdata) ?? Data()) : Data(hexString: sdata)
        let decrypted = try decrypt(encrypted)
        guard let result = String(data: decrypted, encoding: .utf8) else {
            throw SRPError.invalidMessage("Decrypted data is not valid UTF-8")
        }
        return result
    }
}

enum SRPError: Error, LocalizedError {
    case invalidMessage(String)
    case authenticationFailed(String)
    case noSessionKey

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let msg): return "SRP: \(msg)"
        case .authenticationFailed(let msg): return "SRP auth failed: \(msg)"
        case .noSessionKey: return "SRP: no session key"
        }
    }
}

// MARK: - Data hex encoding/decoding

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        var data = Data()
        var chars = Array(hex)
        if chars.count % 2 != 0 { chars.insert("0", at: 0) }
        for i in stride(from: 0, to: chars.count, by: 2) {
            if let byte = UInt8(String(chars[i...i+1]), radix: 16) {
                data.append(byte)
            }
        }
        self = data
    }
}

// MARK: - Native Messaging Protocol

/// Reads/writes Chrome native messaging format: 4-byte LE length prefix + JSON.
private actor NativeMessagingHost {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var isRunning = false

    init(path: String, extensionOrigin: String? = nil) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        if let extensionOrigin {
            proc.arguments = [extensionOrigin]
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
    }

    func start() throws {
        try process.run()
        isRunning = true
        if icpDebug { print("[iCloudPasswords] native host started (pid=\(process.processIdentifier))") }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        isRunning = false
    }

    /// Send a message to the native host.
    func send(_ message: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(json.count).littleEndian
        let header = Data(bytes: &length, count: 4)
        stdin.write(header)
        stdin.write(json)
        if icpDebug { print("[iCloudPasswords] -> \(String(data: json, encoding: .utf8) ?? "")") }
    }

    /// Read a message from the native host. Blocks until data is available.
    func receive() throws -> [String: Any] {
        let headerData = stdout.readData(ofLength: 4)
        guard headerData.count == 4 else {
            throw SRPError.invalidMessage("Native host closed connection")
        }
        let length = headerData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length > 0, length < 10_000_000 else {
            throw SRPError.invalidMessage("Invalid message length: \(length)")
        }

        var body = Data()
        while body.count < Int(length) {
            let chunk = stdout.readData(ofLength: Int(length) - body.count)
            if chunk.isEmpty { throw SRPError.invalidMessage("Unexpected EOF") }
            body.append(chunk)
        }

        if icpDebug { print("[iCloudPasswords] <- \(String(data: body, encoding: .utf8) ?? "")") }

        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw SRPError.invalidMessage("Invalid JSON from native host")
        }
        return obj
    }
}

// MARK: - iCloud Passwords Bridge

/// Credential entry returned from iCloud Keychain.
public struct iCloudCredentialEntry {
    public let username: String
    public let password: String?  // nil until explicitly fetched
    public let domain: String
}

/// Bridges the iCloud Passwords native messaging protocol to provide
/// password autofill from iCloud Keychain.
///
/// Architecture:
///   1. Spawns Apple's PasswordManagerBrowserExtensionHelper
///   2. Implements SRP-6a to establish an encrypted session (PIN required once)
///   3. Queries for credentials on demand
///   4. Session persists for the app lifetime
@MainActor
public final class ICloudPasswordsBridge {
    private static let helperPath = "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"

    private var host: NativeMessagingHost?
    private var srp: SRPClient?
    private var sessionEstablished = false
    private var capabilities: [String: Any] = [:]

    /// Whether the helper binary exists on this system.
    public static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: helperPath)
    }

    public init() {}

    /// Connect to the helper and establish an encrypted session.
    /// Shows a PIN dialog if needed. Returns true on success.
    public func connect(window: NSWindow?) async -> Bool {
        guard Self.isAvailable else {
            if icpDebug { print("[iCloudPasswords] helper not found") }
            return false
        }

        do {
            // Pass the Chrome iCloud Passwords extension origin — the helper validates this
            let nmHost = try NativeMessagingHost(
                path: Self.helperPath,
                extensionOrigin: "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"
            )
            try await nmHost.start()
            self.host = nmHost

            // Send CmdHello
            try await nmHost.send(["cmd": 14])
            let helloResponse = try await nmHost.receive()

            guard let cmd = helloResponse["cmd"] as? Int else {
                if icpDebug { print("[iCloudPasswords] unexpected hello response") }
                return false
            }

            if cmd == 9 || cmd == 10 {
                if icpDebug { print("[iCloudPasswords] passwords disabled or relogin needed (cmd=\(cmd))") }
                return false
            }

            guard cmd == 14 else {
                if icpDebug { print("[iCloudPasswords] unexpected cmd \(cmd) from hello") }
                return false
            }

            if let caps = helloResponse["capabilities"] as? [String: Any] {
                self.capabilities = caps
            }

            let shouldUseBase64 = capabilities["shouldUseBase64"] as? Bool ?? false
            let secretSessionVersion = capabilities["secretSessionVersion"] as? Int ?? 0

            // Start SRP handshake
            let client = SRPClient()
            client.shouldUseBase64 = shouldUseBase64
            client.protocolVersion = secretSessionVersion
            self.srp = client

            // Send PAKE MSG 0 (ChallengePIN)
            // Build msg JSON string manually to match extension's key order exactly
            let initialMsg = client.initialMessage()
            let msg0Str = "{\"QID\":\"m0\",\"PAKE\":\"\(initialMsg)\",\"HSTBRSR\":\"Bromure\"}"
            try await nmHost.send(["cmd": 2, "msg": msg0Str])

            // Receive MSG 1 from server (contains B, s)
            let msg1Response = try await nmHost.receive()
            guard let msg1Payload = msg1Response["payload"] as? [String: Any],
                  let pakeBase64 = msg1Payload["PAKE"] as? String else {
                if icpDebug { print("[iCloudPasswords] no PAKE in msg1 response") }
                return false
            }

            // Decode PAKE message
            guard let pakeData = Data(base64Encoded: pakeBase64),
                  let pakeStr = String(data: pakeData, encoding: .utf8),
                  let pakeMsg = try? JSONSerialization.jsonObject(with: Data(pakeStr.utf8)) as? [String: Any] else {
                if icpDebug { print("[iCloudPasswords] failed to decode PAKE msg1") }
                return false
            }

            // Ask user for PIN
            guard let pin = await showPINDialog(window: window) else {
                if icpDebug { print("[iCloudPasswords] user cancelled PIN entry") }
                await nmHost.stop()
                return false
            }

            client.pin = pin

            // Process MSG 1 and generate MSG 2
            let msg2Base64 = try client.processMessage1(pakeMsg)

            let msg2Str = "{\"QID\":\"m2\",\"PAKE\":\"\(msg2Base64)\"}"
            try await nmHost.send(["cmd": 2, "msg": msg2Str])

            // Receive MSG 3 (confirmation)
            let msg3Response = try await nmHost.receive()

            if let msg3Cmd = msg3Response["cmd"] as? Int, msg3Cmd == 2,
               let msg3Payload = msg3Response["payload"] as? [String: Any],
               let msg3PakeBase64 = msg3Payload["PAKE"] as? String,
               let msg3PakeData = Data(base64Encoded: msg3PakeBase64),
               let msg3PakeStr = String(data: msg3PakeData, encoding: .utf8),
               let msg3Pake = try? JSONSerialization.jsonObject(with: Data(msg3PakeStr.utf8)) as? [String: Any] {
                try client.processMessage3(msg3Pake)
            } else if let msg3Cmd = msg3Response["cmd"] as? Int, msg3Cmd == 9 || msg3Cmd == 10 {
                if icpDebug { print("[iCloudPasswords] session rejected (cmd=\(msg3Cmd))") }
                await nmHost.stop()
                return false
            }

            sessionEstablished = true
            if icpDebug { print("[iCloudPasswords] session established") }
            return true

        } catch {
            if icpDebug { print("[iCloudPasswords] connect failed: \(error)") }
            if let h = host { await h.stop() }
            return false
        }
    }

    /// Get login names (usernames) available for a hostname.
    public func getLoginNames(hostname: String) async -> [iCloudCredentialEntry] {
        guard sessionEstablished, let host, let srp else { return [] }

        do {
            let query = try JSONSerialization.data(withJSONObject: [
                "ACT": 5,  // actGhostSearch
                "URL": hostname,
            ] as [String: Any])
            let queryStr = String(data: query, encoding: .utf8)!
            let smsg = try srp.createSMSG(queryStr)

            let payload = try JSONSerialization.data(withJSONObject: [
                "QID": "CmdGetLoginNames4URL",
                "SMSG": smsg,
            ])

            try await host.send([
                "cmd": 4,
                "url": hostname,
                "tabId": 0,
                "frameId": 0,
                "payload": String(data: payload, encoding: .utf8)!,
            ])

            let response = try await host.receive()

            guard let respPayload = response["payload"] as? [String: Any] else {
                return []
            }

            // SMSG may arrive as a JSON string or as an already-parsed dictionary
            let respSMSG: String
            if let s = respPayload["SMSG"] as? String {
                respSMSG = s
            } else if let dict = respPayload["SMSG"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      let s = String(data: data, encoding: .utf8) {
                respSMSG = s
            } else {
                return []
            }

            let decrypted = try srp.parseSMSG(respSMSG)
            if icpDebug { print("[iCloudPasswords] getLoginNames decrypted: \(decrypted)") }
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(decrypted.utf8)) as? [String: Any] else {
                return []
            }

            guard let status = parsed["STATUS"] as? Int, status == 0 else {
                if icpDebug { print("[iCloudPasswords] getLoginNames status: \(parsed["STATUS"] ?? "nil")") }
                return []
            }

            // Parse entries: either "Entries" array or "Entry_N" keys
            var entries: [[String: Any]] = []
            if let e = parsed["Entries"] as? [[String: Any]] {
                entries = e
            } else {
                for (key, value) in parsed.sorted(by: { $0.key < $1.key }) {
                    if key.hasPrefix("Entry_"), let entry = value as? [String: Any] {
                        entries.append(entry)
                    }
                }
            }

            return entries.compactMap { entry in
                guard let usr = entry["USR"] as? String, usr != "Passwords not saved" else { return nil }
                let sites = entry["sites"] as? [String] ?? []
                // Filter: only return entries whose sites list contains the requested hostname
                // (iCloud matches by high-level domain, so we may get unrelated subdomains)
                let matchesSite = sites.isEmpty || sites.contains(where: { $0 == hostname || hostname.hasSuffix("." + $0) })
                guard matchesSite else {
                    if icpDebug { print("[iCloudPasswords] skipping entry for \(sites) — doesn't match \(hostname)") }
                    return nil
                }
                let site = sites.first ?? hostname
                return iCloudCredentialEntry(username: usr, password: nil, domain: site)
            }

        } catch {
            if icpDebug { print("[iCloudPasswords] getLoginNames error: \(error)") }
            return []
        }
    }

    /// Get the password for a specific username at a URL.
    public func getPassword(url: String, username: String) async -> String? {
        guard sessionEstablished, let host, let srp else { return nil }

        do {
            let query = try JSONSerialization.data(withJSONObject: [
                "ACT": 2,  // actSearch
                "URL": url,
                "USR": username,
            ] as [String: Any])
            let queryStr = String(data: query, encoding: .utf8)!
            let smsg = try srp.createSMSG(queryStr)

            let payload = try JSONSerialization.data(withJSONObject: [
                "QID": "CmdGetPassword4LoginName",
                "SMSG": smsg,
            ])

            try await host.send([
                "cmd": 5,
                "url": url,
                "tabId": 0,
                "frameId": 0,
                "payload": String(data: payload, encoding: .utf8)!,
            ])

            let response = try await host.receive()

            guard let respPayload = response["payload"] as? [String: Any] else {
                return nil
            }

            // SMSG may arrive as a JSON string or as an already-parsed dictionary
            let respSMSG: String
            if let s = respPayload["SMSG"] as? String {
                respSMSG = s
            } else if let dict = respPayload["SMSG"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      let s = String(data: data, encoding: .utf8) {
                respSMSG = s
            } else {
                return nil
            }

            let decrypted = try srp.parseSMSG(respSMSG)
            if icpDebug { print("[iCloudPasswords] getPassword decrypted: \(decrypted)") }
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(decrypted.utf8)) as? [String: Any],
                  let status = parsed["STATUS"] as? Int, status == 0 else {
                return nil
            }

            // Find the matching entry
            var entries: [[String: Any]] = []
            if let e = parsed["Entries"] as? [[String: Any]] {
                entries = e
            } else {
                for (key, value) in parsed.sorted(by: { $0.key < $1.key }) {
                    if key.hasPrefix("Entry_"), let entry = value as? [String: Any] {
                        entries.append(entry)
                    }
                }
            }

            for entry in entries {
                if let usr = entry["USR"] as? String, usr == username,
                   let pwd = entry["PWD"] as? String, pwd != "Not Included" {
                    return pwd
                }
            }

            // If no exact match, return first entry with a password
            return entries.first(where: { ($0["PWD"] as? String) != nil && ($0["PWD"] as? String) != "Not Included" })?["PWD"] as? String

        } catch {
            if icpDebug { print("[iCloudPasswords] getPassword error: \(error)") }
            return nil
        }
    }

    /// Save a credential (new or updated) to iCloud Keychain via the helper.
    public func savePassword(url: String, username: String, password: String) async -> Bool {
        guard sessionEstablished, let host, let srp else { return false }

        do {
            let query = try JSONSerialization.data(withJSONObject: [
                "ACT": 4,  // actMaybeAdd
                "URL": "",
                "USR": "",
                "PWD": "",
                "NURL": url,
                "NUSR": username,
                "NPWD": password,
            ] as [String: Any])
            let queryStr = String(data: query, encoding: .utf8)!
            let smsg = try srp.createSMSG(queryStr)

            let payload = try JSONSerialization.data(withJSONObject: [
                "QID": "CmdSetPassword4LoginName_URL",
                "SMSG": smsg,
            ])

            try await host.send([
                "cmd": 6,
                "tabId": 0,
                "frameId": 0,
                "payload": String(data: payload, encoding: .utf8)!,
            ])

            let response = try await host.receive()
            if icpDebug { print("[iCloudPasswords] savePassword response: \(response)") }
            return true

        } catch {
            if icpDebug { print("[iCloudPasswords] savePassword error: \(error)") }
            return false
        }
    }

    public func disconnect() async {
        sessionEstablished = false
        if let host { await host.stop() }
        host = nil
        srp = nil
    }

    // MARK: - PIN Dialog

    private func showPINDialog(window: NSWindow?) async -> String? {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Enter iCloud Passwords Code"
            alert.informativeText = "Open the Passwords app or System Settings \u{2192} Passwords to see your verification code."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            field.placeholderString = "000000"
            field.alignment = .center
            field.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
            alert.accessoryView = field

            let handler: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertFirstButtonReturn {
                    let pin = field.stringValue.trimmingCharacters(in: .whitespaces)
                    continuation.resume(returning: pin.isEmpty ? nil : pin)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            if let window {
                alert.beginSheetModal(for: window, completionHandler: handler)
                alert.window.makeFirstResponder(field)
            } else {
                let response = alert.runModal()
                handler(response)
            }
        }
    }
}
