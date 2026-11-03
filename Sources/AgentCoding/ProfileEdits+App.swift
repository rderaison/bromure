import Foundation

/// The macOS app's workspace saves: its proxy's salt, and what follows a
/// save on this Mac (the sidebar, the boot launch agent, the streaming
/// toolbar, a browser whose boot settings changed).
extension ACAppDelegate: ProfileEditHost {
    var fakeTokenSalt: Data? { mitmEngine?.fakeTokenSalt }

    func profilesDidChange(saved profile: Profile?, editing: Profile?) {
        refreshSidebar()
        guard let profile else { return }
        reconcileBootLaunchAgent()   // a saved bootAtStartup change may flip the plist
        // The privateMode toggle and enrollment-gated streaming flag both flow
        // off `profiles`; resync the running session toolbars now so a flip from
        // public → private (or back) doesn't wait for the next launch.
        refreshStreamingState()
        // The stay-signed-in persistence setting only applies at browser
        // boot (WorkspaceBrowserController captures it at creation) —
        // recreate this workspace's browser now so the flip takes effect
        // immediately instead of on the next teardown. Runs after the
        // `profiles` refresh above so the new controller reads the saved
        // value.
        if let original = editing, original.browserBootSettingsDiffer(from: profile) {
            unifiedWindow?.rebootBrowser(for: profile.id)
        }
    }

    /// The notes rules (ProfileNotes), by their old names.
    nonisolated static func dropSupersededComments(_ doc: inout [String: Any], stored: String,
                                                   ifStill base: String?) -> Bool {
        ProfileNotes.dropSupersededComments(&doc, stored: stored, ifStill: base)
    }

    nonisolated static func notesStill(_ stored: String, _ base: String) -> Bool {
        ProfileNotes.notesStill(stored, base)
    }
}
