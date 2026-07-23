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
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    /// One RemoteHostController per host, reused while the host is open (across
    /// pushes into its terminals/grid) and torn down the instant the host is
    /// left. Held in a reference type so get-or-create can run during view body
    /// without mutating @State (which SwiftUI wouldn't persist — the terminal
    /// session-cache trap). Without deterministic teardown here, leaving a host
    /// left its poll timer + P2P connection alive; reconnecting stacked a second
    /// one on the stale cached path and stalled until the app was killed.
    @State private var controllers = HostControllerStore()
    @State private var showAddServer = false
    @State private var pendingPeer: DeviceInfo?
    /// A notification tap's target window, opened once its server connects.
    @State private var pendingWorkspace: WorkspaceDeepLink?
    /// Drives the "−" affordance: toggling it reveals delete controls on the
    /// by-address servers (bromure.io servers aren't removable from here).
    @State private var editMode: EditMode = .inactive
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    /// When the app went to the background — used to reconnect on return only
    /// after a real absence (a brief app-switch keeps its sockets).
    @State private var backgroundedAt: Date?
    private let push = PushManager.shared

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
            mainUI
        }
        .onAppear {
            directory.refreshAccount()
            hostBox.onChange = { activeHost = $0; pendingPeer = nil }
            AppBadge.requestAuthorization()
            push.syncToken()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                // Only force a reconnect after a real absence; a quick
                // app-switch usually keeps the sockets alive. The elapsed
                // duration rides along so a LONG absence (the P2P path is surely
                // dead) can tear it down and re-establish, not just re-poll.
                if let b = backgroundedAt {
                    let away = Date().timeIntervalSince(b)
                    if away > 2 {
                        NotificationCenter.default.post(
                            name: .bromureDidForeground, object: nil,
                            userInfo: ["awaySeconds": away])
                    }
                }
                backgroundedAt = nil
                // Remove any delivered notification whose question is already
                // answered — the guarantee behind the silent "clear" push.
                push.reconcile()
            default:
                break
            }
        }
        // Left a host (popped to the list) or switched hosts: stop the one we're
        // leaving NOW — invalidate its poll and close its P2P peer path — so a
        // later reconnect establishes a FRESH connection instead of reusing a
        // stale cached one (the "stalls until I kill the app" bug, plus the flaky
        // tab commands that a degraded reused connection intermittently dropped).
        .onChange(of: activeHost) { old, new in
            if let old, old.id != new?.id { controllers.leave(old) }
        }
        // A tapped notification asks to open the server that's waiting; connect
        // to it so the agent shows up in "At a Glance" ready to answer.
        .onChange(of: push.tapTarget) { _, target in route(target) }
        .onChange(of: directory.p2pServers.map(\.id)) { _, _ in route(push.tapTarget) }
        // Register the APNs token with the account once we're signed in.
        .onChange(of: directory.signedIn) { _, signedIn in if signedIn { push.syncToken() } }
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

    @ViewBuilder private var mainUI: some View {
        if sizeClass == .compact {
            NavigationStack {
                bootList
                    .navigationDestination(item: $activeHost) { host in
                        HostMirrorScreen(controller: controllers.controller(for: host),
                                         host: host, openWorkspace: pendingWorkspace).id(host.id)
                    }
            }
        } else {
            NavigationSplitView {
                bootList
            } detail: {
                if let host = activeHost {
                    HostMirrorScreen(controller: controllers.controller(for: host),
                                     host: host, openWorkspace: pendingWorkspace).id(host.id)
                } else {
                    ContentUnavailableView("Select a server",
                        systemImage: "server.rack",
                        description: Text("Pick a bromure.io server or add one by address."))
                }
            }
        }
    }

    /// Route a tapped-notification target: connect to the server it names once
    /// the directory knows about it (a cold launch can tap before it loads).
    private func route(_ target: PushTapTarget?) {
        guard let target else { return }
        guard let server = directory.p2pServers.first(where: { $0.id == target.serverInstallId }) else {
            directory.refreshAccount() // not loaded yet — retried when servers arrive
            return
        }
        // Carry the exact waiting window so the mirror opens straight into it.
        pendingWorkspace = target.profileId
            .flatMap { UUID(uuidString: $0) }
            .map { WorkspaceDeepLink(profileID: $0, window: target.windowIndex) }
        if server.online { pendingPeer = server }
        push.tapTarget = nil
    }

    // MARK: Boot screen

    /// A fresh, signed-out install with no saved servers gets the branded hero;
    /// once there's an account or a by-address server it's the working list.
    private var showHero: Bool { !directory.signedIn && savedHosts.isEmpty }

    @ViewBuilder private var bootList: some View {
        if showHero {
            heroLanding
                .toolbar(.hidden, for: .navigationBar)   // the hero is its own title
        } else {
            List {
                accountSection
                myServersSection
            }
            .listSectionSpacing(.compact)
            .environment(\.editMode, $editMode)
            .navigationTitle("Bromure")
        }
    }

    // MARK: #0 — pre-login hero

    private var heroLanding: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            RadialGradient(
                colors: [Color.blue.opacity(colorScheme == .dark ? 0.30 : 0.15), .clear],
                center: UnitPoint(x: 0.5, y: 0.30), startRadius: 6, endRadius: 340)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 40)
                brandMark.padding(.bottom, 30)
                Text("Bromure")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                Text("Your coding agents and terminals —\nlive, from your phone.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.horizontal, 32)
                Spacer()

                VStack(spacing: 14) {
                    Button { directory.signIn() } label: {
                        HStack(spacing: 8) {
                            if directory.p2pBusy { ProgressView().tint(.white) }
                            else { Image(systemName: "person.crop.circle.badge.plus") }
                            Text(directory.p2pBusy ? "Finishing sign-in…" : "Sign in to bromure.io")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(colors: [Color.blue, Color.indigo],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 15))
                        .foregroundStyle(.white)
                        .shadow(color: .blue.opacity(0.35), radius: 12, y: 6)
                    }
                    .disabled(directory.p2pBusy)

                    Button { showAddServer = true } label: {
                        Text("Add a server by address")
                            .font(.subheadline.weight(.medium))
                    }

                    if let err = directory.p2pError {
                        Text(err).font(.caption).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
        }
    }

    /// The real app icon, over a matching blue glow — the exact mark people
    /// tapped to open the app.
    private var brandMark: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.blue.opacity(0.5), .clear],
                                     center: .center, startRadius: 4, endRadius: 100))
                .frame(width: 210, height: 210)
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            if directory.signedIn {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(
                            LinearGradient(colors: [Color.blue, Color.indigo],
                                           startPoint: .top, endPoint: .bottom))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(directory.accountLabel ?? "bromure.io")
                            .font(.body.weight(.semibold))
                        Text("Signed in").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out") { directory.signOutAccount() }
                        .font(.callout)
                }
                .padding(.vertical, 4)
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
                    Button { pendingWorkspace = nil; pendingPeer = server } label: { peerRow(server) }
                        .buttonStyle(.plain)
                        .disabled(!server.online || editMode == .active)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            ForEach(savedHosts) { host in
                Button { pendingWorkspace = nil; activeHost = host } label: { savedRow(host) }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
        let status: String = {
            if server.online { return "Online" }
            if let seen = lastSeenText(server.lastSeenAt) { return "Last seen \(seen)" }
            return "Offline"
        }()
        return ServerCard(icon: "server.rack", accent: serverAccent(server.id),
                          name: server.displayName, status: status,
                          online: server.online, showChevron: server.online)
    }

    private func savedRow(_ host: RemoteHost) -> some View {
        // A by-address host: reachability isn't known until you dial it, so no
        // online dot — a neutral "Direct" card with its connect label.
        ServerCard(icon: "network", accent: serverAccent(host.id.uuidString),
                   name: host.name.isEmpty ? host.address : host.name,
                   status: host.connectLabel, online: nil, showChevron: true)
    }
}

// MARK: - Boot-screen building blocks

/// A server row rendered as a card: an accent-tinted icon tile, the name, and a
/// status line with a pulsing dot when the server is online.
private struct ServerCard: View {
    let icon: String
    let accent: Color
    let name: String
    let status: String
    /// true = online (green pulse), false = offline (grey), nil = no dot.
    let online: Bool?
    let showChevron: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold))
                HStack(spacing: 5) {
                    if let online { PulsingDot(color: online ? .green : .secondary, active: online) }
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(online == true ? accent.opacity(0.4) : Color.clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A small status dot that emits a slow expanding ring while `active`.
struct PulsingDot: View {
    let color: Color
    let active: Bool
    @State private var pulse = false
    var body: some View {
        ZStack {
            if active {
                Circle().fill(color.opacity(0.4))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.7 : 0.7)
                    .opacity(pulse ? 0 : 0.9)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            guard active else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// A stable, distinct accent colour per server, derived from its id (FNV-1a →
/// hue), so each server reads as its own thing across launches.
private func serverAccent(_ seed: String) -> Color {
    var h: UInt64 = 1469598103934665603
    for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return Color(hue: Double(h % 1000) / 1000, saturation: 0.55, brightness: 0.85)
}

/// "3h", "2d" … from an ISO-8601 timestamp, or nil if unparseable.
private func lastSeenText(_ iso: String?) -> String? {
    guard let iso else { return nil }
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    guard let date = withFrac.date(from: iso) ?? plain.date(from: iso) else { return nil }
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .abbreviated
    return rel.localizedString(for: date, relativeTo: Date())
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

/// One live `RemoteHostController` per host id. `controller(for:)` reuses the
/// existing one (so pushing into a host's terminals/grid doesn't re-handshake)
/// and mints a fresh one after a `leave`. `leave` stops the controller — poll
/// timer invalidated, P2P peer path closed — the instant the host is left, so a
/// later reconnect never reuses a stale cached connection. A reference type: the
/// view body's get-or-create must not mutate @State (SwiftUI won't persist it),
/// the same reason the terminal session cache is a class.
@MainActor
final class HostControllerStore {
    private var map: [UUID: RemoteHostController] = [:]

    func controller(for host: RemoteHost) -> RemoteHostController {
        if let c = map[host.id] { return c }
        let c = RemoteHostController(host: host)
        map[host.id] = c
        return c
    }

    func leave(_ host: RemoteHost) {
        map.removeValue(forKey: host.id)?.stop()
    }
}
