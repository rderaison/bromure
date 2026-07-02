import CommonCrypto
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
            var lastError: Error = UbuntuImageError.catalogUnavailable
            for attempt in 1...3 {
                if attempt > 1 { progress("Retrying download (attempt \(attempt)/3)…") }
                progress("Fetching image catalog…")
                guard let fetched = await catalogStore.refresh(),
                      let image = fetched.image else {
                    lastError = UbuntuImageError.catalogUnavailable
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
            //    initial set. Fonts ride along in the same boot (the
            //    published image can't contain Apple's fonts; the user's
            //    own Mac provides them here).
            let steps = catalog.sortedSteps
            progress(steps.isEmpty
                ? "Finalizing image (fonts)…"
                : "Installing recommended packages (\(steps.count) step(s), ~2-5 min)…")
            try await runPostinstall(
                steps: steps,
                targetDisk: scratchDisk,
                includeMacFonts: true,
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
                includeMacFonts: false,
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

    private func fetchAndExpand(
        image: RemoteBaseImage,
        gz: URL,
        disk: URL,
        progress: @escaping (String) -> Void
    ) async throws {
        guard image.disk.compression == "gzip" else {
            throw UbuntuImageError.unsupportedCompression(image.disk.compression)
        }
        guard let url = ImageCatalogStore.artifactURL(for: image.disk.path) else {
            throw UbuntuImageError.imageExpandFailed("bad artifact path \(image.disk.path)")
        }

        let human = ByteCountFormatter.string(fromByteCount: image.disk.compressedBytes,
                                              countStyle: .file)
        progress("Downloading \(image.description) image (\(human))…")
        let expectedTotal = image.disk.compressedBytes
        try await LargeFileDownloader(destination: gz) { written, _ in
            guard expectedTotal > 0 else { return }
            let pct = written * 100 / expectedTotal
            progress("Downloading \(image.description) image (\(human))… \(pct)%")
        }.run(from: url)

        progress("Verifying checksum…")
        let actual = try await Task.detached(priority: .userInitiated) {
            try Self.sha256Streaming(of: gz)
        }.value
        guard actual == image.disk.sha256.lowercased() else {
            throw UbuntuImageError.checksumInvalid(
                "\(image.disk.path): expected \(image.disk.sha256), got \(actual)")
        }

        progress("Expanding image…")
        let expectedBytes = image.disk.uncompressedBytes
        try await Task.detached(priority: .userInitiated) {
            try Self.expandGzipSparse(from: gz, to: disk,
                                      expectedBytes: expectedBytes, progress: progress)
        }.value
        try? FileManager.default.removeItem(at: gz)
    }

    /// SHA-256 of a (multi-GB) file without loading it into memory.
    static func sha256Streaming(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        while true {
            let chunk = try autoreleasepool {
                try handle.read(upToCount: 4 * 1024 * 1024)
            }
            guard let chunk, !chunk.isEmpty else { break }
            chunk.withUnsafeBytes {
                _ = CC_SHA256_Update(&ctx, $0.baseAddress, CC_LONG($0.count))
            }
        }
        var hash = [UInt8](repeating: 0, count: 32)
        CC_SHA256_Final(&hash, &ctx)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Stream-gunzip a compressed raw disk to `dest`, skipping writes for
    /// all-zero chunks so the result is APFS-sparse like a locally-built
    /// image (the 24 GB logical disk is ~6-8 GB physical). Ends with a
    /// truncate to the expected logical size to materialise trailing holes.
    static func expandGzipSparse(
        from gz: URL,
        to dest: URL,
        expectedBytes: Int64,
        progress: @escaping (String) -> Void
    ) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: dest.path, contents: nil) else {
            throw UbuntuImageError.imageExpandFailed("cannot create \(dest.path)")
        }
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }

        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = ["-c", gz.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        gunzip.standardOutput = outPipe
        gunzip.standardError = errPipe
        try gunzip.run()

        let reader = outPipe.fileHandleForReading
        let chunkSize = 4 * 1024 * 1024
        let zeroChunk = Data(count: chunkSize)
        var offset: UInt64 = 0
        var lastReported: UInt64 = 0
        while true {
            let chunk = autoreleasepool { reader.readData(ofLength: chunkSize) }
            if chunk.isEmpty { break }
            let isZero = chunk.count == chunkSize
                ? chunk == zeroChunk
                : chunk.allSatisfy { $0 == 0 }
            if !isZero {
                try out.seek(toOffset: offset)
                try out.write(contentsOf: chunk)
            }
            offset += UInt64(chunk.count)
            if expectedBytes > 0, offset - lastReported >= 1024 * 1024 * 1024 {
                lastReported = offset
                progress("Expanding image… \(offset * 100 / UInt64(expectedBytes))%")
            }
        }
        gunzip.waitUntilExit()
        guard gunzip.terminationStatus == 0 else {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
            throw UbuntuImageError.imageExpandFailed(
                "gunzip exited \(gunzip.terminationStatus): \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard Int64(offset) == expectedBytes else {
            throw UbuntuImageError.imageExpandFailed(
                "expanded to \(offset) bytes, catalog says \(expectedBytes)")
        }
        try out.truncate(atOffset: UInt64(expectedBytes))
    }
}

// MARK: - Large-file downloader

/// Delegate-driven URLSession download with byte-level progress — the
/// async `URLSession.download(from:)` sugar offers none, and the image is
/// multi-GB. Moves the finished file to `destination` before completing.
final class LargeFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var lastReportedBytes: Int64 = 0

    init(destination: URL, onProgress: @escaping (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(from url: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        // The CDN caches image objects hard (they're immutable per uuid);
        // the local layer must not, or a retried download could replay a
        // truncated body.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Throttle: a 3 GB pull at 4 KB callbacks would flood the UI.
        if totalBytesWritten - lastReportedBytes >= 64 * 1024 * 1024
            || totalBytesWritten == totalBytesExpectedToWrite {
            lastReportedBytes = totalBytesWritten
            onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            moveError = UbuntuImageError.downloadFailed(http.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let cont = continuation
        continuation = nil
        if let error {
            cont?.resume(throwing: error)
        } else if let moveError {
            cont?.resume(throwing: moveError)
        } else if let http = task.response as? HTTPURLResponse,
                  !(200..<300).contains(http.statusCode) {
            cont?.resume(throwing: UbuntuImageError.downloadFailed(http.statusCode))
        } else {
            cont?.resume()
        }
    }
}
