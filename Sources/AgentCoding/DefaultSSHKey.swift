import Crypto
import Foundation

/// One ed25519 keypair shared as the *default* across new profiles.
///
/// Lives at `~/Library/Application Support/BromureAC/default-ssh/`
/// alongside the same `id_ed25519.raw` (32 seed + 32 pub) and
/// `id_ed25519.pub` (OpenSSH text) layout that `makeSSHKey` writes
/// into per-profile agent dirs. `ensureExists()` runs at app startup
/// and on first read; new profiles forked from the user's preferences
/// template get the keypair copied into their own agent dir at save
/// time, so each profile owns an independent file copy of the same
/// key (matches the per-profile SSH-agent loader's expectations).
public enum DefaultSSHKey {
    public enum Error: Swift.Error, LocalizedError {
        case generationFailed(String)
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .generationFailed(let r): return "Couldn't create the default SSH key: \(r)"
            case .readFailed(let r): return "Couldn't read the default SSH key: \(r)"
            }
        }
    }

    /// `~/Library/Application Support/BromureAC/default-ssh/`.
    public static var directoryURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("default-ssh", isDirectory: true)
    }

    public static var rawURL: URL {
        directoryURL.appendingPathComponent("id_ed25519.raw")
    }

    public static var pubURL: URL {
        directoryURL.appendingPathComponent("id_ed25519.pub")
    }

    /// True iff the keypair files are present on disk.
    public static var exists: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: rawURL.path)
            && fm.fileExists(atPath: pubURL.path)
    }

    /// Generate the keypair if it doesn't exist already. Idempotent —
    /// safe to call from app-launch unconditionally.
    @discardableResult
    public static func ensureExists() throws -> URL {
        if exists { return directoryURL }
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL,
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation              // 32 bytes
        let pub = key.publicKey.rawRepresentation     // 32 bytes

        var raw = Data()
        raw.append(seed)
        raw.append(pub)
        try raw.write(to: rawURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: rawURL.path)

        let label = "ssh-ed25519"
        var blob = Data()
        // length-prefixed strings, big-endian uint32
        var labelLen = UInt32(label.utf8.count).bigEndian
        blob.append(Data(bytes: &labelLen, count: 4))
        blob.append(Data(label.utf8))
        var pubLen = UInt32(pub.count).bigEndian
        blob.append(Data(bytes: &pubLen, count: 4))
        blob.append(pub)
        let pubText = "ssh-ed25519 \(blob.base64EncodedString()) bromure-ac-default"
        try pubText.write(to: pubURL, atomically: true, encoding: .utf8)
        return directoryURL
    }

    /// Read the OpenSSH public-key text from disk. Generates the key
    /// first if it doesn't exist — the only failure path is a real
    /// I/O error.
    public static func publicKeyText() throws -> String {
        try ensureExists()
        do {
            return try String(contentsOf: pubURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Error.readFailed(error.localizedDescription)
        }
    }

    /// Copy the default keypair into a target agent dir (typically
    /// `<profile>/agent/`). Creates the dir if needed. Mirrors the
    /// permission bits set by `makeSSHKey` so the in-process ssh-agent
    /// loader treats the files identically to a per-profile-generated
    /// keypair.
    public static func copy(to agentDir: URL) throws {
        try ensureExists()
        let fm = FileManager.default
        try fm.createDirectory(at: agentDir,
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let dstRaw = agentDir.appendingPathComponent("id_ed25519.raw")
        let dstPub = agentDir.appendingPathComponent("id_ed25519.pub")
        try? fm.removeItem(at: dstRaw)
        try? fm.removeItem(at: dstPub)
        try fm.copyItem(at: rawURL, to: dstRaw)
        try fm.copyItem(at: pubURL, to: dstPub)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: dstRaw.path)
    }
}
