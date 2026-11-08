import CACLinuxShims
import Foundation

// What OpenShellWebSocket takes from Compression.framework on macOS
// (OpenShellWebSocket+Apple.swift), here on the system's zlib.

extension OpenShellWebSocket {
    /// Raw DEFLATE decode of `input` into at most `cap` bytes, as macOS's
    /// compression_decode_buffer: what it decoded, `cap` bytes when the
    /// output would pass it, empty when it couldn't decode.
    // @port-skip linux-only: macOS's decodeRawDeflate (OpenShellWebSocket+Apple.swift) on zlib
    static func decodeRawDeflate(_ input: Data, cap: Int) -> Data {
        guard !input.isEmpty else { return Data() }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = input.withUnsafeBytes { raw in
            acl_inflate(raw.bindMemory(to: UInt8.self).baseAddress!, input.count, -15, cap, &out, &len)
        }
        defer { free(out) }
        if rc == -2 { return Data(count: cap) }          // past the cap: as many bytes as it holds
        guard rc == 0, let out else { return Data() }
        return Data(bytes: out, count: min(len, cap))
    }
}
