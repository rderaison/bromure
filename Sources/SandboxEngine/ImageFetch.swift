import CommonCrypto
import Foundation

// MARK: - Prebuilt-image download plumbing (shared by every channel)
//
// The transfer-side machinery both prebuilt-image channels (Bromure
// Agentic Coding's Ubuntu image, Bromure Web's Alpine/Chromium image) use
// to fetch artifacts named by img-catalog.json: a delegate-driven
// URLSession downloader with byte-level progress, a streaming SHA-256,
// and a gunzip-to-sparse-file expander. Everything here is
// filesystem/URL-level — no channel-specific knowledge.

/// Failures on the download side of a prebuilt-image install — the cases
/// where building the image locally is a genuine remedy. Kept distinct
/// from the VM-side build errors so callers can decide when a local-build
/// fallback makes sense.
public enum ImageFetchError: LocalizedError {
    /// img-catalog.json could not be fetched (or names no image).
    case catalogUnavailable
    /// An artifact download returned an HTTP error.
    case downloadFailed(Int)
    /// A downloaded artifact failed its sha256 check.
    case checksumInvalid(String)
    /// The catalog names a compression this build doesn't implement.
    case unsupportedCompression(String)
    /// Decompressing a downloaded artifact failed or produced the wrong size.
    case expandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .catalogUnavailable:
            return NSLocalizedString(
                "The image catalog could not be downloaded.",
                comment: "Prebuilt image: catalog fetch failed")
        case .downloadFailed(let code):
            return String(format: NSLocalizedString(
                "Download failed (HTTP %d).",
                comment: "Prebuilt image: a download returned an HTTP error"), code)
        case .checksumInvalid(let why):
            return String(format: NSLocalizedString(
                "Checksum invalid: %@",
                comment: "Prebuilt image: downloaded file failed checksum"), why)
        case .unsupportedCompression(let format):
            return String(format: NSLocalizedString(
                "Unsupported image compression \u{201C}%@\u{201D}.",
                comment: "Prebuilt image: catalog names an unknown compression"), format)
        case .expandFailed(let why):
            return String(format: NSLocalizedString(
                "Could not expand the downloaded image: %@",
                comment: "Prebuilt image: decompression failed"), why)
        }
    }
}

public enum ImageFetch {
    /// Download `url` to `destination` with byte-level progress. Local
    /// URLSession caching is disabled — the CDN caches image objects hard
    /// (they're immutable per uuid), but a retried download must never
    /// replay a locally cached truncated body.
    public static func download(
        from url: URL,
        to destination: URL,
        onProgress: @escaping (Int64, Int64) -> Void
    ) async throws {
        try await LargeFileDownloader(destination: destination,
                                      onProgress: onProgress).run(from: url)
    }

    /// Download a catalog artifact (`disk` or a boot file), verify its
    /// sha256, and expand it to `destination` (sparse — all-zero chunks
    /// become holes). `scratchGz` holds the compressed intermediate and
    /// is removed on success.
    public static func fetchVerifiedArtifact(
        path: String,
        sha256: String,
        compression: String,
        compressedBytes: Int64,
        uncompressedBytes: Int64,
        label: String,
        scratchGz: URL,
        destination: URL,
        progress: @escaping (String) -> Void
    ) async throws {
        guard compression == "gzip" else {
            throw ImageFetchError.unsupportedCompression(compression)
        }
        guard let url = ImageCatalogStore.artifactURL(for: path) else {
            throw ImageFetchError.expandFailed("bad artifact path \(path)")
        }

        let human = ByteCountFormatter.string(fromByteCount: compressedBytes,
                                              countStyle: .file)
        progress("Downloading \(label) (\(human))…")
        try await download(from: url, to: scratchGz) { written, _ in
            guard compressedBytes > 0 else { return }
            let pct = written * 100 / compressedBytes
            progress("Downloading \(label) (\(human))… \(pct)%")
        }

        progress("Verifying \(label) checksum…")
        let actual = try await Task.detached(priority: .userInitiated) {
            try sha256Streaming(of: scratchGz)
        }.value
        guard actual == sha256.lowercased() else {
            throw ImageFetchError.checksumInvalid(
                "\(path): expected \(sha256), got \(actual)")
        }

        progress("Expanding \(label)…")
        try await Task.detached(priority: .userInitiated) {
            try expandGzipSparse(from: scratchGz, to: destination,
                                 expectedBytes: uncompressedBytes, progress: progress)
        }.value
        try? FileManager.default.removeItem(at: scratchGz)
    }

    /// SHA-256 of a (multi-GB) file without loading it into memory.
    public static func sha256Streaming(of url: URL) throws -> String {
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
    /// image. Ends with a truncate to the expected logical size to
    /// materialise trailing holes.
    public static func expandGzipSparse(
        from gz: URL,
        to dest: URL,
        expectedBytes: Int64,
        progress: @escaping (String) -> Void
    ) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: dest.path, contents: nil) else {
            throw ImageFetchError.expandFailed("cannot create \(dest.path)")
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
            // 128 MB ≈ 3% steps on the 4.5 GB browser disk — the
            // expansion segment of the install bar moves smoothly.
            if expectedBytes > 0, offset - lastReported >= 128 * 1024 * 1024 {
                lastReported = offset
                progress("Expanding image… \(offset * 100 / UInt64(expectedBytes))%")
            }
        }
        gunzip.waitUntilExit()
        guard gunzip.terminationStatus == 0 else {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
            throw ImageFetchError.expandFailed(
                "gunzip exited \(gunzip.terminationStatus): \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard Int64(offset) == expectedBytes else {
            throw ImageFetchError.expandFailed(
                "expanded to \(offset) bytes, catalog says \(expectedBytes)")
        }
        try out.truncate(atOffset: UInt64(expectedBytes))
    }
}

// MARK: - Large-file downloader

/// Delegate-driven URLSession download with byte-level progress — the
/// async `URLSession.download(from:)` sugar offers none, and the images
/// are multi-GB. Moves the finished file to `destination` before
/// completing.
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
        // Throttle: a multi-GB pull at 4 KB callbacks would flood the UI.
        // 16 MB ≈ 1% steps on the ~1.5 GB browser image — smooth without
        // being chatty.
        if totalBytesWritten - lastReportedBytes >= 16 * 1024 * 1024
            || totalBytesWritten == totalBytesExpectedToWrite {
            lastReportedBytes = totalBytesWritten
            onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            moveError = ImageFetchError.downloadFailed(http.statusCode)
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
            cont?.resume(throwing: ImageFetchError.downloadFailed(http.statusCode))
        } else {
            cont?.resume()
        }
    }
}
