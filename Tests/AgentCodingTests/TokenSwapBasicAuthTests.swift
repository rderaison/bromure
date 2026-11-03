import Foundation
import Testing
@testable import bromure_ac

/// Issue #49: `curl -u "$MY_USER:$MY_PASS"` sent the fake (`brm_…`) to the
/// site: the swap looked for the fake as-is in the headers, and HTTP Basic
/// carries it base64-encoded. Basic credentials are now decoded, swapped
/// and re-encoded — and scanned for leaks like any other header.
@Suite("Token swap — HTTP Basic credentials")
struct TokenSwapBasicAuthTests {
    private let fake = "brm_QH7VL7o31Ot21HTiy4suVYROTVsJInHi"
    private let real = "Secret01"

    private func request(_ auth: String, host: String = "postman-echo.com") -> Data {
        Data(("GET /get HTTP/1.1\r\nHost: \(host)\r\n\(auth)\r\nAccept: */*\r\n\r\n").utf8)
    }

    private func basic(_ creds: String) -> String { Data(creds.utf8).base64EncodedString() }

    private func swapper(_ pid: UUID, host: String? = nil) -> TokenSwapper {
        let s = TokenSwapper(consent: ConsentBroker())
        s.setMap(TokenMap(entries: [.init(fake: fake, real: real, host: host)]), for: pid)
        return s
    }

    private func authHeader(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("authorization:") }
    }

    @Test("curl -u user:$SECRET reaches the site with the real secret")
    func basicPasswordSwapped() async {
        let pid = UUID()
        let out = await swapper(pid).swap(
            rawRequest: request("Authorization: Basic \(basic("User01:\(fake)"))"),
            host: "postman-echo.com", profileID: pid)
        #expect(out.swaps.count == 1)
        #expect(authHeader(out.modified) == "Authorization: Basic \(basic("User01:Secret01"))")
        #expect(String(decoding: out.modified, as: UTF8.self).hasSuffix("Accept: */*\r\n\r\n"))
    }

    @Test("the user name, unpadded base64 and Proxy-Authorization are covered; other headers untouched")
    func variants() async {
        let pid = UUID()
        let s = swapper(pid)
        let user = await s.swap(rawRequest: request("authorization: basic \(basic("\(fake):x"))"),
                                host: "h.example", profileID: pid)
        #expect(authHeader(user.modified) == "authorization: basic \(basic("Secret01:x"))")

        let unpadded = basic("u:\(fake)").replacingOccurrences(of: "=", with: "")
        let p = await s.swap(rawRequest: request("Proxy-Authorization: Basic \(unpadded)"),
                             host: "h.example", profileID: pid)
        #expect(String(decoding: p.modified, as: UTF8.self)
            .contains("Proxy-Authorization: Basic \(basic("u:Secret01"))"))

        let cookie = "Cookie: v=\(basic("u:\(fake)"))"
        let other = await s.swap(rawRequest: request(cookie), host: "h.example", profileID: pid)
        #expect(other.swaps.isEmpty)
    }

    @Test("a scoped secret is swapped only on its host, and flagged inside Basic elsewhere")
    func scopeAndLeak() async {
        let pid = UUID()
        let s = swapper(pid, host: "postman-echo.com")
        let req = request("Authorization: Basic \(basic("User01:\(fake)"))", host: "evil.example")
        let out = await s.swap(rawRequest: req, host: "evil.example", profileID: pid)
        #expect(out.swaps.isEmpty)
        #expect(s.detectCompromise(rawRequest: req, host: "evil.example", profileID: pid).count == 1)
        #expect(s.detectCompromise(rawRequest: req, host: "postman-echo.com", profileID: pid).isEmpty)
    }
}
