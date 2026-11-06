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

    @Test("a cleared root inode is not passed as clean")
    func clearedRootInode() throws {
        // What `debugfs -w -R "clri <2>"` does: inode 2's record zeroed. The
        // walk would see one inode with nothing under it; the root check
        // reports it, so a cluster machine goes on to the real e2fsck.
        var img = Self.buildImage()
        let o = Self.inodeOffset(2)
        img.replaceSubrange(o ..< o + 128, with: [UInt8](repeating: 0, count: 128))
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(r.status == 4, "\(r.output)")
            #expect(r.output.contains("root inode is not a directory"), "\(r.output)")
        }
    }

    @Test("a root whose \"..\" points elsewhere is not passed as clean")
    func rootDotDotElsewhere() throws {
        var img = Self.buildImage()
        putLE32(&img, Self.rootDirBlock * Self.blockSize + 12, 12)   // ".." → inode 12
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: false)
            #expect(r.status == 4, "\(r.output)")
            #expect(r.output.contains("don't both point at inode 2"), "\(r.output)")
        }
    }

    @Test("a root claiming a huge size is refused, not read")
    func rootWithHugeSize() throws {
        // i_size is the image's word: ~4 GiB on a one-block root. "." and
        // ".." come from block 0 alone, the listing is refused past the
        // bound, and the check ends at once as unfixable.
        var img = Self.buildImage()
        putLE32(&img, Self.inodeOffset(2) + 4, 0xFFFF_F000)
        try withImage(img) { path in
            let t0 = Date()
            let r = try Ext4Fsck.check(imagePath: path, autoFix: false)
            #expect(r.status == 4, "\(r.output)")
            #expect(r.output.contains("corrupt inode 2"), "\(r.output)")
            #expect(!r.output.contains("don't both point"), "the dots still read from block 0: \(r.output)")
            #expect(Date().timeIntervalSince(t0) < 5)
        }
    }

    @Test("a file claiming an enormous size is read only up to its limit")
    func hugeFileSize() throws {
        // A guest makes this with one `truncate -s 1T`: i_size is the image's
        // word. The transcript reader and the browser's preview read a prefix;
        // a whole read (or Extract) of more than the filesystem is refused.
        var img = Self.buildImage()
        putLE32(&img, Self.inodeOffset(12) + 4, 0xFFFF_FFFF)
        putLE32(&img, Self.inodeOffset(12) + 108, 0xFFFF_FFFF)    // i_size_high
        try withImage(img) { path in
            let vol = try Ext4Volume(path: path)
            let node = try vol.inode(12)
            #expect(node.size == .max)
            let head = try vol.readData(node, limit: 1 << 20)
            #expect(head.count == 1 << 20)
            #expect(Array(head.prefix(Self.helloContent.count)) == Self.helloContent)
            #expect(throws: Ext4Error.self) { try vol.readData(node) }
            let out = NSTemporaryDirectory() + "ext4-extract-\(UUID().uuidString)"
            FileManager.default.createFile(atPath: out, contents: nil)
            defer { try? FileManager.default.removeItem(atPath: out) }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
            defer { try? handle.close() }
            #expect(throws: Ext4Error.self) { try vol.writeData(node, to: handle) }
        }
    }

    @Test("the check survives a file claiming an enormous size")
    func fsckHugeFileSize() throws {
        // The boot remedy and the cluster disk repair run this on their own.
        var img = Self.buildImage()
        putLE32(&img, Self.inodeOffset(12) + 4, 0xFFFF_FFFF)
        putLE32(&img, Self.inodeOffset(12) + 108, 0xFFFF_FFFF)
        try withImage(img) { path in
            _ = try Ext4Fsck.check(imagePath: path, autoFix: false)
        }
    }

    @Test("a superblock with impossible geometry is refused, not trusted")
    func impossibleSuperblock() throws {
        // Each would trap on open: a shift past the word, a division by zero,
        // a group count (and GDT read) sized by a 64-bit block count.
        let cases: [(String, (inout [UInt8]) -> Void)] = [
            ("s_log_block_size 40", { putLE32(&$0, 1024 + 24, 40) }),
            ("s_inodes_per_group 0", { putLE32(&$0, 1024 + 40, 0) }),
            ("s_blocks_per_group 0", { putLE32(&$0, 1024 + 32, 0) }),
            ("s_blocks_count below s_first_data_block", { putLE32(&$0, 1024 + 4, 0) }),
            ("s_desc_size past EXT4_MAX_DESC_SIZE", {
                putLE32(&$0, 1024 + 96, Ext4Superblock.INCOMPAT_FILETYPE | Ext4Superblock.INCOMPAT_64BIT)
                putLE16(&$0, 1024 + 254, 4096)
            }),
            ("a 64-bit block count of 2^64-1", {
                putLE32(&$0, 1024 + 96, Ext4Superblock.INCOMPAT_FILETYPE | Ext4Superblock.INCOMPAT_64BIT)
                putLE32(&$0, 1024 + 4, 0xFFFF_FFFF)
                putLE32(&$0, 1024 + 0x150, 0xFFFF_FFFF)
            }),
        ]
        for (name, corrupt) in cases {
            var img = Self.buildImage()
            corrupt(&img)
            try withImage(img) { path in
                #expect(throws: Ext4Error.self, "\(name)") { _ = try Ext4Volume(path: path) }
            }
        }
    }

    @Test("a group descriptor table past the image's end is refused, not indexed")
    func gdtPastImageEnd() throws {
        // The superblock claims many groups (a big filesystem); the image file
        // holds a few KiB, so the descriptor table read comes back short.
        var img = Self.buildImage()
        putLE32(&img, 1024 + 4, 40_000_000)                 // s_blocks_count
        putLE32(&img, 1024 + 32, 8)                         // s_blocks_per_group → 5M groups
        try withImage(img) { path in
            #expect(throws: Ext4Error.self) { _ = try Ext4Volume(path: path) }
        }
    }

    @Test("Extract writes the file a block at a time, byte for byte")
    func extractStreams() throws {
        try withImage(Self.buildImage()) { path in
            let vol = try Ext4Volume(path: path)
            let out = NSTemporaryDirectory() + "ext4-extract-\(UUID().uuidString)"
            FileManager.default.createFile(atPath: out, contents: nil)
            defer { try? FileManager.default.removeItem(atPath: out) }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
            #expect(try vol.writeData(try vol.inode(12), to: handle) == UInt64(Self.helloContent.count))
            try handle.close()
            #expect(try Data(contentsOf: URL(fileURLWithPath: out)) == Data(Self.helloContent))
        }
    }

    @Test("an extent index that points back at itself is refused, not followed")
    func extentCycle() throws {
        // hello.txt becomes an extent-mapped file whose depth-1 index names
        // block 13, and block 13 is another depth-1 node naming itself.
        var img = Self.buildImage()
        let o = Self.inodeOffset(12)
        putLE32(&img, o + 32, Ext4Inode.EXTENTS_FL)               // i_flags
        func extentIndex(_ at: Int, child: UInt32) {
            putLE16(&img, at, 0xF30A)                              // magic
            putLE16(&img, at + 2, 1)                               // entries
            putLE16(&img, at + 4, 4)                               // max
            putLE16(&img, at + 6, 1)                               // depth
            putLE32(&img, at + 12, 0)                              // ei_block
            putLE32(&img, at + 16, child)                          // ei_leaf_lo
        }
        extentIndex(o + 40, child: 13)
        extentIndex(13 * Self.blockSize, child: 13)
        try withImage(img) { path in
            let vol = try Ext4Volume(path: path)
            #expect(throws: Ext4Error.self) { try vol.readData(try vol.inode(12), limit: 4096) }
        }
    }

    @Test("a directory entry naming a cleared inode is not passed as clean")
    func entryNamingAClearedInode() throws {
        // hello.txt's record zeroed, as `debugfs clri` does; the root still
        // names it. The error flag (forcing the guest's boot check) stays.
        var img = Self.buildImage()
        putLE16(&img, 1024 + 58, le16(img, 1024 + 58) | 0x0002)
        let o = Self.inodeOffset(12)
        img.replaceSubrange(o ..< o + 128, with: [UInt8](repeating: 0, count: 128))
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: true)
            #expect(r.status == 4, "\(r.output)")
            #expect(r.output.contains("inode 12: referenced by a directory entry but unused"), "\(r.output)")
            #expect((try Ext4Volume(path: path)).sb.hasErrors)
        }
    }

    @Test("a directory entry naming a deleted inode is not passed as clean")
    func entryNamingADeletedInode() throws {
        var img = Self.buildImage()
        putLE16(&img, Self.inodeOffset(12) + 26, 0)            // links_count 0
        putLE32(&img, Self.inodeOffset(12) + 20, 1781652178)   // i_dtime set
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: false)
            #expect(r.status == 4, "\(r.output)")
            #expect(r.output.contains("unused"), "\(r.output)")
        }
    }

    @Test("a directory entry naming an inode with no links is not passed as clean, dtime or not")
    func entryNamingAnUnlinkedInode() throws {
        var img = Self.buildImage()
        putLE16(&img, Self.inodeOffset(12) + 26, 0)            // links_count 0, i_dtime still 0
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: false)
            #expect(r.status == 4, "\(r.output)")
            #expect(r.output.contains("unused"), "\(r.output)")
        }
    }

    @Test("orphans, devices and fast symlinks are in use")
    func inUseWithoutBlocks() throws {
        // A character device and a fast symlink (target inline, no blocks)
        // reached from the root; an orphan-list inode (no links, its dtime
        // the next orphan) that no entry names. None of them is "unused".
        var img = Self.buildImage()
        var o = Self.inodeOffset(12)
        img.replaceSubrange(o ..< o + 128, with: [UInt8](repeating: 0, count: 128))
        putLE16(&img, o, 0x21A4)                                // crw-r--r--
        putLE16(&img, o + 26, 1)
        putLE32(&img, o + 40, 0x0103)                           // device number in i_block
        o = Self.inodeOffset(13)
        putLE16(&img, o, 0xA1FF)                                // lrwxrwxrwx
        putLE32(&img, o + 4, 4)
        putLE16(&img, o + 26, 1)
        for (i, c) in Array("/etc".utf8).enumerated() { img[o + 40 + i] = c }
        // The root's third entry becomes "dev" (12) + a fourth, "lnk" (13).
        var d = Self.rootDirBlock * Self.blockSize + 24
        func dirent(_ ino: UInt32, _ name: String, _ type: UInt8, _ recLen: UInt16) {
            putLE32(&img, d, ino); putLE16(&img, d + 4, recLen)
            img[d + 6] = UInt8(name.utf8.count); img[d + 7] = type
            for (i, c) in Array(name.utf8).enumerated() { img[d + 8 + i] = c }
            d += Int(recLen)
        }
        dirent(12, "dev", 3, 12)
        dirent(13, "lnk", 7, UInt16(Self.blockSize - 36))
        o = Self.inodeOffset(14)                                // the orphan
        putLE16(&img, o, 0x81A4)
        putLE32(&img, o + 20, 0)                                // end of the orphan list
        putLE32(&img, 1024 + 0xE8, 14)                          // s_last_orphan
        try withImage(img) { path in
            let r = try Ext4Fsck.check(imagePath: path, autoFix: false)
            #expect(r.clean, "\(r.output)")
            #expect(!r.output.contains("unused"), "\(r.output)")
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
