// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CompactTabStrip",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CompactTabStrip",
            targets: ["CompactTabStrip"]
        ),
    ],
    targets: [
        .target(
            name: "CompactTabStrip",
            path: "Sources/CompactTabStrip"
        ),
    ]
)
