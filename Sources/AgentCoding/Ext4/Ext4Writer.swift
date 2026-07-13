import Foundation

// MARK: - Userland ext4 writer (best-effort)
//
// The write model is deliberately conservative because these images use
// metadata_csum: any metadata block written with a stale crc32c makes the kernel
// (and fsck) reject the filesystem. Two tiers:
//
//  • In-place overwrite — when the new contents fit the file's *already
//    allocated* blocks, we touch only data blocks plus the one inode, and
//    recompute that inode's checksum. The result is fully self-consistent and
//    needs no fsck.
//  • Grow / create / delete — these mutate block/inode bitmaps and group
//    descriptors (each with its own checksum) and free counts. Getting every
//    checksum right by hand is fragile, so those paths are gated behind a
//    post-write `fsck.ext4 -fy` (Ext4Fsck) and throw `.needsFsckGrow` until it
//    runs. This matches the "post fsck.ext4 if needed" design.

enum Ext4WriteOutcome: Equatable {
    case inPlace                    // fit existing blocks; no fsck required
    case grew(blocksAdded: Int)     // allocated blocks; caller should fsck
}

extension Ext4Error {
    static let needsFsckGrow = Ext4Error.unsupported(
        "file must grow beyond its allocated blocks — enable fsck-backed writes")
}

extension Ext4Volume {

    // MARK: inode checksum (metadata_csum)

    /// Compute an inode's crc32c the way the kernel does: seed → inode number →
    /// i_generation → the inode body with the two checksum fields zeroed.
    func inodeChecksum(_ raw: [UInt8], ino: UInt32) -> (lo: UInt16, hi: UInt16, usesHi: Bool) {
        let seed = sb.csumSeed
        var inum = [UInt8](repeating: 0, count: 4); putLE32(&inum, 0, ino)
        var crc = Crc32c.hash(seed, inum)
        crc = Crc32c.hash(crc, raw[0x64..<0x68])            // i_generation (LE on disk)
        var body = raw
        putLE16(&body, 0x7C, 0)                              // i_checksum_lo
        let extraIsize = raw.count >= 0x82 ? Int(le16(raw, 0x80)) : 0
        let usesHi = sb.inodeSize > 128 && extraIsize >= 4   // FITS_IN_INODE(i_checksum_hi)
        if usesHi { putLE16(&body, 0x82, 0) }               // i_checksum_hi
        crc = Crc32c.hash(crc, body)
        return (UInt16(crc & 0xFFFF), UInt16((crc >> 16) & 0xFFFF), usesHi)
    }

    /// True if the on-disk inode's stored checksum matches a fresh computation.
    /// Always true on filesystems without metadata_csum. This is the acid test
    /// that our crc32c + field layout are correct — it must hold for *every*
    /// untouched inode on a real image.
    func verifyInodeChecksum(_ ino: UInt32) throws -> Bool {
        guard sb.hasMetadataCsum else { return true }
        let node = try inode(ino)
        let c = inodeChecksum(node.raw, ino: ino)
        let storedLo = le16(node.raw, 0x7C)
        let storedHi = c.usesHi ? le16(node.raw, 0x82) : 0
        return c.lo == storedLo && (!c.usesHi || c.hi == storedHi)
    }

    /// Write an inode record back, fixing its checksum first (if enabled).
    func writeInode(_ ino: UInt32, _ raw: [UInt8]) throws {
        guard dev.writable else { throw Ext4Error.io("image opened read-only") }
        var r = raw
        if r.count < sb.inodeSize { r.append(contentsOf: repeatElement(0, count: sb.inodeSize - r.count)) }
        if sb.hasMetadataCsum {
            let c = inodeChecksum(r, ino: ino)
            putLE16(&r, 0x7C, c.lo)
            if c.usesHi { putLE16(&r, 0x82, c.hi) }
        }
        try fsWrite(at: try inodeByteOffset(ino), r)
    }

    // MARK: file overwrite

    /// Replace the contents of the regular file at `path`. Succeeds without fsck
    /// when the new data fits the file's currently-allocated blocks; otherwise
    /// throws `Ext4Error.needsFsckGrow` (the caller runs Ext4Fsck, then retries
    /// with grow enabled once that path is wired).
    @discardableResult
    func overwriteFile(_ path: String, with data: [UInt8]) throws -> Ext4WriteOutcome {
        let ino = try resolve(path)
        return try overwriteFile(ino: ino, with: data)
    }

    @discardableResult
    func overwriteFile(ino: UInt32, with data: [UInt8]) throws -> Ext4WriteOutcome {
        guard dev.writable else { throw Ext4Error.io("image opened read-only") }
        let node = try inode(ino)
        guard node.isRegular else { throw Ext4Error.io("inode \(ino) is not a regular file") }
        if node.isInline { throw Ext4Error.unsupported("inline-data file — editing not supported") }
        if sb.needsRecovery { throw Ext4Error.unsupported("filesystem journal needs recovery — run fsck first") }

        let bs = blockSize
        let neededBlocks = (data.count + bs - 1) / bs
        let map = try blockMap(node, upTo: neededBlocks)

        // Every logical block the new data needs must already be backed by a
        // real (non-hole) physical block, or this is a grow we won't do here.
        for lbn in 0..<neededBlocks where (map[lbn] ?? 0) == 0 {
            throw Ext4Error.needsFsckGrow
        }

        // Overwrite data blocks, zero-filling the tail of the final block.
        for lbn in 0..<neededBlocks {
            guard let phys = map[lbn] else { throw Ext4Error.needsFsckGrow }
            let start = lbn * bs
            let end = Swift.min(start + bs, data.count)
            var blk = Array(data[start..<end])
            if blk.count < bs { blk.append(contentsOf: repeatElement(0, count: bs - blk.count)) }
            try fsWrite(at: phys * UInt64(bs), blk)
        }

        // Update size (lo + high halves) and timestamps, then rewrite the inode
        // with a fresh checksum. Blocks past the (possibly smaller) new EOF stay
        // owned by the inode — harmless; a later fsck -f would only tidy i_blocks.
        var r = node.raw
        putLE32(&r, 4, UInt32(truncatingIfNeeded: data.count))            // i_size_lo
        putLE32(&r, 0x6C, UInt32(truncatingIfNeeded: UInt64(data.count) >> 32))  // i_size_high
        let now = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        putLE32(&r, 0x10, now)                                            // i_mtime
        putLE32(&r, 0x0C, now)                                            // i_ctime
        try writeInode(ino, r)
        dev.fsync()
        return .inPlace
    }

    /// Convenience: overwrite by absolute path with String data.
    @discardableResult
    func overwriteFile(_ path: String, withString s: String) throws -> Ext4WriteOutcome {
        try overwriteFile(path, with: Array(s.utf8))
    }
}
