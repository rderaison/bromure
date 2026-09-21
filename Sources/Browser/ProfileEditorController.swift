import AppKit
import SandboxEngine
import SwiftUI

/// Owns the profile create / edit / delete windows that used to live
/// inside the launcher's `MainView`. Reached from the tab-bar profile
/// chip, the File menu and AppleScript's `open profile settings`.
@MainActor
final class ProfileEditorController {
    private let state: AppState
    private unowned let delegate: GUIAppDelegate

    private var newProfileWindow: NSWindow?
    private var settingsPanel: NSWindow?
    private var settingsDelegateHelper: SettingsWindowDelegate?

    init(state: AppState, delegate: GUIAppDelegate) {
        self.state = state
        self.delegate = delegate
    }

    // MARK: - New profile

    /// Small name + colour form; on Create the profile is saved and its
    /// settings window opens so the user can tune it before first use.
    func presentNewProfile() {
        if let newProfileWindow, newProfileWindow.isVisible {
            newProfileWindow.makeKeyAndOrderFront(nil)
            return
        }
        // Colours aren't exclusive, but defaulting to one not in use keeps
        // profiles distinguishable without the user thinking about it.
        let taken = Set(state.profileManager.allProfiles.compactMap(\.color))
        let suggested = ProfileColor.allCases.first { !taken.contains($0) } ?? ProfileColor.allCases.first

        let form = NewProfileForm(initialColor: suggested) { [weak self] name, color in
            guard let self else { return }
            var settings = ProfileSettings()
            settings.persistent = true
            settings.enableClipboardSharing = true
            settings.enableLinkSender = true
            settings.keychainPasskeys = true
            settings.keychainPasswords = true
            let profile = self.state.profileManager.createProfile(
                name: name, color: color, settings: settings)
            self.state.selectedProfileID = profile.id
            self.state.profileVersion += 1
            self.newProfileWindow?.close()
            self.newProfileWindow = nil
            self.presentSettings(for: profile)
        } onCancel: { [weak self] in
            self?.newProfileWindow?.close()
            self?.newProfileWindow = nil
        }

        let hosting = NSHostingView(rootView: form)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.title = NSLocalizedString("New Profile", comment: "")
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        newProfileWindow = window
    }

    // MARK: - Edit

    func presentSettings(forProfileID id: UUID, category: String? = nil) {
        guard let profile = state.profileManager.profile(withID: id) else { return }
        presentSettings(for: profile, category: category)
    }

    func presentSettings(for profile: Profile, category: String? = nil) {
        settingsPanel?.close()

        let originalProfile = profile
        let initialCat: SettingsCategory
        switch category {
        case "general": initialCat = .general
        case "performance": initialCat = .performance
        case "media": initialCat = .media
        case "fileTransfer": initialCat = .fileTransfer
        case "hostIsolation": initialCat = .hostIsolation
        case "privacy": initialCat = .privacy
        case "extensions": initialCat = .extensions
        case "network": initialCat = .network
        case "vpnAds": initialCat = .vpnAds
        case "enterprise": initialCat = .enterprise
        case "advanced": initialCat = .advanced
        default: initialCat = .general
        }

        let hasActiveSession = delegate.sessions.contains { $0.profile?.id == profile.id }
        let isManaged = state.profileManager.isManaged(profile.id)
        let settingsView = ProfileSettingsView(
            draft: profile,
            profileDiskExists: ProfileDisk.diskExists(
                at: state.profileManager.profileDiskURL(for: profile.id)
            ),
            hasActiveSession: hasActiveSession,
            isReadOnly: isManaged,
            onDeleteProfileDisk: { [state] in
                let diskURL = state.profileManager.profileDiskURL(for: profile.id)
                try? FileManager.default.removeItem(at: diskURL)
            },
            onSave: { [weak self] updated in
                guard let self else { return }
                let hasChanges = updated.settings != originalProfile.settings
                self.state.profileManager.updateProfile(updated)
                self.state.profileVersion += 1
                self.closeSettingsPanel()
                if hasChanges {
                    self.offerSessionRestart(for: updated)
                }
            },
            onCancel: { [weak self] in
                self?.closeSettingsPanel()
            },
            onShowWarpEULA: { [weak delegate] onAccepted in
                delegate?.showWarpEULA(onAccepted: onAccepted)
            },
            onShowPhishingConsent: { [weak delegate] onAccepted in
                delegate?.showPhishingConsent(onAccepted: onAccepted)
            },
            initialCategory: initialCat
        )

        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.setFrameSize(NSSize(width: 680, height: 560))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        let titleFormat = isManaged
            ? NSLocalizedString("Managed Profile \u{2014} %@", comment: "")
            : NSLocalizedString("Profile Settings \u{2014} %@", comment: "")
        window.title = String(format: titleFormat, profile.name)
        window.isReleasedWhenClosed = false
        window.center()

        let delegateHelper = SettingsWindowDelegate(
            originalProfile: originalProfile,
            onCancel: { [weak self] in
                self?.settingsPanel = nil
                self?.settingsDelegateHelper = nil
            }
        )
        window.delegate = delegateHelper
        settingsDelegateHelper = delegateHelper

        window.makeKeyAndOrderFront(nil)
        settingsPanel = window
    }

    private func closeSettingsPanel() {
        settingsPanel?.close()
        settingsPanel = nil
        settingsDelegateHelper = nil
    }

    /// Offer to restart active sessions for a profile after settings change.
    private func offerSessionRestart(for profile: Profile) {
        let activeSessions = delegate.sessions.filter { $0.profile?.id == profile.id }
        guard !activeSessions.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Restart session?", comment: "")
        let count = activeSessions.count
        alert.informativeText = count == 1
            ? NSLocalizedString("Settings have changed. Restart the browser session to apply them?", comment: "")
            : String(format: NSLocalizedString("Settings have changed. Restart %lld browser sessions to apply them?", comment: ""), count)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Restart", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { @MainActor [delegate] in
                for session in activeSessions {
                    await delegate.restartSession(session, profile: profile)
                }
            }
        }
    }

    // MARK: - Delete

    /// Confirm, then delete. A profile with an open window can't go: its
    /// VM holds the disk, so the user closes the window first.
    func confirmDelete(profileID id: UUID) {
        guard let profile = state.profileManager.profile(withID: id),
              !state.profileManager.isManaged(id) else { return }

        let alert = NSAlert()
        if delegate.sessions.contains(where: { $0.profile?.id == id && !$0.isClosing }) {
            alert.messageText = String(format: NSLocalizedString("\u{201C}%@\u{201D} is open", comment: "Delete-profile refusal title"), profile.name)
            alert.informativeText = NSLocalizedString("Close its window before deleting the profile.", comment: "")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
            return
        }

        alert.messageText = String(format: NSLocalizedString("Delete \u{201C}%@\u{201D}?", comment: "Delete-profile confirmation title"), profile.name)
        alert.informativeText = profile.isPersistent
            ? NSLocalizedString("This will permanently delete the profile and all its saved browsing data.", comment: "")
            : NSLocalizedString("This will delete the profile.", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        state.profileManager.deleteProfile(id: id)
        if state.selectedProfileID == id {
            state.selectedProfileID = state.profileManager.allProfiles.first?.id
        }
        state.profileVersion += 1
    }
}

// MARK: - New profile form

private struct NewProfileForm: View {
    @State private var name = ""
    @State private var color: ProfileColor?
    let onCreate: (String, ProfileColor?) -> Void
    let onCancel: () -> Void

    init(initialColor: ProfileColor?,
         onCreate: @escaping (String, ProfileColor?) -> Void,
         onCancel: @escaping () -> Void) {
        _color = State(initialValue: initialColor)
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 16) {
            TextField(NSLocalizedString("Profile Name", comment: ""), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { if !trimmed.isEmpty { onCreate(trimmed, color) } }

            Picker(NSLocalizedString("Color", comment: ""), selection: $color) {
                Text("None").tag(ProfileColor?.none)
                Divider()
                ForEach(ProfileColor.allCases, id: \.self) { c in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ProfileSettingsView.swiftUIColor(for: c))
                            .frame(width: 10, height: 10)
                        Text(LocalizedStringKey(c.label))
                    }
                    .tag(Optional(c))
                }
            }
            .frame(width: 240)

            HStack {
                Button(NSLocalizedString("Cancel", comment: "")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Create", comment: "")) { onCreate(trimmed, color) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(24)
    }
}

// MARK: - Settings Window Delegate

/// Intercepts close to treat as cancel.
final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    let originalProfile: Profile
    let onCancel: () -> Void

    init(originalProfile: Profile, onCancel: @escaping () -> Void) {
        self.originalProfile = originalProfile
        self.onCancel = onCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The ProfileSettingsView's draft is discarded by onCancel.
        onCancel()
        return true
    }
}
