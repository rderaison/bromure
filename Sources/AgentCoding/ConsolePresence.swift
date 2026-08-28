import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Who used a console last — the arbiter for where agent-initiated browser
/// activity lands when BOTH the server's own window and a fat client are
/// alive for a workspace. The server tracks its local input via an app-level
/// event monitor; each fat client reports its own idle time on every /state
/// poll (`X-Bromure-Console-Idle-Ms`, from ITS monitor). The browser-MCP
/// vsock bridge consults `remotePreferred` per guest connection, and `onFlip`
/// lets the app re-route live streams the moment the user changes seats —
/// use the server, walk to the client, come back: the browser follows.
final class ConsolePresence: @unchecked Sendable {
    static let shared = ConsolePresence()
    init() {}

    private let lock = NSLock()
    private var lastLocal = Date.distantPast
    private var lastRemote = Date.distantPast

    /// Fired (on main) when the preferred console FLIPS local↔remote.
    var onFlip: (@MainActor () -> Void)?

    var remotePreferred: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastRemote > lastLocal
    }

    /// Milliseconds since this app's user last touched it — what a fat client
    /// ships to its server. Clamped so a never-touched app reads as ancient.
    func idleMillis() -> Int {
        #if canImport(AppKit)
        lock.lock(); defer { lock.unlock() }
        guard lastLocal > .distantPast else { return Int.max / 2 }
        return max(0, Int(Date().timeIntervalSince(lastLocal) * 1000))
        #else
        // No event monitor on iOS — report always-active, which preserves
        // the pre-arbitration behavior (a connected iPad's relay wins).
        return 0
        #endif
    }

    func noteLocal() {
        flipAware { lastLocal = Date() }
    }

    /// A fat client reported activity `idleMs` ago (poll-interval stale at
    /// worst). Monotonic: an older report never rewinds the newest.
    func noteRemote(idleMs: Int) {
        let t = Date().addingTimeInterval(-Double(max(0, idleMs)) / 1000)
        flipAware { if t > lastRemote { lastRemote = t } }
    }

    private func flipAware(_ mutate: () -> Void) {
        lock.lock()
        let was = lastRemote > lastLocal
        mutate()
        let now = lastRemote > lastLocal
        lock.unlock()
        if was != now, let onFlip {
            DispatchQueue.main.async { MainActor.assumeIsolated { onFlip() } }
        }
    }

    #if canImport(AppKit)
    /// App-level monitor: any keystroke/click/scroll in THIS app = the user
    /// is at this console. Install once at launch.
    @MainActor
    func installLocalMonitor() {
        NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] e in
            self?.noteLocal()
            return e
        }
    }
    #endif
}
