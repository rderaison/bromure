import Foundation
import SandboxEngine

// MARK: - The Agentic Coding prebuilt-image channel
//
// The catalog model, signature verification, fetch/cache store, and
// download plumbing live in SandboxEngine (shared with Bromure Web's
// browser-image channel — see Sources/SandboxEngine/ImageCatalog.swift).
// This file binds them to the AC channel: the `images/` CDN prefix, the
// AC signing-payload magic, and the bundled baseline resource
// (Sources/AgentCoding/Resources/img-catalog.json, the canonical source
// of the AC postinstall list).

extension ImageDistribution {
    /// The Bromure Agentic Coding Ubuntu image (single EFI-bootable disk
    /// artifact under https://dl.bromure.io/images/<major>/).
    ///
    /// One catalog per image major, at `images/<major>/img-catalog.json`
    /// (scripts/publish-image.sh derives the same path from the version
    /// it just built): an app only ever sees images of the major it was
    /// built for, so a newer major — which may need the newer app, as
    /// 201 (baked agent unit) does — can't be offered to an older app.
    /// Apps before 5.0.0 read the unversioned `images/img-catalog.json`,
    /// which stays frozen at the last 200.x publish.
    ///
    /// `signingMagic` predates the multi-channel split — it MUST stay
    /// "bromure-img-catalog-v1" so already-published AC catalogs keep
    /// verifying; the browser channel uses its own magic so a validly
    /// signed catalog can never be replayed across channels.
    public static let agentCoding = ImageDistribution(
        catalogPrefix: "images/\(UbuntuImageManager.imageVersion)",
        signingMagic: "bromure-img-catalog-v1",
        cacheFileName: "img-catalog.json",
        defaultSupportDirName: "BromureAC",
        loadBaseline: {
            ImageCatalog.loadBaseline(bundle: acResourceBundle, resource: "img-catalog")
        }
    )
}

extension ImageCatalogStore {
    /// The AC-channel store — same role (and name) as before the shared
    /// refactor, so call sites and the `downloadBaseImage` default
    /// parameter read unchanged.
    public static let shared = ImageCatalogStore(distribution: .agentCoding)
}

extension ImageCatalog {
    /// The shipped AC baseline — the bundled `img-catalog.json` resource,
    /// the same file `scripts/publish-image.sh` reads the postinstall
    /// list from, so shipped baseline and published manifest can never
    /// drift. Its `image` is null: with no network there is nothing to
    /// download (the local build path is the fallback), but the
    /// postinstall list still applies.
    public static let baseline: ImageCatalog = ImageDistribution.agentCoding.loadBaseline()
}
