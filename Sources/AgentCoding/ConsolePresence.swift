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
    /// This app's user last touched one of its MIRROR windows (a fat-client
    /// window onto another Bromure). That is console activity for the REMOTE
    /// server — what `idleMillis()` reports to it — never for this app's own
    /// workspaces. Kept apart from `lastLocal` so an app that is both a
    /// server and a client (self-mirror, or a Mac mirroring a peer while it
    /// runs its own VMs) doesn't count mirror clicks as server-console use,
    /// which made the browser route flap with every click and poll.
    private var lastMirror = Date.distantPast

    #if canImport(AppKit)
    /// Whether an event's window belongs to a fat-client mirror (set by the
    /// app at launch; nil = no mirror windows exist in this build).
    @MainActor var isMirrorWindow: ((NSWindow) -> Bool)?
    #endif

    /// Fired (on main) when the preferred console FLIPS local↔remote.
    var onFlip: (@MainActor () -> Void)?

    var remotePreferred: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastRemote > lastLocal
    }

    /// Milliseconds since this app's user last touched a MIRROR window — what
    /// a fat client ships to its server. Clamped so a never-touched mirror
    /// reads as ancient.
    func idleMillis() -> Int {
        #if canImport(AppKit)
        lock.lock(); defer { lock.unlock() }
        return Self.idleMillis(since: lastMirror, now: Date())
        #else
        // No event monitor on iOS — report always-active, which preserves
        // the pre-arbitration behavior (a connected iPad's relay wins).
        return 0
        #endif
    }

    static func idleMillis(since last: Date, now: Date) -> Int {
        guard last > .distantPast else { return Int.max / 2 }
        return max(0, Int(now.timeIntervalSince(last) * 1000))
    }

    func noteLocal() {
        flipAware { lastLocal = Date() }
    }

    /// The user acted in a fat-client mirror window (or a debug verb drove
    /// one). Reported to that mirror's server on its next /state poll.
    func noteMirror() {
        lock.lock(); lastMirror = Date(); lock.unlock()
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
            guard let self else { return e }
            // Local monitors run on the main thread.
            let mirror = MainActor.assumeIsolated { e.window.map { self.isMirrorWindow?($0) == true } ?? false }
            if mirror { self.noteMirror() }
            else { self.noteLocal() }
            return e
        }
    }
    #endif
}

/// One `[dbgbrowser]` line on stderr (teed into bromure-ac.log): where an
/// agent's browser call was routed (server's own browser vs a fat client's
/// relay) and what each side did to surface it. Low volume — once per agent
/// MCP connection and per browser boot request.
func browserRouteLog(_ msg: @autoclosure () -> String) {
    FileHandle.standardError.write(Data("[dbgbrowser] \(msg())\n".utf8))
}
