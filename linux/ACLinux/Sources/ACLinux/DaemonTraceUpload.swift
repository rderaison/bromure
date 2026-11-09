import NIOConcurrencyHelpers
import Foundation

/// The detailed HTTP logs to bromure.io (BACTraceUploader, shared) and the
/// private workspaces kept out of everything sent there, in step with the
/// enrollment and the profiles (macOS: refreshStreamingState): the uploader
/// stands up on the trace store while enrolled and goes, its buffer
/// dropped, on an unenroll; a private-mode workspace's events and logs are
/// never sent.
extension Daemon {
    /// Refreshes run so far (tests).
    static let streamingRefreshCount = NIOLockedValueBox(0)

    // partial: no panes' streaming indicator on a server
    // @port ACAppDelegate.refreshStreamingState() h=e935bc6403fd746e @4237c02e
    @MainActor static func refreshStreamingState(store: TraceStore?) {
        streamingRefreshCount.withLockedValue { $0 += 1 }
        let privateIDs = Set(ProfileStore().loadAll().filter(\.privateMode).map(\.id))
        applyStreamingState(store: store, privateIDs: privateIDs, enrolled: BACEnrollmentStore.load() != nil)
    }

    /// The private set last handed to the emitter and the uploader (tests).
    static let streamingPrivateIDs = NIOLockedValueBox<Set<UUID>>([])

    /// Now, from the daemon: its trace store's uploader and the emitter
    /// updated before the caller goes on (a VM about to boot, a clone just
    /// made).
    // @port-skip linux-only: refreshStreamingState from the daemon's actor
    func refreshStreamingNow() async {
        let store = mitm?.traces.withLockedValue { $0 }
        await MainActor.run { Self.refreshStreamingState(store: store) }
    }

    /// One refresh soon for any number of writes now. Cleared before it
    /// runs, so a write during it queues another.
    // @port-skip linux-only: the funnel's coalescing (macOS: profiles.didSet runs per assignment on the main actor)
    nonisolated func refreshStreamingSoon() {
        let first = streamingRefreshQueued.withLockedValue { q -> Bool in
            defer { q = true }
            return !q
        }
        guard first else { return }
        Task {
            streamingRefreshQueued.withLockedValue { $0 = false }
            await refreshStreamingNow()
        }
    }

    /// refreshStreamingState over given state (testable).
    // @port-skip linux-only: refreshStreamingState's body over given state
    @MainActor static func applyStreamingState(store: TraceStore?, privateIDs: Set<UUID>, enrolled: Bool,
                                               makeUploader: () -> BACTraceUploader = { BACTraceUploader() }) {
        BACEventEmitter.shared.setPrivateProfiles(privateIDs)
        streamingPrivateIDs.withLockedValue { $0 = privateIDs }
        guard let store else { return }
        if enrolled {
            if let up = store.uploader as? BACTraceUploader {
                up.setPrivateProfiles(privateIDs)
            } else if store.uploader == nil {
                let up = makeUploader()
                up.setPrivateProfiles(privateIDs)
                store.uploader = up
            }
        } else if let up = store.uploader as? BACTraceUploader {
            up.shutdown()
            store.uploader = nil
        }
    }
}
