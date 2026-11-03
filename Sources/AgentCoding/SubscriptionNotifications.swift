import Foundation

extension Notification.Name {
    /// Posted after a subscription credential is registered or forgotten, so
    /// open editors re-read their per-tool registration status. Posted by the
    /// subscription stores and the mac registration coordinator; declared in
    /// its own file so the stores (macOS, the Linux daemon) and the editor
    /// observing it (macOS, iOS) all compile it.
    static let bromureSubscriptionStoresChanged =
        Notification.Name("bromureSubscriptionStoresChanged")
}
