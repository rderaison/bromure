import CACLinuxShims
import Foundation

/// A content-coded request body decoded for the content scans (macOS:
/// HTTPMitmConnection.decodeRequestContentEncoding, on Compression.framework):
/// gzip, deflate and br over the system's zlib and libbrotlidec, zstd with
/// the shared pure-Swift decoder. Forwarded decoded, as macOS forwards it.
// @port-skip linux-only: decodeRequestContentEncoding's result, on the Linux proxy
enum RequestBodyDecoding: Equatable {
    /// No (or `identity`) Content-Encoding: the body is already plain.
    case identity
    /// The whole request with its body decoded, no Content-Encoding, and a
    /// Content-Length for the decoded body.
    case decoded(Data)
    /// A coding that can't be decoded (unknown, corrupt, a zstd frame that
    /// needs a dictionary, or one inflating past the 64 MiB cap).
    case undecodable(String)
}

extension RequestReader {
    /// Decoded bodies stop here (macOS's cap).
    static let decodedBodyCap = 64 << 20

    /// The request's body decoded. Every Content-Encoding line counts (a
    /// later `identity` doesn't make an earlier `gzip` plain); stacked codings
    /// are undone in reverse, as they were applied in order.
    // @port HTTPMitmConnection.static decodeRequestContentEncoding(_: Data) h=53e3c61c88724cc4 @cf1cec65
    static func decodeRequestContentEncoding(_ raw: Data) -> RequestBodyDecoding {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return .identity }
        let header = String(decoding: raw[raw.startIndex..<sep.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        let codings = lines.dropFirst().flatMap { line -> [String] in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-encoding" else { return [] }
            return line[line.index(after: colon)...].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && $0 != "identity" }
        }
        guard !codings.isEmpty else { return .identity }
        var plain = Data(raw[sep.upperBound...])
        for coding in codings.reversed() {
            let next: Data?
            switch coding {
            case "gzip", "x-gzip": next = inflated(plain, windowBits: 16 + 15)
            case "deflate": next = inflated(plain, windowBits: 15) ?? inflated(plain, windowBits: -15)   // zlib, then raw
            case "br": next = brotliDecoded(plain)
            case "zstd": next = try? Zstd.decompress(plain, maxOutput: decodedBodyCap)
            default: next = nil
            }
            guard let next else { return .undecodable(coding) }
            plain = next
        }
        let kept = lines.filter { line in
            guard let colon = line.firstIndex(of: ":") else { return true }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            return name != "content-encoding" && name != "content-length" && name != "transfer-encoding"
        }
        return .decoded(Data((kept.joined(separator: "\r\n") + "\r\nContent-Length: \(plain.count)\r\n\r\n").utf8) + plain)
    }

    // @port-skip linux-only: zlib's inflate (macOS: Compression.framework's)
    static func inflated(_ data: Data, windowBits: Int32) -> Data? {
        decoded(data) { p, n, out, len in acl_inflate(p, n, windowBits, decodedBodyCap, out, len) }
    }

    // @port-skip linux-only: libbrotlidec (macOS: Compression.framework's brotli)
    static func brotliDecoded(_ data: Data) -> Data? {
        decoded(data) { p, n, out, len in acl_brotli_decode(p, n, decodedBodyCap, out, len) }
    }

    // @port-skip linux-only: the C decoders' calling convention
    private static func decoded(_ data: Data,
                                _ run: (UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> Int32) -> Data? {
        guard !data.isEmpty else { return nil }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = data.withUnsafeBytes { raw in
            run(raw.bindMemory(to: UInt8.self).baseAddress!, data.count, &out, &len)
        }
        defer { free(out) }
        guard rc == 0, let out else { return nil }
        return Data(bytes: out, count: len)
    }
}
