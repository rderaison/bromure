import AppKit
import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): the close button reverted a settings window's live
/// firewall edits but kept the window, so reopening that workspace's
/// Settings showed the reverted edits as in force — and its finished live
/// edit dropped every further one. However it closes, the window is now
/// forgotten, and reopening builds a new editor with a new live edit.
@Suite("Settings window: a close forgets the window", .serialized)
@MainActor struct SettingsWindowSessionTests {
    private final class Host {
        var rules: String
        init(_ rules: String) { self.rules = rules }
    }

    /// What the local editor and the fat client's settings windows do: one
    /// open session per workspace, forgotten when it ends.
    @MainActor private final class Owner {
        var open: [UUID: SettingsWindowSession] = [:]
        let host: Host
        init(_ host: Host) { self.host = host }

        func openSettings(_ id: UUID) -> SettingsWindowSession {
            if let s = open[id] { return s }
            let live = FirewallLiveEdit(profileID: id, opening: host.rules, settle: 0,
                                        commit: { [host] t in host.rules = t; return true },
                                        observeChanges: false)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                               styleMask: [.titled, .closable], backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            let s = SettingsWindowSession(window: win, live: live) { [weak self] gone in
                guard let self, self.open[id] === gone else { return }
                self.open[id] = nil
            }
            open[id] = s
            return s
        }
    }

    private let opening = "allow tcp github.com:443\ndefault deny"

    @Test("the close button reverts and forgets: reopening applies edits again")
    func closeButtonForgets() {
        let host = Host(opening), owner = Owner(host), id = UUID()
        let first = owner.openSettings(id)
        first.live?.edited("deny tcp github.com:443\ndefault deny")
        #expect(host.rules.hasPrefix("deny"))
        first.window.close()                         // the red button
        #expect(host.rules == opening)
        #expect(first.hasEnded)
        #expect(owner.open[id] == nil)

        let again = owner.openSettings(id)
        #expect(again !== first)
        #expect(again.live?.restore == opening)      // built from the rules in force
        again.live?.edited("default allow")
        #expect(host.rules == "default allow")       // edits go live again
        again.close()
        #expect(host.rules == opening)
    }

    @Test("a save keeps the edits and still forgets the window; a second close is a no-op")
    func saveThenClose() {
        let host = Host(opening), owner = Owner(host), id = UUID()
        let s = owner.openSettings(id)
        s.live?.edited("default allow")
        s.live?.keep()
        s.close()
        #expect(host.rules == "default allow")
        #expect(owner.open[id] == nil)
        let next = owner.openSettings(id)
        s.window.close()                             // a stale close
        #expect(owner.open[id] === next)             // the newer window stays
        #expect(host.rules == "default allow")
        next.close()
    }
}
