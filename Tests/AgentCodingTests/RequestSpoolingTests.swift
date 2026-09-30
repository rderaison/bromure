import Foundation
import Testing
@testable import bromure_ac

/// `readRequestSpooling` is the MITM's request reader — it must read a full
/// body regardless of size or framing, never truncating. Two framings matter:
/// `Content-Length` (spilled to a temp file past the inline cap) and
/// `Transfer-Encoding: chunked` (no length — de-chunked, then inline or
/// spilled). The old reader capped the request at 8 MB, so a docker layer PUT
/// was truncated (digest mismatch / EOF), and it treated a chunked request as
/// having no body at all. These pin both fixes, including the parsing edges of
/// the chunk grammar (extensions, trailers) and the inline↔spill boundary.
// The code under test (readRequestSpooling) is deprecated on purpose — it wraps
// SecureTransport, which the MiTM needs, and the product confines that
// deprecation to the MiTM layer. Swift Testing refuses a deprecated suite,
// so the warning is silenced here instead (compilers without @diagnose
// skip the attribute and just warn).
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored)
#endif
@Suite("MITM request spooling + de-chunking")
struct RequestSpoolingTests {

    /// Feeds a scripted byte sequence to the reader, one `read()` per segment,
    /// to model TCP segmentation. `write()` (the 100-continue interim) is
    /// captured for inspection. An empty script → EOF.
    private final class ScriptedStream: MitmServerStream, @unchecked Sendable {
        private var segments: [Data]
        private(set) var written = Data()
        init(_ segments: [Data]) { self.segments = segments }
        func handshake() throws {}
        func write(_ data: Data) throws { written.append(data) }
        func read(maxBytes: Int) throws -> Data {
            guard !segments.isEmpty else { return Data() }   // EOF
            let next = segments.removeFirst()
            if next.count > maxBytes {                       // respect the caller's cap
                segments.insert(next.suffix(from: next.startIndex + maxBytes), at: 0)
                return next.prefix(maxBytes)
            }
            return next
        }
    }

    /// Reassemble the returned request (and any spooled body file) into the
    /// full de-framed body the proxy would forward upstream.
    private func bodyOf(_ result: (request: Data, bodyFile: URL?)) throws -> Data {
        if let f = result.bodyFile {
            defer { try? FileManager.default.removeItem(at: f) }
            return try Data(contentsOf: f)
        }
        guard let sep = result.request.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return result.request.subdata(in: sep.upperBound..<result.request.count)
    }

    private func chunkFraming(_ body: Data, chunkSize: Int, extensions: Bool = false,
                              trailer: Bool = false) -> Data {
        var out = Data()
        var i = 0
        while i < body.count {
            let n = min(chunkSize, body.count - i)
            let ext = extensions ? ";weird=1" : ""
            out.append(Data("\(String(n, radix: 16))\(ext)\r\n".utf8))
            out.append(body.subdata(in: i..<(i + n)))
            out.append(Data("\r\n".utf8))
            i += n
        }
        out.append(Data("0\r\n".utf8))
        if trailer { out.append(Data("X-Checksum: abc\r\n".utf8)) }
        out.append(Data("\r\n".utf8))
        return out
    }

    // MARK: - Content-Length

    @Test("Small Content-Length body stays inline, byte-exact")
    func inlineContentLength() throws {
        let body = Data((0..<5000).map { UInt8($0 & 0xff) })
        let req = Data("PUT /x HTTP/1.1\r\nhost: h\r\ncontent-length: \(body.count)\r\n\r\n".utf8) + body
        let r = try readRequestSpooling(via: ScriptedStream([req]), inlineCap: 8 * 1024 * 1024)
        #expect(r.bodyFile == nil)
        #expect(try bodyOf(r) == body)
    }

    @Test("Content-Length body over the inline cap spills to a file, whole")
    func spilledContentLength() throws {
        let body = Data((0..<20_000).map { UInt8(($0 * 7) & 0xff) })
        let req = Data("PUT /x HTTP/1.1\r\nhost: h\r\ncontent-length: \(body.count)\r\n\r\n".utf8) + body
        // Tiny cap so 20 KB counts as "large"; segmented to exercise the read loop.
        let seg = stride(from: 0, to: req.count, by: 1500).map { req.subdata(in: $0..<min($0 + 1500, req.count)) }
        let r = try readRequestSpooling(via: ScriptedStream(seg), inlineCap: 4096)
        #expect(r.bodyFile != nil)                 // spilled
        #expect(try bodyOf(r) == body)             // and complete
    }

    // MARK: - Chunked

    @Test("Small chunked body is de-chunked inline, byte-exact")
    func inlineChunked() throws {
        let body = Data("the quick brown fox jumps over the lazy dog".utf8)
        let req = Data("POST /u HTTP/1.1\r\nhost: h\r\ntransfer-encoding: chunked\r\n\r\n".utf8)
            + chunkFraming(body, chunkSize: 7)
        let r = try readRequestSpooling(via: ScriptedStream([req]), inlineCap: 8 * 1024 * 1024)
        #expect(r.bodyFile == nil)
        #expect(try bodyOf(r) == body)
        // Transfer-Encoding stays in the header we hand back; relayUpstream
        // strips it — but the returned body must be the DECODED bytes, not the
        // chunk framing.
        #expect(!(try bodyOf(r)).starts(with: Data("2b\r\n".utf8)))
    }

    @Test("Chunk extensions and trailers are ignored; body is exact")
    func chunkedExtensionsAndTrailers() throws {
        let body = Data((0..<3000).map { UInt8(($0 * 3) & 0xff) })
        let req = Data("POST /u HTTP/1.1\r\nhost: h\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
            + chunkFraming(body, chunkSize: 256, extensions: true, trailer: true)
        // Segment finely so the parser must reassemble size-lines/data across reads.
        let seg = stride(from: 0, to: req.count, by: 40).map { req.subdata(in: $0..<min($0 + 40, req.count)) }
        let r = try readRequestSpooling(via: ScriptedStream(seg), inlineCap: 8 * 1024 * 1024)
        #expect(try bodyOf(r) == body)
    }

    @Test("Chunked body over the inline cap spills to a file, whole")
    func spilledChunked() throws {
        let body = Data((0..<50_000).map { UInt8(($0 * 11) & 0xff) })
        let req = Data("POST /u HTTP/1.1\r\nhost: h\r\ntransfer-encoding: chunked\r\n\r\n".utf8)
            + chunkFraming(body, chunkSize: 1024)
        let r = try readRequestSpooling(via: ScriptedStream([req]), inlineCap: 8192)
        #expect(r.bodyFile != nil)                 // crossed the cap → spilled
        #expect(try bodyOf(r) == body)             // and complete
    }

    // MARK: - No body / Expect

    @Test("Bodyless request (no CL, not chunked) returns just the header")
    func noBody() throws {
        let req = Data("GET / HTTP/1.1\r\nhost: h\r\n\r\n".utf8)
        let r = try readRequestSpooling(via: ScriptedStream([req]), inlineCap: 8 * 1024 * 1024)
        #expect(r.bodyFile == nil)
        #expect(try bodyOf(r).isEmpty)
    }

    @Test("Expect: 100-continue is answered before the body is read")
    func expectContinue() throws {
        let body = Data("hello".utf8)
        let req = Data("PUT /x HTTP/1.1\r\nhost: h\r\nExpect: 100-continue\r\ncontent-length: \(body.count)\r\n\r\n".utf8) + body
        let stream = ScriptedStream([req])
        let r = try readRequestSpooling(via: stream, inlineCap: 8 * 1024 * 1024)
        #expect(String(data: stream.written, encoding: .isoLatin1) == "HTTP/1.1 100 Continue\r\n\r\n")
        #expect(try bodyOf(r) == body)
    }

    // MARK: - Framing hygiene (both modes)

    private func read(_ raw: String, strict: Bool = false, extra: Data = Data()) throws -> (request: Data, bodyFile: URL?) {
        try readRequestSpooling(via: ScriptedStream([Data(raw.utf8) + extra]), inlineCap: 8 * 1024 * 1024, strict: strict)
    }

    private func rejected(_ raw: String, _ fragment: String, extra: Data = Data()) {
        do {
            _ = try read(raw, strict: true, extra: extra)
            Issue.record("accepted: \(raw.prefix(60))")
        } catch MitmError.invalidRequest(let why) {
            #expect(why.contains(fragment), "\(why)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A pipelined request after a Content-Length body is not folded into it")
    func pipelinedBytesStayOut() throws {
        for strict in [false, true] {
            let r = try read("POST /a HTTP/1.1\r\nhost: h\r\ncontent-length: 5\r\n\r\nhelloGET /b HTTP/1.1\r\nhost: h\r\n\r\n",
                             strict: strict)
            #expect(try bodyOf(r) == Data("hello".utf8))
        }
    }

    @Test("Lenient: an invalid Content-Length means no body, and nothing past the header leaks in")
    func lenientInvalidContentLength() throws {
        let r = try read("POST /a HTTP/1.1\r\nhost: h\r\ncontent-length: 12abc\r\n\r\nsmuggled-bytes")
        #expect(try bodyOf(r).isEmpty)
    }

    @Test("Chunk data not followed by CRLF is malformed in either mode")
    func missingChunkCRLF() {
        let raw = "POST /u HTTP/1.1\r\nhost: h\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabcXY0\r\n\r\n"
        #expect(throws: MitmError.self) { try read(raw) }
        rejected(raw, "missing terminating CRLF")
    }

    // MARK: - OpenShell-strict framing (openshell-supervisor-network l7/rest.rs)

    @Test("Strict: ambiguous or invalid framing is rejected")
    func strictFraming() {
        rejected("POST /a HTTP/1.1\r\nhost: h\r\ncontent-length: 3\r\ntransfer-encoding: chunked\r\n\r\n", "both Transfer-Encoding and Content-Length")
        rejected("POST /a HTTP/1.1\r\nhost: h\r\ncontent-length: 3\r\ncontent-length: 4\r\n\r\nabcd", "differing values")
        rejected("POST /a HTTP/1.1\r\nhost: h\r\ncontent-length: 12abc\r\n\r\n", "invalid Content-Length")
        rejected("POST /a HTTP/1.1\r\nhost: h\r\ntransfer-encoding: gzip, chunked\r\n\r\n", "unsupported Transfer-Encoding")
        rejected("POST /a HTTP/1.1\r\nhost: h\r\ntransfer-encoding: chunked,\r\n\r\n", "empty Transfer-Encoding")
        rejected("POST /a HTTP/1.1\r\nhost: h\r\ncontent-length: 10\r\n\r\nshort", "ended before Content-Length")
        rejected("POST /u HTTP/1.1\r\nhost: h\r\ntransfer-encoding: chunked\r\n\r\n5\r\nab", "ended inside a chunk")
        rejected("POST /u HTTP/1.1\r\nhost: h\r\ntransfer-encoding: chunked\r\n\r\nzz\r\n", "Invalid chunk size")
    }

    @Test("Strict: malformed header blocks are rejected")
    func strictHeaders() {
        rejected("GET /a HTTP/1.1\nhost: h\r\n\r\n", "bare LF")
        rejected("GET /a HTTP/2.0\r\nhost: h\r\n\r\n", "Unsupported HTTP version")
        rejected("GET /a HTTP/1.1\r\n\r\n", "missing a Host header")
        rejected("GET /a HTTP/1.1\r\nhost: a\r\nhost: b\r\n\r\n", "multiple Host headers")
        rejected("GET /a HTTP/1.1\r\nhost: h\r\n folded: x\r\n\r\n", "continuation lines")
        rejected("GET /a HTTP/1.1\r\nhost : h\r\n\r\n", "whitespace before ':'")
        rejected("GET /a HTTP/1.1\r\nhost: h\r\nconnection: close, content-length\r\n\r\n", "nominates")
        rejected("GET http://other.example/a HTTP/1.1\r\nhost: h\r\n\r\n", "does not match the Host header")
        rejected("GET  /a HTTP/1.1\r\nhost: h\r\n\r\n", "exactly 'METHOD SP target SP")
        rejected("GET /a HTTP/1.1\r\nhost: h\r\nx: " + String(repeating: "a", count: 17_000) + "\r\n\r\n", "exceed 16384")
    }

    @Test("Strict: well-formed requests read exactly as before")
    func strictAcceptsGoodRequests() throws {
        let body = Data("the quick brown fox".utf8)
        let chunked = Data("POST /u HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
            + chunkFraming(body, chunkSize: 4, extensions: true, trailer: true)
        #expect(try bodyOf(readRequestSpooling(via: ScriptedStream([chunked]), inlineCap: 1 << 20, strict: true)) == body)
        let fixed = try read("PUT /x HTTP/1.1\r\nHost: h:8443\r\nContent-Length: 5\r\n\r\nhello", strict: true)
        #expect(try bodyOf(fixed) == Data("hello".utf8))
        let http10 = try read("GET /x HTTP/1.0\r\n\r\n", strict: true)   // HTTP/1.0 needs no Host
        #expect(try bodyOf(http10).isEmpty)
    }
}
