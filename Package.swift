// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "bromure",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "bromure",
            dependencies: [
                "SandboxEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
            ],
            path: "Sources/SandboxEngine",
            resources: [.copy("Resources/vm-setup")],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("vmnet"),
                .linkedFramework("SystemConfiguration"),
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
