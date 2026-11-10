import CACLinuxShims
import Foundation

// What NPMRegistryTransforms needs that macOS takes from Compression.framework
// (NPMRegistryTransforms+Apple.swift): a tarball's raw-deflate codec, here on
// the system's zlib.

extension NPMRegistryTransforms {
    /// Streaming raw-deflate decode, bounded by `limit` (exactly `limit`
    /// bytes is fine, more fails). nil on error or a truncated stream.
    // partial: zlib
    // @port NPMRegistryTransforms.static inflateRaw(_: Data, limit: Int) h=cea4c0eca4322d3b @b657b5de
    static func inflateRaw(_ payload: Data, limit: Int) -> Data? {
        guard !payload.isEmpty else { return nil }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = payload.withUnsafeBytes { raw in
            acl_inflate(raw.bindMemory(to: UInt8.self).baseAddress!, payload.count, -15, limit, &out, &len)
        }
        defer { free(out) }
        guard rc == 0, let out else { return nil }
        return Data(bytes: out, count: len)
    }

    /// Raw deflate (no zlib or gzip wrapper) of all of `data`. nil on error.
    // partial: zlib
    // @port NPMRegistryTransforms.static deflateRaw(_: Data) h=10c3b617dbc1c5b7 @b657b5de
    static func deflateRaw(_ data: Data) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        // An empty input still needs a pointer: one byte, none of it read.
        let n = data.count
        let rc = (n == 0 ? Data([0]) : data).withUnsafeBytes { raw in
            acl_deflate_raw(raw.bindMemory(to: UInt8.self).baseAddress!, n, &out, &len)
        }
        defer { free(out) }
        guard rc == 0, let out else { return nil }
        return Data(bytes: out, count: len)
    }
}
