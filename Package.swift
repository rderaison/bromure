// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "bromure",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "bromure",
            dependencies: [
                "SandboxEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI",
            exclude: ["Info.plist", "SafariSandbox.entitlements"]
        ),
        .target(
            name: "SandboxEngine",
            dependencies: [],
            path: "Sources/SandboxEngine",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
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
