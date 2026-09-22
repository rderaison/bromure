import SwiftUI

/// A remote host the Preferences window can target (an open mirror window).
struct PreferencesRemoteHost: Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// A remote's preferences template as fetched over its control tunnel:
/// the (secret-blanked) profile plus the server-computed credential list
/// the Guardrails pane needs, since blanked secrets hide their rows.
struct RemotePreferences {
    let profile: Profile
    let credentialRefs: [CredentialRef]?
}

/// Content of Bromure → Preferences…. With remote mirror windows open, a
/// picker at the top chooses whose defaults the editor below edits — this
/// Mac's, or a remote server's (fetched live over its tunnel). Each target
/// gets a fresh editor (`.id`), so switching never carries a half-edited
/// draft from one machine into another's document.
struct PreferencesWindowView: View {
    let hosts: [PreferencesRemoteHost]
    @State private var target: ACAppDelegate.PreferencesTarget
    let makeLocalEditor: () -> AnyView
    let loadRemote: (UUID) async throws -> RemotePreferences
    let makeRemoteEditor: (UUID, RemotePreferences) -> AnyView
    let onTargetChange: (ACAppDelegate.PreferencesTarget) -> Void

    @State private var remote: RemotePreferences?
    @State private var loadError: String?

    init(hosts: [PreferencesRemoteHost],
         initialTarget: ACAppDelegate.PreferencesTarget,
         makeLocalEditor: @escaping () -> AnyView,
         loadRemote: @escaping (UUID) async throws -> RemotePreferences,
         makeRemoteEditor: @escaping (UUID, RemotePreferences) -> AnyView,
         onTargetChange: @escaping (ACAppDelegate.PreferencesTarget) -> Void) {
        self.hosts = hosts
        // A remote that has no mirror window anymore can't be edited — fall
        // back to this Mac rather than showing a picker with no such entry.
        let resolved: ACAppDelegate.PreferencesTarget
        if case .remote(let id) = initialTarget, !hosts.contains(where: { $0.id == id }) {
            resolved = .local
        } else {
            resolved = initialTarget
        }
        _target = State(initialValue: resolved)
        self.makeLocalEditor = makeLocalEditor
        self.loadRemote = loadRemote
        self.makeRemoteEditor = makeRemoteEditor
        self.onTargetChange = onTargetChange
    }

    var body: some View {
        VStack(spacing: 0) {
            if !hosts.isEmpty {
                HStack(spacing: 8) {
                    Text(NSLocalizedString("Settings for:",
                                           comment: "Preferences window: label of the local/remote target picker"))
                    Picker("", selection: $target) {
                        Text(NSLocalizedString("This Mac",
                                               comment: "Preferences window: the local-machine target"))
                            .tag(ACAppDelegate.PreferencesTarget.local)
                        ForEach(hosts) { h in
                            Label(h.name, systemImage: "network")
                                .tag(ACAppDelegate.PreferencesTarget.remote(h.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
            }
            switch target {
            case .local:
                makeLocalEditor()
                    .id(target)
            case .remote(let hostID):
                if let remote {
                    makeRemoteEditor(hostID, remote)
                        .id(target)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("Couldn't load the remote preferences",
                                               comment: "Preferences window: remote fetch failed"))
                            .font(.headline)
                        Text(loadError)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        Button(NSLocalizedString("Retry", comment: "")) {
                            Task { await load(hostID) }
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(String(format: NSLocalizedString("Loading preferences from %@…",
                                                              comment: "Preferences window: fetching a remote's template"),
                                    hostName(hostID)))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: target) {
            onTargetChange(target)
            remote = nil
            loadError = nil
            if case .remote(let id) = target { await load(id) }
        }
    }

    private func hostName(_ id: UUID) -> String {
        hosts.first(where: { $0.id == id })?.name ?? ""
    }

    @MainActor
    private func load(_ hostID: UUID) async {
        loadError = nil
        do {
            let prefs = try await loadRemote(hostID)
            // The user may have switched targets while the fetch was in flight.
            guard case .remote(let now) = target, now == hostID else { return }
            remote = prefs
        } catch {
            guard case .remote(let now) = target, now == hostID else { return }
            loadError = error.localizedDescription
        }
    }
}
