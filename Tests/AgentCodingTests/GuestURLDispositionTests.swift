import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-918): "Guest URL gate permits private-network browser
/// requests through DNS names and redirects". The gate read only the URL's
/// spelling and let every public-looking name through, and the host opened
/// it unasked: a guest's `http://rebind.attacker.example/` resolving to
/// 127.0.0.1 or the LAN, or a public page redirecting to 192.168.1.1, sent
/// the user's browser there. Now only an agent's own sign-in page opens by
/// itself; any other public page waits for the user.
@Suite("Guest URLs: sign-in pages open, other pages ask, local ones never")
struct GuestURLDispositionTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    private static func d(_ s: String) -> GuestURLGate.Disposition {
        GuestURLGate.disposition(for: URL(string: s)!)
    }

    @Test("an agent's sign-in page opens without asking")
    func signInPagesOpen() {
        let id = AgentScreen.claudeClientID
        for s in ["https://claude.ai/oauth/authorize?client_id=\(id)&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback",
                  "https://claude.com/cai/oauth/authorize?code=true&client_id=\(id)"
                    + "&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=s",
                  "https://auth.openai.com/codex/device",
                  "https://accounts.x.ai/oauth2/device?user_code=QZQD-KPB5",
                  "https://auth.kimi.ai/device"] {
            #expect(Self.d(s) == .open, "\(s)")
        }
    }

    @Test("any other public page asks: a name can resolve to the LAN, a page redirect there")
    func otherPagesAsk() {
        let id = AgentScreen.claudeClientID
        for s in ["http://rebind.attacker.example/admin/reboot",            // resolves to 127.0.0.1 / 192.168.x
                  "https://public.example/r?to=http%3A%2F%2F192.168.1.1%2F",  // redirects to the LAN
                  "https://github.com/rderaison/bromure",                      // an ordinary link
                  "https://8.8.8.8/",
                  // Look-alikes of a sign-in page.
                  "https://claude.ai.evil.example/oauth/authorize?client_id=\(id)",
                  "http://claude.ai/oauth/authorize?client_id=\(id)&redirect_uri=http%3A%2F%2Flocalhost%3A1%2F",
                  "https://claude.ai/oauth/authorize?client_id=\(id)&redirect_uri=https%3A%2F%2Fattacker.example%2Fcb",
                  "https://claude.ai/oauth/authorize?client_id=attacker&redirect_uri=http%3A%2F%2Flocalhost%3A1%2F"] {
            #expect(Self.d(s) == .ask, "\(s)")
        }
    }

    @Test("a local or private host never opens, asked or not")
    func localRefused() {
        for s in ["http://127.0.0.1:8080/", "http://localhost/", "http://192.168.1.1/", "http://[::1]/",
                  "http://printer.local/", "http://0x7f000001/", "mailto:a@b.com", "file:///etc/passwd"] {
            #expect(Self.d(s) == .refuse, "\(s)")
        }
    }

    @Test("every guest-URL hand-off goes through the disposition")
    func handOffsUseIt() throws {
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let fn = try #require(ac.range(of: "static func openGuestRelayedURL(_ url: URL, workspace: String? = nil) {"))
        let body = ac[fn.upperBound...].prefix(700)
        #expect(body.contains("switch GuestURLGate.disposition(for: url) {"))
        #expect(body.contains("case .ask:\n            askBeforeOpeningGuestURL(url, workspace: workspace)"))
        // The fat client (Mac and iOS) opens a published sign-in URL only when
        // it is one: no ask there, the VM terminal still shows the URL.
        let fc = try Self.src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains("GuestURLGate.disposition(for: url) != .open {"))
        #expect(fc.contains("guard GuestURLGate.disposition(for: url) == .open else { return }"))
        #expect(!fc.contains("GuestURLGate.opensInRealBrowser(url)"))
    }

    @Test("the prompt is in every locale")
    func localized() throws {
        for loc in ["en", "fr", "de", "es", "pt", "ja", "zh-Hans", "zh-Hant"] {
            let s = try Self.src("Sources/AgentCoding/\(loc).lproj/Localizable.strings")
            for key in ["Open a Page from the Workspace?", "Open in Browser",
                        "Something in “%1$@” wants to open this page in your browser:",
                        "Something in a workspace wants to open this page in your browser:"] {
                #expect(s.contains("\n\"\(key)"), "\(loc): \(key)")
            }
        }
    }
}
