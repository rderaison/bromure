import Foundation
import Testing
@testable import ACLinux

/// zlib's inflate (CACLinuxShims' acl_inflate) under each window: a raw
/// stream followed by other bytes ends at its final block (a WebSocket
/// permessage-deflate message carries a sync-flush tail; a body may carry a
/// stray byte), while gzip members one after another are all read.
@Suite("Raw inflate with trailing bytes")
struct InflateTrailingTests {
    @Test func aRawStreamEndsAtItsFinalBlock() throws {
        let text = Data("hello hello hello hello".utf8)
        let raw = try #require(NPMRegistryTransforms.deflateRaw(text))
        // As a request body (Content-Encoding: deflate, raw form) with a byte after it.
        #expect(RequestReader.inflated(raw + Data([0x00]), windowBits: -15) == text)
        // As the npm codec reads it.
        #expect(NPMRegistryTransforms.inflateRaw(raw + Data([0x00, 0x00, 0xff, 0xff]), limit: 1 << 20) == text)
    }

    @Test func gzipMembersOneAfterAnotherAreAllRead() throws {
        // Two gzip members of "a" and "b" (RFC 1952 concatenation).
        let a: [UInt8] = [0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0x02, 0xff, 0x4b, 0x04, 0x00, 0x43, 0xbe, 0xb7, 0xe8, 0x01, 0, 0, 0]
        let b: [UInt8] = [0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0x02, 0xff, 0x4b, 0x02, 0x00, 0xf9, 0xef, 0xbe, 0x71, 0x01, 0, 0, 0]
        #expect(RequestReader.inflated(Data(a + b), windowBits: 16 + 15) == Data("ab".utf8))
    }
}
