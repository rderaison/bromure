import Foundation

// How a compromised workspace's mark is resolved: macOS (SessionDisk) and
// the Linux daemon (DaemonCompromise.swift) record and answer the same.

extension SessionDisk {
    /// What the sidebar offers on a workspace marked compromised.
    public enum CompromiseRemedy: String, Sendable {
        /// Wipe its disk, home and saved state now (as "Wipe and Launch"
        /// would), without booting it.
        case wipe
        /// A false alarm: drop the mark, keep everything.
        case clear
    }
}
