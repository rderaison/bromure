import Foundation

// MARK: - Native JBD2 journal replay
//
// The one repair a crash-consistent image actually needs. Checkpoints are
// clonefile'd from a live disk, so their journal is dirty (INCOMPAT_RECOVER
// set) and their metadata is stale until the committed transactions are
// written back to their home blocks — exactly what the guest kernel does at
// mount and what e2fsck does first. This is a from-scratch Swift port of that
// recovery pass (kernel fs/jbd2/recovery.c), so the host needs no e2fsprogs.
//
// Scope: replay only. The orphan list (s_last_orphan) is deliberately left
// alone — the guest kernel processes it on every mount, clean or not — and
// arbitrary-corruption repair stays with the real e2fsck inside the VM.
//
// JBD2 on-disk format notes (kernel Documentation/filesystems/journalling):
//   • ALL journal metadata fields are BIG-endian, unlike ext4 proper.
//   • The journal is a regular file (inode 8); its logical block j maps to an
//     fs block through the inode's block map. Journal block 0 holds the
//     journal superblock; the circular log occupies [s_first, s_maxlen).
//   • Log records: descriptor (type 1: tags naming the fs blocks the data
//     blocks that follow belong to), commit (type 2: seals a transaction),
//     revoke (type 5: fs blocks whose earlier journal copies must NOT be
//     replayed). A transaction missing its commit block never happened.

// MARK: big-endian byte helpers (JBD2 only — ext4 proper is little-endian)

@inline(__always) func be16(_ b: [UInt8], _ o: Int) -> UInt16 {
    (UInt16(b[o]) << 8) | UInt16(b[o + 1])
}
@inline(__always) func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
    (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
}
@inline(__always) func putBE32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    b[o] = UInt8((v >> 24) & 0xff); b[o + 1] = UInt8((v >> 16) & 0xff)
    b[o + 2] = UInt8((v >> 8) & 0xff); b[o + 3] = UInt8(v & 0xff)
}

enum Ext4JournalError: Error, CustomStringConvertible {
    case noJournal(String)
    case unsupported(String)
    case corrupt(String)
    var description: String {
        switch self {
        case .noJournal(let m): return "no usable journal: \(m)"
        case .unsupported(let m): return "unsupported journal feature: \(m)"
        case .corrupt(let m): return "corrupt journal: \(m)"
        }
    }
}

final class Ext4Journal {
    static let magic: UInt32 = 0xC03B_3998

    // journal_header_t h_blocktype values
    private static let DESCRIPTOR: UInt32 = 1
    private static let COMMIT: UInt32 = 2
    private static let SUPERBLOCK_V1: UInt32 = 3
    private static let SUPERBLOCK_V2: UInt32 = 4
    private static let REVOKE: UInt32 = 5

    // journal incompat feature bits
    private static let INCOMPAT_REVOKE: UInt32 = 0x1
    private static let INCOMPAT_64BIT: UInt32 = 0x2
    private static let INCOMPAT_ASYNC_COMMIT: UInt32 = 0x4
    private static let INCOMPAT_CSUM_V2: UInt32 = 0x8
    private static let INCOMPAT_CSUM_V3: UInt32 = 0x10
    private static let INCOMPAT_KNOWN: UInt32 = 0x1 | 0x2 | 0x8 | 0x10

    // block-tag flags
    private static let FLAG_ESCAPE: UInt32 = 1
    private static let FLAG_SAME_UUID: UInt32 = 2
    private static let FLAG_LAST_TAG: UInt32 = 8

    private let vol: Ext4Volume
    /// journal logical block → fs physical block
    private let map: [Int: UInt64]

    // Journal superblock fields (all parsed from big-endian block 0).
    private(set) var maxlen: UInt32 = 0
    private(set) var first: UInt32 = 0
    private(set) var sequence: UInt32 = 0
    private(set) var start: UInt32 = 0
    private(set) var errno: Int32 = 0
    private var featureIncompat: UInt32 = 0
    private var uuid = [UInt8](repeating: 0, count: 16)

    private var is64: Bool { featureIncompat & Ext4Journal.INCOMPAT_64BIT != 0 }
    private var csumV3: Bool { featureIncompat & Ext4Journal.INCOMPAT_CSUM_V3 != 0 }
    private var csumV2: Bool { featureIncompat & Ext4Journal.INCOMPAT_CSUM_V2 != 0 }
    private var hasCsum: Bool { csumV2 || csumV3 }
    /// Seed for every v2/v3 journal checksum: crc32c(~0, journal uuid).
    private var csumSeed: UInt32 { Crc32c.hash(0xFFFF_FFFF, uuid) }

    /// True when the log has anything to replay (s_start == 0 ⇔ empty log).
    var needsReplay: Bool { start != 0 }

    init(volume: Ext4Volume) throws {
        self.vol = volume
        guard volume.sb.hasJournal else {
            throw Ext4JournalError.noJournal("filesystem has no journal feature")
        }
        let jino = volume.sb.journalInum
        guard jino != 0 else {
            throw Ext4JournalError.unsupported("external journal device")
        }
        let jnode = try volume.inode(jino)
        let jblocks = Int(jnode.size) / volume.blockSize
        guard jblocks >= 2 else {
            throw Ext4JournalError.corrupt("journal inode is only \(jnode.size) bytes")
        }
        self.map = try volume.blockMap(jnode, upTo: jblocks)

        let sb = try readJournalBlock(0)
        guard sb.count == volume.blockSize, be32(sb, 0) == Ext4Journal.magic else {
            throw Ext4JournalError.corrupt("bad journal superblock magic")
        }
        let btype = be32(sb, 4)
        guard btype == Ext4Journal.SUPERBLOCK_V1 || btype == Ext4Journal.SUPERBLOCK_V2 else {
            throw Ext4JournalError.corrupt("journal superblock has block type \(btype)")
        }
        guard be32(sb, 12) == UInt32(volume.blockSize) else {
            throw Ext4JournalError.unsupported(
                "journal block size \(be32(sb, 12)) ≠ fs block size \(volume.blockSize)")
        }
        maxlen = be32(sb, 16)
        first = be32(sb, 20)
        sequence = be32(sb, 24)
        start = be32(sb, 28)
        errno = Int32(bitPattern: be32(sb, 32))
        featureIncompat = btype == Ext4Journal.SUPERBLOCK_V2 ? be32(sb, 40) : 0
        uuid = Array(sb[48..<64])
        guard maxlen >= 2, first >= 1, first < maxlen, UInt64(maxlen) <= UInt64(jblocks) else {
            throw Ext4JournalError.corrupt("journal geometry first=\(first) maxlen=\(maxlen)")
        }
        let unknown = featureIncompat & ~Ext4Journal.INCOMPAT_KNOWN
        if unknown != 0 {
            throw Ext4JournalError.unsupported(
                String(format: "incompat journal features 0x%x", unknown))
        }
        if featureIncompat & Ext4Journal.INCOMPAT_ASYNC_COMMIT != 0 {
            throw Ext4JournalError.unsupported("journal_async_commit")
        }
    }

    private func readJournalBlock(_ n: UInt32) throws -> [UInt8] {
        guard let phys = map[Int(n)], phys != 0 else {
            throw Ext4JournalError.corrupt("journal block \(n) is a hole")
        }
        return try vol.readBlock(phys)
    }

    /// Circular-log advance: past s_maxlen the log wraps to s_first.
    private func advance(_ n: UInt32, by k: UInt32) -> UInt32 {
        var v = n + k
        while v >= maxlen { v -= maxlen - first }
        return v
    }

    // MARK: log records

    private struct Tag {
        let fsBlock: UInt64
        let escaped: Bool
        let checksum: UInt32          // tag checksum as stored (v2: 16-bit)
        let journalBlock: UInt32      // where the data copy lives in the log
    }

    /// Parse a descriptor block's tag list. Each tag names the home fs block of
    /// the next data block in the log (data blocks follow the descriptor).
    private func parseTags(_ block: [UInt8], descriptorAt: UInt32) -> [Tag] {
        var tags = [Tag]()
        var pos = 12
        var dataIndex: UInt32 = 1
        let tagSize = csumV3 ? 16 : (is64 ? 12 : 8)
        // v2/v3 descriptor blocks reserve a 4-byte tail checksum.
        let end = block.count - (hasCsum ? 4 : 0)
        while pos + tagSize <= end {
            let lo = UInt64(be32(block, pos))
            let flags: UInt32
            let checksum: UInt32
            var hi: UInt64 = 0
            if csumV3 {
                flags = be32(block, pos + 4)
                hi = UInt64(be32(block, pos + 8))
                checksum = be32(block, pos + 12)
            } else {
                checksum = UInt32(be16(block, pos + 4))
                flags = UInt32(be16(block, pos + 6))
                if is64 { hi = UInt64(be32(block, pos + 8)) }
            }
            tags.append(Tag(fsBlock: (hi << 32) | lo,
                            escaped: flags & Ext4Journal.FLAG_ESCAPE != 0,
                            checksum: checksum,
                            journalBlock: advance(descriptorAt, by: dataIndex)))
            dataIndex += 1
            pos += tagSize
            if flags & Ext4Journal.FLAG_LAST_TAG != 0 { break }
            if flags & Ext4Journal.FLAG_SAME_UUID == 0 { pos += 16 }   // per-tag uuid
        }
        return tags
    }

    /// Revoked fs blocks listed in a revoke record.
    private func parseRevoke(_ block: [UInt8]) -> [UInt64] {
        guard block.count >= 16 else { return [] }
        var count = Int(be32(block, 12))            // bytes used, incl. 16-byte header
        count = min(count, block.count - (hasCsum ? 4 : 0))
        var out = [UInt64]()
        var pos = 16
        let step = is64 ? 8 : 4
        while pos + step <= count {
            out.append(is64 ? ((UInt64(be32(block, pos)) << 32) | UInt64(be32(block, pos + 4)))
                            : UInt64(be32(block, pos)))
            pos += step
        }
        return out
    }

    /// A commit block seals its transaction only if its checksum verifies
    /// (v2/v3): crc32c over the whole block with h_chksum[0] zeroed.
    private func commitVerifies(_ block: [UInt8]) -> Bool {
        guard hasCsum else { return true }
        let stored = be32(block, 16)                // h_chksum[0]
        var b = block
        putBE32(&b, 16, 0)
        return Crc32c.hash(csumSeed, b) == stored
    }

    /// v2/v3 data-block tag checksum: crc32c(seed → seq(be32) → data block).
    private func tagChecksum(seq: UInt32, data: [UInt8]) -> UInt32 {
        var seqBytes = [UInt8](repeating: 0, count: 4)
        putBE32(&seqBytes, 0, seq)
        return Crc32c.hash(Crc32c.hash(csumSeed, seqBytes), data)
    }

    // MARK: replay

    struct ReplayStats {
        var transactions = 0
        var blocksWritten = 0
        var revoked = 0
        var checksumErrors = 0
    }

    private struct Transaction {
        let seq: UInt32
        var tags: [Tag] = []
        var revokes: [UInt64] = []
    }

    /// Scan the log from s_start and return every transaction sealed by a
    /// valid commit block, in commit order. An unterminated tail transaction
    /// (crash mid-commit) is dropped, matching the kernel.
    private func scan() throws -> [Transaction] {
        var done = [Transaction]()
        var current = Transaction(seq: sequence)
        var next = start
        var steps: UInt32 = 0
        while steps <= maxlen {                     // one full lap = corrupt/loop guard
            steps += 1
            let block: [UInt8]
            do { block = try readJournalBlock(next) } catch { break }
            guard block.count == vol.blockSize,
                  be32(block, 0) == Ext4Journal.magic,
                  be32(block, 8) == current.seq else { break }   // end of log
            switch be32(block, 4) {
            case Ext4Journal.DESCRIPTOR:
                let tags = parseTags(block, descriptorAt: next)
                current.tags.append(contentsOf: tags)
                next = advance(next, by: 1 + UInt32(tags.count))
            case Ext4Journal.REVOKE:
                current.revokes.append(contentsOf: parseRevoke(block))
                next = advance(next, by: 1)
            case Ext4Journal.COMMIT:
                guard commitVerifies(block) else { return done }  // torn commit = end
                done.append(current)
                current = Transaction(seq: current.seq &+ 1)
                next = advance(next, by: 1)
            default:
                return done                          // stray superblock/unknown = end
            }
        }
        return done
    }

    /// Write every committed transaction's blocks back to their home location,
    /// honouring revocations. Caller is responsible for clearing the ext4
    /// superblock's INCOMPAT_RECOVER afterwards (`finish` resets the log).
    func replay() throws -> ReplayStats {
        var stats = ReplayStats()
        guard needsReplay else { return stats }
        let transactions = try scan()
        guard !transactions.isEmpty else { return stats }

        // Revocation table: fs block → highest sequence that revoked it. A
        // journal copy is stale (skipped) when a revoke with sequence >= its
        // transaction's exists — the block was freed/reused after that write.
        var revoked = [UInt64: UInt32]()
        for t in transactions {
            for b in t.revokes { revoked[b] = max(revoked[b] ?? 0, t.seq) }
        }

        let fsBlocks = vol.sb.blocksCount
        for t in transactions {
            stats.transactions += 1
            for tag in t.tags {
                if let rseq = revoked[tag.fsBlock], rseq >= t.seq {
                    stats.revoked += 1
                    continue
                }
                guard tag.fsBlock < fsBlocks else {
                    stats.checksumErrors += 1        // wild target — never write it
                    continue
                }
                var data = try readJournalBlock(tag.journalBlock)
                if hasCsum {
                    let want = csumV3 ? tag.checksum : (tag.checksum & 0xFFFF)
                    let got = tagChecksum(seq: t.seq, data: data)
                    let match = csumV3 ? got == want : (got & 0xFFFF) == want
                    if !match {
                        stats.checksumErrors += 1    // corrupt copy — don't spread it
                        continue
                    }
                }
                if tag.escaped { putBE32(&data, 0, Ext4Journal.magic) }
                try vol.fsWrite(at: tag.fsBlock * UInt64(vol.blockSize), data)
                stats.blocksWritten += 1
            }
        }
        vol.dev.fsync()

        // Reset the log: empty (s_start = 0), next transaction follows the last
        // replayed one. Mirrors jbd2_mark_journal_empty.
        var jsb = try readJournalBlock(0)
        let nextSeq = (transactions.last?.seq ?? sequence) &+ 1
        putBE32(&jsb, 24, nextSeq)                   // s_sequence
        putBE32(&jsb, 28, 0)                         // s_start
        putBE32(&jsb, 32, UInt32(bitPattern: errno)) // preserve s_errno
        if hasCsum {
            putBE32(&jsb, 0xFC, 0)                   // s_checksum
            putBE32(&jsb, 0xFC, Crc32c.hash(0xFFFF_FFFF, Array(jsb[0..<1024])))
        }
        guard let phys = map[0] else { throw Ext4JournalError.corrupt("journal block 0 unmapped") }
        try vol.fsWrite(at: phys * UInt64(vol.blockSize), jsb)
        vol.dev.fsync()
        start = 0
        sequence = nextSeq
        return stats
    }
}
