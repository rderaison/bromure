import Foundation
import Testing
@testable import bromure_ac

/// `SupplyChainRegistry.classify(host:path:)` maps an intercepted
/// (host, path) onto a `RequestKind` — metadata vs. artifact vs.
/// passthrough — per ecosystem, and returns nil for hosts that aren't
/// a recognised package registry. All pure string parsing.
@Suite("Supply-chain registry classification")
struct SupplyChainEnforcerTests {

    private typealias Kind = SupplyChainEnforcer.RequestKind

    /// Assert a classification is `.metadata` for the given ecosystem
    /// + package name.
    private func expectMetadata(_ kind: Kind?,
                                _ eco: SupplyChainEnforcer.Ecosystem,
                                _ pkg: String,
                                _ comment: Comment) {
        guard case let .metadata(ecosystem, packageName)? = kind else {
            Issue.record("expected .metadata, got \(String(describing: kind)) — \(comment)")
            return
        }
        #expect(ecosystem == eco)
        #expect(packageName == pkg)
    }

    private func expectArtifact(_ kind: Kind?,
                                _ eco: SupplyChainEnforcer.Ecosystem,
                                _ pkg: String, _ version: String,
                                _ comment: Comment) {
        guard case let .artifact(ecosystem, packageName, ver)? = kind else {
            Issue.record("expected .artifact, got \(String(describing: kind)) — \(comment)")
            return
        }
        #expect(ecosystem == eco)
        #expect(packageName == pkg)
        #expect(ver == version)
    }

    // MARK: - unknown / non-registry hosts

    @Test("Unknown host returns nil")
    func unknownHost() {
        #expect(SupplyChainRegistry.classify(host: "example.com", path: "/foo") == nil)
        #expect(SupplyChainRegistry.classify(host: "github.com", path: "/a/b") == nil)
        #expect(SupplyChainRegistry.classify(host: "api.anthropic.com", path: "/v1/messages") == nil)
    }

    // MARK: - npm

    @Test("npm unscoped metadata")
    func npmMetadata() {
        expectMetadata(SupplyChainRegistry.classify(host: "registry.npmjs.org", path: "/express"),
                       .npm, "express", "bare unscoped manifest")
    }

    @Test("npm %2f-encoded scoped metadata is decoded and classified (the recent fix)")
    func npmScopedEncodedMetadata() {
        // npm requests scoped-package metadata with the slash percent-
        // encoded. Both lowercase %2f and uppercase %2F must decode.
        expectMetadata(SupplyChainRegistry.classify(host: "registry.npmjs.org", path: "/@babel%2fcore"),
                       .npm, "@babel/core", "lowercase %2f")
        expectMetadata(SupplyChainRegistry.classify(host: "registry.npmjs.org", path: "/@babel%2Fcore"),
                       .npm, "@babel/core", "uppercase %2F")
    }

    @Test("npm scoped metadata with a real slash also classifies")
    func npmScopedSlashMetadata() {
        expectMetadata(SupplyChainRegistry.classify(host: "registry.npmjs.org", path: "/@babel/core"),
                       .npm, "@babel/core", "literal-slash scoped manifest")
    }

    @Test("npm unscoped artifact")
    func npmArtifact() {
        expectArtifact(SupplyChainRegistry.classify(host: "registry.npmjs.org",
                                                    path: "/express/-/express-4.18.2.tgz"),
                       .npm, "express", "4.18.2", "tgz artifact")
    }

    @Test("npm scoped artifact")
    func npmScopedArtifact() {
        expectArtifact(SupplyChainRegistry.classify(host: "registry.npmjs.org",
                                                    path: "/@babel/core/-/core-7.23.0.tgz"),
                       .npm, "@babel/core", "7.23.0", "scoped tgz artifact")
    }

    @Test("npm subdomain (suffix) still recognised")
    func npmSubdomain() {
        let kind = SupplyChainRegistry.classify(host: "registry.yarnpkg.npmjs.org", path: "/lodash")
        expectMetadata(kind, .npm, "lodash", ".npmjs.org suffix match")
    }

    // MARK: - PyPI

    @Test("PyPI JSON-API metadata")
    func pypiJSON() {
        expectMetadata(SupplyChainRegistry.classify(host: "pypi.org", path: "/pypi/requests/json"),
                       .pypi, "requests", "JSON API")
    }

    @Test("PyPI simple-index metadata")
    func pypiSimple() {
        expectMetadata(SupplyChainRegistry.classify(host: "pypi.org", path: "/simple/requests/"),
                       .pypi, "requests", "simple index")
    }

    @Test("PyPI sdist artifact from files.pythonhosted.org")
    func pypiSdist() {
        expectArtifact(SupplyChainRegistry.classify(host: "files.pythonhosted.org",
                                                    path: "/packages/aa/bb/requests-2.31.0.tar.gz"),
                       .pypi, "requests", "2.31.0", "sdist tarball")
    }

    @Test("PyPI wheel artifact parses dist + version")
    func pypiWheel() {
        expectArtifact(SupplyChainRegistry.classify(host: "files.pythonhosted.org",
                                                    path: "/packages/aa/bb/numpy-1.26.0-cp311-cp311-macosx.whl"),
                       .pypi, "numpy", "1.26.0", "wheel")
    }

    // MARK: - Cargo

    @Test("Cargo sparse-index metadata")
    func cargoSparse() {
        expectMetadata(SupplyChainRegistry.classify(host: "index.crates.io", path: "/se/rd/serde"),
                       .cargo, "serde", "sparse index")
    }

    @Test("Cargo API metadata")
    func cargoAPI() {
        expectMetadata(SupplyChainRegistry.classify(host: "crates.io", path: "/api/v1/crates/serde"),
                       .cargo, "serde", "crates.io API")
    }

    @Test("Cargo download artifact")
    func cargoArtifact() {
        expectArtifact(SupplyChainRegistry.classify(host: "crates.io",
                                                    path: "/api/v1/crates/serde/1.0.0/download"),
                       .cargo, "serde", "1.0.0", "download")
    }

    // MARK: - RubyGems

    @Test("RubyGems metadata")
    func rubygemsMetadata() {
        expectMetadata(SupplyChainRegistry.classify(host: "rubygems.org",
                                                    path: "/api/v1/versions/rails.json"),
                       .rubygems, "rails", "versions API")
    }

    @Test("RubyGems gem artifact")
    func rubygemsArtifact() {
        expectArtifact(SupplyChainRegistry.classify(host: "rubygems.org",
                                                    path: "/gems/rails-7.1.0.gem"),
                       .rubygems, "rails", "7.1.0", "gem file")
    }

    // MARK: - Maven

    @Test("Maven metadata maps group:artifact")
    func mavenMetadata() {
        expectMetadata(SupplyChainRegistry.classify(host: "repo1.maven.org",
                                                    path: "/maven2/com/google/guava/guava/maven-metadata.xml"),
                       .maven, "com.google.guava:guava", "maven-metadata.xml")
    }

    @Test("Maven artifact maps group:artifact + version")
    func mavenArtifact() {
        expectArtifact(SupplyChainRegistry.classify(host: "repo1.maven.org",
                                                    path: "/maven2/com/google/guava/guava/32.0/guava-32.0.jar"),
                       .maven, "com.google.guava:guava", "32.0", "jar artifact")
    }

    // MARK: - NuGet

    @Test("NuGet flatcontainer index metadata")
    func nugetMetadata() {
        expectMetadata(SupplyChainRegistry.classify(host: "api.nuget.org",
                                                    path: "/v3-flatcontainer/newtonsoft.json/index.json"),
                       .nuget, "newtonsoft.json", "flatcontainer index")
    }

    @Test("NuGet nupkg artifact")
    func nugetArtifact() {
        expectArtifact(SupplyChainRegistry.classify(host: "api.nuget.org",
                                                    path: "/v3-flatcontainer/newtonsoft.json/13.0.1/newtonsoft.json.13.0.1.nupkg"),
                       .nuget, "newtonsoft.json", "13.0.1", "nupkg")
    }

    // MARK: - Go modules

    @Test("Go @v/list metadata")
    func goList() {
        expectMetadata(SupplyChainRegistry.classify(host: "proxy.golang.org",
                                                    path: "/github.com/pkg/errors/@v/list"),
                       .goModules, "github.com/pkg/errors", "version list")
    }

    @Test("Go @v/<ver>.info metadata")
    func goInfo() {
        expectMetadata(SupplyChainRegistry.classify(host: "proxy.golang.org",
                                                    path: "/github.com/pkg/errors/@v/v0.9.1.info"),
                       .goModules, "github.com/pkg/errors", ".info")
    }

    @Test("Go @v/<ver>.zip artifact")
    func goZip() {
        expectArtifact(SupplyChainRegistry.classify(host: "proxy.golang.org",
                                                    path: "/github.com/pkg/errors/@v/v0.9.1.zip"),
                       .goModules, "github.com/pkg/errors", "v0.9.1", "module zip")
    }

    // MARK: - Packagist

    @Test("Packagist p2 metadata maps vendor/package")
    func packagist() {
        expectMetadata(SupplyChainRegistry.classify(host: "repo.packagist.org",
                                                    path: "/p2/monolog/monolog.json"),
                       .packagist, "monolog/monolog", "p2 metadata")
    }

    @Test("Packagist ~dev branch metadata strips the suffix")
    func packagistDev() {
        expectMetadata(SupplyChainRegistry.classify(host: "packagist.org",
                                                    path: "/p2/monolog/monolog~dev.json"),
                       .packagist, "monolog/monolog", "~dev branch")
    }

    // MARK: - passthrough

    @Test("Recognised host but unrecognised path is passthrough, not nil")
    func passthrough() {
        let kind = SupplyChainRegistry.classify(host: "registry.npmjs.org", path: "/-/v1/search?text=foo")
        guard case .passthrough? = kind else {
            Issue.record("expected .passthrough, got \(String(describing: kind))")
            return
        }
    }

    @Test("Query strings are stripped before classification")
    func stripsQuery() {
        expectMetadata(SupplyChainRegistry.classify(host: "pypi.org", path: "/pypi/requests/json?foo=bar"),
                       .pypi, "requests", "query suffix ignored")
    }
}
