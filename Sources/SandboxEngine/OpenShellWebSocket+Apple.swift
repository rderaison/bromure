import Compression
import Foundation

// What OpenShellWebSocket takes from Compression.framework: its raw-deflate
// decode (the Linux build has its own over zlib).

extension OpenShellWebSocket {
    /// One raw DEFLATE (`COMPRESSION_ZLIB`) stream from `input`, streamed so
    /// how it ends is known: ended (its final block decoded; what follows it
    /// isn't reported), truncated, corrupt, or too large (`cap` bytes or
    /// more). Nothing partial is passed on.
    static func decodeRawDeflate(_ input: Data, cap: Int) -> RawInflate {
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return .corrupt
        }
        defer { compression_stream_destroy(&stream) }
        var out = Data()
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> RawInflate in
            guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return .truncated }
            stream.src_ptr = base
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 { out.append(dst, count: produced) }
                if out.count >= cap { return .tooLarge }
                switch status {
                case COMPRESSION_STATUS_END: return .ended(out)
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 { return .truncated }   // stalled: the input ran out
                default: return .corrupt
                }
            }
        }
    }
}
