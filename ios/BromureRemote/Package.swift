// swift-tools-version: 5.9
import PackageDescription

// Bromure Remote — iOS / iPadOS fat client.
//
// This package compiles the fat-client SUBSET of Sources/AgentCoding (linked in
// by `Sources/BromureRemote/_shared/`, a farm of symlinks kept in sync by
// `scripts/gen-ios-sources.py`) together with the iOS-only sources in
// `Sources/BromureRemote/`. It builds as a library so the whole port is
// compile-checkable from the command line:
//
//   xcodebuild -scheme BromureRemote \
//     -destination 'generic/platform=iOS Simulator' \
//     -derivedDataPath .build-ios CODE_SIGNING_ALLOWED=NO build
//
// The shipping app bundle is produced by the generated Xcode project
// (scripts/gen-ios-project.py), which reuses these exact sources and defines
// BROMURE_APP to switch on the `@main` entry point.
let package = Package(
    name: "BromureRemote",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "BromureRemote", targets: ["BromureRemote"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.7.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "BromureRemote",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/BromureRemote"
        ),
    ]
)
