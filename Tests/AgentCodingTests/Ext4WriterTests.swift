import Testing
import Foundation
@testable import bromure_ac

// Writer + checksum tests. Gated on BROMURE_EXT4_TEST_IMAGE like the reader
// tests. The write test operates on a clonefile copy (cp -c) of the image, never
// the original, and deletes it afterward.
@Suite("Ext4Writer")
struct Ext4WriterTests {

    private var imagePath: String? { ProcessInfo.processInfo.environment["BROMURE_EXT4_TEST_IMAGE"] }

    @Test("fsck locate + degradation are sane")
    func fsckDegradation() throws {
        // locate() returns nil or a real executable — never a bogus path.
        if let p = Ext4Fsck.locate() {
            #expect(FileManager.default.isExecutableFile(atPath: p))
        } else {
            #expect(!Ext4Fsck.isAvailable)
            // With no binary, check() must throw a clear, actionable error.
            #expect(throws: Ext4Fsck.FsckError.self) {
                _ = try Ext4Fsck.check(imagePath: "/nonexistent.img", partitionOffset: 0, autoFix: false)
            }
            #expect("\(Ext4Fsck.FsckError.notInstalled)".contains("brew install e2fsprogs"))
        }
    }

    @Test("crc32c matches the well-known 'check' vector")
    func crc32cVector() {
        // The Castagnoli crc32c of "123456789" is 0xE3069283 (final XOR applied).
        // Our running hash omits pre/post inversion, so replicate the framing.
        let data = Array("123456789".utf8)
        let crc = Crc32c.hash(0xFFFF_FFFF, data) ^ 0xFFFF_FFFF
        #expect(crc == 0xE306_9283)
    }

    @Test("every inode's stored checksum recomputes correctly")
    func inodeChecksumsMatch() throws {
        guard let path = imagePath else { return }
        let vol = try Ext4Volume(path: path)
        guard vol.sb.hasMetadataCsum else { print("(no metadata_csum on image)"); return }
        // Walk a subtree and verify each inode we touch — a single mismatch means
        // the crc32c/seed/field-offset logic is wrong.
        var checked = 0, bad = 0
        func walk(_ ino: UInt32, depth: Int) throws {
            if try !vol.verifyInodeChecksum(ino) { bad += 1 }
            checked += 1
            guard depth < 3 else { return }
            let node = try vol.inode(ino)
            if node.isDir {
                for e in try vol.listDir(ino) where checked < 3000 {
                    try walk(e.ino, depth: depth + 1)
                }
            }
        }
        try walk(Ext4Volume.rootInode, depth: 0)
        print("inode checksums: verified \(checked), mismatches \(bad)")
        #expect(bad == 0)
        #expect(checked > 10)
    }

    @Test("in-place overwrite round-trips and keeps the fs consistent")
    func overwriteRoundTrip() throws {
        guard let path = imagePath else { return }
        // Clone the image (CoW) so we never touch the user's real disk.
        let clone = path + ".ext4test.tmp"
        try? FileManager.default.removeItem(atPath: clone)
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-c", path, clone]              // -c = clonefile
        try cp.run(); cp.waitUntilExit()
        guard cp.terminationStatus == 0 else { print("clone failed; skipping"); return }
        defer { try? FileManager.default.removeItem(atPath: clone) }

        let vol = try Ext4Volume(path: clone, writable: true)
        if vol.sb.needsRecovery { print("clone journal needs recovery; skipping write"); return }

        // Find a small, non-empty regular file (≥1 block, ≤ one block of data).
        var target: (ino: UInt32, size: UInt64)? = nil
        func find(_ ino: UInt32, depth: Int) throws {
            if target != nil || depth > 4 { return }
            for e in try vol.listDir(ino) {
                if target != nil { break }
                let n = try vol.inode(e.ino)
                if n.isRegular, n.size > 0, n.size <= UInt64(vol.blockSize) {
                    target = (e.ino, n.size)
                } else if n.isDir {
                    try find(e.ino, depth: depth + 1)
                }
            }
        }
        try find(Ext4Volume.rootInode, depth: 0)
        guard let t = target else { print("no suitable file found; skipping"); return }

        // 1. Overwrite in place (fits one block) → round-trips.
        let payload = Array("bromure ext4 writer round-trip ✔\n".utf8)
        let outcome = try vol.overwriteFile(ino: t.ino, with: payload)
        #expect(outcome == .inPlace)
        let readBack = try vol.readData(try vol.inode(t.ino))
        #expect(readBack == payload)
        #expect(try vol.inode(t.ino).size == UInt64(payload.count))

        // 2. The mutated inode's checksum must still verify (self-consistent, no fsck).
        #expect(try vol.verifyInodeChecksum(t.ino))

        // 3. Re-open the image fresh from disk and confirm the write persisted.
        let vol2 = try Ext4Volume(path: clone)
        #expect(try vol2.readData(try vol2.inode(t.ino)) == payload)
        #expect(try vol2.verifyInodeChecksum(t.ino))

        // 4. A write that would need more blocks than allocated is refused.
        let tooBig = [UInt8](repeating: 0x41, count: vol.blockSize + 1)
        #expect(throws: Ext4Error.self) { try vol.overwriteFile(ino: t.ino, with: tooBig) }
        print("overwrote inode \(t.ino) (was \(t.size)B) → \(payload.count)B, checksum OK, persisted")
    }
}
