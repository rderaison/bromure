import Foundation
import Testing
@testable import ACLinux

/// The HTTP-log uploader in step with the enrollment (macOS:
/// refreshStreamingState): stood up while enrolled, kept (its private set
/// updated) on later changes, gone on an unenroll.
@Suite("Trace upload lifecycle")
@MainActor
struct TraceUploadTests {
    @Test func theUploaderFollowsTheEnrollment() throws {
        let d = try shortTempDir()
        let store = TraceStore(rootDir: URL(fileURLWithPath: d, isDirectory: true))
        var made = 0
        let make = { () -> BACTraceUploader in made += 1; return BACTraceUploader() }
        Daemon.applyStreamingState(store: store, privateIDs: [], enrolled: false, makeUploader: make)
        #expect(store.uploader == nil && made == 0, "not enrolled: none")
        Daemon.applyStreamingState(store: store, privateIDs: [UUID()], enrolled: true, makeUploader: make)
        let first = try #require(store.uploader as? BACTraceUploader)
        Daemon.applyStreamingState(store: store, privateIDs: [UUID()], enrolled: true, makeUploader: make)
        #expect(store.uploader as? BACTraceUploader === first && made == 1, "kept across changes")
        Daemon.applyStreamingState(store: store, privateIDs: [], enrolled: false, makeUploader: make)
        #expect(store.uploader == nil, "an unenroll takes it down")
    }

    /// A workspace turned private: what the uploader had buffered for it goes
    /// (the shared purge), through the daemon's refresh.
    @Test func turningPrivatePurgesWhatWasBuffered() throws {
        let d = try shortTempDir()
        let store = TraceStore(rootDir: URL(fileURLWithPath: d, isDirectory: true))
        let up = BACTraceUploader(endpoint: URL(string: "https://upload.invalid/ac-http-ingest")!)
        defer { up.shutdown() }
        Daemon.applyStreamingState(store: store, privateIDs: [], enrolled: true, makeUploader: { up })
        let mine = UUID(), other = UUID()
        func rec(_ p: UUID) -> TraceRecord {
            TraceRecord(sessionID: p, profileID: p, timestamp: Date(), host: "example.com", port: 443,
                        method: "GET", path: "/", statusCode: 200, requestBytes: 1,
                        responseBytes: 1, latencyMs: 1, swaps: [], leaks: [], bodyStored: false)
        }
        up.upload(rec(mine), requestBody: nil, responseBody: nil)
        up.upload(rec(other), requestBody: nil, responseBody: nil)
        Daemon.applyStreamingState(store: store, privateIDs: [mine], enrolled: true, makeUploader: { up })
        #expect(up.queuedProfileIDs() == [other])
    }

    /// A burst of profile writes makes one refresh (not a full store read on
    /// the main actor per write).
    @Test func aBurstOfWritesRefreshesOnce() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let before = Daemon.streamingRefreshCount.withLockedValue { $0 }
        for _ in 0..<50 { d.refreshStreamingSoon() }
        for _ in 0..<100 where Daemon.streamingRefreshCount.withLockedValue({ $0 }) == before { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        let n = Daemon.streamingRefreshCount.withLockedValue { $0 } - before
        // Other suites refresh too (a VM start): a bound, not an exact count.
        #expect(n >= 1 && n < 10, "\(n) refreshes for 50 writes")
        await d.shutdown()
    }
}

