// swift-tools-version: 6.0
import PackageDescription

// ACLinux: the Linux implementations behind Bromure AC's platform protocols
// (Firecracker/KVM VMs, hybrid vsock, guest CIDs). A package of its own until the
// ACCore carve-out lands, so the root package stays untouched. Linux-only.
let package = Package(
    name: "ACLinux",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ACLinux", targets: ["ACLinux"]),
        .executable(name: "bromure-ac", targets: ["bromure-ac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // The shared SSH server (Sources/AgentCoding/RemoteAccessServer.swift), as the app builds it.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        // Enrollment's X.509 handling, as the app builds it.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        // The workspaces' intercepting proxy (TLS termination for the stand-in swaps).
        // 2.37.6: an IP-literal upstream's certificate bound to the connected
        // address under .fullVerification (MitmProxy, KubeUpstreamTrust rely on it).
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.6"),
        // SandboxEngine's policy parser, as the app builds it.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(name: "CACLinuxShims"),
        // macOS's SandboxEngine module: its portable files (symlinks into
        // Sources/SandboxEngine) and the Linux stand-ins under Linux/.
        .target(
            name: "SandboxEngine",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            // Swift 5 mode, as the app builds it.
            swiftSettings: [.define("BROMURE_LINUX"), .swiftLanguageMode(.v5)]),
        .target(
            name: "ACLinux",
            dependencies: [
                "CACLinuxShims",
                "SandboxEngine",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
            ],
            // Shared macOS sources (Sources/ACLinux/_shared) build with their
            // Linux stand-ins under this flag, in Swift 5 mode as the app
            // builds them (they share one module with the daemon's code).
            swiftSettings: [.define("BROMURE_LINUX"), .swiftLanguageMode(.v5)]),
        // The headless Linux daemon and its CLI.
        .executableTarget(
            name: "bromure-ac",
            dependencies: [
                "ACLinux",
                "CACLinuxShims",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(
            name: "ACLinuxTests",
            dependencies: [
                "ACLinux",
                "CACLinuxShims",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]),
        // Boots the baked amd64 image under KVM; skips itself without
        // /dev/kvm, /dev/vhost-vsock access, or the image.
        .testTarget(
            name: "ACLinuxIntegrationTests",
            dependencies: [
                "ACLinux",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]),
    ]
)
