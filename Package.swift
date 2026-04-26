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
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "bromure",
            dependencies: [
                "SandboxEngine",
                "BrowserBridges",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Browser",
            exclude: ["Info.plist", "SafariSandbox.entitlements", "Bromure.sdef"]
        ),
        .executableTarget(
            name: "bromure-ac",
            dependencies: [
                "SandboxEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            path: "Sources/AgentCoding",
            exclude: ["Info.plist", "BromureAC.entitlements"],
            resources: [.copy("Resources/vm-setup")],
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
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
            name: "BrowserBridges",
            dependencies: [
                "SandboxEngine",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/BrowserBridges",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("AuthenticationServices"),
            ]
        ),
        .target(
            name: "HostServices",
            dependencies: ["SandboxEngine"],
            path: "Sources/HostServices"
        ),
        .testTarget(
            name: "BromureTests",
            dependencies: ["SandboxEngine", "BrowserBridges"],
            path: "Tests/SafariSandboxTests"
        ),
    ]
)
