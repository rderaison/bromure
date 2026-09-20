import Foundation
import Testing
@testable import bromure_ac

/// The "Register with …" throwaway VM pins its pane to the raw terminal: the
/// interactive OAuth login (sign-in URL, the CLI's prompts) is exactly what the
/// beautified transcript hides. The lock must win over the user's global
/// preference, ignore later toggles, and never rewrite that global preference.
@Suite("Session pane beautifier lock")
struct SessionPaneBeautifierLockTests {
    private static let key = "ui.beautifiedTranscript"

    @MainActor
    @Test("A locked pane is terminal-only even when the user prefers beautified, and toggles are ignored")
    func lockedPaneStaysTerminal() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: Self.key)
        defer {   // never leave the test's preference behind
            if let original { defaults.set(original, forKey: Self.key) }
            else { defaults.removeObject(forKey: Self.key) }
        }

        // The user's usual preference: beautified.
        defaults.set(true, forKey: Self.key)
        // A headless delegate over a temp dir that is never touched — both
        // inits only store their arguments.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-lock-\(UUID().uuidString)", isDirectory: true)
        let delegate = ACAppDelegate(
            imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp), headless: true)
        let scratch = Profile(name: "Register with Claude", tool: .claude,
                              authMode: .subscription, homeModel: .virtiofs)

        // A fresh pane inherits that preference…
        let pane = SessionPane(profile: scratch, acDelegate: delegate)
        #expect(pane.viewMode == .beautified)

        // …the registration lock forces the terminal…
        pane.beautifierLocked = true
        #expect(pane.viewMode == .terminal)

        // …any attempt to flip it back is ignored while locked…
        pane.setViewMode(.beautified)
        #expect(pane.viewMode == .terminal)

        // …and the app-global default is NOT touched by the lock.
        #expect(defaults.bool(forKey: Self.key) == true)

        // Sanity: an unlocked pane still toggles normally.
        let normal = SessionPane(profile: scratch, acDelegate: delegate)
        normal.setViewMode(.terminal)
        #expect(normal.viewMode == .terminal)
        normal.setViewMode(.beautified)
        #expect(normal.viewMode == .beautified)
    }
}
