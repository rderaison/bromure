import Crypto
import Foundation

/// ImageFetch's streaming SHA-256 (macOS: CommonCrypto's, in ImageFetch.swift).
// @port-skip linux-only: ImageFetch's hasher over swift-crypto (macOS: CommonCrypto)
struct StreamingSHA256 {
    private var hasher = SHA256()

    // partial: swift-crypto's SHA256 (macOS: CC_SHA256_Init)
    // @port StreamingSHA256.init() h=6c48063b29b6eb5e @c22a41ae
    init() {}

    // partial: swift-crypto's SHA256 (macOS: CC_SHA256_Update)
    // @port StreamingSHA256.update(_: Data) h=5ac57a71d7c1067b @c22a41ae
    mutating func update(_ chunk: Data) { hasher.update(data: chunk) }

    // partial: swift-crypto's SHA256 (macOS: CC_SHA256_Final)
    // @port StreamingSHA256.hexDigest() h=1835d62448b87afb @c22a41ae
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
