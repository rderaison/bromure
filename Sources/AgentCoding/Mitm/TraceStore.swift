import Foundation
import Observation
import CryptoKit

/// Process-lifetime sink for `TraceRecord`s emitted by the MITM
/// proxy. Two layers:
///
///   1. **In-memory ring** — last `ringCapacity` records, available
///      to the Trace Inspector for live tail. Sorted newest first.
///   2. **On-disk JSONL** — append-only `traces/YYYY-MM-DD/<sessionID>.jsonl`
///      per session. Bodies (when captured) live next to the JSONL
///      under `traces/YYYY-MM-DD/<sessionID>/<recordID>.{req,res}.enc`,
///      AES-GCM-sealed with the SecretsVault master key.
///
/// All disk writes happen on a serial dispatch queue so the proxy's
/// hot path stays non-blocking. `record(_:)` returns immediately;
/// the eventual file write may lag by a frame or two on heavy load.
///
/// Caps:
///   - per-session bodies total ≤ 100 MB (drops oldest body files)
///   - whole `traces/` dir ≤ 5 GB (drops oldest day directories)
///
/// Cleanup runs lazily on every Nth append.
@MainActor
@Observable
public final class TraceStore {
    /// Newest first. Capped at `ringCapacity`. SwiftUI binds to this.
    public private(set) var recent: [TraceRecord] = []
    public var ringCapacity: Int = 5000

    /// Optional sink the engine plugs in to ship traces somewhere
    /// else (analytics.bromure.io). Called for every record after the
    /// disk write completes. nil = no streaming.
    public var uploader: TraceUploader?

    private let rootDir: URL
    private let queue = DispatchQueue(label: "io.bromure.ac.trace-store",
                                      qos: .utility)
    /// Mutable bookkeeping state lifted out of the @Observable class
    /// so it can be marked Sendable and accessed from the serial
    /// `queue` without tripping the macro's isolation rules.
    /// All access goes through the queue, so unchecked is safe.
    fileprivate final class State: @unchecked Sendable {
        var appendsSinceLastCleanup = 0
        var bodyBytesPerSession: [UUID: Int] = [:]
    }
    fileprivate let state = State()
    nonisolated private static let perSessionBodyCap: Int = 100 * 1024 * 1024
    nonisolated private static let totalDirCap: Int       = 5 * 1024 * 1024 * 1024
    nonisolated private static let cleanupInterval = 200

    public init(rootDir: URL? = nil) {
        if let rootDir {
            self.rootDir = rootDir
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("BromureAC", isDirectory: true)
            self.rootDir = support.appendingPathComponent("traces", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.rootDir,
                                                 withIntermediateDirectories: true)
    }

    // MARK: - Recording (called from the proxy)

    /// Add a record + persist. Body data is optional — pass nil when
    /// the level/host doesn't authorize body capture.
    public func record(_ record: TraceRecord,
                       requestBody: Data? = nil,
                       responseBody: Data? = nil) {
        // In-memory ring update — synchronous because SwiftUI needs
        // the change reflected this run loop.
        recent.insert(record, at: 0)
        if recent.count > ringCapacity {
            recent.removeLast(recent.count - ringCapacity)
        }

        // Disk write — off the main thread.
        let root = rootDir
        queue.async { [weak self] in
            Self.appendJSONL(record: record, root: root)
            if let req = requestBody, !req.isEmpty {
                Self.writeBody(record: record, kind: .request,
                                data: req, root: root)
            }
            if let res = responseBody, !res.isEmpty {
                Self.writeBody(record: record, kind: .response,
                                data: res, root: root)
            }
            self?.queue_updateBodyAccount(
                sessionID: record.sessionID,
                added: (requestBody?.count ?? 0) + (responseBody?.count ?? 0))
            self?.queue_periodicCleanup()
        }

        // Streaming hook — fire-and-forget.
        uploader?.upload(record)
    }

    // MARK: - Reading (called from UI)

    public func reload() {
        // Pull recent records from disk if the in-memory ring was cold
        // (e.g. fresh app launch). Reads only today and yesterday's
        // dirs so cold-start is fast even with a year of traces on disk.
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: rootDir,
                                                     includingPropertiesForKeys: nil) else { return }
        let dayDirs = dirs.filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(2)
        var loaded: [TraceRecord] = []
        for dir in dayDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: nil) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let decoder = JSONDecoder.iso8601()
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    if let bytes = line.data(using: .utf8),
                       let rec = try? decoder.decode(TraceRecord.self, from: bytes) {
                        loaded.append(rec)
                        if loaded.count >= ringCapacity { break }
                    }
                }
                if loaded.count >= ringCapacity { break }
            }
            if loaded.count >= ringCapacity { break }
        }
        loaded.sort { $0.timestamp > $1.timestamp }
        recent = Array(loaded.prefix(ringCapacity))
    }

    /// Decrypt and return the request body for a record, if it was
    /// captured. Returns nil if the body wasn't stored or decryption
    /// fails (e.g. master key was rotated since the record was written).
    public nonisolated func loadBody(for record: TraceRecord, kind: BodyKind) -> Data? {
        guard record.bodyStored else { return nil }
        let dayDir = rootDir.appendingPathComponent(Self.dayString(for: record.timestamp),
                                                    isDirectory: true)
        let sessionDir = dayDir.appendingPathComponent(record.sessionID.uuidString,
                                                       isDirectory: true)
        let url = sessionDir.appendingPathComponent("\(record.id.uuidString).\(kind.fileSuffix).enc")
        guard let blob = try? Data(contentsOf: url) else { return nil }
        return try? SecretsVault.decrypt(blob)
    }

    public enum BodyKind: String, Sendable {
        case request, response
        var fileSuffix: String { rawValue == "request" ? "req" : "res" }
    }

    // MARK: - Disk plumbing (queue-isolated)

    nonisolated private static func dayString(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    nonisolated private static func sessionJSONLURL(for record: TraceRecord, root: URL) -> URL {
        let dayDir = root.appendingPathComponent(dayString(for: record.timestamp),
                                                 isDirectory: true)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        return dayDir.appendingPathComponent("\(record.sessionID.uuidString).jsonl")
    }

    nonisolated private static func appendJSONL(record: TraceRecord, root: URL) {
        let url = sessionJSONLURL(for: record, root: root)
        let encoder = JSONEncoder.iso8601()
        // No pretty-printing in JSONL — one record per line.
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0a)  // newline
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated private static func writeBody(record: TraceRecord, kind: BodyKind,
                                                data: Data, root: URL) {
        let dayDir = root.appendingPathComponent(dayString(for: record.timestamp),
                                                 isDirectory: true)
        let sessionDir = dayDir.appendingPathComponent(record.sessionID.uuidString,
                                                       isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir,
                                                  withIntermediateDirectories: true)
        let url = sessionDir.appendingPathComponent("\(record.id.uuidString).\(kind.fileSuffix).enc")
        guard let sealed = try? SecretsVault.encrypt(data) else { return }
        try? sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path)
    }

    // MARK: - Caps

    private nonisolated func queue_updateBodyAccount(sessionID: UUID, added: Int) {
        guard added > 0 else { return }
        let total = (state.bodyBytesPerSession[sessionID] ?? 0) + added
        state.bodyBytesPerSession[sessionID] = total
        if total > Self.perSessionBodyCap {
            queue_evictOldestBodiesInSession(sessionID, currentTotal: total)
        }
    }

    /// Drop oldest body files in this session until we're back under
    /// the per-session cap. Records keep their JSONL line — just the
    /// .enc body files disappear.
    private nonisolated func queue_evictOldestBodiesInSession(_ sessionID: UUID,
                                                              currentTotal: Int) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: rootDir,
                                                     includingPropertiesForKeys: nil) else { return }
        var sessionDir: URL?
        for dayDir in dirs where dayDir.hasDirectoryPath {
            let candidate = dayDir.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { sessionDir = candidate; break }
        }
        guard let dir = sessionDir,
              let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return }
        let sorted = files.compactMap { url -> (URL, Date, Int)? in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = currentTotal
        for (url, _, size) in sorted where total > Self.perSessionBodyCap {
            try? fm.removeItem(at: url)
            total -= size
        }
        state.bodyBytesPerSession[sessionID] = total
    }

    private nonisolated func queue_periodicCleanup() {
        // Take the lock by swapping into a local then resetting on
        // main; queue is already serial so simple integer increment is
        // safe via nonisolated unsafe.
        let count = appendsSinceCleanup_increment()
        guard count >= Self.cleanupInterval else { return }
        appendsSinceCleanup_reset()
        evictOldestDaysIfOverTotalCap()
    }

    private nonisolated func appendsSinceCleanup_increment() -> Int {
        // Accessing main-actor state from this queue requires an
        // unsafe access pattern. We funnel reads/writes through a
        // single serial queue (this very queue) so there's no race.
        return Self.unsafeIncrementAppendCounter(self)
    }
    private nonisolated func appendsSinceCleanup_reset() {
        Self.unsafeResetAppendCounter(self)
    }

    private nonisolated func evictOldestDaysIfOverTotalCap() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: rootDir,
                                                     includingPropertiesForKeys: nil) else { return }
        let dayDirs = dirs.filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }  // oldest first
        var total = dayDirs.reduce(0) { acc, dir in
            acc + Self.directorySize(at: dir)
        }
        var idx = 0
        while total > Self.totalDirCap, idx < dayDirs.count {
            let dir = dayDirs[idx]
            let size = Self.directorySize(at: dir)
            try? fm.removeItem(at: dir)
            total -= size
            idx += 1
        }
    }

    nonisolated private static func directorySize(at url: URL) -> Int {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: url,
                                     includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                     options: [],
                                     errorHandler: nil) else { return 0 }
        var total = 0
        for case let u as URL in it {
            if let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
               let n = v.totalFileAllocatedSize {
                total += n
            }
        }
        return total
    }

    // unsafe back-channel for the queue-only counter
    nonisolated fileprivate static func unsafeIncrementAppendCounter(_ store: TraceStore) -> Int {
        store.state.appendsSinceLastCleanup += 1
        return store.state.appendsSinceLastCleanup
    }
    nonisolated fileprivate static func unsafeResetAppendCounter(_ store: TraceStore) {
        store.state.appendsSinceLastCleanup = 0
    }
}

/// Plug-in interface for shipping records to a remote sink. The
/// engine optionally injects an implementation that POSTs to
/// analytics.bromure.io (TBD, not implemented yet).
public protocol TraceUploader: Sendable {
    func upload(_ record: TraceRecord)
}

// MARK: - JSON convenience

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
