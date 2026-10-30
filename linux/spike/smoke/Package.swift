// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "Smoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
    ],
    targets: [
        .executableTarget(name: "Smoke", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
            .product(name: "X509", package: "swift-certificates"),
        ]),
    ]
)
