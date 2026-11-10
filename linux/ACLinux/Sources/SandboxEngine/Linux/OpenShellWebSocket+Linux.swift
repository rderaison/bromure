import CACLinuxShims
import Foundation

// What OpenShellWebSocket takes from Compression.framework on macOS
// (OpenShellWebSocket+Apple.swift), here on the system's zlib.

extension OpenShellWebSocket {
    /// One raw DEFLATE stream from `input`, as macOS's: ended (its final
    /// block decoded), truncated, corrupt, or too large (`cap` bytes or more).
    // partial: zlib
    // @port OpenShellWebSocket.static decodeRawDeflate(_: Data, cap: Int) h=1ae0a4612297f4b1 @83fb7191
    static func decodeRawDeflate(_ input: Data, cap: Int) -> RawInflate {
        guard !input.isEmpty else { return .truncated }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = input.withUnsafeBytes { raw in
            acl_inflate_raw_message(raw.bindMemory(to: UInt8.self).baseAddress!, input.count, cap, &out, &len)
        }
        defer { free(out) }
        switch rc {
        case 0: return len >= cap ? .tooLarge : .ended(out.map { Data(bytes: $0, count: len) } ?? Data())
        case -2: return .tooLarge
        case -3: return .truncated
        default: return .corrupt
        }
    }
}
