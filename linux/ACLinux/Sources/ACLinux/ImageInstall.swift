import Foundation
import SandboxEngine

/// The prebuilt amd64 image (macOS: UbuntuImageManager+Remote.swift's
/// download path): the amd64 channel's signed catalog names a disk, which
/// is downloaded, checked against its SHA-256, expanded sparse, and
/// finished by the Firecracker installer's postinstall boot with every
/// catalog step (and the customize script); promoted as a bake's image.
public enum ImageInstall {
    /// Whether a download failure is the download's (the catalog, the
    /// transfer, the checksum, the expansion): the ones a local bake
    /// remedies. The postinstall boot's failures, disk space and a cancel
    /// aren't: the bake runs the same installer.
    // @port UbuntuImageManager.static isDownloadSideFailure(_: Error) h=94869d1f08725683 @84e171b8
    public static func isDownloadSideFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is ImageFetchError { return true }
        return error is URLError
    }

    /// The download and its postinstall boot, retried up to 3 times with
    /// the catalog fetched again in between (a publish deletes the previous
    /// build's objects once the new catalog is live). Everything lands in
    /// partial files beside the image; the live one is replaced only by the
    /// bake's promotion.
    // partial: no stock.img checkpoint (each install downloads, then runs every step); no provisioner (the installer is the Alpine netboot)
    // @port UbuntuImageManager.downloadBaseImage(catalogStore: ImageCatalogStore, fresh: Bool, progress: @escaping(String)->Void, output: @escaping(String)->Void) h=213f4adbcc46f72b @84e171b8
    public static func download(_ o: InterimBake.Options, store: ImageCatalogStore, steps: Bool = true,
                                progress: @escaping @Sendable (String) -> Void = { _ in },
                                output: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> InterimBake.Result {
        let fm = FileManager.default
        try fm.createDirectory(atPath: o.outputDir, withIntermediateDirectories: true)
        // One download per output dir: two would share the partial files.
        let lock = open(o.outputDir + "/.download.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw MachineError.io("open \(o.outputDir)/.download.lock", errno) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw BakeError.staging("another image install is running into \(o.outputDir)")
        }
        let gz = URL(fileURLWithPath: o.outputDir + "/base.img.gz.partial")
        let disk = URL(fileURLWithPath: o.outputDir + "/base.img.download")
        defer { try? fm.removeItem(at: gz); try? fm.removeItem(at: disk) }
        var lastError: Error = ImageFetchError.catalogUnavailable
        for attempt in 1...3 {
            if attempt > 1 { progress("Retrying download (attempt \(attempt)/3)…") }
            progress("Fetching image catalog…")
            guard let catalog = await store.refresh(), let image = catalog.image else {
                lastError = ImageFetchError.catalogUnavailable
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            do {
                try await fetchAndExpand(image, gz: gz, disk: disk, progress: progress)
            } catch {
                lastError = error
                try? fm.removeItem(at: gz)
                try? fm.removeItem(at: disk)
                continue
            }
            var b = o
            b.postinstallSteps = steps ? catalog.sortedSteps : []
            b.downloaded = .init(disk: disk.path, imageUUID: image.uuid, version: image.version)
            let r = try await InterimBake.bake(b, progress: progress, output: output)
            progress("Base image ready at \(o.outputDir)/base.img (\(image.description))")
            return r
        }
        throw lastError
    }

    /// The catalog's disk: downloaded, its SHA-256 checked, expanded sparse.
    // @port UbuntuImageManager.fetchAndExpand(image: RemoteBaseImage, gz: URL, disk: URL, progress: @escaping(String)->Void) h=5dd320a9570d1cee @84e171b8
    static func fetchAndExpand(_ image: RemoteBaseImage, gz: URL, disk: URL,
                               progress: @escaping (String) -> Void) async throws {
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
