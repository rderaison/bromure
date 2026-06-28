import Foundation
import CryptoKit

/// Per-VM API keys for the local inference engine — persistent across app runs
/// and VM suspend/reset, and self-identifying so a call can be traced to the
/// profile that made it.
///
/// A guest's key is `brk-<profileID>-<HMAC(master, profileID)>`. The engine
/// validates it and recovers the profileID with only the persistent `master`
/// secret — there's no per-key registry to keep in sync as VMs come and go.
/// Because the key is a deterministic function of (master, profileID) and the
/// master is persisted once, a VM's key is stable across reboots, suspend/reset
/// and app restarts. (The old key was random per app-run, so a VM that had
/// baked the previous run's key 401'd after the app relaunched.)
///
/// The parent loads the master from disk; the engine child receives the same
/// master via `BROMURE_ENGINE_MASTER` so both sides agree.
enum EngineKey {
    static let masterEnvVar = "BROMURE_ENGINE_MASTER"

    /// 32-byte master secret (env-provided in the engine child, else read from
    /// — or created in — Application Support).
    static let master: Data = {
        if let hex = ProcessInfo.processInfo.environment[masterEnvVar],
           let d = Data(hexString: hex), d.count == 32 { return d }
        if let d = try? Data(contentsOf: masterURL), d.count == 32 { return d }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        do {
            try FileManager.default.createDirectory(
                at: masterURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // .atomic only — NOT .completeFileProtection (an iOS data-protection
            // flag; on macOS it can make the write fail / the file unreadable,
            // which silently defeated persistence and broke per-VM key auth).
            try fresh.write(to: masterURL, options: [.atomic])
        } catch {
            FileHandle.standardError.write(Data("[enginekey] master persist failed: \(error)\n".utf8))
        }
        return fresh
    }()

    /// The master as hex — handed to the engine child via `BROMURE_ENGINE_MASTER`.
    static var masterHex: String { master.hexString }

    private static var masterURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("engine-master.key")
    }

    private static func compact(_ id: UUID) -> String {
        id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    private static func tag(forCompactID pid: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(pid.utf8), using: SymmetricKey(data: master))
        return String(mac.hexString.prefix(32))   // 128-bit auth tag
    }

    /// The persistent per-VM key for `profileID`.
    static func perVM(profileID: UUID) -> String {
        let pid = compact(profileID)
        return "brk-\(pid)-\(tag(forCompactID: pid))"
    }

    /// Validate a guest key; return the profileID it identifies, or nil if it's
    /// malformed or the HMAC tag doesn't verify.
    static func profileID(forKey key: String) -> UUID? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "brk" else { return nil }
        let pid = String(parts[1]), provided = String(parts[2])
        guard pid.count == 32 else { return nil }
        let expected = tag(forCompactID: pid)
        guard constantTimeEqual(provided, expected) else { return nil }
        return uuid(fromCompact: pid)
    }

    private static func uuid(fromCompact pid: String) -> UUID? {
        guard pid.count == 32 else { return nil }
        let h = Array(pid)
        let dashed = String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16])
            + "-" + String(h[16..<20]) + "-" + String(h[20..<32])
        return UUID(uuidString: dashed)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        let s = hexString.count % 2 == 0 ? hexString : "0" + hexString
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}

private extension HashedAuthenticationCode {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
