import Foundation
import Testing
@testable import bromure_ac

/// Issue #47: a `.tgz` served with `Content-Encoding: gzip` (Helm charts on
/// GitHub Pages) reached the guest still gzipped — URLSession left the body
/// encoded for that path and Content-Type, and the proxy's head dropped the
/// Content-Encoding. The proxy now asks for such files as they are.
@Suite("Proxy: already-compressed downloads")
struct MitmCompressedArchiveTests {
    @Test("a .gz or .tgz is fetched as identity; anything else keeps its codings")
    func identityForArchives() {
        func u(_ s: String) -> URL { URL(string: s)! }
        #expect(mitmFetchesIdentity(u("https://helm.cilium.io/cilium-1.20.2.tgz")))
        #expect(mitmFetchesIdentity(u("https://example.com/pkg/a.tar.gz?x=1")))
        #expect(mitmFetchesIdentity(u("https://example.com/A.TGZ")))
        #expect(mitmFetchesIdentity(u("https://example.com/dump.json.gz")))
        #expect(!mitmFetchesIdentity(u("https://helm.cilium.io/index.yaml")))
        #expect(!mitmFetchesIdentity(u("https://example.com/gz")))
        #expect(!mitmFetchesIdentity(u("https://example.com/a.tgz/files")))
        #expect(!mitmFetchesIdentity(u("https://example.com/?f=a.tgz")))
    }
}
