import Testing
import Foundation
@testable import bromure_ac

// Native fsck / JBD2 replay tests over a hand-built minimal ext4 image — no
// fixtures, no e2fsprogs, fully deterministic. The image is deliberately
// old-school (1K blocks, one group, legacy block maps, no metadata_csum) so
// every byte is simple to place; the journal format is the same JBD2 the real
// images use, which is what these tests exercise.
@Suite("Ext4Fsck (native)")
struct Ext4FsckTests {

    // Image geometry (block numbers; 1K blocks ⇒ first_data_block = 1).
    private static let blockSize = 1024
    private static let totalBlocks = 64
    private static let inodeTableBlock = 5      // inodes 1–16, 128 B each, blocks 5–6
    private static let rootDirBlock = 10
    private static let helloBlock = 11
    private static let spareBlock = 12          // replay target for the escape test
    private static let journalFirstBlock = 20   // journal file: blocks 20–31
    private static let journalBlocks = 12
    private static let helloContent = Array("hello world\n".utf8)

    private static let jbd2Magic: UInt32 = 0xC03B_3998

    // MARK: image builder

    private static func inodeOffset(_ ino: UInt32) -> Int {
        inodeTableBlock * blockSize + Int(ino - 1) * 128
    }

    /// A minimal, mountable-in-spirit ext4 image: superblock, one group, root
    /// dir with hello.txt, and a 12-block journal file at inode 8.
    private static func buildImage() -> [UInt8] {
        var img = [UInt8](repeating: 0, count: totalBlocks * blockSize)

        // Superblock (bytes 1024..2048).
        let sb = 1024
        func sb32(_ off: Int, _ v: UInt32) { putLE32(&img, sb + off, v) }
        func sb16(_ off: Int, _ v: UInt16) { putLE16(&img, sb + off, v) }
        sb32(0, 16)                     // s_inodes_count
        sb32(4, UInt32(totalBlocks))    // s_blocks_count_lo
        sb32(20, 1)                     // s_first_data_block
        sb32(24, 0)                     // s_log_block_size → 1024
        sb32(32, 8192)                  // s_blocks_per_group
        sb32(40, 16)                    // s_inodes_per_group
        sb16(56, 0xEF53)                // magic
        sb16(58, 1)                     // s_state = clean
        sb32(84, 11)                    // s_first_ino
        sb16(88, 128)                   // s_inode_size
        sb32(92, Ext4Superblock.COMPAT_HAS_JOURNAL)
        sb32(96, Ext4Superblock.INCOMPAT_FILETYPE)
        for (i, c) in Array("brmtest".utf8).enumerated() { img[sb + 120 + i] = c }
        sb32(0xE0, 8)                   // s_journal_inum

        // Group descriptor 0 (block 2): only the inode-table pointer matters.
        putLE32(&img, 2 * blockSize + 8, UInt32(inodeTableBlock))

        // Inode 2: root directory (755, one data block).
        var o = inodeOffset(2)
        putLE16(&img, o, 0x41ED)                        // mode
        putLE32(&img, o + 4, UInt32(blockSize))         // size
        putLE16(&img, o + 26, 2)                        // links
        putLE32(&img, o + 40, UInt32(rootDirBlock))     // i_block[0]

        // Inode 8: the journal file, 12 direct blocks.
        o = inodeOffset(8)
        putLE16(&img, o, 0x8180)
        putLE32(&img, o + 4, UInt32(journalBlocks * blockSize))
        putLE16(&img, o + 26, 1)
        for i in 0..<journalBlocks {
            putLE32(&img, o + 40 + i * 4, UInt32(journalFirstBlock + i))
        }

        // Inode 12: /hello.txt.
        o = inodeOffset(12)
        putLE16(&img, o, 0x81A4)
        putLE32(&img, o + 4, UInt32(helloContent.count))
        putLE16(&img, o + 26, 1)
        putLE32(&img, o + 40, UInt32(helloBlock))
        img.replaceSubrange(helloBlock * blockSize ..< helloBlock * blockSize + helloContent.count,
                            with: helloContent)

        // Root dir block: ".", "..", "hello.txt".
        var d = rootDirBlock * blockSize
        func dirent(_ ino: UInt32, _ name: String, _ type: UInt8, _ recLen: UInt16) {
            putLE32(&img, d, ino)
            putLE16(&img, d + 4, recLen)
            img[d + 6] = UInt8(name.utf8.count)
            img[d + 7] = type
            for (i, c) in Array(name.utf8).enumerated() { img[d + 8 + i] = c }
            d += Int(recLen)
        }
        dirent(2, ".", 2, 12)
        dirent(2, "..", 2, 12)
        dirent(12, "hello.txt", 1, UInt16(blockSize - 24))

        // Journal superblock (journal block 0 = fs block 20), empty log.
        let j = journalFirstBlock * blockSize
        putBE32(&img, j, jbd2Magic)
        putBE32(&img, j + 4, 4)                         // blocktype: superblock v2
        putBE32(&img, j + 12, UInt32(blockSize))        // s_blocksize
        putBE32(&img, j + 16, UInt32(journalBlocks))    // s_maxlen
        putBE32(&img, j + 20, 1)                        // s_first
        putBE32(&img, j + 24, 7)                        // s_sequence
        putBE32(&img, j + 28, 0)                        // s_start (0 = clean)
        return img
    }

    /// Journal-block byte offset within the image.
    private static func jOff(_ jblock: Int) -> Int { (journalFirstBlock + jblock) * blockSize }

    private static func writeHeader(_ img: inout [UInt8], jblock: Int, type: UInt32, seq: UInt32) {
        let o = jOff(jblock)
        putBE32(&img, o, jbd2Magic)
        putBE32(&img, o + 4, type)
        putBE32(&img, o + 8, seq)
    }

    /// Mark the fs dirty and lay a committed transaction into the log:
    ///   j1 descriptor (tags: hello block, escaped spare block)
    ///   j2 data → hello block      j3 data → spare block (escaped)
    ///   j4 commit
    /// plus, when `revokeHello`, a second transaction revoking the hello block:
    ///   j5 revoke      j6 commit
    private static func makeDirty(_ img: inout [UInt8], revokeHello: Bool) -> [UInt8] {
        // superblock: INCOMPAT_RECOVER on
        putLE32(&img, 1024 + 96, le32(img, 1024 + 96) | Ext4Superblock.INCOMPAT_RECOVER)
        // journal superblock: log starts at journal block 1
        putBE32(&img, jOff(0) + 28, 1)

        let newHello = Array("replayed by native fsck\n".utf8)

        writeHeader(&img, jblock: 1, type: 1, seq: 7)          // descriptor
        var t = jOff(1) + 12
        putBE32(&img, t, UInt32(helloBlock))                   // tag 1: hello
        putBE16(&img, t + 6, 2)                                // SAME_UUID
        t += 8
        putBE32(&img, t, UInt32(spareBlock))                   // tag 2: spare
        putBE16(&img, t + 6, 2 | 1 | 8)                        // SAME_UUID|ESCAPE|LAST_TAG

        var data = [UInt8](repeating: 0, count: blockSize)     // j2: new hello content
        data.replaceSubrange(0..<newHello.count, with: newHello)
        img.replaceSubrange(jOff(2)..<jOff(2) + blockSize, with: data)

        var esc = [UInt8](repeating: 0xAB, count: blockSize)   // j3: escaped block —
        esc[0] = 0; esc[1] = 0; esc[2] = 0; esc[3] = 0         // magic zeroed in the log
        img.replaceSubrange(jOff(3)..<jOff(3) + blockSize, with: esc)

        writeHeader(&img, jblock: 4, type: 2, seq: 7)          // commit seq 7

        if revokeHello {
            writeHeader(&img, jblock: 5, type: 5, seq: 8)      // revoke block
            putBE32(&img, jOff(5) + 12, 16 + 4)                // r_count
            putBE32(&img, jOff(5) + 16, UInt32(helloBlock))
            writeHeader(&img, jblock: 6, type: 2, seq: 8)      // commit seq 8
        }
        return newHello
    }

    private static func putBE16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
        b[o] = UInt8(v >> 8); b[o + 1] = UInt8(v & 0xff)
    }

    private func withImage(_ bytes: [UInt8], _ body: (String) throws -> Void) throws {
        let path = NSTemporaryDirectory() + "ext4fsck-\(UUID().uuidString).img"
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    // MARK: tests

    @Test("clean image: status 0, nothing rewritten")
    func cleanImage() throws {
        try withImage(Self.buildImage()) { path in
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            let r = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(r.clean)
            #expect(r.status == 0)
            #expect(r.output.contains("journal is clean"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        }
    }

    @Test("dirty journal: replay applies committed blocks, unescapes, clears recovery")
    func replayAppliesTransaction() throws {
        var img = Self.buildImage()
        let newHello = Self.makeDirty(&img, revokeHello: false)
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(r.repaired, "\(r.output)")
            #expect(r.status == 1)

            let vol = try Ext4Volume(path: path)
            #expect(!vol.sb.needsRecovery)
            // hello.txt data block now carries the journal's committed copy.
            let hello = try vol.readBlock(UInt64(Self.helloBlock))
            #expect(Array(hello[0..<newHello.count]) == newHello)
            // The escaped block got its JBD2 magic restored.
            let spare = try vol.readBlock(UInt64(Self.spareBlock))
            #expect(be32(spare, 0) == Self.jbd2Magic)
            #expect(spare[4] == 0xAB)
            // Journal log was reset: start 0, sequence advanced past 7.
            let jsb = try vol.readBlock(UInt64(Self.journalFirstBlock))
            #expect(be32(jsb, 28) == 0)
            #expect(be32(jsb, 24) == 8)

            // Second pass: now clean, and idempotent.
            let again = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(again.clean, "\(again.output)")
        }
    }

    @Test("a revoked block is not replayed")
    func revokeSuppressesReplay() throws {
        var img = Self.buildImage()
        _ = Self.makeDirty(&img, revokeHello: true)
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(r.repaired, "\(r.output)")
            let vol = try Ext4Volume(path: path)
            // hello.txt keeps its ORIGINAL bytes — the revoke in seq 8 kills
            // the seq-7 copy.
            let hello = try vol.readData(try vol.inode(12))
            #expect(hello == Self.helloContent)
            // The non-revoked escaped block still replayed.
            let spare = try vol.readBlock(UInt64(Self.spareBlock))
            #expect(be32(spare, 0) == Self.jbd2Magic)
            #expect(!vol.sb.needsRecovery)
        }
    }

    @Test("dirty journal without autoFix: reported, untouched")
    func reportOnlyLeavesImageAlone() throws {
        var img = Self.buildImage()
        _ = Self.makeDirty(&img, revokeHello: false)
        try withImage(img) { path in
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            let r = try Ext4Fsck.check(imagePath: path, autoFix: false)
            #expect(r.status == 4)
            #expect(r.output.contains("needs replay"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        }
    }

    @Test("recovery flag with an empty log is just cleared")
    func staleRecoveryFlag() throws {
        var img = Self.buildImage()
        putLE32(&img, 1024 + 96, le32(img, 1024 + 96) | Ext4Superblock.INCOMPAT_RECOVER)
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(r.repaired, "\(r.output)")
            #expect(r.output.contains("journal is empty"))
            #expect(!(try Ext4Volume(path: path)).sb.needsRecovery)
        }
    }

    @Test("uncommitted tail transaction is dropped")
    func unterminatedTransactionIgnored() throws {
        var img = Self.buildImage()
        _ = Self.makeDirty(&img, revokeHello: false)
        // Truncate the log: wipe the commit block → transaction never happened.
        let c = Self.jOff(4)
        img.replaceSubrange(c..<c + Self.blockSize,
                            with: [UInt8](repeating: 0, count: Self.blockSize))
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(r.repaired, "\(r.output)")     // flag cleared, nothing replayed
            let vol = try Ext4Volume(path: path)
            let hello = try vol.readData(try vol.inode(12))
            #expect(hello == Self.helloContent)    // original bytes intact
            #expect(!vol.sb.needsRecovery)
        }
    }

    @Test("verification walks the synthetic tree")
    func verificationWalk() throws {
        try withImage(Self.buildImage()) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: false)
            #expect(r.clean, "\(r.output)")
            #expect(r.output.contains("verified 2 reachable inode(s)"))   // root + hello.txt
        }
    }

    @Test("error flag with a clean fs is cleared — the boot-blocker case")
    func errorFlagClearedWhenClean() throws {
        // The 'sub' failure mode: journal clean, filesystem consistent, but
        // s_state carries EXT2_ERROR_FS — which makes the guest's boot-time
        // `e2fsck -p` refuse ("RUN fsck MANUALLY") and strand the boot.
        var img = Self.buildImage()
        putLE16(&img, 1024 + 58, le16(img, 1024 + 58) | 0x0002)
        putLE32(&img, 1024 + 0x188, 7)          // s_error_count
        putLE32(&img, 1024 + 0x1C0, 1781652178) // s_last_error_time
        try withImage(img) { path in
            #expect((try Ext4Volume(path: path)).sb.hasErrors)

            // Report-only names the blocker and does NOT touch the image.
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            let report = try Ext4Fsck.check(imagePath: path, autoFix: false)
            #expect(report.status == 4)
            #expect(report.output.contains("error flag is set"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)

            // Repair clears it (check found nothing) and zeroes the records.
            let repair = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(repair.repaired, "\(repair.output)")
            #expect(repair.output.contains("error flag cleared"))
            let vol = try Ext4Volume(path: path)
            #expect(!vol.sb.hasErrors)
            #expect(vol.sb.isClean)
            let sb = try vol.fsRead(at: 1024, count: 1024)
            #expect(le32(sb, 0x188) == 0)       // s_error_count
            #expect(le32(sb, 0x1C0) == 0)       // s_last_error_time
            #expect(try Ext4Fsck.check(imagePath: path, autoFix: false).clean)
        }
    }

    @Test("error flag is NOT cleared when the check finds damage")
    func errorFlagKeptWhenDamaged() throws {
        var img = Self.buildImage()
        putLE16(&img, 1024 + 58, le16(img, 1024 + 58) | 0x0002)
        // Corrupt hello.txt's extent/block map so the walk reports a problem:
        // point the inode at a block far past the end of the filesystem.
        putLE32(&img, Self.inodeOffset(12) + 4, UInt32(Self.blockSize))  // size = 1 block
        putLE32(&img, Self.inodeOffset(12) + 40, 0xFFFF_FFF0)            // wild i_block[0]
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(r.status == 4, "\(r.output)")
            #expect(r.output.contains("leaving the flag set"), "\(r.output)")
            #expect((try Ext4Volume(path: path)).sb.hasErrors)   // still set
        }
    }

    @Test("real image (env-gated): native fsck parses, replays, and verifies")
    func realImage() throws {
        // Point BROMURE_EXT4_TEST_IMAGE at a *clone* of a real home/disk image
        // (kernel-written: metadata_csum, extents, csum_v3 journal). autoFix
        // runs, so never the live original.
        guard let path = ProcessInfo.processInfo.environment["BROMURE_EXT4_TEST_IMAGE"] else { return }
        // The superblock error flag records that the guest kernel hit
        // corruption at runtime; only a full e2fsck may clear it, so a native
        // repair honestly reports status 4 on such an image.
        let hadErrorFlag = (try Ext4Volume(path: path)).sb.hasErrors
        let report = try Ext4Fsck.check(imagePath: path, autoFix: false)
        print("report-only:\n\(report.output)\n")
        let repair = try Ext4Fsck.check(imagePath: path, autoFix: true)
        print("repair:\n\(repair.output)\n")
        if !hadErrorFlag {
            #expect(repair.status == 0 || repair.status == 1, "\(repair.output)")
        }
        // Whatever the flag says: the journal must be fully consumed and the
        // replayed metadata checksum-consistent.
        let again = try Ext4Fsck.check(imagePath: path, autoFix: false)
        print("re-check:\n\(again.output)\n")
        #expect(again.output.contains("journal is clean"), "\(again.output)")
        #expect(!again.output.contains("mismatch"), "\(again.output)")
        #expect(!again.output.contains("bad"), "\(again.output)")
        #expect(!(try Ext4Volume(path: path)).sb.needsRecovery)
        if !hadErrorFlag { #expect(again.clean, "\(again.output)") }
    }
}
