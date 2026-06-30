import Foundation
import Testing
@testable import bromure_ac

/// Coverage for the npm-registry metadata age-gate
/// (`NPMRegistryTransforms.filterMetadata`) and the tarball
/// script-strip entry point (`stripScriptsFromTarball`). These are
/// pure, I/O-free byte transforms over a captured HTTP response, so
/// they're fully deterministic from a crafted in-memory response.
@Suite("npm registry transforms")
struct NPMRegistryTransformsTests {

    // MARK: - helpers

    /// Wrap a JSON object body in a minimal HTTP/1.1 200 response.
    private func httpResponse(json: [String: Any]) -> Data {
        let body = try! JSONSerialization.data(withJSONObject: json)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    /// Split the HTTP response the transform produced and parse the
    /// JSON body back into a dictionary.
    private func parseBody(_ resp: Data) -> [String: Any]? {
        guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let body = resp.subdata(in: sep.upperBound..<resp.count)
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// A two-version manifest: 1.0.0 (old, 2020) and 2.0.0 (fresh,
    /// 2025). `latest` points at the fresh one.
    private func manifest() -> [String: Any] {
        return [
            "name": "demo",
            "dist-tags": ["latest": "2.0.0"],
            "versions": [
                "1.0.0": ["name": "demo", "version": "1.0.0",
                          "dist": ["integrity": "sha512-OLD",
                                   "shasum": "oldshasum",
                                   "tarball": "https://registry.npmjs.org/demo/-/demo-1.0.0.tgz"]],
                "2.0.0": ["name": "demo", "version": "2.0.0",
                          "dist": ["integrity": "sha512-NEW",
                                   "shasum": "newshasum",
                                   "tarball": "https://registry.npmjs.org/demo/-/demo-2.0.0.tgz"]],
            ],
            "time": [
                "created": "2020-01-01T00:00:00.000Z",
                "modified": "2025-06-01T00:00:00.000Z",
                "1.0.0": "2020-01-01T00:00:00.000Z",
                "2.0.0": "2025-06-01T00:00:00.000Z",
            ],
        ]
    }

    /// Cutoff between the two versions: 2020 survives, 2025 is dropped.
    private var cutoff: Date {
        ISO8601DateFormatter().date(from: "2023-01-01T00:00:00Z")!
    }

    // MARK: - age gate

    @Test("Too-fresh version is dropped from versions{} and time{}")
    func dropsFreshVersion() {
        var times: [(String, Date)] = []
        let out = NPMRegistryTransforms.filterMetadata(
            rawResponse: httpResponse(json: manifest()),
            packageName: "demo", allowedAfter: cutoff,
            allowlistedPackage: false, stripIntegrity: false,
            publishTimes: &times)
        let body = parseBody(out)!
        let versions = body["versions"] as! [String: Any]
        #expect(versions["1.0.0"] != nil)
        #expect(versions["2.0.0"] == nil)
        let time = body["time"] as! [String: String]
        #expect(time["1.0.0"] != nil)
        #expect(time["2.0.0"] == nil)
        // `created` / `modified` housekeeping keys survive.
        #expect(time["created"] != nil)
    }

    @Test("dist-tags pointing at a dropped version are re-aimed at newest survivor")
    func rewritesDistTags() {
        var times: [(String, Date)] = []
        let out = NPMRegistryTransforms.filterMetadata(
            rawResponse: httpResponse(json: manifest()),
            packageName: "demo", allowedAfter: cutoff,
            allowlistedPackage: false, stripIntegrity: false,
            publishTimes: &times)
        let body = parseBody(out)!
        let tags = body["dist-tags"] as! [String: String]
        #expect(tags["latest"] == "1.0.0")
    }

    @Test("Every per-version publish time is recorded into publishTimes")
    func recordsPublishTimes() {
        var times: [(String, Date)] = []
        _ = NPMRegistryTransforms.filterMetadata(
            rawResponse: httpResponse(json: manifest()),
            packageName: "demo", allowedAfter: cutoff,
            allowlistedPackage: false, stripIntegrity: false,
            publishTimes: &times)
        // Both versions recorded (created/modified are skipped).
        let recorded = Set(times.map { $0.0 })
        #expect(recorded == ["1.0.0", "2.0.0"])
        #expect(times.count == 2)
    }

    @Test("stripIntegrity removes dist.integrity / dist.shasum on survivors")
    func stripsIntegrity() {
        var times: [(String, Date)] = []
        let out = NPMRegistryTransforms.filterMetadata(
            rawResponse: httpResponse(json: manifest()),
            packageName: "demo", allowedAfter: cutoff,
            allowlistedPackage: false, stripIntegrity: true,
            publishTimes: &times)
        let body = parseBody(out)!
        let versions = body["versions"] as! [String: Any]
        let v1 = versions["1.0.0"] as! [String: Any]
        let dist = v1["dist"] as! [String: Any]
        #expect(dist["integrity"] == nil)
        #expect(dist["shasum"] == nil)
        // tarball URL is preserved — only the hashes are scrubbed.
        #expect(dist["tarball"] != nil)
    }

    @Test("Allowlisted package without stripIntegrity is forwarded byte-for-byte")
    func allowlistedPassthrough() {
        var times: [(String, Date)] = []
        let input = httpResponse(json: manifest())
        let out = NPMRegistryTransforms.filterMetadata(
            rawResponse: input,
            packageName: "demo", allowedAfter: cutoff,
            allowlistedPackage: true, stripIntegrity: false,
            publishTimes: &times)
        #expect(out == input)
    }

    @Test("Allowlisted package keeps all versions but still strips integrity when asked")
    func allowlistedNoAgeFilterButStrips() {
        var times: [(String, Date)] = []
        let out = NPMRegistryTransforms.filterMetadata(
            rawResponse: httpResponse(json: manifest()),
            packageName: "demo", allowedAfter: cutoff,
            allowlistedPackage: true, stripIntegrity: true,
            publishTimes: &times)
        let body = parseBody(out)!
        let versions = body["versions"] as! [String: Any]
        // No age filtering: the fresh 2.0.0 survives.
        #expect(versions["2.0.0"] != nil)
        #expect(versions["1.0.0"] != nil)
        // But integrity is gone everywhere.
        let v2 = versions["2.0.0"] as! [String: Any]
        let dist = v2["dist"] as! [String: Any]
        #expect(dist["integrity"] == nil)
    }

    @Test("Non-HTTP / unparseable input is returned unchanged")
    func malformedPassthrough() {
        var times: [(String, Date)] = []
        let garbage = Data("not an http response at all".utf8)
        let out = NPMRegistryTransforms.filterMetadata(
            rawResponse: garbage,
            packageName: "demo", allowedAfter: cutoff,
            allowlistedPackage: false, stripIntegrity: false,
            publishTimes: &times)
        #expect(out == garbage)
    }

    @Test("Everything-fresh manifest drops every version when nothing is allowlisted")
    func dropsAllWhenAllFresh() {
        var times: [(String, Date)] = []
        // Cutoff in 1990 — both 2020 and 2025 are "too fresh".
        let ancient = ISO8601DateFormatter().date(from: "1990-01-01T00:00:00Z")!
        let out = NPMRegistryTransforms.filterMetadata(
            rawResponse: httpResponse(json: manifest()),
            packageName: "demo", allowedAfter: ancient,
            allowlistedPackage: false, stripIntegrity: false,
            publishTimes: &times)
        let body = parseBody(out)!
        let versions = body["versions"] as! [String: Any]
        #expect(versions.isEmpty)
    }

    // MARK: - tarball strip (simpler entry point)

    @Test("stripScriptsFromTarball falls back cleanly on a non-gzip body")
    func tarballNonGzipFallthrough() {
        // Body isn't a gzip stream → gunzip fails → original response,
        // didStrip == false. Supply-chain transforms must never brick a
        // download they can't parse.
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
        head += "Content-Length: 5\r\n\r\n"
        var resp = Data(head.utf8)
        resp.append(contentsOf: [0x00, 0x01, 0x02, 0x03, 0x04])
        let (out, didStrip) = NPMRegistryTransforms.stripScriptsFromTarball(rawResponse: resp)
        #expect(didStrip == false)
        #expect(out == resp)
    }

    @Test("stripScriptsFromTarball returns original on a non-HTTP buffer")
    func tarballMalformed() {
        let garbage = Data([0x1f, 0x8b, 0x08])   // gzip magic but no HTTP head
        let (out, didStrip) = NPMRegistryTransforms.stripScriptsFromTarball(rawResponse: garbage)
        #expect(didStrip == false)
        #expect(out == garbage)
    }

    @Test("tagInspected injects the rewrite marker without touching the body")
    func tagInspectedKeepsBody() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n"
        var resp = Data(head.utf8)
        let bodyBytes: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
        resp.append(contentsOf: bodyBytes)
        let out = NPMRegistryTransforms.tagInspected(rawResponse: resp)
        let sep = out.range(of: Data("\r\n\r\n".utf8))!
        let outHead = String(data: out.subdata(in: 0..<sep.lowerBound), encoding: .utf8)!
        let outBody = out.subdata(in: sep.upperBound..<out.count)
        #expect(outHead.contains("X-Bromure-Rewritten: supply-chain"))
        #expect(Array(outBody) == bodyBytes)
    }
}
