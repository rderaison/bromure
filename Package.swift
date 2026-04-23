// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "bromure",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "bromure",
            dependencies: [
                "SandboxEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/CLI",
            exclude: ["Info.plist", "SafariSandbox.entitlements", "Bromure.sdef"]
        ),
        .systemLibrary(
            name: "CVmnet",
            path: "Sources/CVmnet"
        ),
        .target(
            name: "SandboxEngine",
            dependencies: [
                "CVmnet",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Sources/SandboxEngine",
            resources: [.copy("Resources/vm-setup")],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("vmnet"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "HostServices",
            dependencies: ["SandboxEngine"],
            path: "Sources/HostServices"
        ),
        .testTarget(
            name: "BromureTests",
            dependencies: ["SandboxEngine"],
            path: "Tests/SafariSandboxTests"
        ),
    ]
)
