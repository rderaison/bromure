import Foundation
import Testing
@testable import bromure_ac

/// H2: a guest-relayed URL may only reach the user's REAL browser when its host
/// is public. Loopback / private / link-local / ULA / `.local` hosts are
/// refused, so a compromised guest can't drive the host browser into local
/// services (which it would fetch with the user's cookies/session).
@Suite("Guest URL → real browser host guard (H2)")
struct GuestBrowserHostGuardTests {

    @Test("Local and private hosts are refused")
    func localRefused() {
        for h in ["127.0.0.1", "127.1.2.3", "0.0.0.0", "10.0.0.5", "10.255.255.255",
                  "172.16.0.1", "172.20.5.5", "172.31.255.255",
                  "192.168.1.1", "169.254.10.10", "100.64.0.1", "100.127.255.255",
                  "localhost", "foo.localhost", "printer.local", "local",
                  "[::1]", "[::]", "[fe80::1]", "[fc00::1]", "[fd12:3456::1]"] {
            #expect(ACAppDelegate.hostIsLocalOrPrivate(h), "should be local/private: \(h)")
            let url = URL(string: "http://\(h)/x")!
            #expect(!ACAppDelegate.opensInRealBrowser(url), "should NOT open: \(h)")
        }
    }

    @Test("Public hosts are allowed")
    func publicAllowed() {
        for h in ["accounts.google.com", "github.com", "login.microsoftonline.com",
                  "x.ai", "8.8.8.8", "1.1.1.1", "93.184.216.34",
                  "172.15.0.1", "172.32.0.1", "192.169.0.1", "100.63.0.1", "100.128.0.1",
                  "[2606:4700::1111]"] {
            #expect(!ACAppDelegate.hostIsLocalOrPrivate(h), "should be public: \(h)")
        }
        #expect(ACAppDelegate.opensInRealBrowser(URL(string: "https://accounts.google.com/o/oauth2/auth?x=1")!))
        // A real OAuth authorize URL (public host, loopback redirect in the
        // query) still opens — the redirect target is not the URL's own host.
        #expect(ACAppDelegate.opensInRealBrowser(
            URL(string: "https://accounts.google.com/o/oauth2/auth?redirect_uri=http://127.0.0.1:8765/cb")!))
    }

    @Test("A URL with no host never opens")
    func noHost() {
        #expect(!ACAppDelegate.opensInRealBrowser(URL(string: "mailto:a@b.com")!))
        #expect(!ACAppDelegate.opensInRealBrowser(URL(string: "file:///etc/passwd")!))
    }
}
