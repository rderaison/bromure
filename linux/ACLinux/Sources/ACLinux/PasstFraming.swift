import Foundation
import NIOCore

/// passt's wire format on its Unix socket: each Ethernet frame is a 4-byte
/// big-endian length followed by the frame.
// @port-skip linux-only: passt framing (macOS: vmnet)
public enum PasstFraming {
    /// Ethernet header (14) at least; jumbo frames up to 64 KiB at most.
    public static let minFrame = 14
    public static let maxFrame = 65_550

    /// `u32 length (big-endian) + frame` for each frame, in one buffer.
    // @port-skip linux-only: passt framing
    static func encode(_ frames: [Data]) -> ByteBuffer {
        var buf = ByteBuffer()
        buf.reserveCapacity(frames.reduce(0) { $0 + $1.count + 4 })
        for f in frames {
            buf.writeInteger(UInt32(f.count))
            buf.writeBytes(f)
        }
        return buf
    }
}
