import Foundation

/// Shared free-disk-space preflight for the two model-download flows — local
/// MLX inference weights (`ModelDownloader`) and the prompt-injection detector
/// models (`PromptInjectionModels`). Both refuse to start a download that
/// wouldn't fit, plus a safety margin, so a large pull can't drive the boot
/// volume to zero and wedge macOS. The genuinely fiddly bit — resolving the
/// volume of a leaf directory that doesn't exist yet, and failing open on a
/// stat hiccup — lives here so both flows behave identically.
enum DiskSpace {
    /// Free space (bytes) we insist on leaving for the OS on top of whatever a
    /// download will write. A flat floor, not a percentage: the hazard is an
    /// absolute near-empty volume, regardless of how big the download is.
    static let safetyMarginBytes: Int64 = 2_000_000_000   // 2 GB

    /// Free bytes on the volume backing `url`. The leaf may not exist yet (a
    /// per-repo directory created at download time), so walk up to the nearest
    /// existing ancestor before stat'ing. nil if it still can't be read.
    ///
    /// Uses `.systemFreeSize` (truly-free blocks), matching the rest of the app
    /// and staying conservative on APFS — it ignores purgeable space the OS
    /// *might* reclaim, so we never start a download counting on space that
    /// isn't actually there.
    static func freeBytes(at url: URL) -> UInt64? {
        let fm = FileManager.default
        var dir = url.standardizedFileURL
        while !fm.fileExists(atPath: dir.path) && dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        return (try? fm.attributesOfFileSystem(forPath: dir.path)[.systemFreeSize]) as? UInt64
    }

    /// Bytes that must be free before writing `writeBytes` into `url`'s volume:
    /// the payload (less anything already on disk for a resumable/partial pull)
    /// plus the safety margin.
    static func requiredBytes(forWriting writeBytes: Int64,
                              alreadyOnDisk: Int64 = 0,
                              margin: Int64 = safetyMarginBytes) -> Int64 {
        max(0, writeBytes - alreadyOnDisk) + margin
    }
}
