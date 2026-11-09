import Crypto
import Foundation

/// ImageFetch's streaming SHA-256 (macOS: CommonCrypto's, in ImageFetch.swift).
// @port-skip linux-only: ImageFetch's hasher over swift-crypto (macOS: CommonCrypto)
struct StreamingSHA256 {
    private var hasher = SHA256()

    // @port-skip linux-only: see StreamingSHA256
    mutating func update(_ chunk: Data) { hasher.update(data: chunk) }

    // @port-skip linux-only: see StreamingSHA256
    mutating func hexDigest() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Foundation's autoreleasepool, which corelibs Foundation doesn't have:
/// no Objective-C autorelease here, so the body just runs.
// @port-skip linux-only: corelibs Foundation has no autoreleasepool
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
