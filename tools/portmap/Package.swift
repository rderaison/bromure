// swift-tools-version: 5.9
import PackageDescription

// The Linux port's function ledger: every macOS function, its body hash, and
// what the Linux build does about it. A package of its own so the app's build
// never pulls in swift-syntax. Builds and runs on macOS and Linux.
let package = Package(
    name: "portmap",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.7.0"),
    ],
    targets: [
        .target(
            name: "PortMapCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .executableTarget(
            name: "portmap",
            dependencies: [
                "PortMapCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "PortMapCoreTests", dependencies: ["PortMapCore"]),
    ]
)
