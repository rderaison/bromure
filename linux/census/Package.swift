// swift-tools-version: 6.0
import PackageDescription

// The ACCore census: builds, on Linux, the third-party modules the macOS
// targets import (so the census can typecheck their sources against them).
// Nothing here is shipped.
let package = Package(
    name: "Census",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.7.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
    ],
    targets: [
        .target(name: "CensusDeps", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "BigInt", package: "BigInt"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
            .product(name: "Yams", package: "Yams"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
        ]),
    ]
)
