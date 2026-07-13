import Foundation

// crc32c (Castagnoli, reflected) — the checksum ext4's metadata_csum feature
// uses. `hash` is a *running* crc: it does no pre/post inversion, so the caller
// supplies the seed (the fs checksum seed, or a previous crc) exactly as the
// kernel's ext4_chksum()/e2fsprogs ext2fs_crc32c_le() do.
enum Crc32c {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0x82F6_3B78 ^ (c >> 1)) : (c >> 1)
            }
            t[n] = c
        }
        return t
    }()

    static func hash(_ seed: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var crc = seed
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        return crc
    }

    static func hash(_ seed: UInt32, _ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc = seed
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        return crc
    }
}
