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

    init() {
        // Ignore SIGPIPE at PROCESS ENTRY, before any scene exists. This used
        // to live in RootView.init — fine on iPhone/iPad, where RootView is
        // the only scene and always runs first. On visionOS it left a hole: a
        // launch that restores only pinned terminal / grid windows (the main
        // window closed — a completely normal spatial arrangement) never
        // creates RootView, so the process ran with SIGPIPE at its default
        // disposition and the first write to a closed socket — a pump thread
        // mid-write while a pinned window closes, the guest dropping a stream
        // — killed the app instantly. A SIGPIPE death is a plain signal
        // termination, not an exception, so it leaves NO crash report; if the
        // app "just vanished" without an .ips anywhere, suspect this. Ignored,
        // the write returns EPIPE and the pump ends cleanly.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        #if os(visionOS)
        // The main shell — same split layout as the iPad — plus two extra scene
        // types the spatial canvas earns: any terminal can be popped out into
        // its own window and pinned anywhere in the room, and the grid can run
        // as a stage window of live terminals (VisionScenes.swift).
        WindowGroup(id: "main") {
            RootView()
        }
        .defaultSize(width: 1480, height: 940)

        WindowGroup(id: "terminal", for: TerminalWindowValue.self) { $value in
            if let value { PinnedTerminalWindow(value: value) }
        }
        .defaultSize(width: 920, height: 640)

        WindowGroup(id: "grid", for: GridWindowValue.self) { $value in
            if let value { GridStageWindow(value: value) }
        }
        .defaultSize(width: 1760, height: 1080)
        #else
        WindowGroup {
            RootView()
        }
        #endif
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
    /// What's open on the active server — a session, room, machine or board —
    /// shared by the iPhone stack and the iPad split view so an iPhone Duo
    /// folding or unfolding (which swaps one for the other) keeps your place.
    @State private var hostFocus: PadSelection?
    /// One RemoteHostController per host, reused while the host is open (across
    /// pushes into its terminals/grid) and torn down the instant the host is
    /// left. Held in a reference type so get-or-create can run during view body
    /// without mutating @State (which SwiftUI wouldn't persist — the terminal
    /// session-cache trap). Without deterministic teardown here, leaving a host
    /// left its poll timer + P2P connection alive; reconnecting stacked a second
    /// one on the stale cached path and stalled until the app was killed.
    @State private var controllers = HostControllerStore.shared
    @State private var showAddServer = false
    @State private var pendingPeer: DeviceInfo?
    #if os(visionOS)
    /// The identity owner, held as @State so body observes `webSignIn` — the
    /// embedded sign-in sheet presents the moment `signIn()` publishes it.
    @State private var enroll = P2PEnrollmentCoordinator.shared
    #endif
    #if DEBUG
    /// `BROMURE_DEBUG_EDITOR=1` presents the shared workspace editor over a
    /// dummy host at launch — screenshot/smoke the ProfileEditorView port
    /// without a live server (the "new" flavour never dials until Save).
    @State private var debugEditorController: RemoteHostController?
    #endif
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
        // SIGPIPE is ignored in BromureRemoteApp.init — process entry, before
        // any scene. It lived here once, which left visionOS launches that
        // restore only pinned terminal windows (no RootView) unprotected; see
        // the comment there before moving it again.

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
            #if DEBUG
            // Headless simulator bring-up: `BROMURE_DEBUG_SEED_KEY=<base64 of a
            // 32-byte ed25519 seed>` installs this device's SSH identity (only
            // when none exists) so a test server can pre-authorize it, and
            // `BROMURE_DEBUG_OPEN_HOST=<saved host UUID>` opens that server's
            // mirror at launch — no taps needed for a screenshot run. (AppBadge
            // honours `BROMURE_DEBUG_NO_PUSH_PROMPT=1` for the permission alert.)
            let debugEnv = ProcessInfo.processInfo.environment
            if let seed = debugEnv["BROMURE_DEBUG_SEED_KEY"], !seed.isEmpty,
               case .notFound = FatClientKeyStore.load() {
                _ = FatClientKeyStore.store(seed)
            }
            #endif
            // Publish our SSH key so the user's servers authorize us passwordless.
            RemoteTransport.publishSSHKey()
            #if DEBUG
            if let id = debugEnv["BROMURE_DEBUG_OPEN_HOST"].flatMap(UUID.init(uuidString:)) {
                store.reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let h = savedHosts.first(where: { $0.id == id }) { activeHost = h }
                }
            }
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG_EDITOR"] == "1" {
                debugEditorController = RemoteHostController(
                    host: RemoteHost(name: "debug", address: "127.0.0.1", user: "debug"))
                // Optional deep-link for screenshots: jump to one pane once the
                // editor is up (same notification ScriptCommands posts on macOS).
                if let cat = ProcessInfo.processInfo.environment["BROMURE_DEBUG_EDITOR_CATEGORY"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        NotificationCenter.default.post(
                            name: .bromureACSelectEditorCategory, object: cat)
                    }
                }
            }
            #endif
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
            if old?.id != new?.id { hostFocus = nil }
            if let old, old.id != new?.id { controllers.leave(old) }
        }
        // A tapped notification asks to open the server that's waiting; connect
        // to it so the agent shows up in "At a Glance" ready to answer.
        .onChange(of: push.tapTarget) { _, target in route(target) }
        .onChange(of: directory.p2pServers.map(\.id)) { _, _ in route(push.tapTarget) }
        // Register the APNs token with the account once we're signed in.
        .onChange(of: directory.signedIn) { _, signedIn in
            if signedIn { push.syncToken(); RemoteTransport.publishSSHKey() }
        }
        .onOpenURL { url in
            // bromure://enroll?…&state=… — complete the account sign-in.
            guard url.scheme == "bromure", let link = EnrollLink(parsing: url.absoluteString) else { return }
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
            P2PEnrollmentCoordinator.shared.complete(link, state: state)
            directory.refreshAccount()
        }
        #if os(visionOS)
        // The embedded bromure.io sign-in: `signIn()` publishes the enroll URL
        // instead of bouncing out to Safari (an App Review rejection), and this
        // sheet renders it in-app. Dismissing without completing cancels the
        // attempt so its nonce dies with it.
        .sheet(item: Binding(
            get: { enroll.webSignIn },
            set: { if $0 == nil { enroll.cancelWebSignIn() } })) { request in
            SignInWebSheet(request: request)
        }
        #endif
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
        #if DEBUG
        .sheet(isPresented: Binding(
            get: { debugEditorController != nil },
            set: { if !$0 { debugEditorController = nil } })) {
            if let c = debugEditorController {
                WorkspaceEditorSheet(controller: c, editing: nil) {
                    debugEditorController = nil
                }
            }
        }
        #endif
    }

    @ViewBuilder private var mainUI: some View {
        if sizeClass == .compact {
            NavigationStack {
                bootList
                    .navigationDestination(item: $activeHost) { host in
                        HostMirrorScreen(controller: controllers.controller(for: host),
                                         host: host, openWorkspace: pendingWorkspace,
                                         focus: $hostFocus).id(host.id)
                    }
            }
        } else if let host = activeHost {
            // iPad: one host fills the screen with the macOS-window layout —
            // sidebar (boards + workspaces) and a detail column — instead of
            // the phone's pushed dashboard. "Servers" in the sidebar returns
            // to the list (which tears the controller down via onChange).
            PadHostMirror(controller: controllers.controller(for: host),
                          host: host,
                          openWorkspace: pendingWorkspace,
                          onClose: { activeHost = nil },
                          selection: $hostFocus)
                .id(host.id)
        } else {
            // iPad, nothing open: the boot screen (hero or server picker) owns
            // the whole screen — a sidebar next to an empty "Select a server"
            // pane wasted the width and squeezed the account row into wrapping.
            NavigationStack {
                bootList
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
    /// (The disconnected state owns the full screen on iPad too, so the hero
    /// renders everywhere — its content column is width-capped below.)
    private var showHero: Bool {
        #if DEBUG
        // Headless screenshots of the signed-out landing on a signed-in
        // simulator: `BROMURE_DEBUG_HERO=1`.
        if ProcessInfo.processInfo.environment["BROMURE_DEBUG_HERO"] == "1" { return true }
        #endif
        return !directory.signedIn && savedHosts.isEmpty
    }

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
            // A comfortable reading column on iPad's full-screen picker; a
            // no-op on phone widths. The outer band matches the list's own
            // grouped background so the cap is invisible. (visionOS: no band —
            // an opaque fill would paint over the window's glass.)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            #if !os(visionOS)
            .background(Color(uiColor: .systemGroupedBackground))
            #endif
        }
    }

    // MARK: #0 — pre-login hero

    private var heroLanding: some View {
        ZStack {
            #if !os(visionOS)
            // visionOS: keep the window's glass — an opaque backdrop under the
            // glow reads as a giant white card floating in the room.
            Color(uiColor: .systemBackground).ignoresSafeArea()
            // The Bromure AC landing page's "bonds" lines, set well back and
            // drifting.
            BondsBackdrop().ignoresSafeArea()
            #endif

            VStack(spacing: 0) {
                Spacer(minLength: 40)
                brandMark.padding(.bottom, 30)
                Text("Bromure")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                Text("Your coding agents and terminals —\nlive, wherever you are.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.horizontal, 32)
                Spacer()

                VStack(spacing: 14) {
                    #if os(visionOS)
                    // The system's prominent glass capsule — a hand-painted
                    // gradient rectangle reads as an iOS transplant here.
                    Button { directory.signIn() } label: {
                        HStack(spacing: 8) {
                            if directory.p2pBusy { ProgressView() }
                            else { Image(systemName: "person.crop.circle.badge.plus") }
                            Text(directory.p2pBusy ? "Finishing sign-in…" : "Sign in to bromure.io")
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(directory.p2pBusy)
                    #else
                    Button { directory.signIn() } label: {
                        HStack(spacing: 8) {
                            if directory.p2pBusy { ProgressView().tint(.white) }
                            else { Image(systemName: "person.crop.circle.badge.plus") }
                            Text(directory.p2pBusy ? "Finishing sign-in…" : "Sign in to bromure.io")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        // The brand's flat accent -- no gradient, no glow. The
                        // light-mode indigo in dark mode too: white on the
                        // dark accent (periwinkle) wouldn't read.
                        .background(Color(hex: "#5866FE"), in: RoundedRectangle(cornerRadius: 15))
                        .foregroundStyle(.white)
                    }
                    .disabled(directory.p2pBusy)
                    #endif

                    Button { showAddServer = true } label: {
                        Text("Add a server by address")
                            .font(.subheadline.weight(.medium))
                            // Small accent text: the brand's navy on light
                            // (its indigo is under 4.5:1 on white), periwinkle
                            // on dark.
                            .foregroundStyle(Color(hex: colorScheme == .dark ? "#93AEFF" : "#33497B"))
                    }

                    if let err = directory.p2pError {
                        Text(err).font(.caption).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
            // Phone-tuned proportions read right on iPad too as long as the
            // column doesn't stretch — the sign-in button spanning a 13"
            // screen edge-to-edge did not.
            .frame(maxWidth: 480)
        }
    }

    /// The real app icon -- the exact mark people tapped to open the app.
    /// Flat, no glow: the brand's bonds drift behind it (BondsBackdrop).
    private var brandMark: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 132, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .accessibilityHidden(true)
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
                            .lineLimit(1)
                            .truncationMode(.middle)
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
        // ServerCard takes a plain String, which SwiftUI renders with the
        // NON-localizing Text overload — so localize here rather than at the
        // call site. "Last seen \(seen)" keys off "Last seen %@".
        let status: String = {
            if server.online { return String(localized: "Online") }
            if let seen = lastSeenText(server.lastSeenAt) {
                return String(localized: "Last seen \(seen)")
            }
            return String(localized: "Offline")
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
///
/// A process-wide singleton: on iPhone/iPad there is a single scene, so this is
/// equivalent to the old per-RootView store; on visionOS the pinned terminal /
/// grid windows are SEPARATE scenes that must reach the same live controller as
/// the main shell. Those aux scenes `claim`/`release` the host — while claims
/// are outstanding, `leave` defers the teardown (so popping the main shell back
/// to the server list doesn't kill a terminal the user pinned to the wall) and
/// the LAST release performs it.
@MainActor
final class HostControllerStore {
    static let shared = HostControllerStore()

    private var map: [UUID: RemoteHostController] = [:]
    /// Outstanding aux-scene claims per host id.
    private var claims: [UUID: Int] = [:]
    /// Hosts the main shell left while still claimed — stopped on last release.
    private var leftWhileClaimed: Set<UUID> = []

    func controller(for host: RemoteHost) -> RemoteHostController {
        leftWhileClaimed.remove(host.id)   // main shell is (back) on this host
        if let c = map[host.id] { return c }
        let c = RemoteHostController(host: host)
        map[host.id] = c
        return c
    }

    /// A live controller for an aux window (pinned terminal / grid stage): the
    /// main shell's if the host is open, else a fresh dial for a saved
    /// by-address host. nil = unresolvable — a bromure.io peer that isn't open,
    /// since those are dialed through the account directory, which only the
    /// main shell runs.
    func claim(_ hostID: UUID) -> RemoteHostController? {
        if let c = map[hostID] {
            claims[hostID, default: 0] += 1
            return c
        }
        guard let host = RemoteHostStore.shared.hosts.first(where: { $0.id == hostID })
        else { return nil }
        let c = RemoteHostController(host: host)
        map[hostID] = c
        claims[hostID] = 1
        // Nobody's main shell owns this controller; treat it as claimed-only so
        // the last window closing tears it down.
        leftWhileClaimed.insert(hostID)
        return c
    }

    func release(_ hostID: UUID) {
        guard let n = claims[hostID] else { return }
        if n > 1 {
            claims[hostID] = n - 1
            return
        }
        claims[hostID] = nil
        if leftWhileClaimed.remove(hostID) != nil {
            map.removeValue(forKey: hostID)?.stop()
        }
    }

    func leave(_ host: RemoteHost) {
        if (claims[host.id] ?? 0) > 0 {
            leftWhileClaimed.insert(host.id)
            return
        }
        map.removeValue(forKey: host.id)?.stop()
    }
}

// MARK: - The bonds motif, drifting

/// The brand's "bonds" motif -- the wavy lines behind the Bromure AC
/// landing page's hero (bromure.io: MotifBonds, HeroBackdrop "bonds"),
/// drawn the way the site does: 16 parallel lanes that each jog sideways
/// once, a few dashed, two dots; bleeding off the top-right corner, faint
/// (0.30-0.42), fading out by 96% of its height so it never reaches the
/// copy. The site holds it still; here the lanes drift down-left along
/// their own spacing (one lane in 8 s -- a seamless loop) and the dashes
/// march, while the dots, contact points, only breathe. Reduce Motion:
/// the site's still frame.
struct BondsBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One lane, in the artwork's viewBox (2735 x 2705).
    private static let lane: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 2732.03, y: 1242.43))
        p.addLine(to: CGPoint(x: 2276.97, y: 1822.03))
        p.addCurve(to: CGPoint(x: 2016.74, y: 1902.86),
                   control1: CGPoint(x: 2184.64, y: 1939.63), control2: CGPoint(x: 2097.89, y: 1966.57))
        p.addLine(to: CGPoint(x: 1874.72, y: 1791.36))
        p.addCurve(to: CGPoint(x: 1674.61, y: 1858.28),
                   control1: CGPoint(x: 1813.86, y: 1743.57), control2: CGPoint(x: 1747.15, y: 1765.88))
        p.addLine(to: CGPoint(x: 1229.44, y: 2425.28))
        return p
    }()
    /// From one lane to the next.
    private static let step = CGSize(width: -81.83, height: -64.25)
    private static let viewBox = CGSize(width: 2735, height: 2705)
    /// Lane k's stroke (k = 0...15): solid 5.159 but for the dashed ones.
    private static func stroke(_ k: Int, dashPhase: CGFloat) -> StrokeStyle {
        switch k {
        case 7: return StrokeStyle(lineWidth: 5.159, dash: [10.96, 10.96], dashPhase: dashPhase)
        case 10, 12: return StrokeStyle(lineWidth: 3.287, dash: [16.44, 16.44], dashPhase: dashPhase)
        case 14: return StrokeStyle(lineWidth: 3.287, dash: [13.15, 13.15], dashPhase: dashPhase)
        default: return StrokeStyle(lineWidth: 5.159)
        }
    }
    private static let dots = [CGPoint(x: 1222.72, y: 815.26), CGPoint(x: 1407.89, y: 1233.85)]
    /// Seconds for the family to move one lane.
    private static let period: Double = 8

    var body: some View {
        GeometryReader { geo in
            let frame = Self.framing(geo.size, regular: hSize == .regular)
            Group {
                if reduceMotion {
                    Canvas { ctx, _ in draw(ctx, frame: frame, t: 0) }
                } else {
                    // 30 fps: a lane every 8 s needs no more, at half the cost.
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        Canvas { ctx, _ in
                            draw(ctx, frame: frame, t: context.date.timeIntervalSinceReferenceDate)
                        }
                    }
                }
            }
            // Opaque down to 45% of the motif, gone by 96%.
            .mask {
                let h = max(geo.size.height, 1)
                let top = (frame.minY + 0.45 * frame.height) / h
                let end = (frame.minY + 0.96 * frame.height) / h
                LinearGradient(stops: [.init(color: .black, location: min(max(top, 0), 1)),
                                       .init(color: .clear, location: min(max(end, 0.001), 1))],
                               startPoint: .top, endPoint: .bottom)
            }
            .opacity((hSize == .regular ? 0.40 : 0.30) * (scheme == .dark ? 1.05 : 1))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where the artwork sits, as the site frames it: off the top-right
    /// corner (phone: 150vw wide, right -50vw; wider: 78vmax, right
    /// -20vmax; top -14vmax).
    private static func framing(_ size: CGSize, regular: Bool) -> CGRect {
        let vmax = max(size.width, size.height)
        let width = regular ? 0.78 * vmax : 1.5 * size.width
        let right = regular ? 0.20 * vmax : 0.5 * size.width
        let height = width * viewBox.height / viewBox.width
        return CGRect(x: size.width + right - width, y: -0.14 * vmax, width: width, height: height)
    }

    private func draw(_ ctx: GraphicsContext, frame: CGRect, t: Double) {
        let scale = frame.width / Self.viewBox.width
        var ctx = ctx
        ctx.translateBy(x: frame.minX, y: frame.minY)
        ctx.scaleBy(x: scale, y: scale)

        let cycles = t / Self.period
        let phase = CGFloat(cycles - cycles.rounded(.down))
        // A lane keeps its stroke as it drifts: style follows the lane, not
        // the slot, or a dashed lane would jump back a slot each loop.
        let shift = Int(cycles.rounded(.down))
        let dashPhase = CGFloat(-t * 20)
        let line = GraphicsContext.Shading.color(Color(hex: "#93AEFF").opacity(0.86))
        // One extra lane each end, so no gap opens at the edges.
        for k in -1...16 {
            let o = CGFloat(k) + phase
            let lane = Self.lane.applying(CGAffineTransform(translationX: o * Self.step.width,
                                                            y: o * Self.step.height))
            let style = ((k - shift) % 16 + 16) % 16
            ctx.stroke(lane, with: line, style: Self.stroke(style, dashPhase: dashPhase))
        }
        let breath = 0.8 + 0.2 * cos(t * .pi / 3)   // 1 -> 0.6 -> 1 over 6 s
        let dot = Color(hex: scheme == .dark ? "#FFFFFF" : "#33497B").opacity(breath)
        for c in Self.dots {
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 21.92, y: c.y - 21.92, width: 43.84, height: 43.84)),
                     with: .color(dot))
        }
    }
}
