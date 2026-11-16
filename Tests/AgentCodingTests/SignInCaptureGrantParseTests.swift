import Foundation
import Testing
@testable import bromure_ac

/// A sign-in capture tells the token exchange (kept on the host) from a
/// refresh (passed on) by the request's `grant_type`. It used to look for
/// the words anywhere in the body, so an authorization-code exchange with
/// `x=grant_type=refresh_token` tacked on skipped the capture -- and an
/// ended sign-in's refusal -- and the provider's real tokens reached the
/// guest. Finding: "OAuth token capture can be bypassed with an unrelated
/// form parameter" (CWE-200).
@Suite("Sign-in capture: what counts as a refresh")
struct SignInCaptureGrantParseTests {
    private let pid = UUID()
    private var capture: SignInCapture {
        SignInCapture(profileID: pid, hosts: ["auth.example.com"], pathPrefix: "/oauth/token", handle: { _, _ in nil })
    }
    private func exchange(_ body: String, path: String = "/oauth/token") -> Bool {
        capture.matches(host: "auth.example.com", method: "POST", path: path, body: Data(body.utf8))
    }

    @Test("real refreshes, form and JSON, still pass on")
    func refreshes() {
        #expect(!exchange("grant_type=refresh_token&refresh_token=rt%2Babc%3D&client_id=app"))
        #expect(!exchange("refresh_token=rt_abc&grant_type=refresh_token"))
        #expect(!exchange(#"{"grant_type":"refresh_token","refresh_token":"sk-ant-ort01-abc","client_id":"9d1c"}"#))
        #expect(!exchange(#"{ "grant_type" : "refresh_token", "refresh_token": "rt" }"#))
    }

    @Test("the reported bypass and its kin are exchanges")
    func bypasses() {
        let code = "grant_type=authorization_code&code=abc&redirect_uri=x"
        #expect(exchange(code))
        #expect(exchange(code + "&x=grant_type=refresh_token"))
        #expect(exchange(code + "&x=grant_type%3Drefresh_token"))
        #expect(exchange("x=grant_type%3Drefresh_token&code=abc&grant%5Ftype=authorization_code"))
        #expect(exchange("grant_type=refresh_token&grant%5Ftype=authorization_code&code=abc"))
        #expect(exchange("grant_type=refresh_token;grant_type=authorization_code"))
        #expect(exchange("grant_type=authorization_code&code=abc", path: "/oauth/token?grant_type=refresh_token"))
        #expect(exchange("grant_type=refresh_token", path: "/oauth/token?grant_type=authorization_code"))
        #expect(exchange("grant_type=refresh_token&x=GRANT_TYPE"))
        #expect(exchange("grant_type=Refresh_Token&code=abc"))
        // JSON: the top-level grant only; nothing escaped, encoded or repeated.
        #expect(exchange(#"{"grant_type":"authorization_code","code":"abc","x":"grant_type=refresh_token"}"#))
        #expect(exchange(#"{"x":{"grant_type":"refresh_token"},"code":"abc"}"#))
        #expect(exchange(#"{"grant_type":"refresh_token","grant_type":"authorization_code","code":"abc"}"#))
        #expect(exchange(#"{"grant_type":"authorization_code","grant_type":"refresh_token"}"#))
        #expect(exchange(#"{"grant_type":"refresh_token","x":"&grant%5Ftype=authorization_code&code=abc"}"#))
        // Neither a form nor JSON, or not text: not plainly a refresh.
        #expect(exchange("--b\r\nContent-Disposition: form-data; name=\"grant_type\"\r\n\r\nrefresh_token\r\n--b--"))
        #expect(capture.matches(host: "auth.example.com", method: "POST", path: "/oauth/token",
                                body: Data([0xFF, 0xFE]) + Data("&grant_type=refresh_token".utf8)))
        #expect(exchange(""))
    }

    @Test("an ended sign-in refuses the bypass too")
    func spentRefuses() {
        let spent = SignInCapture.spentMarker(profileID: pid, hosts: ["auth.example.com"], pathPrefix: "/oauth/token")
        let body = Data("grant_type=authorization_code&code=abc&x=grant_type=refresh_token".utf8)
        #expect(spent.refusesExchange(host: "auth.example.com", method: "POST", path: "/oauth/token", body: body))
        #expect(!spent.refusesExchange(host: "auth.example.com", method: "POST", path: "/oauth/token",
                                       body: Data("grant_type=refresh_token&refresh_token=rt".utf8)))
    }
}
