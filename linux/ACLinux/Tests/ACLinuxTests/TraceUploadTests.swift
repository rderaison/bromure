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
}
