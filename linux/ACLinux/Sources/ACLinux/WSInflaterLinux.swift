import CACLinuxShims
import Foundation

/// Inflater for RFC 7692 permessage-deflate over the system's zlib (macOS:
/// WSInflater on Compression.framework's raw DEFLATE). Each message gets the
/// `00 00 FF FF` trailer the sender stripped; with `noContextTakeover` the
/// window is reset between messages, else it carries over. A corrupt stream
/// or a message past 32 MB inflates to nil: the trace shows the raw bytes.
// @port-skip linux-only: zlib under WSInflater (macOS: Compression.framework)
final class WSInflater {
    private let z: OpaquePointer?
    private let noContextTakeover: Bool

    // @port-skip linux-only: the zlib WSInflater (macOS: Compression.framework, under #if !BROMURE_LINUX)
    init(noContextTakeover: Bool) {
        self.noContextTakeover = noContextTakeover
        z = acl_ws_inflater_new()
    }

    // @port-skip linux-only: the zlib WSInflater (macOS: Compression.framework, under #if !BROMURE_LINUX)
    deinit { acl_ws_inflater_free(z) }

    // @port-skip linux-only: the zlib WSInflater (macOS: Compression.framework, under #if !BROMURE_LINUX)
    func inflate(_ compressed: Data) -> Data? {
        guard let z else { return nil }
        var input = compressed
        input.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF])
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = input.withUnsafeBytes { raw in
            acl_ws_inflate(z, raw.bindMemory(to: UInt8.self).baseAddress, input.count, 32 * 1024 * 1024, &out, &len)
        }
        defer { free(out) }
        if noContextTakeover { _ = acl_ws_inflater_reset(z) }
        guard rc == 0 else { return nil }
        return out.map { Data(bytes: $0, count: len) } ?? Data()
    }
}
