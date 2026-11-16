import Crypto
import Foundation

/// Which overlay a saved state belongs to. A state file is only valid with
/// the exact disk it was saved with (the guest's page cache and the disk
/// must agree), so the two are one snapshot: the identity is written next to
/// the state as `<state>.identity.json` and checked before a restore. Same
/// intent as the macOS `vm.state.json` drift fingerprint.
///
/// The disk is matched by what a move or copy keeps: size, mtime (ns), the
/// first 64 KiB and sampled blocks across the file. Not by device and inode
/// (recorded, for the log only): a workspace moved to another filesystem
/// (rsync -a, a restore from backup) is the same disk, and macOS's
/// fingerprint doesn't tie a save to a file either.
// @port-skip linux-only: Firecracker snapshots pair with raw system disks (VZ save files with APFS clones)
public struct SnapshotIdentity: Codable, Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var size: UInt64
    public var mtimeNanoseconds: Int64
    /// SHA-256 of the overlay's first 64 KiB (the qcow2 header and L1 table).
    public var headerSHA256: String
    /// SHA-256 over `sampleCount` blocks of 64 KiB spread evenly across the
    /// file, the last block included (each prefixed by its offset). Nil in a
    /// sidecar written before samples: it verifies on the other fields.
    public var sampleSHA256: String?

    static let blockSize = 64 * 1024
    static let sampleCount = 8

    // @port-skip linux-only: snapshot identity
    public static func of(overlay path: String) throws -> SnapshotIdentity {
        var st = stat()
        guard stat(path, &st) == 0 else { throw MachineError.io("stat \(path)", errno) }
        guard let h = FileHandle(forReadingAtPath: path) else { throw MachineError.io("open \(path)", errno) }
        defer { try? h.close() }
        let head = try h.read(upToCount: blockSize) ?? Data()
        // Bounded on any disk: sampleCount reads of one block (holes in a
        // sparse image read as zeros without touching storage).
        var samples = SHA256()
        for offset in sampleOffsets(size: UInt64(st.st_size)) {
            try h.seek(toOffset: offset)
            var o = offset.littleEndian
            withUnsafeBytes(of: &o) { samples.update(bufferPointer: $0) }
            samples.update(data: try h.read(upToCount: blockSize) ?? Data())
        }
        return SnapshotIdentity(
            device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: UInt64(st.st_size),
            mtimeNanoseconds: Int64(st.st_mtim.tv_sec) * 1_000_000_000 + Int64(st.st_mtim.tv_nsec),
            headerSHA256: hex(SHA256.hash(data: head)),
            sampleSHA256: hex(samples.finalize()))
    }

    /// Where the sampled blocks start: `sampleCount` offsets from 0 to the
    /// last whole block, evenly spaced, 4 KiB-aligned.
    // @port-skip linux-only: snapshot identity
    static func sampleOffsets(size: UInt64) -> [UInt64] {
        let block = UInt64(blockSize)
        guard size > block else { return [0] }
        let last = size - block, n = UInt64(sampleCount)
        return (0..<n).map { i in i == n - 1 ? last : (last * i / (n - 1)) & ~4095 }
    }

    // @port-skip linux-only: snapshot identity
    private static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// The same disk: size, mtime, header and (when both have them) the
    /// samples. Device and inode don't count (see the type's doc).
    // @port-skip linux-only: snapshot identity
    public func matches(_ other: SnapshotIdentity) -> Bool {
        guard size == other.size, mtimeNanoseconds == other.mtimeNanoseconds,
              headerSHA256 == other.headerSHA256 else { return false }
        guard let mine = sampleSHA256, let theirs = other.sampleSHA256 else { return true }
        return mine == theirs
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
        guard saved.matches(now) else { throw MachineError.snapshotMismatch(state: state, overlay: overlay) }
    }

    /// Every sidecar a state may have (cleanup after a restore or a removal).
    // @port-skip linux-only: snapshot identity
    public static func sidecars(forState state: String, disks: Int) -> [String] {
        [sidecarPath(forState: state)] + (0..<disks).map { sidecarPath(forState: state, disk: $0) }
    }
}
