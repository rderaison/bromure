import Darwin
import Foundation
import SandboxEngine
@preconcurrency import Virtualization

// MARK: - Prebuilt-image download + postinstall-on-existing-image
//
// The fast path for new installations: instead of the ~10 min local
// Alpine/debootstrap build, fetch the prebuilt free-software image the
// weekly Jenkins pipeline publishes (img-catalog.json → images/<uuid>/
// base.img.gz on dl.bromure.io), verify, expand, and apply the catalog's
// postinstall steps (the non-free software) in a chroot via postinstall.sh.

extension UbuntuImageManager {

    /// True when a `downloadBaseImage` failure is download-side — the
    /// catalog fetch, the transfer itself, checksum verification, or
    /// expansion — i.e. the cases where building the image locally is a
    /// genuine remedy. VM-side failures (the postinstall boot), disk
    /// space, and cancellation return false: a local bake runs the exact
    /// same machinery, so falling back would burn ~10 minutes before
    /// failing identically.
    public static func isDownloadSideFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        // Every ImageFetchError case is download-side by construction
        // (that's the enum's contract — see ImageFetch.swift).
        if error is ImageFetchError { return true }
        if let e = error as? UbuntuImageError {
            switch e {
            case .catalogUnavailable, .downloadFailed, .checksumInvalid,
                 .unsupportedCompression, .imageExpandFailed:
                return true
            default:
                return false
            }
        }
        // Transport-level failures out of URLSession (offline, DNS, TLS,
        // connection reset mid-transfer).
        return error is URLError
    }

    /// End-to-end "new installation" download. Always fetches the latest
    /// img-catalog.json first, then the image it names. Mirrors
    /// `createBaseImage`'s crash-safety: everything lands in .partial
    /// files, the live image is only touched by the final atomic swap.
    ///
    /// The download is retried (with a fresh catalog fetch in between) up
    /// to 3 times: the weekly publish deletes the previous build's objects
    /// right after the new catalog goes live, so a client that fetched the
    /// catalog just before the switch can see its download 404/truncate —
    /// the refetch lands on the new build.
    public func downloadBaseImage(
        catalogStore: ImageCatalogStore = .shared,
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void = { _ in }
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try EphemeralDisk.checkDiskSpace(at: storageDir.path,
                                         minimumFreeBytes: Self.minimumBuildFreeBytes)

        let scratchGz = storageDir.appendingPathComponent("base.img.gz.partial")
        let scratchDisk = storageDir.appendingPathComponent("base.img.partial")
        let scratchEFI = storageDir.appendingPathComponent("efivars.partial")

        // Same failure-cleanup contract as createBaseImage (see there).
        let hadCompletePriorImage = hasBaseImage
        let priorStamp = installedImageVersion

        do {
            // 1. Catalog + image, with the delete-race retry loop.
            var catalog: ImageCatalog?
            var lastError: Error = ImageFetchError.catalogUnavailable
            for attempt in 1...3 {
                if attempt > 1 { progress("Retrying download (attempt \(attempt)/3)…") }
                progress("Fetching image catalog…")
                guard let fetched = await catalogStore.refresh(),
                      let image = fetched.image else {
                    lastError = ImageFetchError.catalogUnavailable
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                do {
                    try await fetchAndExpand(image: image, gz: scratchGz,
                                             disk: scratchDisk, progress: progress)
                    catalog = fetched
                    break
                } catch {
                    lastError = error
                    try? fm.removeItem(at: scratchGz)
                    try? fm.removeItem(at: scratchDisk)
                }
            }
            guard let catalog, let image = catalog.image else { throw lastError }

            // 2. Postinstall: every catalog step, unprompted — the setup
            //    screen the user clicked through is the consent for the
            //    initial set. Runs even with zero steps: the postinstall
            //    boot also restores resolv.conf and e2fsck-gates the
            //    downloaded image before promotion.
            let steps = catalog.sortedSteps
            progress(steps.isEmpty
                ? "Finalizing image…"
                : "Installing recommended packages (\(steps.count) step(s), ~2-5 min)…")
            try await runPostinstall(
                steps: steps,
                targetDisk: scratchDisk,
                progress: progress,
                output: output
            )

            // 3. Fresh EFI variable store — GRUB is installed in removable
            //    mode, so no NVRAM entries need to ship with the image.
            try? fm.removeItem(at: scratchEFI)
            _ = try VZEFIVariableStore(creatingVariableStoreAt: scratchEFI, options: [])

            // 4. Promote. A re-download at the same major bumps the
            //    dot-revision so existing workspaces detect drift and get
            //    offered a reset (same semantics as a local rebuild).
            let newStamp = Self.nextStamp(priorStamp: priorStamp,
                                          bundled: Self.majorVersion(of: image.version))
            try? fm.removeItem(at: baseDiskURL)
            try fm.moveItem(at: scratchDisk, to: baseDiskURL)
            try? fm.removeItem(at: efiVarsURL)
            try fm.moveItem(at: scratchEFI, to: efiVarsURL)
            try newStamp.write(to: versionStampURL, atomically: true, encoding: .utf8)
            writeImageState(BaseImageState(
                imageUUID: image.uuid,
                version: newStamp,
                appliedStepUUIDs: steps.map(\.uuid)))

            progress("Base image ready at \(baseDiskURL.path) (v\(newStamp), \(image.description))")
        } catch {
            try? fm.removeItem(at: scratchGz)
            try? fm.removeItem(at: scratchDisk)
            try? fm.removeItem(at: scratchEFI)
            if !hadCompletePriorImage {
                try? fm.removeItem(at: baseDiskURL)
                try? fm.removeItem(at: efiVarsURL)
                try? fm.removeItem(at: versionStampURL)
                try? fm.removeItem(at: imageStateURL)
            }
            throw error
        }
    }

    /// Apply newly-published img-catalog postinstall steps to the existing
    /// base.img (after the user accepted them). Works on an APFS clone and
    /// promotes atomically, so live sessions keep a bootable image
    /// throughout; the dot-revision bump makes existing workspaces'
    /// drift detection offer a reset onto the amended base.
    public func applyPostinstallSteps(
        _ steps: [PostinstallStep],
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void = { _ in }
    ) async throws {
        guard !steps.isEmpty else { return }
        guard hasBaseImage else {
            throw UbuntuImageError.installerReportedFailure("no base image to amend")
        }
        let fm = FileManager.default
        try EphemeralDisk.checkDiskSpace(at: storageDir.path,
                                         minimumFreeBytes: Self.minimumBuildFreeBytes)

        let scratchDisk = storageDir.appendingPathComponent("base.img.partial")
        try? fm.removeItem(at: scratchDisk)
        // clonefile(2): instant CoW copy; only diverged blocks cost space.
        if clonefile(baseDiskURL.path, scratchDisk.path, 0) != 0 {
            try fm.copyItem(at: baseDiskURL, to: scratchDisk)  // non-APFS fallback
        }

        do {
            progress("Installing recommended packages (\(steps.count) step(s))…")
            try await runPostinstall(
                steps: steps,
                targetDisk: scratchDisk,
                progress: progress,
                output: output
            )

            let priorStamp = installedImageVersion
            let bundledMajor = priorStamp.map(Self.majorVersion(of:)) ?? Self.imageVersion
            let newStamp = Self.nextStamp(priorStamp: priorStamp, bundled: bundledMajor)
            try? fm.removeItem(at: baseDiskURL)
            try fm.moveItem(at: scratchDisk, to: baseDiskURL)
            try newStamp.write(to: versionStampURL, atomically: true, encoding: .utf8)

            var state = loadImageState()
                ?? BaseImageState(imageUUID: nil, version: newStamp, appliedStepUUIDs: [])
            state.version = newStamp
            state.appliedStepUUIDs = (Set(state.appliedStepUUIDs)
                .union(steps.map(\.uuid))).sorted()
            writeImageState(state)
            progress("Packages installed (base image now v\(newStamp)).")
        } catch {
            try? fm.removeItem(at: scratchDisk)
            throw error
        }
    }

    // MARK: - Download + verify + expand

    /// Thin wrapper over the shared ImageFetch plumbing (SandboxEngine):
    /// download the catalog's disk artifact, verify its sha256, and
    /// expand it sparse (the 24 GB logical disk is ~6-8 GB physical).
    private func fetchAndExpand(
        image: RemoteBaseImage,
        gz: URL,
        disk: URL,
        progress: @escaping (String) -> Void
    ) async throws {
        try await ImageFetch.fetchVerifiedArtifact(
            path: image.disk.path,
            sha256: image.disk.sha256,
            compression: image.disk.compression,
            compressedBytes: image.disk.compressedBytes,
            uncompressedBytes: image.disk.uncompressedBytes,
            label: "\(image.description) image",
            scratchGz: gz,
            destination: disk,
            progress: progress
        )
    }
}
