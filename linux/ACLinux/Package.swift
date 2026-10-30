// swift-tools-version: 6.0
import PackageDescription

// ACLinux: the Linux implementations behind Bromure AC's platform protocols
// (QEMU/KVM VMs, host AF_VSOCK, guest CIDs). A package of its own until the
// ACCore carve-out lands, so the root package stays untouched. Linux-only.
let package = Package(
    name: "ACLinux",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ACLinux", targets: ["ACLinux"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
    ],
    targets: [
        .target(name: "CACLinuxShims"),
        .target(
            name: "ACLinux",
            dependencies: [
                "CACLinuxShims",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .testTarget(
            name: "ACLinuxTests",
            dependencies: [
                "ACLinux",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
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
