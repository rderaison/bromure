import Compression
import Foundation

// What NPMRegistryTransforms needs that's Apple's: Compression.framework's
// streaming raw-deflate codec (a tarball's gzip payload). Linux has its own,
// on the system's zlib.

extension NPMRegistryTransforms {
    /// Streaming raw-deflate decode, bounded by `limit`. nil on error.
    static func inflateRaw(_ payload: Data, limit: Int) -> Data? {
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: 256 * 1024)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }
        var out = Data()
        return payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            stream.src_ptr = base
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = 256 * 1024
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = 256 * 1024 - stream.dst_size
                if produced > 0 { out.append(dst, count: produced) }
                if out.count > limit { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 { return nil }   // stalled: truncated input
                default: return nil
                }
            }
        }
    }

    /// Raw deflate (no zlib or gzip wrapper) of all of `data`, streamed (no
    /// guessed output size). nil on error.
    static func deflateRaw(_ data: Data) -> Data? {
        let cap = 256 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }
        var acc = Data()
        let ok: Bool = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Bool in
            stream.src_ptr = src.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(dst)
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = cap
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = cap - stream.dst_size
                if produced > 0 { acc.append(dst, count: produced) }
                if status == COMPRESSION_STATUS_END { return true }
                if status != COMPRESSION_STATUS_OK { return false }
            }
        }
        guard ok else { return nil }
        return acc
    }
}
