import SwiftUI

// MARK: - App entry
//
// `@main` is gated on BROMURE_APP so the SwiftPM library target (the CLI
// compile-check) builds the whole UI without an app entry point; the generated
// Xcode app target defines BROMURE_APP to switch it on.

#if BROMURE_APP
@main
#endif
struct BromureRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Top-level navigation and the sign-in / server-directory boot screen. Lists
/// this device's bromure.io servers (fetched over the account's control-plane
/// connection) plus any by-address servers, and opens a live mirror when one is
/// picked. iPhone gets a stack; iPad a sidebar/detail split.
struct RootView: View {
    @State private var store = RemoteHostStore.shared
    /// Long-lived model that owns the bromure.io account + server directory and
    /// runs a peer/direct connect. Its `onConnected` drives navigation.
    @State private var directory: RemoteConnectModel
    /// The host currently being mirrored (saved OR a resolved peer).
    @State private var activeHost: RemoteHost?
    @State private var showAddServer = false
    @State private var pendingPeer: DeviceInfo?
    /// Drives the "−" affordance: toggling it reveals delete controls on the
    /// by-address servers (bromure.io servers aren't removable from here).
    @State private var editMode: EditMode = .inactive
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// When the app went to the background — used to reconnect on return only
    /// after a real absence (a brief app-switch keeps its sockets).
    @State private var backgroundedAt: Date?

    init() {
        // The directory model navigates to the mirror on a successful connect.
        // `activeHost` is assigned in `.onAppear` via a closure box so the
        // State is capturable (SwiftUI inits can't reference self yet).
        let box = HostBox()
        _directory = State(initialValue: RemoteConnectModel(onConnected: { box.host = $0 }))
        _hostBox = State(initialValue: box)
    }
    @State private var hostBox: HostBox

    var body: some View {
        Group {
            if sizeClass == .compact {
                NavigationStack {
                    bootList
                        .navigationDestination(item: $activeHost) { host in
                            HostMirrorScreen(host: host).id(host.id)
                        }
                }
            } else {
                NavigationSplitView {
                    bootList
                } detail: {
                    if let host = activeHost {
                        HostMirrorScreen(host: host).id(host.id)
                    } else {
                        ContentUnavailableView("Select a server",
                            systemImage: "server.rack",
                            description: Text("Pick a bromure.io server or add one by address."))
                    }
                }
            }
        }
        .onAppear {
            directory.refreshAccount()
            hostBox.onChange = { activeHost = $0; pendingPeer = nil }
            AppBadge.requestAuthorization()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                // Only force a reconnect after a real absence; a quick
                // app-switch usually keeps the sockets alive.
                if let b = backgroundedAt, Date().timeIntervalSince(b) > 2 {
                    NotificationCenter.default.post(name: .bromureDidForeground, object: nil)
                }
                backgroundedAt = nil
            default:
                break
            }
        }
        .onOpenURL { url in
            // bromure://enroll?…&state=… — complete the account sign-in.
            guard url.scheme == "bromure", let link = EnrollLink(parsing: url.absoluteString) else { return }
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
            P2PEnrollmentCoordinator.shared.complete(link, state: state)
            directory.refreshAccount()
        }
        .sheet(isPresented: $showAddServer) {
            NavigationStack {
                ConnectScreen { host in
                    store.reload()
                    activeHost = host
                    showAddServer = false
                }
            }
        }
        .sheet(item: $pendingPeer) { server in
            PeerConnectSheet(server: server) { host in
                activeHost = host
                pendingPeer = nil
            }
        }
    }

    // MARK: Boot list

    private var bootList: some View {
        List {
            accountSection
            myServersSection
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Bromure Client")
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            if directory.signedIn {
                HStack {
                    Label(directory.accountLabel ?? "bromure.io", systemImage: "person.crop.circle.fill")
                    Spacer()
                    Button("Sign Out") { directory.signOutAccount() }
                        .font(.callout)
                }
            } else {
                Button {
                    directory.signIn()
                } label: {
                    Label("Sign in to bromure.io", systemImage: "person.crop.circle.badge.plus")
                }
                if directory.p2pBusy {
                    HStack { ProgressView(); Text("Finishing sign-in…").foregroundStyle(.secondary) }
                }
            }
            if let err = directory.p2pError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        } footer: {
            if !directory.signedIn {
                Text("Sign in with your bromure.io account to see and connect to your servers from anywhere — no address or port needed.")
            }
        }
    }

    private var savedHosts: [RemoteHost] {
        store.hosts.sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
    }

    /// One list of everything this account can reach — the bromure.io directory
    /// servers plus any added-by-address (direct) ones — with a +/− in the
    /// header to add and remove direct connections, matching the desktop.
    @ViewBuilder private var myServersSection: some View {
        Section {
            if directory.signedIn {
                ForEach(directory.p2pServers) { server in
                    Button { pendingPeer = server } label: { peerRow(server) }
                        .buttonStyle(.plain)
                        .disabled(!server.online || editMode == .active)
                }
            }
            ForEach(savedHosts) { host in
                Button { activeHost = host } label: { savedRow(host) }
                    .buttonStyle(.plain)
            }
            .onDelete { idx in for i in idx { store.remove(savedHosts[i].id) } }

            if directory.signedIn && directory.p2pServers.isEmpty && savedHosts.isEmpty {
                if directory.directoryLoading {
                    HStack { ProgressView(); Text("Loading your servers…").foregroundStyle(.secondary) }
                } else {
                    Text("No servers yet. Turn on Remote Access on a Bromure Mac, or add one by address with +.")
                        .foregroundStyle(.secondary)
                }
            } else if !directory.signedIn && savedHosts.isEmpty {
                Text("Add a server by address with +, or sign in above to reach your bromure.io servers.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 16) {
                Text("My Servers")
                Spacer()
                if directory.signedIn && directory.directoryLoading && !directory.p2pServers.isEmpty {
                    ProgressView().controlSize(.mini)
                }
                Button { showAddServer = true } label: {
                    Image(systemName: "plus").font(.body)
                }
                .accessibilityLabel("Add a server by address")
                Button {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                } label: {
                    Image(systemName: editMode == .active ? "checkmark" : "minus").font(.body)
                }
                .disabled(savedHosts.isEmpty)
                .accessibilityLabel(editMode == .active ? "Done editing" : "Remove a saved server")
            }
            .textCase(nil)
        }
    }

    private func peerRow(_ server: DeviceInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(server.online ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName).font(.body)
                Text(server.online ? "Online" : "Offline")
                    .font(.caption)
                    .foregroundStyle(server.online ? .green : .secondary)
            }
            Spacer()
            if server.online {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func savedRow(_ host: RemoteHost) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.name.isEmpty ? host.address : host.name)
                .font(.body.weight(.medium))
            Text(host.connectLabel).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A tiny reference box so the model's `onConnected` (set at init, before
/// `self` exists) can hand the resolved host back to the view's `@State`.
@MainActor
final class HostBox {
    var onChange: ((RemoteHost) -> Void)?
    var host: RemoteHost? {
        didSet { if let host { onChange?(host) } }
    }
}
