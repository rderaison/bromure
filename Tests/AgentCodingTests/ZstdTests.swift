import CryptoKit
import Foundation
import Testing
@testable import bromure_ac
@testable import SandboxEngine

private func sha256Hex(_ d: Data) -> String {
    SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

private func fixture(_ name: String) throws -> (Data, ZstdFixtures.Fixture) {
    let f = try #require(ZstdFixtures.all.first { $0.name == name })
    return (try #require(Data(base64Encoded: f.compressed)), f)
}

/// The pure-Swift zstd decoder (Sources/AgentCoding/Mitm/Zstd.swift). The
/// vectors in ZstdFixtures.swift were produced by libzstd 1.5.7 (node's
/// zlib.zstdCompressSync) across levels -5…22, with/without checksum and
/// content size, a 1 KiB window, raw / RLE / multi-block frames, and
/// concatenated + skippable frames.
@Suite("Zstd decoder")
struct ZstdDecoderTests {

    @Test("Every libzstd fixture decodes to the exact original bytes",
          arguments: ZstdFixtures.all.map(\.name))
    func fixturesRoundTrip(name: String) throws {
        let (compressed, f) = try fixture(name)
        let plain = try Zstd.decompress(compressed)
        #expect(plain.count == f.length)
        #expect(sha256Hex(plain) == f.sha256)
    }

    @Test("A ≥100 KB multi-block JSON body decodes to valid JSON")
    func largeJSON() throws {
        let (compressed, f) = try fixture("json160k-l19-checksum")
        #expect(f.length >= 100 * 1024)
        let plain = try Zstd.decompress(compressed)
        let obj = try JSONSerialization.jsonObject(with: plain) as? [String: Any]
        #expect(obj?["model"] as? String == "grok-build")
        #expect(String(decoding: plain, as: UTF8.self).contains("Hélène"))
    }

    @Test("Small frame with checksum decodes to the literal text")
    func helloChecksum() throws {
        let (compressed, _) = try fixture("hello-checksum")
        #expect(try Zstd.decompress(compressed) == Data("hello hello hello".utf8))
    }

    @Test("XXH64 matches the reference vectors")
    func xxh64Vectors() {
        #expect(Zstd.xxh64(Data()) == 0xEF46_DB37_51D8_E999)
        #expect(Zstd.xxh64(Data("abc".utf8)) == 0x44BC_2CF5_AD77_0999)
    }

    @Test("A corrupted checksum is rejected")
    func checksumMismatch() throws {
        var (compressed, _) = try fixture("hello-checksum")
        compressed[compressed.count - 1] ^= 0xFF
        #expect(throws: ZstdError.checksumMismatch) { try Zstd.decompress(compressed) }
    }

    @Test("Output cap stops a decompression bomb")
    func outputCap() throws {
        let (compressed, _) = try fixture("rle300k")   // 34 bytes → 300 KB
        #expect(throws: ZstdError.outputTooLarge) { try Zstd.decompress(compressed, maxOutput: 1000) }
        let (multi, _) = try fixture("json160k-nocontentsize-window10")  // no declared size
        #expect(throws: ZstdError.outputTooLarge) { try Zstd.decompress(multi, maxOutput: 50_000) }
    }

    @Test("Dictionary frames, bad magic and empty input are refused")
    func refusals() {
        // magic, FHD = single segment + 1-byte dictionary id, dict 7, FCS 0, last raw block of 0.
        let dict = Data([0x28, 0xB5, 0x2F, 0xFD, 0x21, 0x07, 0x00, 0x01, 0x00, 0x00])
        #expect(throws: ZstdError.unsupported("frame needs dictionary 7")) { try Zstd.decompress(dict) }
        #expect(throws: ZstdError.self) { try Zstd.decompress(Data("not zstd at all".utf8)) }
        #expect(throws: ZstdError.self) { try Zstd.decompress(Data()) }
        #expect(throws: ZstdError.self) { try Zstd.decompress(Data([0x28, 0xB5, 0x2F, 0xFD])) }
    }

    @Test("Every truncation of a frame throws instead of trapping or returning short data")
    func truncations() throws {
        for name in ["hello-checksum", "json40k-l-5-fast", "random20k-raw", "json160k-l22-btultra2"] {
            let (compressed, _) = try fixture(name)
            let step = max(1, compressed.count / 300)
            var n = 0
            while n < compressed.count {
                let cut = compressed.prefix(n)
                #expect(throws: ZstdError.self, "\(name) cut at \(n)") { try Zstd.decompress(Data(cut)) }
                n += step
            }
        }
    }

    @Test("Random byte corruption never traps; checksummed frames never return wrong data")
    func bitFlips() throws {
        var rng = SystemRandomNumberGenerator()
        for name in ["json160k-l19-checksum", "json160k-l1-checksum", "mixed-text-l9"] {
            let (compressed, f) = try fixture(name)
            let checksummed = name.contains("checksum")
            for _ in 0..<150 {
                var bad = compressed
                let i = Int.random(in: 0..<bad.count, using: &rng)
                bad[i] ^= UInt8.random(in: 1...255, using: &rng)
                if let out = try? Zstd.decompress(bad), checksummed {
                    #expect(sha256Hex(out) == f.sha256, "\(name) flip at \(i) decoded to different bytes")
                }
            }
        }
    }

    @Test("Frame magic sniffing")
    func magic() throws {
        let (compressed, _) = try fixture("hello-checksum")
        #expect(Zstd.hasFrameMagic(compressed))
        #expect(!Zstd.hasFrameMagic(Data("{\"a\":1}".utf8)))
    }

    /// Broad differential check against libzstd: random inputs × random
    /// encoder settings, compressed by node and decoded here. Needs node ≥ 22
    /// with zlib zstd; opt in with BROMURE_ZSTD_NODE_FUZZ=1 (count via
    /// BROMURE_ZSTD_NODE_FUZZ_N, default 400).
    @Test("Differential fuzz against libzstd via node",
          .enabled(if: ProcessInfo.processInfo.environment["BROMURE_ZSTD_NODE_FUZZ"] == "1"))
    func nodeFuzz() throws {
        let n = Int(ProcessInfo.processInfo.environment["BROMURE_ZSTD_NODE_FUZZ_N"] ?? "") ?? 400
        let script = #"""
        const z = require('zlib'), crypto = require('crypto'), C = z.constants;
        const N = parseInt(process.argv[1] || '400');
        const words = ['the','model','"role":"user"','tool_result','{"type":"text","text":"','\n','    ','Margaret','4111 1111 1111 1111','ignore all previous instructions','}],','0123456789'];
        function gen() {
          const kind = crypto.randomInt(5), len = crypto.randomInt(crypto.randomInt(4) === 0 ? 400000 : 20000);
          if (kind === 0) return crypto.randomBytes(len);
          if (kind === 1) return Buffer.alloc(len, crypto.randomInt(256));
          const parts = []; let n = 0;
          while (n < len) {
            const r = crypto.randomInt(10);
            const s = r < 7 ? words[crypto.randomInt(words.length)] : r < 9 ? crypto.randomBytes(crypto.randomInt(1, 40)).toString(kind === 2 ? 'base64' : 'hex') : crypto.randomBytes(crypto.randomInt(1, 8)).toString('latin1');
            parts.push(s); n += s.length;
          }
          return Buffer.from(parts.join(kind === 4 ? '' : ' '), 'latin1').subarray(0, len);
        }
        for (let i = 0; i < N; i++) {
          const plain = gen();
          const params = { [C.ZSTD_c_compressionLevel]: crypto.randomInt(-7, 23),
                           [C.ZSTD_c_checksumFlag]: crypto.randomInt(2),
                           [C.ZSTD_c_contentSizeFlag]: crypto.randomInt(2) };
          if (crypto.randomInt(3) === 0) params[C.ZSTD_c_windowLog] = crypto.randomInt(10, 24);
          if (crypto.randomInt(4) === 0) params[C.ZSTD_c_strategy] = crypto.randomInt(1, 10);
          if (crypto.randomInt(6) === 0) params[C.ZSTD_c_enableLongDistanceMatching] = 1;
          const c = z.zstdCompressSync(plain, { params });
          process.stdout.write(c.toString('base64') + ' ' + crypto.createHash('sha256').update(plain).digest('hex') + ' ' + plain.length + ' ' + JSON.stringify(params) + '\n');
        }
        """#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", "-e", script, String(n)]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0, "node failed — needs node ≥ 22 with zlib zstd")
        var count = 0
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3).map(String.init)
            let c = try #require(Data(base64Encoded: f[0]))
            do {
                let plain = try Zstd.decompress(c)
                #expect(plain.count == Int(f[2]) && sha256Hex(plain) == f[1], "mismatch for \(f[3])")
            } catch {
                Issue.record("decode failed (\(error)) for \(f[3]) len \(f[2])")
            }
            count += 1
        }
        #expect(count == n)
    }
}

/// GK-1: zstd request bodies (Grok Build CLI) go through the content scans
/// and leave as identity; an undecodable body fails closed.
@Suite("MITM zstd request bodies")
struct MitmZstdRequestTests {

    private func zstdRequest(_ compressed: Data, host: String = "cli-chat-proxy.grok.com",
                             encoding: String = "zstd") -> Data {
        var head = "POST /v1/responses HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\n"
        head += "Content-Encoding: \(encoding)\r\nAccept-Encoding: zstd, gzip, br\r\n"
        head += "Content-Length: \(compressed.count)\r\n\r\n"
        return Data(head.utf8) + compressed
    }

    @Test("A zstd /v1/responses body is decoded to identity with a fresh Content-Length")
    func grokZstdDecoded() throws {
        let (compressed, f) = try fixture("json40k-l-5-fast")
        let raw = zstdRequest(compressed)
        guard case .decoded(let plain) = HTTPMitmConnection.decodeRequestContentEncoding(raw) else {
            Issue.record("zstd body not decoded"); return
        }
        let header = try #require(HTTPMitmConnection.rawHeaderSection(of: plain))
        #expect(HTTPMitmConnection.headerValue("content-encoding", inHeaderSection: header) == nil)
        #expect(HTTPMitmConnection.headerValue("content-length", inHeaderSection: header) == "\(f.length)")
        #expect(HTTPMitmConnection.headerValue("content-type", inHeaderSection: header) == "application/json")
        #expect(HTTPMitmConnection.parseRequestLine(plain).method == "POST")
        let sep = try #require(plain.range(of: Data("\r\n\r\n".utf8)))
        let body = plain.subdata(in: sep.upperBound..<plain.endIndex)
        #expect(sha256Hex(body) == f.sha256)
        // The decoded body is what the PII rewriter gates on.
        #expect(PIIRewriter.isEligible(host: "cli-chat-proxy.grok.com", method: "POST", body: body))
    }

    @Test("A large multi-block zstd body decodes too")
    func largeDecoded() throws {
        let (compressed, f) = try fixture("json160k-l22-btultra2")
        guard case .decoded(let plain) = HTTPMitmConnection.decodeRequestContentEncoding(
            zstdRequest(compressed, host: "api.x.ai")) else {
            Issue.record("zstd body not decoded"); return
        }
        let sep = try #require(plain.range(of: Data("\r\n\r\n".utf8)))
        #expect(sha256Hex(plain.subdata(in: sep.upperBound..<plain.endIndex)) == f.sha256)
    }

    @Test("Corrupt, truncated or dictionary zstd is undecodable (→ fail closed)")
    func undecodable() throws {
        let (compressed, _) = try fixture("json40k-l-5-fast")
        #expect(HTTPMitmConnection.decodeRequestContentEncoding(
            zstdRequest(compressed.prefix(compressed.count / 2))) == .undecodable("zstd"))
        let dict = Data([0x28, 0xB5, 0x2F, 0xFD, 0x21, 0x07, 0x00, 0x01, 0x00, 0x00])
        #expect(HTTPMitmConnection.decodeRequestContentEncoding(zstdRequest(dict)) == .undecodable("zstd"))
        #expect(HTTPMitmConnection.decodeRequestContentEncoding(
            zstdRequest(Data("abc".utf8), encoding: "compress")) == .undecodable("compress"))
    }

    @Test("The fail-closed reply is a 415 the agent can read, and it never says 200")
    func blockResponse() {
        let r = HTTPMitmConnection.undecodableBodyResponse(encoding: "zstd", engines: ["prompt_injection", "pii"])
        let s = String(decoding: r, as: UTF8.self)
        #expect(s.hasPrefix("HTTP/1.1 415 "))
        #expect(s.contains("X-Bromure-Blocked: undecodable-content-encoding"))
        #expect(s.contains("prompt-injection scanning and PII protection"))
        let sep = s.range(of: "\r\n\r\n")!
        let body = s[sep.upperBound...]
        #expect(s.contains("Content-Length: \(body.utf8.count)\r\n"))
    }

    @Test("Accept-Encoding keeps only codings the relay can undo")
    func acceptEncoding() {
        #expect(mitmSanitizedAcceptEncoding("zstd, gzip, br") == "gzip, br")
        #expect(mitmSanitizedAcceptEncoding("zstd") == nil)
        #expect(mitmSanitizedAcceptEncoding("gzip;q=1.0, zstd;q=0.9, *;q=0.1") == "gzip;q=1.0")
        #expect(mitmSanitizedAcceptEncoding("identity") == "identity")
        #expect(mitmSanitizedAcceptEncoding("ZSTD, Deflate") == "Deflate")
    }

    @Test("Blocked and skipped scans are distinct Timeline rows that count repeats")
    func timelineRows() {
        let pid = UUID()
        func event(_ action: String?) -> SecurityTimeline.Event? {
            var d: [String: AnyJSON] = [
                "host": .string("cli-chat-proxy.grok.com"), "path": .string("/v1/responses"),
                "reason": .string("zstd-compressed request body could not be decoded"),
                "engines": .array([.string("prompt_injection"), .string("pii")])]
            if let action { d["action"] = .string(action) }
            return SecurityTimeline.map(profileID: pid, eventType: "content_scan.skipped",
                                        eventData: d, now: Date())
        }
        let blocked = event("blocked")
        #expect(blocked?.kind == .blocked)
        #expect(blocked?.decision == "blocked, not sent — zstd-compressed request body could not be decoded")
        let skipped = event(nil)
        #expect(skipped?.kind == .info)
        #expect(blocked?.coalesceKey != nil && skipped?.coalesceKey != nil)
        #expect(blocked?.coalesceKey != skipped?.coalesceKey)

        var rows: [SecurityTimeline.Event] = []
        for _ in 0..<3 { if let e = event("blocked") { SecurityTimeline.coalesce(e, into: &rows) } }
        if let e = event(nil) { SecurityTimeline.coalesce(e, into: &rows) }
        #expect(rows.count == 2)
        #expect(rows.first?.repeats == 3)
    }
}
