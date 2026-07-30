import Foundation

// MARK: - Native fsck
//
// macOS ships no e2fsprogs and we don't rely on third-party binaries, so this
// is a self-contained check/repair built on Ext4Volume + Ext4Journal:
//
//   repair (autoFix) — replay the JBD2 journal and clear INCOMPAT_RECOVER,
//     which is the whole story for our images: they go unclean by being
//     clonefile'd from a live disk or by a VM dying, not by bit rot. After
//     replay the metadata is exactly what the guest kernel had committed.
//   verify (always) — superblock + group-descriptor checksums, then a
//     reachability walk from the root directory validating every inode's
//     checksum and extent tree. Report-only: anything found here is real
//     corruption beyond a dirty journal, and the honest fix is e2fsck inside
//     a VM (bromure-agentd fscks the home image on boot), not hand-patching.
//
// The orphan list is left for the guest kernel, which processes it on every
// mount regardless of the recovery flag.

enum Ext4Fsck {

    struct Result {
        let status: Int32          // e2fsck-compatible: 0 clean, 1 repaired, 4 errors remain, 8 error
        let output: String
        var repaired: Bool { status == 1 }
        var clean: Bool { status == 0 }
        var summary: String {
            switch status {
            case 0: return "Filesystem is clean."
            case 1: return "Journal replayed; filesystem is now consistent."
            case 4: return "Filesystem has errors this checker cannot repair."
            default: return "fsck could not run (status \(status))."
            }
        }
    }

    enum FsckError: Error, CustomStringConvertible {
        case open(String)
        var description: String {
            switch self {
            case .open(let m): return "cannot check image: \(m)"
            }
        }
    }

    /// Check (and with `autoFix` repair) the ext4 filesystem inside `imagePath`.
    /// `partitionOffset` is accepted for call-site compatibility; the volume
    /// locates the filesystem itself (raw image or GPT/MBR partition).
    static func check(imagePath: String, partitionOffset: UInt64 = 0,
                      autoFix: Bool) throws -> Result {
        var log = [String]()
        var repaired = false
        var unfixable = 0

        var vol: Ext4Volume
        do { vol = try Ext4Volume(path: imagePath, writable: autoFix) }
        catch { throw FsckError.open("\(error)") }
        log.append("volume \"\(vol.volumeName.isEmpty ? "(unnamed)" : vol.volumeName)\", "
                   + "\(vol.sb.blocksCount) blocks of \(vol.blockSize)")

        // Phase 1: journal. Replay is the repair; without autoFix just report.
        if vol.sb.needsRecovery {
            if !autoFix {
                log.append("journal needs replay (INCOMPAT_RECOVER set) — re-run with repair enabled")
                unfixable += 1
            } else {
                do {
                    let journal = try Ext4Journal(volume: vol)
                    if journal.needsReplay {
                        let stats = try journal.replay()
                        log.append("journal replayed: \(stats.transactions) transaction(s), "
                                   + "\(stats.blocksWritten) block(s) written, "
                                   + "\(stats.revoked) revoked")
                        if stats.checksumErrors > 0 {
                            log.append("journal: \(stats.checksumErrors) block(s) skipped "
                                       + "(bad checksum or out-of-range target)")
                            unfixable += stats.checksumErrors
                        }
                    } else {
                        log.append("recovery flag set but the journal is empty — clearing the flag")
                    }
                    // Re-read the superblock from disk (replay may have
                    // rewritten it), clear INCOMPAT_RECOVER, fix its checksum.
                    try clearRecoveryFlag(vol)
                    repaired = true
                    vol = try Ext4Volume(path: imagePath, writable: autoFix)
                } catch {
                    log.append("journal replay failed: \(error)")
                    unfixable += 1
                }
            }
        } else {
            log.append("journal is clean")
        }

        // Phase 2: verification (report-only).
        let issues = verify(vol, log: &log)
        unfixable += issues

        if vol.sb.hasErrors {
            log.append("superblock error flag is set (the kernel hit corruption at runtime)")
            unfixable += 1
        }
        if vol.sb.lastOrphan != 0 {
            log.append("orphan list present (inode \(vol.sb.lastOrphan)) — the guest kernel "
                       + "processes it at next mount")
        }

        let status: Int32 = unfixable > 0 ? 4 : (repaired ? 1 : 0)
        return Result(status: status, output: log.joined(separator: "\n"))
    }

    // MARK: recovery flag

    /// Clear INCOMPAT_RECOVER on the on-disk superblock and recompute its
    /// checksum. Reads fresh bytes: journal replay may have rewritten the
    /// superblock block itself.
    private static func clearRecoveryFlag(_ vol: Ext4Volume) throws {
        var sb = try vol.fsRead(at: 1024, count: 1024)
        guard sb.count == 1024, le16(sb, 56) == 0xEF53 else {
            throw Ext4JournalError.corrupt("superblock vanished after replay")
        }
        putLE32(&sb, 96, le32(sb, 96) & ~Ext4Superblock.INCOMPAT_RECOVER)
        if le32(sb, 100) & Ext4Superblock.ROCOMPAT_METADATA_CSUM != 0 {
            putLE32(&sb, 0x3FC, Crc32c.hash(0xFFFF_FFFF, Array(sb[0..<0x3FC])))
        }
        try vol.fsWrite(at: 1024, sb)
        vol.dev.fsync()
    }

    // MARK: verification

    /// Structural checks. Returns the number of problems found (0 = healthy).
    private static func verify(_ vol: Ext4Volume, log: inout [String]) -> Int {
        var issues = 0

        // Superblock checksum.
        if vol.sb.hasMetadataCsum {
            if let sb = try? vol.fsRead(at: 1024, count: 1024), sb.count == 1024 {
                let stored = le32(sb, 0x3FC)
                let computed = Crc32c.hash(0xFFFF_FFFF, Array(sb[0..<0x3FC]))
                if stored != computed {
                    log.append("superblock checksum mismatch")
                    issues += 1
                }
            }
            issues += verifyGroupDescriptors(vol, log: &log)
        }

        // Reachability walk from the root: inode checksums + extent trees +
        // directory structure. Bounded so a many-million-file image can't hang
        // the UI; the cap is reported, never silent.
        var visited = Set<UInt32>()
        var bad = 0
        let cap = 200_000
        var stack: [UInt32] = [Ext4Volume.rootInode]
        while let ino = stack.popLast(), visited.count < cap {
            if !visited.insert(ino).inserted { continue }
            do {
                let node = try vol.inode(ino)
                if try !vol.verifyInodeChecksum(ino) {
                    bad += 1
                    if bad <= 10 { log.append("inode \(ino): checksum mismatch") }
                    continue
                }
                if node.isDir {
                    for e in try vol.listDir(ino) where e.ino != 0 && e.ino <= vol.sb.inodesCount {
                        stack.append(e.ino)
                    }
                } else if node.isRegular && !node.isInline {
                    // Parses the whole extent tree / block map; throws on a
                    // corrupt header or unreadable interior node.
                    let blocks = (Int(node.size) + vol.blockSize - 1) / vol.blockSize
                    _ = try vol.blockMap(node, upTo: min(blocks, 1))
                }
            } catch {
                bad += 1
                if bad <= 10 { log.append("inode \(ino): \(error)") }
            }
        }
        if visited.count >= cap {
            log.append("verification capped at \(cap) inodes — walk was NOT exhaustive")
        }
        log.append("verified \(visited.count) reachable inode(s)"
                   + (bad > 0 ? ", \(bad) bad" : ""))
        return issues + bad
    }

    /// metadata_csum group-descriptor checksums: crc32c(seed → group# (le32) →
    /// descriptor with bg_checksum zeroed), low 16 bits, stored at +0x1E.
    private static func verifyGroupDescriptors(_ vol: Ext4Volume, log: inout [String]) -> Int {
        let sb = vol.sb
        let gdtStart = (UInt64(sb.firstDataBlock) + 1) * UInt64(vol.blockSize)
        let total = sb.groupCount * sb.descSize
        guard let gdt = try? vol.fsRead(at: gdtStart, count: total), gdt.count == total else {
            log.append("group descriptor table unreadable")
            return 1
        }
        var bad = 0
        for g in 0..<sb.groupCount {
            let o = g * sb.descSize
            let desc = Array(gdt[o..<o + sb.descSize])
            let stored = le16(desc, 0x1E)
            var groupLE = [UInt8](repeating: 0, count: 4)
            putLE32(&groupLE, 0, UInt32(g))
            var crc = Crc32c.hash(sb.csumSeed, groupLE)
            crc = Crc32c.hash(crc, desc[0..<0x1E])
            crc = Crc32c.hash(crc, [0, 0])                       // bg_checksum as zero
            if sb.descSize > 0x20 {
                crc = Crc32c.hash(crc, desc[0x20..<sb.descSize])
            }
            if UInt16(crc & 0xFFFF) != stored {
                bad += 1
                if bad <= 4 { log.append("group \(g): descriptor checksum mismatch") }
            }
        }
        if bad > 0 { log.append("\(bad) group descriptor(s) bad of \(sb.groupCount)") }
        return bad
    }
}
