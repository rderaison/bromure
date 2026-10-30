// swift-tools-version: 6.0
import PackageDescription

// Phase 4 spike: TLS interception on swift-nio-ssl + swift-certificates.
// MitmCore: CA, per-SNI leaf minting (LRU), CONNECT handling, TLS
// termination with ALPN, upstream re-origination with system trust, relay.
// mitm-proxy: the proxy. mitm-bench: local upstream + load generator.
let package = Package(
    name: "MitmSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
    ],
    targets: [
        .target(name: "MitmCore", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .executableTarget(name: "mitm-proxy", dependencies: ["MitmCore"]),
        .executableTarget(name: "mitm-bench", dependencies: [
            "MitmCore",
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ],
    // A spike: Swift 5 mode keeps the NIO handler plumbing short.
    swiftLanguageModes: [.v5]
)
