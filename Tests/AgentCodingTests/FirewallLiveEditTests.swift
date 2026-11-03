import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

/// Issue #48: firewall edits waited for Save (which closed the window), and a
/// timed rule extended in the table still expired on the saved clock. The
/// editor now puts each valid edit in force at once, and closing it without
/// saving puts the opening rules back.
@Suite("Firewall editor: edits apply live, Cancel restores", .serialized)
@MainActor struct FirewallLiveEditTests {
    private final class Host {
        var rules: String
        var commits: [String] = []
        init(_ rules: String) { self.rules = rules }
        func commit(_ text: String) -> Bool {
            guard text != rules else { return false }   // as commitFirewallRules: unchanged is no commit
            rules = text
            commits.append(text)
            return true
        }
    }

    private func session(_ host: Host, settle: TimeInterval = 0) -> FirewallLiveEdit {
        FirewallLiveEdit(profileID: UUID(), opening: host.rules, settle: settle,
                         commit: { host.commit($0) }, observeChanges: false)
    }

    private let opening = "allow tcp github.com:443\ndefault deny"

    @Test("a valid edit is in force at once; a half-typed one waits")
    func editsApplyLive() {
        let host = Host(opening)
        let live = session(host)
        live.edited("allow tcp github.com:443\nallow tcp pypi.org:443\ndefault deny")
        #expect(host.rules.contains("pypi.org"))
        live.edited("allow tcp pypi.org:99999999\ndefault deny")   // doesn't parse
        #expect(host.commits.count == 1)
    }

    @Test("extending a timed rule moves its expiry now, not on Save")
    func extendedTimerIsInForce() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = Int(now.timeIntervalSince1970) + 60, later = Int(now.timeIntervalSince1970) + 300
        let host = Host("allow tcp github.com:443 #@until=\(soon)\ndefault deny")
        let live = session(host)
        live.edited("allow tcp github.com:443 #@until=\(later)\ndefault deny")
        // What the expiry timer reads is the extended clock.
        let inForce = try EgressPolicy.parse(host.rules)
        #expect(inForce.nextExpiry == Date(timeIntervalSince1970: TimeInterval(later)))
    }

    @Test("closing without saving puts the opening rules back; a save keeps the edits")
    func cancelRestores() {
        let host = Host(opening)
        let live = session(host)
        live.edited("allow tcp github.com:443\nallow tcp evil.example:443\ndefault deny")
        live.edited("default allow")
        live.revert()
        #expect(host.rules == opening)

        let saved = Host(opening)
        let kept = session(saved)
        kept.edited("default allow")
        kept.keep()
        kept.revert()                                   // the close after a save
        #expect(saved.rules == "default allow")

        let untouched = Host(opening)
        session(untouched).revert()                     // nothing edited: nothing written
        #expect(untouched.commits.isEmpty)
    }

    @Test("a change made elsewhere meanwhile survives the cancel; an expired rule stays off")
    func cancelKeepsOtherChanges() {
        let host = Host(opening)
        let live = session(host)
        live.edited("default allow")
        // A Security Timeline quick action blocks a host meanwhile.
        let before = opening
        let after = "deny tcp tracker.example\nallow tcp github.com:443\ndefault deny"
        live.changedElsewhere(previous: before, new: after)
        live.revert()
        #expect(host.rules.contains("deny tcp tracker.example"))
        #expect(host.rules.contains("default deny"))      // the editor's own edit is gone

        // A timed rule that ran out while the editor was open isn't revived.
        let now = Date(timeIntervalSince1970: 2_000_000)
        let timed = "allow tcp github.com:443 #@until=\(Int(now.timeIntervalSince1970) - 10)\ndefault deny"
        let h2 = Host(timed)
        let l2 = session(h2)
        l2.edited("default allow")
        l2.revert(now: now)
        #expect(h2.rules.hasPrefix("#@off allow tcp github.com:443"))
    }

    @Test("its own commits, announced late, aren't taken for changes made elsewhere")
    func ownNoticesIgnored() {
        let host = Host(opening)
        let live = session(host)
        let a = "allow tcp github.com:443\nallow tcp a.example:443\ndefault deny"
        let b = "allow tcp github.com:443\nallow tcp b.example:443\ndefault deny"
        live.edited(a)
        live.edited(b)
        live.changedElsewhere(previous: opening, new: a)   // A's notice, after B
        live.changedElsewhere(previous: a, new: b)
        live.revert()
        #expect(host.rules == opening)
    }

    @Test("once Save is pressed nothing more goes live; a close meanwhile waits for the save's outcome")
    func saveInFlight() {
        // Saved: the edit still settling is dropped (the document carries
        // it), a later edit isn't sent, and the close doesn't revert.
        let host = Host(opening)
        let live = session(host, settle: 10)
        live.edited("default allow")                    // still settling
        live.beginSave()
        live.edited("default deny")
        live.revert()                                   // the close button, mid-save
        #expect(host.commits.isEmpty)
        live.keep()                                     // saved: the document is the editor at the click
        #expect(host.commits.isEmpty)

        // Failed: the close that came meanwhile reverts now.
        let h2 = Host(opening)
        let l2 = session(h2)
        l2.edited("default allow")
        l2.beginSave()
        l2.revert()
        #expect(h2.rules == "default allow")            // not yet: the save may still land
        l2.saveFailed()
        #expect(h2.rules == opening)

        // Failed with the window still open: edits go live again.
        let h3 = Host(opening)
        let l3 = session(h3)
        l3.beginSave()
        l3.saveFailed()
        l3.edited("default allow")
        #expect(h3.rules == "default allow")
    }

    @Test("a save that fails with the editor open puts the table's rules in force, after the settle")
    func failedSaveAppliesTable() async throws {
        let host = Host(opening)
        let live = session(host, settle: 0.1)
        live.beginSave()
        live.edited("allow tcp e:443\ndefault deny")       // mid-typing during the save
        live.edited("allow tcp example.com:443\ndefault deny")
        #expect(host.commits.isEmpty)
        live.saveFailed()
        #expect(host.commits.isEmpty)                    // not frozen mid-field
        #expect(!live.isSaving)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(host.commits == ["allow tcp example.com:443\ndefault deny"])
    }

    @Test("typing settles before it's put in force: only the last text lands")
    func typingSettles() async throws {
        let host = Host(opening)
        let live = session(host, settle: 0.1)
        for h in ["p", "py", "pyp", "pypi.org"] {
            live.edited("allow tcp \(h):443\ndefault deny")
        }
        #expect(host.commits.isEmpty)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(host.commits == ["allow tcp pypi.org:443\ndefault deny"])
        // Closed before a pending edit settles: it never lands.
        live.edited("default allow")
        live.revert()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(host.rules == opening)
    }
}
