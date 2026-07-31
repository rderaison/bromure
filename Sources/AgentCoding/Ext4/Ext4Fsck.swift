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
            case 1: return "Filesystem repaired; it is now consistent."
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

        // Phase 2: verification.
        let (issues, complete) = verify(vol, log: &log)
        unfixable += issues

        // Phase 3: the error flag. This is the one that actually strands a
        // boot. systemd-fsck runs `e2fsck -p` (preen), and preen REFUSES to
        // touch a filesystem whose superblock error bit is set — it prints
        // "UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY" and exits 4, dropping
        // the headless guest into an emergency shell nobody can reach. The
        // flag only records that the kernel hit *an* error at some point; the
        // filesystem itself is often perfectly consistent (ours typically get
        // it from a hard stop mid-write). Clearing it is exactly what
        // `e2fsck -fy` does once its check comes back clean — so we do it
        // only when our own check was EXHAUSTIVE and found nothing, never on
        // a truncated walk or alongside real damage.
        if vol.sb.hasErrors {
            if !autoFix {
                log.append("superblock error flag is set — this is what makes the guest's "
                           + "boot-time e2fsck -p refuse; re-run with repair enabled")
                unfixable += 1
            } else if issues == 0 && complete {
                do {
                    try clearErrorFlag(vol)
                    repaired = true
                    log.append("superblock error flag cleared (check found no errors) — "
                               + "the guest's boot-time fsck will proceed")
                } catch {
                    log.append("could not clear the error flag: \(error)")
                    unfixable += 1
                }
            } else {
                log.append("superblock error flag is set and the check "
                           + (complete ? "found \(issues) problem(s)" : "could not complete")
                           + " — leaving the flag set (run e2fsck inside a VM)")
                unfixable += 1
            }
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

    /// Clear the superblock's error state the way a completed `e2fsck -fy`
    /// does: drop EXT2_ERROR_FS from s_state, zero the error counters and the
    /// first/last error records, and stamp s_lastcheck so the guest doesn't
    /// immediately re-check. Caller guarantees the check found nothing.
    private static func clearErrorFlag(_ vol: Ext4Volume) throws {
        var sb = try vol.fsRead(at: 1024, count: 1024)
        guard sb.count == 1024, le16(sb, 56) == 0xEF53 else {
            throw Ext4JournalError.corrupt("superblock unreadable")
        }
        putLE16(&sb, 58, le16(sb, 58) & ~UInt16(0x0002))     // s_state: -EXT2_ERROR_FS
        putLE32(&sb, 0x188, 0)                               // s_error_count
        for off in stride(from: 0x18C, through: 0x1F3, by: 4) {
            putLE32(&sb, off, 0)                             // first/last error records
        }
        putLE32(&sb, 64, UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))  // s_lastcheck
        if le32(sb, 100) & Ext4Superblock.ROCOMPAT_METADATA_CSUM != 0 {
            putLE32(&sb, 0x3FC, Crc32c.hash(0xFFFF_FFFF, Array(sb[0..<0x3FC])))
        }
        try vol.fsWrite(at: 1024, sb)
        vol.dev.fsync()
    }

    // MARK: verification

    /// Structural checks. Returns the problem count and whether the walk was
    /// EXHAUSTIVE — clearing the error flag is only defensible when it was.
    private static func verify(_ vol: Ext4Volume, log: inout [String]) -> (issues: Int, complete: Bool) {
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
        // directory structure. The cap only exists so a pathological image
        // can't spin forever — it is sized off the filesystem's own inode
        // count, so a normal disk is walked EXHAUSTIVELY (a truncated walk
        // can't authorize clearing the error flag). Never silent: a hit cap
        // is reported and reported as incomplete.
        var visited = Set<UInt32>()
        var bad = 0
        let cap = Int(vol.sb.inodesCount) + 1
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
                // Block pointers must land inside the filesystem. Parsing the
                // map also throws on a corrupt extent header or an unreadable
                // interior node. Bounded per inode (the head of the file) so a
                // huge tree can't blow up memory — walkExtents materializes one
                // dict entry per block, not per extent.
                if !node.isInline && (node.isDir || node.isRegular) {
                    let want = (Int(node.size) + vol.blockSize - 1) / vol.blockSize
                    for (_, phys) in try vol.blockMap(node, upTo: min(max(want, 1), 12))
                    where phys != 0 && phys >= vol.sb.blocksCount {
                        bad += 1
                        if bad <= 10 {
                            log.append("inode \(ino): block pointer \(phys) is past the "
                                       + "end of the filesystem (\(vol.sb.blocksCount) blocks)")
                        }
                        break
                    }
                }
                if node.isDir {
                    for e in try vol.listDir(ino) where e.ino != 0 && e.ino <= vol.sb.inodesCount {
                        stack.append(e.ino)
                    }
                }
            } catch {
                bad += 1
                if bad <= 10 { log.append("inode \(ino): \(error)") }
            }
        }
        let complete = visited.count < cap
        if !complete {
            log.append("verification capped at \(cap) inodes — walk was NOT exhaustive")
        }
        log.append("verified \(visited.count) reachable inode(s)"
                   + (bad > 0 ? ", \(bad) bad" : ""))
        return (issues + bad, complete)
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
