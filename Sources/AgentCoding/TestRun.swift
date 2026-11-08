import Foundation

/// A test run, which must never write the user's own files (their Security
/// Timeline, chat queue, keys): XCTest's bundle or configuration; Swift
/// Testing under `swift test`, which runs in swiftpm-testing-helper with no
/// XCTest configuration and the .xctest bundle loaded but not listed as a
/// bundle (only as an image path); or SwiftPM's test runner
/// (`<Package>-test-runner`, or an `.xctest` executable), which loads no
/// bundle.
func isTestRun() -> Bool {
    if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") || $0.bundlePath.contains(".xctest/") })
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
    let name = ProcessInfo.processInfo.processName
    if name == "swiftpm-testing-helper" || name.hasSuffix("-test-runner") || name.hasSuffix(".xctest") { return true }
    // The test bundle's image (swiftpm-testing-helper loads it with dlopen).
    return ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest/") || $0.hasSuffix(".xctest") }
}
