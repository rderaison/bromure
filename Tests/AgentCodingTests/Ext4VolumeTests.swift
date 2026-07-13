import Testing
import Foundation
@testable import bromure_ac

// Structural tests for the userland ext4 reader.
//
// The heavy end-to-end checks run against a REAL ext4 image and are therefore
// gated on the env var BROMURE_EXT4_TEST_IMAGE (a path to a .img — raw ext4 or a
// GPT/MBR disk with an ext4 partition). Unset in CI, so these skip cleanly.
//
//   BROMURE_EXT4_TEST_IMAGE="$HOME/Library/Application Support/BromureAC/base.img" \
//     swift test --filter Ext4Volume
@Suite("Ext4Volume")
struct Ext4VolumeTests {

    private var imagePath: String? { ProcessInfo.processInfo.environment["BROMURE_EXT4_TEST_IMAGE"] }

    @Test("opens a real image and reports a sane superblock")
    func opensImage() throws {
        guard let path = imagePath else { return }        // skip when not configured
        let vol = try Ext4Volume(path: path)
        // block size is a power of two in [1024, 65536]
        #expect(vol.blockSize >= 1024 && vol.blockSize <= 65536)
        #expect(vol.blockSize & (vol.blockSize - 1) == 0)
        #expect(vol.sb.inodesPerGroup > 0)
        #expect(vol.sb.blocksPerGroup > 0)
        print("ext4: name=\(vol.volumeName.isEmpty ? "(none)" : vol.volumeName) "
            + "block=\(vol.blockSize) groups=\(vol.sb.groupCount) "
            + "partOffset=\(vol.partitionOffset) clean=\(vol.sb.isClean)")
    }

    @Test("root inode is a directory and lists entries")
    func listsRoot() throws {
        guard let path = imagePath else { return }
        let vol = try Ext4Volume(path: path)
        let root = try vol.inode(Ext4Volume.rootInode)
        #expect(root.isDir)
        let entries = try vol.listDir(Ext4Volume.rootInode)
        #expect(!entries.isEmpty)
        let names = entries.map(\.name).sorted()
        print("root/ (\(entries.count)): \(names.prefix(40).joined(separator: " "))")
        // Every listed entry must resolve to a readable inode.
        for e in entries.prefix(50) {
            let n = try vol.inode(e.ino)
            #expect(n.mode != 0)
        }
    }

    @Test("reads a small text file end-to-end")
    func readsFile() throws {
        guard let path = imagePath else { return }
        let vol = try Ext4Volume(path: path)
        // Try a few well-known small files; at least one should exist on a rootfs.
        let candidates = ["/etc/hostname", "/etc/os-release", "/etc/fstab", "/etc/hosts"]
        var read = false
        for c in candidates {
            if let ino = try? vol.resolve(c) {
                let node = try vol.inode(ino)
                guard node.isRegular else { continue }
                let bytes = try vol.readData(node)
                #expect(UInt64(bytes.count) == node.size)
                print("\(c) (\(bytes.count)B): "
                    + String(decoding: bytes.prefix(120), as: UTF8.self)
                        .replacingOccurrences(of: "\n", with: "⏎"))
                read = true
                break
            }
        }
        if !read { print("(no candidate file found — image may be a /home fs)") }
    }

    @Test("recursively walks a subtree without corruption")
    func walksSubtree() throws {
        guard let path = imagePath else { return }
        let vol = try Ext4Volume(path: path)
        var dirs = 0, files = 0, symlinks = 0
        func walk(_ ino: UInt32, depth: Int) throws {
            guard depth < 4 else { return }
            for e in try vol.listDir(ino) {
                let node = try vol.inode(e.ino)
                if node.isDir { dirs += 1; try walk(e.ino, depth: depth + 1) }
                else if node.isSymlink { symlinks += 1 }
                else if node.isRegular {
                    files += 1
                    // sanity: read the head of a handful of files
                    if files <= 20 { _ = try vol.readData(node) }
                }
            }
        }
        try walk(Ext4Volume.rootInode, depth: 0)
        print("walk: dirs=\(dirs) files=\(files) symlinks=\(symlinks)")
        #expect(dirs + files + symlinks > 0)
    }
}
