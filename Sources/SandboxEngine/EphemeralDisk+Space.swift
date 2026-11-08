import Foundation

// The free-space floor every disk image is created or grown under, apart
// from EphemeralDisk's clonefile(2) half, so the Linux daemon (which has
// no EphemeralDisk class: Linux/EphemeralDisk.swift) checks it the same way.

extension EphemeralDisk {
    /// Minimum free space (1 GB) required before creating a disk image.
    public static let minimumFreeBytes: UInt64 = 1_073_741_824

    /// Free bytes on the volume backing `path`, or nil if it can't be read.
    public static func freeBytes(at path: String) -> UInt64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: path)[.systemFreeSize]) as? UInt64
    }

    /// Throw ``SandboxError/diskFull`` if the volume at `path` has less than
    /// `minimumFreeBytes` free (default 1 GB). Fails open if free space can't
    /// be read — a stat hiccup shouldn't block a launch.
    public static func checkDiskSpace(at path: String,
                                      minimumFreeBytes: UInt64 = EphemeralDisk.minimumFreeBytes) throws {
        guard let free = freeBytes(at: path) else { return }
        if free < minimumFreeBytes {
            throw SandboxError.diskFull(availableMB: free / (1024 * 1024), path: path)
        }
    }
}
