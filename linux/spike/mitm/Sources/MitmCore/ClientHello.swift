import NIOCore

/// The parts of a TLS ClientHello the proxy needs before it picks a leaf and
/// an upstream: SNI and the offered ALPN protocols.
public struct ClientHelloInfo: Equatable {
    public var serverName: String?
    public var alpn: [String]

    public enum Parse: Equatable {
        case needMore
        case notTLS
        case hello(ClientHelloInfo)
    }

    /// Parses the first TLS record of `buf` (not consumed). The ClientHello
    /// must fit one record (16 KiB), which it does in practice, post-quantum
    /// key shares included.
    public static func parse(_ buf: ByteBuffer) -> Parse {
        let b = Array(buf.readableBytesView)
        guard b.count >= 5 else { return .needMore }
        guard b[0] == 0x16, b[1] == 0x03 else { return .notTLS }
        let recLen = Int(b[3]) << 8 | Int(b[4])
        guard b.count >= 5 + recLen else { return .needMore }
        var i = 5
        func u8() -> Int? { guard i < 5 + recLen else { return nil }; defer { i += 1 }; return Int(b[i]) }
        func u16() -> Int? { guard let h = u8(), let l = u8() else { return nil }; return h << 8 | l }
        func skip(_ n: Int) -> Bool { i += n; return i <= 5 + recLen }
        guard u8() == 1, skip(3), skip(2 + 32),                         // handshake type, length, version, random
              let sid = u8(), skip(sid), let cs = u16(), skip(cs), let cm = u8(), skip(cm) else { return .notTLS }
        var info = ClientHelloInfo(serverName: nil, alpn: [])
        guard let extLen = u16() else { return .hello(info) }
        let extEnd = min(i + extLen, 5 + recLen)
        while i + 4 <= extEnd {
            guard let type = u16(), let len = u16() else { break }
            let start = i
            if type == 0x0000, let listLen = u16(), listLen > 3, u8() == 0, let n = u16(), i + n <= extEnd {
                info.serverName = String(decoding: b[i..<i + n], as: UTF8.self)
            } else if type == 0x0010, let listLen = u16() {
                let end = min(i + listLen, extEnd)
                while i < end, let n = u8(), i + n <= end {
                    info.alpn.append(String(decoding: b[i..<i + n], as: UTF8.self))
                    i += n
                }
            }
            i = start + len
        }
        return .hello(info)
    }
}
