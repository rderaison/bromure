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
    /// More stacked codings than this aren't decoded (refused).
    static let maxCodings = 4

    /// The request's body decoded. Every Content-Encoding line counts (a
    /// later `identity` doesn't make an earlier `gzip` plain); stacked codings
    /// are undone in reverse, as they were applied in order, at most
    /// `maxCodings` of them. A header line this can't read with certainty (no
    /// colon, an obs-fold continuation, a bare LF) could hide a coding: the
    /// request is undecodable. One empty line may lead the request line. Headers
    /// are Latin-1, as macOS reads them.
    // @port HTTPMitmConnection.static decodeRequestContentEncoding(_: Data) h=0d9bf1c5e5591c9e @b0ecb81f
    static func decodeRequestContentEncoding(_ raw: Data) -> RequestBodyDecoding {
        // One empty line before the request line is allowed (RFC 9112 §2.2).
        let raw = raw.starts(with: Data("\r\n".utf8)) ? raw.dropFirst(2) : raw
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: raw[raw.startIndex..<sep.lowerBound], encoding: .isoLatin1) else { return .identity }
        let lines = header.components(separatedBy: "\r\n")
        if lines.dropFirst().contains(where: { $0.contains("\n") || $0.contains("\r") || $0.first == " " || $0.first == "\t" || !$0.contains(":") }) {
            return .undecodable("an unreadable header line")
        }
        let codings = lines.dropFirst().flatMap { line -> [String] in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-encoding" else { return [] }
            return line[line.index(after: colon)...].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && $0 != "identity" }
        }
        guard !codings.isEmpty else { return .identity }
        guard codings.count <= maxCodings else { return .undecodable("\(codings.count) stacked codings") }
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
        return .decoded(withDecodedBody(lines, plain))
    }

    /// `raw` with `plain` as its body (its coding and length headers
    /// replaced): the trace's copy of a request whose body was decoded once.
    // @port-skip linux-only: the trace copy's share of one decode
    static func withDecodedBody(_ raw: Data, _ plain: Data) -> Data? {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: raw[raw.startIndex..<sep.lowerBound], encoding: .isoLatin1) else { return nil }
        return withDecodedBody(header.components(separatedBy: "\r\n"), plain)
    }

    // @port-skip linux-only: decodeRequestContentEncoding's header rewrite
    private static func withDecodedBody(_ lines: [String], _ plain: Data) -> Data {
        let kept = lines.filter { line in
            guard let colon = line.firstIndex(of: ":") else { return true }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            return name != "content-encoding" && name != "content-length" && name != "transfer-encoding"
        }
        let head = kept.joined(separator: "\r\n") + "\r\nContent-Length: \(plain.count)\r\n\r\n"
        return (head.data(using: .isoLatin1) ?? Data(head.utf8)) + plain
    }

    // partial: zlib's inflate (gzip, zlib and raw deflate by window bits) for Compression.framework's
    // @port decompressBody(_: Data, encoding: String) h=01c546a9542be1af @003f61e7
    // @port gunzipData(_: Data) h=cd2a28f4055e58f5 @003f61e7
    // @port inflateData(_: Data, format: DeflateFormat) h=3fbc76787f0e72c3 @003f61e7
    static func inflated(_ data: Data, windowBits: Int32) -> Data? {
        decoded(data) { p, n, out, len in acl_inflate(p, n, windowBits, decodedBodyCap, out, len) }
    }

    // partial: libbrotlidec for Compression.framework's brotli
    // @port brotliDecode(_: Data) h=66090b2457bc9e6c @003f61e7
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
