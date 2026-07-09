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
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        // Pinned to the range MLXLLM (mlx-swift-lm) requires; the classifier
        // only uses the stable `Tokenizers` + `Hub` API. 1.1+ declares package
        // traits (the Xet opt-in), which the newer SwiftPM toolchain requires.
        .package(url: "https://github.com/huggingface/swift-transformers.git", "1.2.0" ..< "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        // In-process MLX inference engine (replaces the Python vllm-mlx subprocess).
        // mlx-swift-examples was renamed mlx-swift-lm; track the latest (3.x adds
        // the SpeculativeTokenIterator API).
        // 3.31.4 raises its swift-syntax floor to 602..<604 (matches the Swift
        // 6.3 toolchain). After bumping, do a clean build — stale macro-plugin
        // artifacts from the previous swift-syntax otherwise fail to load.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMinor(from: "0.31.5")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", "3.31.4" ..< "3.32.0"),
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
                // libghostty (native terminal surfaces). Built from the
                // pinned commit in tools/ghostty.commit by
                // tools/build-ghostty.sh — build.sh runs it automatically
                // when vendor/ is missing; it is never committed.
                "GhosttyKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // HuggingFace tokenizer/downloader integration (split out of
                // MLXLMCommon in 3.x); provides #huggingFaceTokenizerLoader().
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            ],
            path: "Sources/AgentCoding",
            exclude: ["Info.plist", "BromureAC.entitlements", "BromureAC.sdef"],
            resources: [.copy("Resources/vm-setup"), .copy("Resources/icons"),
                        .copy("Resources/catalog.json"),
                        .copy("Resources/img-catalog.json")],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("OpenDirectory"),
                // GhosttyKit (static) resolves against these at link time.
                // libc++ for its bundled glslang/spirv-cross.
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedLibrary("c++"),
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/GhosttyKit.xcframework"
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
        .testTarget(
            name: "AgentCodingTests",
            // GhosttyKit repeated here: SPM doesn't propagate a binaryTarget
            // through an executable-target dependency into the test bundle's
            // link, so the tests need it (and its frameworks) directly.
            dependencies: ["bromure-ac", "GhosttyKit"],
            path: "Tests/AgentCodingTests",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
