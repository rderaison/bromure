import Foundation
import NIOConcurrencyHelpers

/// The daemon's defaults (`$XDG_CONFIG_HOME/bromure-ac.plist`) written out.
/// swift-corelibs-foundation keeps a UserDefaults write in memory until
/// `synchronize()`: no timer, no flush at exit (macOS's cfprefsd persists
/// each write). Without this every restart forgot what the daemon and the
/// shared code had saved (the workspace subnet's choice among them: a
/// restart moved the workspaces to another subnet under suspended guests).
/// A flush with nothing changed is free (it writes nothing).
extension Daemon {
    static let defaultsFlusher = NIOLockedValueBox<Task<Void, Never>?>(nil)

    /// Writes out what changed since the last flush.
    // @port-skip linux-only: corelibs UserDefaults persistence (macOS: cfprefsd)
    static func flushDefaults() {
        UserDefaults.standard.synchronize()
    }

    /// A flush every 2 s for the process's life: the shared code's writes
    /// (settings, governance, tasks) reach the disk without each saying so.
    /// Once per process; not in a test run (its defaults are the test
    /// runner's).
    // @port-skip linux-only: corelibs UserDefaults persistence (macOS: cfprefsd)
    static func startDefaultsFlusher() {
        guard !isTestRun() else { return }
        defaultsFlusher.withLockedValue { task in
            guard task == nil else { return }
            task = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    flushDefaults()
                }
            }
        }
    }
}
