import Foundation
import Virtualization

/// Manages an ephemeral APFS copy-on-write clone of the base disk image.
///
/// On creation, uses `clonefile(2)` to instantly create a zero-cost copy of the
/// base image. All writes from the VM go to the clone. On destruction, the clone
/// is deleted — all changes are lost, giving a clean sandbox every time.
public final class EphemeralDisk {
    /// URL of the golden base disk image (read-only source).
    public let baseImageURL: URL

    /// URL of the ephemeral clone (read-write, discarded on destroy).
    public let ephemeralURL: URL

    /// URL of the ephemeral auxiliary storage.
    public let ephemeralAuxURL: URL

    /// If true, the clone should be preserved after the VM shuts down.
    public let persist: Bool

    /// Track whether we've been cleaned up.
    private var destroyed = false

    public init(
        baseImageURL: URL,
        sessionID: String = UUID().uuidString,
        persistAt: URL? = nil
    ) {
        self.baseImageURL = baseImageURL

        if let persistAt = persistAt {
            self.ephemeralURL = persistAt
            self.ephemeralAuxURL = persistAt
                .deletingPathExtension()
                .appendingPathExtension("aux.img")
            self.persist = true
        } else {
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bromure", isDirectory: true)
            self.ephemeralURL = tmpDir.appendingPathComponent("session-\(sessionID).img")
            self.ephemeralAuxURL = tmpDir.appendingPathComponent("session-\(sessionID)-aux.img")
            self.persist = false
        }
    }

    /// Create the APFS CoW clone of the base image.
    ///
    /// Uses `clonefile(2)` which is:
    /// - Instant (no data copying)
    /// - Zero additional disk space until writes diverge
    /// - Atomic
    /// - Only works on APFS volumes
    public func create() throws {
        let fm = FileManager.default
        let parentDir = ephemeralURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Remove any stale clone from a previous crashed session
        try? fm.removeItem(at: ephemeralURL)
        try? fm.removeItem(at: ephemeralAuxURL)

        // clonefile(2): create a copy-on-write clone
        let result = clonefile(
            baseImageURL.path(percentEncoded: false),
            ephemeralURL.path(percentEncoded: false),
            0  // no flags
        )
        guard result == 0 else {
            let err = String(cString: strerror(errno))
            throw SandboxError.cloneFailed(
                "clonefile failed: \(err). Ensure both source and destination are on an APFS volume."
            )
        }
    }

    /// Clone the base auxiliary storage for this session.
    ///
    /// The base aux storage contains boot records written during `init`
    /// (by the macOS installer). Without these records, the VM firmware
    /// cannot locate the boot volume and the screen stays black.
    public func cloneBaseAuxStorage(from baseAuxURL: URL) throws {
        let result = clonefile(
            baseAuxURL.path(percentEncoded: false),
            ephemeralAuxURL.path(percentEncoded: false),
            0
        )
        guard result == 0 else {
            let err = String(cString: strerror(errno))
            throw SandboxError.cloneFailed(
                "clonefile failed for aux storage: \(err). "
                + "Ensure both source and destination are on an APFS volume."
            )
        }
    }

    /// Delete the ephemeral clone and auxiliary storage.
    ///
    /// After this call, all guest modifications are permanently lost.
    public func destroy() throws {
        guard !destroyed else { return }
        destroyed = true

        if persist {
            // Keep the files around for forensics / inspection
            return
        }

        let fm = FileManager.default
        try? fm.removeItem(at: ephemeralURL)
        try? fm.removeItem(at: ephemeralAuxURL)
    }

    deinit {
        if !destroyed && !persist {
            try? destroy()
        }
    }

    /// Disk space used by the clone beyond the shared base blocks.
    /// Returns bytes of diverged (written) data.
    public var divergedBytes: UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: ephemeralURL.path
        ) else { return 0 }

        _ = attrs[.size] as? UInt64 ?? 0
        // On APFS, the physical size of a clone starts at ~0 and grows
        // as blocks are written. Unfortunately, FileManager doesn't expose
        // physical size directly; we'd need stat(2) for st_blocks.
        var statBuf = stat()
        guard lstat(ephemeralURL.path(percentEncoded: false), &statBuf) == 0 else {
            return 0
        }
        let physicalSize = UInt64(statBuf.st_blocks) * 512
        return physicalSize
    }
}
