import Crypto
import Foundation

/// Which overlay a saved state belongs to. A state file is only valid with
/// the exact disk it was saved with (the guest's page cache and the disk
/// must agree), so the two are one snapshot: the identity is written next to
/// the state as `<state>.identity.json` and checked before a restore. Same
/// intent as the macOS `vm.state.json` drift fingerprint.
// @port-skip linux-only: QEMU state files pair with qcow2 overlays (VZ save files with APFS clones)
public struct SnapshotIdentity: Codable, Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var size: UInt64
    public var mtimeNanoseconds: Int64
    /// SHA-256 of the overlay's first 64 KiB (the qcow2 header and L1 table).
    public var headerSHA256: String

    // @port-skip linux-only: snapshot identity
    public static func of(overlay path: String) throws -> SnapshotIdentity {
        var st = stat()
        guard stat(path, &st) == 0 else { throw MachineError.io("stat \(path)", errno) }
        guard let h = FileHandle(forReadingAtPath: path) else { throw MachineError.io("open \(path)", errno) }
        defer { try? h.close() }
        let head = try h.read(upToCount: 64 * 1024) ?? Data()
        return SnapshotIdentity(
            device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: UInt64(st.st_size),
            mtimeNanoseconds: Int64(st.st_mtim.tv_sec) * 1_000_000_000 + Int64(st.st_mtim.tv_nsec),
            headerSHA256: SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined())
    }

    // @port-skip linux-only: snapshot identity
    public static func sidecarPath(forState state: String) -> String { state + ".identity.json" }

    /// The sidecar for a further disk of the snapshot (the home image).
    // @port-skip linux-only: snapshot identity
    public static func sidecarPath(forState state: String, disk index: Int) -> String {
        state + ".identity.disk\(index).json"
    }

    // @port-skip linux-only: snapshot identity
    public func write(forState state: String, disk index: Int? = nil) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let p = index.map { Self.sidecarPath(forState: state, disk: $0) } ?? Self.sidecarPath(forState: state)
        try enc.encode(self).write(to: URL(fileURLWithPath: p), options: .atomic)
    }

    // @port-skip linux-only: snapshot identity
    public static func read(forState state: String, disk index: Int? = nil) throws -> SnapshotIdentity {
        let p = index.map { sidecarPath(forState: state, disk: $0) } ?? sidecarPath(forState: state)
        guard let d = FileManager.default.contents(atPath: p) else { throw MachineError.snapshotMissing(p) }
        return try JSONDecoder().decode(SnapshotIdentity.self, from: d)
    }

    /// Throws unless `overlay` is the very file `state` was saved with.
    // @port-skip linux-only: snapshot identity
    public static func verify(state: String, overlay: String, disk index: Int? = nil) throws {
        let saved = try read(forState: state, disk: index)
        let now = try of(overlay: overlay)
        guard saved == now else { throw MachineError.snapshotMismatch(state: state, overlay: overlay) }
    }

    /// Every sidecar a state may have (cleanup after a restore or a removal).
    // @port-skip linux-only: snapshot identity
    public static func sidecars(forState state: String, disks: Int) -> [String] {
        [sidecarPath(forState: state)] + (0..<disks).map { sidecarPath(forState: state, disk: $0) }
    }
}
