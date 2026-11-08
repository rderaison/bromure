import Compression
import Foundation

// What OpenShellWebSocket takes from Compression.framework: its raw-deflate
// decode (the Linux build has its own over zlib).

extension OpenShellWebSocket {
    /// Raw DEFLATE (`COMPRESSION_ZLIB`) decode of `input` into at most `cap`
    /// bytes: what it decoded, `cap` bytes when the output fills it, empty
    /// when it couldn't decode (compression_decode_buffer's contract).
    static func decodeRawDeflate(_ input: Data, cap: Int) -> Data {
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(n)
    }
}
