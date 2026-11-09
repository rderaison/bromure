import Foundation

/// The detailed HTTP logs to bromure.io (BACTraceUploader, shared) and the
/// private workspaces kept out of everything sent there, in step with the
/// enrollment and the profiles (macOS: refreshStreamingState): the uploader
/// stands up on the trace store while enrolled and goes, its buffer
/// dropped, on an unenroll; a private-mode workspace's events and logs are
/// never sent.
extension Daemon {
    // partial: no panes' streaming indicator on a server
    // @port ACAppDelegate.refreshStreamingState() h=e935bc6403fd746e @4237c02e
    @MainActor static func refreshStreamingState(store: TraceStore?) {
        let privateIDs = Set(ProfileStore().loadAll().filter(\.privateMode).map(\.id))
        applyStreamingState(store: store, privateIDs: privateIDs, enrolled: BACEnrollmentStore.load() != nil)
    }

    /// refreshStreamingState over given state (testable).
    // @port-skip linux-only: refreshStreamingState's body over given state
    @MainActor static func applyStreamingState(store: TraceStore?, privateIDs: Set<UUID>, enrolled: Bool,
                                               makeUploader: () -> BACTraceUploader = { BACTraceUploader() }) {
        BACEventEmitter.shared.setPrivateProfiles(privateIDs)
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
