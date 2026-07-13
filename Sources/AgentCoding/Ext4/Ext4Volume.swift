import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Userland ext4 reader
//
// A dependency-free, read-only ext4 (and ext2/ext3) parser so the host can open
// a guest's `.img` disk without mounting it — macOS has no native ext4 support.
// The image may be a raw filesystem or a partitioned disk (MBR/GPT); we locate
// the ext4 superblock either way. The matching best-effort writer lives in
// Ext4Writer.swift, and fsck integration in Ext4Fsck.swift.
//
// On-disk layout references: the ext4 disk-format spec (kernel
// Documentation/filesystems/ext4/). All multi-byte fields are little-endian.

enum Ext4Error: Error, CustomStringConvertible {
    case open(String)
    case io(String)
    case notExt4                       // no ext4 superblock found anywhere
    case unsupported(String)           // a feature we don't parse
    case badInode(UInt32)
    case notADirectory(String)
    case notFound(String)

    var description: String {
        switch self {
        case .open(let m): return "cannot open image: \(m)"
        case .io(let m): return "I/O error: \(m)"
        case .notExt4: return "no ext4 filesystem found in this image"
        case .unsupported(let m): return "unsupported ext4 feature: \(m)"
        case .badInode(let n): return "corrupt inode \(n)"
        case .notADirectory(let p): return "not a directory: \(p)"
        case .notFound(let p): return "no such file: \(p)"
        }
    }
}

// MARK: On-disk structures (only the fields we use)

/// The ext4 superblock (1024 bytes at offset 1024 into the filesystem).
struct Ext4Superblock {
    let inodesCount: UInt32
    let blocksCount: UInt64
    let blockSize: Int            // 1024 << s_log_block_size
    let blocksPerGroup: UInt32
    let inodesPerGroup: UInt32
    let firstDataBlock: UInt32    // 1 for 1K blocks, else 0
    let firstIno: UInt32
    let inodeSize: Int
    let featureIncompat: UInt32
    let featureRoCompat: UInt32
    let descSize: Int             // group-descriptor size (32, or 64 for 64bit)
    let state: UInt16             // bit0 = cleanly unmounted
    let volumeName: String
    let uuid: [UInt8]             // s_uuid (16 bytes), for the checksum seed
    let checksumSeedRaw: UInt32   // s_checksum_seed (valid only with CSUM_SEED)

    // incompat feature bits
    static let INCOMPAT_FILETYPE:  UInt32 = 0x0002
    static let INCOMPAT_RECOVER:   UInt32 = 0x0004   // journal needs replay
    static let INCOMPAT_EXTENTS:   UInt32 = 0x0040
    static let INCOMPAT_64BIT:     UInt32 = 0x0080
    static let INCOMPAT_CSUM_SEED: UInt32 = 0x2000
    // ro_compat feature bits
    static let ROCOMPAT_METADATA_CSUM: UInt32 = 0x0400

    var is64Bit: Bool { featureIncompat & Ext4Superblock.INCOMPAT_64BIT != 0 }
    var hasFiletype: Bool { featureIncompat & Ext4Superblock.INCOMPAT_FILETYPE != 0 }
    var needsRecovery: Bool { featureIncompat & Ext4Superblock.INCOMPAT_RECOVER != 0 }
    var hasMetadataCsum: Bool { featureRoCompat & Ext4Superblock.ROCOMPAT_METADATA_CSUM != 0 }
    var hasCsumSeed: Bool { featureIncompat & Ext4Superblock.INCOMPAT_CSUM_SEED != 0 }

    /// The fs-wide checksum seed used by metadata_csum: either stored explicitly
    /// (CSUM_SEED feature) or derived from the volume UUID.
    var csumSeed: UInt32 {
        hasCsumSeed ? checksumSeedRaw : Crc32c.hash(0xFFFF_FFFF, uuid)
    }
    var groupCount: Int {
        Int((blocksCount - UInt64(firstDataBlock) + UInt64(blocksPerGroup) - 1) / UInt64(blocksPerGroup))
    }
    var isClean: Bool { state & 0x1 != 0 }

    init?(_ b: [UInt8]) {
        guard b.count >= 1024, le16(b, 56) == 0xEF53 else { return nil }
        inodesCount = le32(b, 0)
        let blkLo = UInt64(le32(b, 4))
        let logBS = le32(b, 24)
        blockSize = 1024 << logBS
        blocksPerGroup = le32(b, 32)
        inodesPerGroup = le32(b, 40)
        firstDataBlock = le32(b, 20)
        firstIno = le32(b, 84)
        let isz = Int(le16(b, 88))
        inodeSize = isz == 0 ? 128 : isz
        featureIncompat = le32(b, 96)
        featureRoCompat = le32(b, 100)
        let dsz = Int(le16(b, 254))
        state = le16(b, 58)
        uuid = Array(b[104..<120])            // s_uuid @0x68, 16 bytes
        checksumSeedRaw = le32(b, 0x270)      // s_checksum_seed
        // 64-bit block count
        let blkHi = (featureIncompat & Ext4Superblock.INCOMPAT_64BIT != 0) ? UInt64(le32(b, 0x150)) : 0
        blocksCount = blkLo | (blkHi << 32)
        descSize = (featureIncompat & Ext4Superblock.INCOMPAT_64BIT != 0)
            ? (dsz < 32 ? 32 : dsz) : 32
        // volume name @ 120, 16 bytes, NUL-padded
        var name = [UInt8]()
        for i in 120..<136 where i < b.count { if b[i] == 0 { break }; name.append(b[i]) }
        volumeName = String(decoding: name, as: UTF8.self)
    }
}

/// One inode, with its raw bytes kept for i_block region parsing.
struct Ext4Inode {
    let ino: UInt32
    let mode: UInt16
    let size: UInt64
    let flags: UInt32
    let links: UInt16
    let raw: [UInt8]              // full inode record (>= 128 bytes)

    static let EXTENTS_FL:     UInt32 = 0x0008_0000
    static let INLINE_DATA_FL: UInt32 = 0x1000_0000

    var isDir: Bool     { mode & 0xF000 == 0x4000 }
    var isRegular: Bool { mode & 0xF000 == 0x8000 }
    var isSymlink: Bool { mode & 0xF000 == 0xA000 }
    var usesExtents: Bool { flags & Ext4Inode.EXTENTS_FL != 0 }
    var isInline: Bool { flags & Ext4Inode.INLINE_DATA_FL != 0 }
    /// The 60-byte i_block area (extent root, block map, or inline data start).
    var iBlock: ArraySlice<UInt8> { raw[40..<100] }
}

/// A directory entry as returned to callers.
struct Ext4DirEntry {
    let name: String
    let ino: UInt32
    let fileType: UInt8          // 1=reg 2=dir 3=chr 4=blk 5=fifo 6=sock 7=symlink (0 if unknown)
    var isDir: Bool { fileType == 2 }
}

// MARK: - Block device abstraction

/// Positional reader over an image file, offset by the ext4 partition's start.
/// pread/pwrite are used so concurrent access needs no shared seek cursor.
final class Ext4Device {
    private let fd: Int32
    let base: UInt64             // byte offset of the filesystem within the image
    let writable: Bool

    init(path: String, writable: Bool) throws {
        let flags = writable ? O_RDWR : O_RDONLY
        let f = open(path, flags)
        guard f >= 0 else { throw Ext4Error.open("\(path): \(String(cString: strerror(errno)))") }
        self.fd = f
        self.base = 0
        self.writable = writable
    }

    /// Re-base an existing device onto a partition offset (shares the fd owner).
    private init(fd: Int32, base: UInt64, writable: Bool) {
        self.fd = fd; self.base = base; self.writable = writable
    }

    deinit { close(fd) }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        try buf.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!
            while got < count {
                let n = pread(fd, p + got, count - got, off_t(base + offset + UInt64(got)))
                if n == 0 { break }                       // short read past EOF
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Ext4Error.io(String(cString: strerror(errno)))
                }
                got += n
            }
        }
        if got < count { buf.removeLast(count - got) }
        return buf
    }

    func write(at offset: UInt64, _ bytes: [UInt8]) throws {
        guard writable else { throw Ext4Error.io("device opened read-only") }
        var put = 0
        try bytes.withUnsafeBytes { raw in
            let p = raw.baseAddress!
            while put < bytes.count {
                let n = pwrite(fd, p + put, bytes.count - put, off_t(base + offset + UInt64(put)))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Ext4Error.io(String(cString: strerror(errno)))
                }
                put += n
            }
        }
    }

    func fsync() { _ = Darwin.fsync(fd) }

    /// Raw byte size of the underlying image file (not the partition).
    func imageSize() -> UInt64 {
        var st = stat(); if fstat(fd, &st) == 0 { return UInt64(st.st_size) }
        return 0
    }
}

// MARK: - Volume

/// An opened ext4 filesystem. Read APIs are the core; Ext4Writer extends it.
final class Ext4Volume {
    let dev: Ext4Device
    let sb: Ext4Superblock
    let partitionOffset: UInt64   // where the fs starts within the image
    private var groupInodeTable: [UInt64] = []   // per-group inode-table block

    var blockSize: Int { sb.blockSize }
    var volumeName: String { sb.volumeName }

    /// Open the image, finding the ext4 filesystem (raw or inside a partition).
    init(path: String, writable: Bool = false) throws {
        self.dev = try Ext4Device(path: path, writable: writable)
        let (off, sb) = try Ext4Volume.locateFilesystem(dev)
        self.partitionOffset = off
        self.sb = sb
        try loadGroupDescriptors()
    }

    // MARK: filesystem location (raw vs MBR/GPT partition)

    /// Try offset 0 first (raw fs), then MBR/GPT partitions, then a coarse scan.
    private static func locateFilesystem(_ dev: Ext4Device) throws -> (UInt64, Ext4Superblock) {
        func trySuperblock(at part: UInt64) -> Ext4Superblock? {
            guard let bytes = try? dev.read(at: part + 1024, count: 1024) else { return nil }
            return Ext4Superblock(bytes)
        }
        // 1. Raw filesystem at offset 0.
        if let sb = trySuperblock(at: 0) { return (0, sb) }
        // 2. Partition tables give candidate starts.
        for start in partitionStarts(dev) {
            if let sb = trySuperblock(at: start) { return (start, sb) }
        }
        // 3. Fallback: scan the first 64 MiB at 1 MiB alignment (common
        //    partition alignment) for a stray ext4 superblock.
        let imgSize = dev.imageSize()
        var off: UInt64 = 1 << 20
        while off < min(imgSize, 64 << 20) {
            if let sb = trySuperblock(at: off) { return (off, sb) }
            off += 1 << 20
        }
        throw Ext4Error.notExt4
    }

    /// Candidate partition start offsets (bytes) from an MBR and/or GPT.
    private static func partitionStarts(_ dev: Ext4Device) -> [UInt64] {
        var starts: [UInt64] = []
        guard let first = try? dev.read(at: 0, count: 512), first.count == 512 else { return starts }
        let sectorSize: UInt64 = 512
        // GPT? "EFI PART" at LBA 1.
        if let hdr = try? dev.read(at: sectorSize, count: 512), hdr.count == 512,
           Array(hdr[0..<8]) == Array("EFI PART".utf8) {
            let partEntryLBA = le64(hdr, 72)
            let numEntries = le32(hdr, 80)
            let entrySize = le32(hdr, 84)
            let count = min(numEntries, 128)
            if let table = try? dev.read(at: partEntryLBA * sectorSize,
                                         count: Int(count) * Int(entrySize)) {
                for i in 0..<Int(count) {
                    let e = i * Int(entrySize)
                    guard e + 40 <= table.count else { break }
                    // Skip empty entries (zero type GUID).
                    if Array(table[e..<e+16]).allSatisfy({ $0 == 0 }) { continue }
                    let firstLBA = le64(table, e + 32)
                    starts.append(firstLBA * sectorSize)
                }
            }
        }
        // MBR partitions (also covers the protective/hybrid case).
        if first[510] == 0x55 && first[511] == 0xAA {
            for i in 0..<4 {
                let e = 446 + i * 16
                let type = first[e + 4]
                if type == 0 { continue }               // empty
                if type == 0xEE { continue }            // GPT protective, handled above
                let lba = UInt64(le32(first, e + 8))
                if lba != 0 { starts.append(lba * sectorSize) }
            }
        }
        return starts
    }

    // MARK: group descriptors

    private func loadGroupDescriptors() throws {
        // The GDT lives in the block right after the block holding the superblock.
        let gdtBlock = UInt64(sb.firstDataBlock) + 1
        let count = sb.groupCount
        let bytes = try readBlocks(startBlock: gdtBlock,
                                   count: (count * sb.descSize + blockSize - 1) / blockSize)
        groupInodeTable.reserveCapacity(count)
        for g in 0..<count {
            let o = g * sb.descSize
            let lo = UInt64(le32(bytes, o + 8))
            let hi = sb.is64Bit && sb.descSize >= 64 ? UInt64(le32(bytes, o + 40)) : 0
            groupInodeTable.append(lo | (hi << 32))
        }
    }

    // MARK: block I/O
    //
    // All filesystem offsets are relative to the ext4 superblock; the partition
    // may start partway into the image (GPT disk), so every read is rebased by
    // partitionOffset here. (locateFilesystem rebases its own probe reads.)

    func fsRead(at offset: UInt64, count: Int) throws -> [UInt8] {
        try dev.read(at: partitionOffset + offset, count: count)
    }

    func fsWrite(at offset: UInt64, _ bytes: [UInt8]) throws {
        try dev.write(at: partitionOffset + offset, bytes)
    }

    func readBlock(_ block: UInt64) throws -> [UInt8] {
        try fsRead(at: block * UInt64(blockSize), count: blockSize)
    }

    private func readBlocks(startBlock: UInt64, count: Int) throws -> [UInt8] {
        try fsRead(at: startBlock * UInt64(blockSize), count: count * blockSize)
    }

    // MARK: inodes

    /// Filesystem-relative byte offset of an inode's on-disk record.
    func inodeByteOffset(_ ino: UInt32) throws -> UInt64 {
        guard ino >= 1 else { throw Ext4Error.badInode(ino) }
        let group = Int((ino - 1) / sb.inodesPerGroup)
        let index = Int((ino - 1) % sb.inodesPerGroup)
        guard group < groupInodeTable.count else { throw Ext4Error.badInode(ino) }
        return groupInodeTable[group] * UInt64(blockSize) + UInt64(index * sb.inodeSize)
    }

    func inode(_ ino: UInt32) throws -> Ext4Inode {
        let byteOff = try inodeByteOffset(ino)
        let raw = try fsRead(at: byteOff, count: sb.inodeSize)
        guard raw.count >= 128 else { throw Ext4Error.badInode(ino) }
        let mode = le16(raw, 0)
        let sizeLo = UInt64(le32(raw, 4))
        // Upper 32 bits of size live in i_size_high (@108) for regular files.
        let sizeHi = UInt64(le32(raw, 108))
        let isReg = mode & 0xF000 == 0x8000
        let size = isReg ? (sizeLo | (sizeHi << 32)) : sizeLo
        return Ext4Inode(ino: ino, mode: mode, size: size,
                         flags: le32(raw, 32), links: le16(raw, 26), raw: raw)
    }

    // MARK: file contents

    /// The full byte contents of a regular file or directory inode.
    func readData(_ inode: Ext4Inode) throws -> [UInt8] {
        if inode.isInline {
            // Inline data: first 60 bytes live in i_block; the tail (if any) is
            // in a system.data xattr, which we don't parse — cap to what we have.
            let want = Int(min(inode.size, 60))
            return Array(inode.iBlock.prefix(want))
        }
        let bs = blockSize
        let total = Int(inode.size)
        let numBlocks = (total + bs - 1) / bs
        var out = [UInt8](); out.reserveCapacity(total)
        let map = try blockMap(inode, upTo: numBlocks)
        for lbn in 0..<numBlocks {
            if let phys = map[lbn], phys != 0 {
                out.append(contentsOf: try readBlock(phys))
            } else {
                out.append(contentsOf: repeatElement(0, count: bs))   // sparse hole
            }
        }
        if out.count > total { out.removeLast(out.count - total) }
        return out
    }

    /// logical-block -> physical-block map for the first `upTo` blocks.
    func blockMap(_ inode: Ext4Inode, upTo: Int) throws -> [Int: UInt64] {
        if inode.usesExtents {
            var map = [Int: UInt64]()
            try walkExtents(Array(inode.iBlock), into: &map, limit: upTo)
            return map
        } else {
            return try legacyBlockMap(inode, upTo: upTo)
        }
    }

    /// Recursively walk an extent tree node (header + entries).
    private func walkExtents(_ node: [UInt8], into map: inout [Int: UInt64], limit: Int) throws {
        guard node.count >= 12, le16(node, 0) == 0xF30A else {
            throw Ext4Error.unsupported("bad extent header")
        }
        let entries = Int(le16(node, 2))
        let depth = Int(le16(node, 6))
        for i in 0..<entries {
            let e = 12 + i * 12
            guard e + 12 <= node.count else { break }
            if depth == 0 {
                // leaf: ext4_extent
                let logical = Int(le32(node, e))
                var len = Int(le16(node, e + 4))
                if len > 32768 { len -= 32768 }          // uninitialized extent
                let physHi = UInt64(le16(node, e + 6))
                let physLo = UInt64(le32(node, e + 8))
                let phys = (physHi << 32) | physLo
                for k in 0..<len where logical + k < limit {
                    map[logical + k] = phys + UInt64(k)
                }
            } else {
                // internal: ext4_extent_idx -> child node block
                let leafLo = UInt64(le32(node, e + 4))
                let leafHi = UInt64(le16(node, e + 8))
                let child = (leafHi << 32) | leafLo
                let childBytes = try readBlock(child)
                try walkExtents(childBytes, into: &map, limit: limit)
            }
        }
    }

    /// Classic ext2/3 direct/indirect block map.
    private func legacyBlockMap(_ inode: Ext4Inode, upTo: Int) throws -> [Int: UInt64] {
        var map = [Int: UInt64]()
        let ib = Array(inode.iBlock)
        let ptrsPerBlock = blockSize / 4
        func ptr(_ i: Int) -> UInt64 { UInt64(le32(ib, i * 4)) }

        var lbn = 0
        func place(_ phys: UInt64) -> Bool {
            if lbn >= upTo { return false }
            if phys != 0 { map[lbn] = phys }
            lbn += 1
            return true
        }
        // 12 direct
        for i in 0..<12 { if !place(ptr(i)) { return map } }
        // single / double / triple indirect
        func indirect(_ blk: UInt64, level: Int) throws -> Bool {
            if blk == 0 {
                // Skip the blocks this pointer would have covered (all holes).
                let span = Int(powInt(ptrsPerBlock, level))
                for _ in 0..<span { if !place(0) { return false } }
                return true
            }
            let table = try readBlock(blk)
            for i in 0..<ptrsPerBlock {
                let p = UInt64(le32(table, i * 4))
                if level == 1 { if !place(p) { return false } }
                else { if try !indirect(p, level: level - 1) { return false } }
            }
            return true
        }
        if lbn < upTo { if try !indirect(ptr(12), level: 1) { return map } }
        if lbn < upTo { if try !indirect(ptr(13), level: 2) { return map } }
        if lbn < upTo { _ = try indirect(ptr(14), level: 3) }
        return map
    }

    // MARK: directories

    /// List a directory inode's entries (linear parse; works for htree dirs too,
    /// whose leaf blocks are ordinary dir blocks). "." and ".." are omitted.
    func listDir(_ ino: UInt32) throws -> [Ext4DirEntry] {
        let node = try inode(ino)
        guard node.isDir else { throw Ext4Error.notADirectory("inode \(ino)") }
        if node.isInline {
            return try inlineDirEntries(node)
        }
        let data = try readData(node)
        return parseDirBlock(data, includeDots: false)
    }

    private func parseDirBlock(_ data: [UInt8], includeDots: Bool) -> [Ext4DirEntry] {
        var out = [Ext4DirEntry]()
        let bs = blockSize
        var block = 0
        while block * bs < data.count {
            var pos = block * bs
            let end = min(pos + bs, data.count)
            while pos + 8 <= end {
                let entryIno = le32(data, pos)
                let recLen = Int(le16(data, pos + 4))
                if recLen < 8 { break }                  // corrupt; stop this block
                let nameLen = Int(data[pos + 6])
                if entryIno != 0 && pos + 8 + nameLen <= end {
                    let fileType = sb.hasFiletype ? data[pos + 7] : 0
                    let name = String(decoding: data[(pos + 8)..<(pos + 8 + nameLen)], as: UTF8.self)
                    if includeDots || (name != "." && name != "..") {
                        out.append(Ext4DirEntry(name: name, ino: entryIno, fileType: fileType))
                    }
                }
                pos += recLen
            }
            block += 1
        }
        return out
    }

    private func inlineDirEntries(_ node: Ext4Inode) throws -> [Ext4DirEntry] {
        // Inline dir: first 4 bytes are the "." fake header, then a normal
        // dir-entry stream. Parse conservatively from the i_block area.
        let data = Array(node.iBlock)
        var out = [Ext4DirEntry]()
        var pos = 4                                       // skip inline "." header
        while pos + 8 <= data.count {
            let entryIno = le32(data, pos)
            let recLen = Int(le16(data, pos + 4))
            if recLen < 8 { break }
            let nameLen = Int(data[pos + 6])
            if entryIno != 0 && pos + 8 + nameLen <= data.count {
                let name = String(decoding: data[(pos + 8)..<(pos + 8 + nameLen)], as: UTF8.self)
                if name != "." && name != ".." {
                    out.append(Ext4DirEntry(name: name, ino: entryIno,
                                            fileType: sb.hasFiletype ? data[pos + 7] : 0))
                }
            }
            pos += recLen
        }
        return out
    }

    // MARK: path resolution

    static let rootInode: UInt32 = 2

    /// Resolve an absolute path (e.g. "/etc/hostname") to an inode number.
    func resolve(_ path: String) throws -> UInt32 {
        var cur = Ext4Volume.rootInode
        for comp in path.split(separator: "/") where comp != "." {
            let entries = try listDir(cur)
            guard let match = entries.first(where: { $0.name == String(comp) }) else {
                throw Ext4Error.notFound(path)
            }
            cur = match.ino
        }
        return cur
    }

    /// Read a file at an absolute path.
    func read(_ path: String) throws -> [UInt8] {
        try readData(try inode(try resolve(path)))
    }

    /// Target of a symlink inode (fast symlinks store the target inline in i_block).
    func symlinkTarget(_ node: Ext4Inode) throws -> String {
        if node.size < 60 && !node.usesExtents {
            return String(decoding: node.iBlock.prefix(Int(node.size)), as: UTF8.self)
        }
        return String(decoding: try readData(node), as: UTF8.self)
    }
}

// MARK: - little-endian byte helpers

@inline(__always) func le16(_ b: [UInt8], _ o: Int) -> UInt16 {
    UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
}
@inline(__always) func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}
@inline(__always) func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
    UInt64(le32(b, o)) | (UInt64(le32(b, o + 4)) << 32)
}
@inline(__always) private func powInt(_ base: Int, _ exp: Int) -> Int {
    var r = 1; for _ in 0..<exp { r *= base }; return r
}
@inline(__always) func putLE16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
    b[o] = UInt8(v & 0xff); b[o + 1] = UInt8((v >> 8) & 0xff)
}
@inline(__always) func putLE32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    b[o] = UInt8(v & 0xff); b[o + 1] = UInt8((v >> 8) & 0xff)
    b[o + 2] = UInt8((v >> 16) & 0xff); b[o + 3] = UInt8((v >> 24) & 0xff)
}
