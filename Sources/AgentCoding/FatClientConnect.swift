import AppKit
import SwiftUI

// MARK: - Connect to a remote Bromure (auth flow)

/// State machine backing the "Connect to Remote Bromure…" window. Handles, in
/// order: reach the host, verify its SSH host key (TOFU — show the fingerprint,
/// warn loudly if a pinned key changed), try public-key auth, and on failure
/// fall back to the macOS password (retried inline with a shake, no reopen
/// cycle). A successful password login enrolls this Mac's key so the next
/// connect is passwordless.
@MainActor
@Observable
final class RemoteConnectModel {
    enum Phase: Equatable {
        case editing
        case working(String)
        case confirmHostKey(HostKeyInfo, changed: Bool, previous: String?)
        case needPassword(error: String?)
        case unreachable(String)
    }

    var name = ""
    var address = ""
    var port = "2222"
    var user = NSUserName()
    var password = ""

    var phase: Phase = .editing
    /// Bumped to trigger the password-field shake on a bad password.
    var shakes = 0
    /// Test hook: auto-accept the shown host key (skips the manual confirm).
    var autoTrust = false

    /// Existing host being (re)connected, if any — carries the pinned key.
    private var host: RemoteHost
    /// "address:port" the current `host.pinnedHostKey` was pinned for — editing
    /// the endpoint invalidates a carried pin (it belongs to another server).
    private var pinnedEndpoint: String?
    private let onConnected: (RemoteHost) -> Void
    private let work = DispatchQueue(label: "io.bromure.connect")

    init(existing: RemoteHost? = nil, onConnected: @escaping (RemoteHost) -> Void) {
        self.onConnected = onConnected
        if let existing {
            host = existing
            name = existing.name; address = existing.address
            port = String(existing.port); user = existing.user
            pinnedEndpoint = existing.pinnedHostKey != nil ? "\(existing.address):\(existing.port)" : nil
        } else {
            host = RemoteHost(name: "", address: "", user: NSUserName())
        }
    }

    /// Fill the form from a saved host (recents list) without connecting.
    func prefill(_ saved: RemoteHost) {
        host = saved
        pinnedEndpoint = saved.pinnedHostKey != nil ? "\(saved.address):\(saved.port)" : nil
        name = saved.name; address = saved.address
        port = String(saved.port); user = saved.user
    }

    /// One-click reconnect to a saved host. TOFU already happened, so this
    /// normally goes straight to key auth with no fingerprint sheet.
    func connect(to saved: RemoteHost) {
        prefill(saved)
        begin()
    }

    var clientPublicKey: String { RemoteTransport.ensureClientKey() ?? "" }

    /// Human label for the endpoint being connected — the directory name for a
    /// peer (its address is an ephemeral loopback port), the typed address
    /// otherwise.
    var connectDisplayName: String { host.isPeer ? host.name : address }

    private func syncHostFromFields() {
        host.name = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? address.trimmingCharacters(in: .whitespaces)
            : name.trimmingCharacters(in: .whitespaces)
        host.address = address.trimmingCharacters(in: .whitespaces)
        host.port = Int(port) ?? 2222
        host.user = user.trimmingCharacters(in: .whitespaces).isEmpty ? NSUserName() : user.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Flow

    /// Adopt the saved record matching the typed endpoint, so reconnecting to a
    /// known server reuses its identity + TOFU pin (no fingerprint sheet), and
    /// drop a carried pin when the endpoint was edited to a different server.
    private func adoptSavedIdentity() {
        let store = RemoteHostStore.shared
        if let same = store.hosts.first(where: {
            $0.address == host.address && $0.port == host.port && $0.user == host.user
        }) {
            host.id = same.id
            host.lastConnected = same.lastConnected
            if name.trimmingCharacters(in: .whitespaces).isEmpty { host.name = same.name }
        }
        // The host key is a property of the endpoint, not of the login user.
        if let pin = store.hosts.first(where: {
            $0.address == host.address && $0.port == host.port && $0.pinnedHostKey != nil
        })?.pinnedHostKey {
            host.pinnedHostKey = pin
        } else if pinnedEndpoint != "\(host.address):\(host.port)" {
            host.pinnedHostKey = nil
        }
    }

    /// Step 1: reach the host and verify its host key.
    func begin() {
        syncHostFromFields()
        guard !host.address.isEmpty else { return }
        adoptSavedIdentity()
        phase = .working("Contacting \(host.connectLabel)…")
        let host = self.host
        work.async { [weak self] in
            let info = RemoteTransport.scanHostKey(address: host.address, port: host.port)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let info else {
                    self.phase = .unreachable("Couldn't reach \(host.connectLabel).\n\nMake sure the remote Bromure is running with remote access enabled (Preferences → Remote Access, or `bromure-ac remote enable`), and that the address and port are correct.")
                    return
                }
                self.scannedHostKeyLine = info.line
                if let pinned = self.host.pinnedHostKey {
                    if pinned == info.fingerprint {
                        RemoteTransport.pinHostKey(address: host.address, port: host.port, info: info)
                        self.tryKey()
                    } else {
                        self.phase = .confirmHostKey(info, changed: true, previous: pinned)
                    }
                } else if self.autoTrust {
                    self.trustHostKey(info)
                } else {
                    self.phase = .confirmHostKey(info, changed: false, previous: nil)
                }
            }
        }
    }

    /// The raw host-key line from the LAST scan — passed into the password
    /// enrollment so that handshake is pinned to the key the user saw.
    private var scannedHostKeyLine: String?

    /// User accepted the shown fingerprint (new host or an expected change).
    /// A peer host pins under its stable HostKeyAlias (the loopback endpoint
    /// is ephemeral); a direct host pins under address:port as before.
    func trustHostKey(_ info: HostKeyInfo) {
        host.pinnedHostKey = info.fingerprint
        let host = self.host
        phase = .working("Connecting…")
        work.async {
            if let alias = host.hostKeyAlias {
                RemoteTransport.pinHostKey(alias: alias, info: info)
            } else {
                RemoteTransport.pinHostKey(address: host.address, port: host.port, info: info)
            }
            DispatchQueue.main.async { [weak self] in self?.tryKey() }
        }
    }

    /// Step 2: try public-key auth.
    private func tryKey() {
        phase = .working("Authenticating…")
        let host = self.host
        work.async { [weak self] in
            let r = RemoteTransport.probe(host: host, strictHostKey: true)
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .ok: self.succeed()
                case .authFailed: self.phase = .needPassword(error: nil)   // key not authorized yet
                case .hostKeyChanged:
                    if let info = RemoteTransport.scanHostKey(address: host.address, port: host.port) {
                        self.phase = .confirmHostKey(info, changed: true, previous: self.host.pinnedHostKey)
                    } else { self.phase = .unreachable("Host key verification failed.") }
                case .unreachable(let m): self.phase = .unreachable(m)
                }
            }
        }
    }

    /// Step 3: try the typed password via our embedded NIOSSH *client* (no
    /// system `ssh`, no SSH_ASKPASS) — it sends the password through the SSH
    /// auth API directly and, on success, enrolls this Mac's public key over the
    /// control bridge so the next connect is passwordless.
    func submitPassword() {
        let pw = password
        guard !pw.isEmpty else { return }
        // The password step's user field is live — apply an edit ("renaud" →
        // "admin") to the host before authenticating. Only the user: a peer
        // host's address is the resolved loopback endpoint, never the form's.
        let editedUser = user.trimmingCharacters(in: .whitespaces)
        if !editedUser.isEmpty { host.user = editedUser }
        phase = .working("Signing in…")
        let host = self.host
        let keyLine = scannedHostKeyLine
        work.async { [weak self] in
            let r = FatClientNIOSSH.enrollWithPassword(host: host, password: pw,
                                                       hostKeyLine: keyLine)
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .ok:
                    self.password = ""
                    self.succeed()
                case .authFailed:
                    self.password = ""
                    self.shakes += 1
                    self.phase = .needPassword(error: "Incorrect password. Try again.")
                case .unreachable(let m):
                    self.phase = .unreachable(m)
                }
            }
        }
    }

    private func succeed() {
        host.lastConnected = Date()
        // Peer hosts live in the control-plane directory, not the by-address
        // recents list — their identity is the device id + known_hosts alias.
        // Remember the login user that worked so the next connect doesn't
        // re-guess it from the LOCAL account name.
        if let pid = host.peerDeviceID {
            Self.rememberUser(host.user, forPeer: pid)
        } else {
            RemoteHostStore.shared.upsert(host)
        }
        onConnected(host)
    }

    // MARK: - bromure.io account (P2P directory)

    /// Identity + sign-in live in the shared coordinator; the connect window
    /// owns only the server directory it renders.
    private var account: P2PEnrollmentCoordinator { .shared }
    /// Server devices in the workspace this Mac can mirror peer-to-peer.
    var p2pServers: [DeviceInfo] = []
    var directoryError: String?
    private var identityObserver: NSObjectProtocol?
    /// Polls the directory while the window is open so a server that stops
    /// heartbeating bromure.io greys out within a refresh cycle.
    private var directoryTimer: Timer?

    var signedIn: Bool { account.signedIn }
    var accountLabel: String? { account.accountLabel }
    /// Managed (enterprise) identity — owned by the managed-enrollment
    /// lifecycle, so this window must not offer Sign Out for it (the
    /// coordinator refuses it anyway).
    var isEnterpriseAccount: Bool { account.isEnterprise }
    var p2pBusy: Bool { account.busy }
    var p2pError: String? { account.error ?? directoryError }

    /// True while a directory fetch is in flight with nothing to show yet —
    /// the empty state renders a spinner instead of a premature "No servers".
    private(set) var directoryLoading = false

    /// Load the identity and, if present, refresh the server directory. Also
    /// starts observing identity changes so a sign-in completed while the window
    /// is open refreshes the list.
    func refreshAccount() {
        account.refresh()
        if identityObserver == nil {
            identityObserver = NotificationCenter.default.addObserver(
                forName: .p2pIdentityChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.p2pServers = []
                    if self.account.signedIn { Task { await self.loadDirectory() } }
                    self.startDirectoryRefresh()
                }
            }
        }
        if account.signedIn {
            Task { await loadDirectory() }
        }
        // Unconditional: the tick no-ops while signed out (loadDirectory
        // guards on the identity), and arming it here closes every path
        // where a later sign-in would otherwise poll nothing.
        startDirectoryRefresh()
    }

    /// `silent` background refreshes keep the last-known list on a transient
    /// failure instead of flashing an error (the reachability poll shouldn't
    /// flap the UI on one dropped request).
    func loadDirectory(silent: Bool = false) async {
        guard let id = account.identity, let ep = try? ControlPlaneEndpoint(base: id.apiBase) else { return }
        if !silent { directoryError = nil }
        if p2pServers.isEmpty { directoryLoading = true }
        defer { directoryLoading = false }
        let client = ControlPlaneClient(endpoint: ep)
        do {
            let devices = try await client.listDevices(bearer: id.bearer)
            // The directory is already scoped to this user's own servers; just
            // drop our own row (you don't mirror yourself).
            p2pServers = devices.filter { !$0.isSelf && !$0.revoked }
        } catch ControlPlaneError.http(401, _) {
            stopDirectoryRefresh()
            account.signOut()
            p2pServers = []
            directoryError = "This Mac's bromure.io device was revoked. Sign in again."
        } catch {
            if !silent {
                directoryError = "Couldn't load your servers."
                // One fast retry: the first fetch after launch/wake can lose
                // to a cold network — don't make the user find the ⟳ button
                // or wait out the poll interval.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self?.loadDirectory(silent: true)
                }
            }
        }
    }

    private func startDirectoryRefresh() {
        guard directoryTimer == nil else { return }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.loadDirectory(silent: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        directoryTimer = t
    }

    func stopDirectoryRefresh() {
        directoryTimer?.invalidate()
        directoryTimer = nil
    }

    /// Open the browser to sign in and enroll this Mac as a client device.
    func signIn() { account.signIn() }

    /// Test hook: replaces the broker resolution (which needs a live control
    /// plane and a real peer). Returns the resolved loopback endpoint, or nil.
    var peerResolver: (String) -> (host: String, port: Int)? = { id in
        P2PBroker.shared.endpoint(forPeer: id, timeout: 20).map { ($0.host, $0.port) }
    }

    /// Last successful login user per peer device. Peer hosts aren't in the
    /// by-address store, so this is where "log in as admin next time too"
    /// lives. The local NSUserName() default is only a first guess — the two
    /// Macs' short names routinely differ.
    private static func rememberedUser(forPeer id: String) -> String? {
        UserDefaults.standard.string(forKey: "p2p.remoteUser.\(id)")
    }
    static func rememberUser(_ user: String, forPeer id: String) {
        UserDefaults.standard.set(user, forKey: "p2p.remoteUser.\(id)")
    }

    /// The RemoteHost a directory server dial produces. Not saved to the
    /// by-address list — it lives in the live directory.
    static func peerHost(for server: DeviceInfo) -> RemoteHost {
        var host = RemoteHost(name: server.displayName, address: "",
                              user: rememberedUser(forPeer: server.id) ?? NSUserName())
        host.peerDeviceID = server.id
        host.lastConnected = Date()
        return host
    }

    /// Mirror a server reached over the control plane (peer-to-peer). The P2P
    /// path is established HERE, bounded, with an honest failure state — then
    /// the same host-key / key-auth / password pipeline as a direct host runs
    /// against the resolved loopback endpoint, so a first connect can enroll
    /// this Mac's key. The mirror window only opens once the tunnel works —
    /// never as an empty stage with an error overlay.
    func connect(toPeer server: DeviceInfo) {
        host = Self.peerHost(for: server)
        user = host.user   // the password step's user field edits this
        pinnedEndpoint = nil
        phase = .working("Connecting to \(server.displayName) via bromure.io…")
        let name = server.displayName
        let resolve = peerResolver
        let peerID = server.id
        work.async { [weak self] in
            let ep = resolve(peerID)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let ep else {
                    self.phase = .unreachable("Couldn't establish a connection to \(name).\n\nIt may have just gone offline, or no network path (direct or relayed) could be set up between the two Macs. Check that both can reach bromure.io, then try again.")
                    return
                }
                self.host.address = ep.host
                self.host.port = ep.port
                self.beginPeerAuth()
            }
        }
    }

    /// Host-key + auth against the freshly resolved loopback endpoint. The
    /// fingerprint sheet only shows on the FIRST connect to this peer — later
    /// connects find the pin under the peer's stable HostKeyAlias.
    private func beginPeerAuth() {
        let host = self.host
        phase = .working("Verifying \(host.name)…")
        work.async { [weak self] in
            let info = RemoteTransport.scanHostKey(address: host.address, port: host.port)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let info else {
                    self.phase = .unreachable("Reached \(host.name) over bromure.io, but its SSH front door didn't answer. Make sure Remote Access is still enabled on it.")
                    return
                }
                self.scannedHostKeyLine = info.line
                guard let alias = host.hostKeyAlias else { return }   // peers always have one
                if RemoteTransport.hasAliasPin(alias) {
                    self.tryKey()
                } else if self.autoTrust {
                    RemoteTransport.pinHostKey(alias: alias, info: info)
                    self.tryKey()
                } else {
                    self.phase = .confirmHostKey(info, changed: false, previous: nil)
                }
            }
        }
    }

    func signOutAccount() {
        stopDirectoryRefresh()
        account.signOut()
        p2pServers = []
    }
}

// MARK: - Shake effect

private struct Shake: GeometryEffect {
    var travel: CGFloat = 8
    var shakes: CGFloat = 3
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(animatableData * .pi * shakes), y: 0))
    }
}

// MARK: - Connect view

struct RemoteConnectView: View {
    @Bindable var model: RemoteConnectModel
    var onClose: () -> Void
    /// Open directly on the details form (editing an existing host) instead
    /// of the server picker.
    var startInForm = false

    /// Unified picker selection — `"peer:<deviceID>"` for a control-plane server
    /// or `"host:<uuid>"` for a saved by-address host.
    @State private var selection: String?
    /// True while the add/edit details form is showing instead of the picker.
    @State private var showingForm: Bool

    init(model: RemoteConnectModel, onClose: @escaping () -> Void, startInForm: Bool = false) {
        self.model = model
        self.onClose = onClose
        self.startInForm = startInForm
        _showingForm = State(initialValue: startInForm)
    }

    private var savedHosts: [RemoteHost] {
        RemoteHostStore.shared.hosts.sorted {
            ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Remote Bromure")
                .font(.title3).bold()

            switch model.phase {
            case .editing:               editing
            case .working(let msg):      working(msg)
            case .confirmHostKey(let info, let changed, let previous):
                hostKey(info, changed: changed, previous: previous)
            case .needPassword(let err): passwordStep(err)
            case .unreachable(let msg):  unreachable(msg)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { model.refreshAccount() }
        .onDisappear { model.stopDirectoryRefresh() }
    }

    /// Picker (like Screen Sharing) unless the add/edit form is up. The picker
    /// handles the empty case itself (it offers sign-in + add).
    @ViewBuilder private var editing: some View {
        if showingForm {
            form
        } else {
            picker
        }
    }

    // MARK: Server picker

    private var hasAnyServer: Bool { !model.p2pServers.isEmpty || !savedHosts.isEmpty }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mirror another Mac running Bromure — its grid, workspaces, tabs and automations. Sign in to reach your servers from anywhere, or add one directly by address on your LAN.")
                .foregroundStyle(.secondary).font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if hasAnyServer {
                serverList
            } else {
                emptyState
            }
            if let err = model.p2pError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            accountBar

            HStack(spacing: 10) {
                ControlGroup {
                    Button {
                        model.prefill(RemoteHost(name: "", address: "", user: NSUserName()))
                        showingForm = true
                    } label: { Image(systemName: "plus") }
                    .help("Add a server by address")
                    Button {
                        if let sel = selection, sel.hasPrefix("host:"),
                           let id = UUID(uuidString: String(sel.dropFirst(5))) {
                            RemoteHostStore.shared.remove(id)
                            selection = nil
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(!(selection?.hasPrefix("host:") ?? false))
                    .help("Remove the selected saved server")
                }
                .frame(width: 70)
                Button("Show this Mac's key") { showClientKey() }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Connect") { connectSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnectSelection)
            }
        }
    }

    /// Connect is enabled for a saved host, or a server that's currently
    /// reachable — not one that just greyed out under the selection.
    private var canConnectSelection: Bool {
        guard let sel = selection else { return false }
        if sel.hasPrefix("peer:") {
            let id = String(sel.dropFirst(5))
            return model.p2pServers.first(where: { $0.id == id })?.online ?? false
        }
        return sel.hasPrefix("host:")
    }

    private var serverList: some View {
        List(selection: $selection) {
            if model.signedIn && !model.p2pServers.isEmpty {
                Section("My servers · bromure.io") {
                    ForEach(model.p2pServers) { s in
                        peerRow(s).tag("peer:\(s.id)")
                    }
                }
            }
            if !savedHosts.isEmpty {
                Section(model.signedIn ? "On this network" : "Saved servers") {
                    ForEach(savedHosts) { h in
                        serverRow(h).tag("host:\(h.id.uuidString)")
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear {
            if selection == nil {
                if let s = model.p2pServers.first(where: { $0.online }) ?? model.p2pServers.first {
                    selection = "peer:\(s.id)"
                } else if let h = savedHosts.first {
                    selection = "host:\(h.id.uuidString)"
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.signedIn && model.directoryLoading {
                // First fetch in flight — an empty list here isn't "no
                // servers", it's "not answered yet".
                ProgressView().controlSize(.small)
                Text("Looking for your servers…")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: "macmini").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text(model.signedIn
                     ? "No servers in your workspace yet.\nEnable Remote Access on the Mac you want to reach, or add one by address."
                     : "Sign in with bromure.io to see your servers, or add one by address.")
                    .multilineTextAlignment(.center)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
    }

    /// bromure.io account row: sign-in button, or the signed-in workspace with
    /// refresh / sign-out.
    private var accountBar: some View {
        HStack(spacing: 8) {
            if model.p2pBusy {
                ProgressView().controlSize(.small)
            }
            if model.signedIn {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.secondary)
                Text(model.accountLabel ?? "bromure.io").font(.callout)
                Button { Task { await model.loadDirectory() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh servers")
                Spacer()
                if model.isEnterpriseAccount {
                    // A managed identity can't be signed out of from here —
                    // a button that silently no-ops is worse than saying so.
                    Text("Managed by your organization")
                        .font(.caption).foregroundStyle(.tertiary)
                        .help("This Mac is enrolled by your organization; its bromure.io identity is managed outside this window.")
                } else {
                    Button("Sign Out") { model.signOutAccount(); selection = nil }
                        .buttonStyle(.link)
                }
            } else {
                Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.secondary)
                Button("Sign in with bromure.io") { model.signIn() }
                Spacer()
            }
        }
        .font(.callout)
    }

    private func connectSelected() {
        guard let sel = selection else { return }
        if sel.hasPrefix("peer:") {
            let id = String(sel.dropFirst(5))
            // Only a reachable server — an offline one's grant is refused.
            if let s = model.p2pServers.first(where: { $0.id == id }), s.online {
                model.connect(toPeer: s)
            }
        } else if sel.hasPrefix("host:"), let id = UUID(uuidString: String(sel.dropFirst(5))),
                  let h = savedHosts.first(where: { $0.id == id }) {
            model.connect(to: h)
        }
    }

    private func peerRow(_ s: DeviceInfo) -> some View {
        // "Reachable" = the server pinged bromure.io within the presence window
        // (a live control connection). Otherwise it's greyed out and can't be
        // dialed — a connection grant to an offline server is refused anyway.
        let reachable = s.online
        return HStack(spacing: 10) {
            Image(systemName: "macmini.fill")
                .foregroundStyle(reachable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayName).font(.callout)
                lastSeenLabel(s, reachable: reachable)
            }
            Spacer()
            Circle().fill(reachable ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(reachable ? "reachable" : "offline")
                .font(.caption)
                .foregroundStyle(reachable ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
        }
        .padding(.vertical, 3)
        .opacity(reachable ? 1 : 0.45)
        .contentShape(Rectangle())
        // Offline servers aren't selectable or connectable — nothing to do but
        // wait for them to come back.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if reachable { model.connect(toPeer: s) } })
        .simultaneousGesture(TapGesture().onEnded { if reachable { selection = "peer:\(s.id)" } })
        .help(reachable
              ? "Connect to \(s.displayName)"
              : "\(s.displayName) hasn't connected to bromure.io recently")
    }

    /// "Active now" for a reachable server, otherwise how long ago it last
    /// reached bromure.io (a live relative timestamp), or "offline" if unknown.
    @ViewBuilder private func lastSeenLabel(_ s: DeviceInfo, reachable: Bool) -> some View {
        if reachable {
            Text("Active now").font(.caption).foregroundStyle(.green)
        } else if let seen = ISO8601.date(from: s.lastSeenAt) {
            Text("Last seen \(seen, format: .relative(presentation: .named))")
                .font(.caption).foregroundStyle(.tertiary)
        } else {
            Text("Offline").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func serverRow(_ h: RemoteHost) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "macmini.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(h.name.isEmpty ? h.address : h.name).font(.callout)
                Text(h.connectLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let last = h.lastConnected {
                Text(last, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.connect(to: h)
        })
        .simultaneousGesture(TapGesture().onEnded {
            selection = "host:\(h.id.uuidString)"
        })
        .contextMenu {
            Button("Connect") { model.connect(to: h) }
            Button("Edit…") {
                model.prefill(h)
                showingForm = true
            }
            Divider()
            Button("Remove", role: .destructive) {
                RemoteHostStore.shared.remove(h.id)
                if selection == "host:\(h.id.uuidString)" { selection = nil }
            }
        }
        .help("Connect to \(h.connectLabel)")
    }

    // MARK: Add/edit details form

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mirror another Mac running Bromure — its grid, workspaces, tabs and automations — over SSH.")
                .foregroundStyle(.secondary).font(.callout)
            field("Name", text: $model.name, placeholder: "e.g. rack mini")
            field("Address", text: $model.address, placeholder: "host or IP")
            HStack {
                field("Port", text: $model.port, placeholder: "2222").frame(width: 130)
                field("Remote user", text: $model.user, placeholder: NSUserName())
            }
            HStack {
                Button("Back") { showingForm = false }
                Button("Show this Mac's key") { showClientKey() }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Connect") { model.begin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func working(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) { ProgressView().controlSize(.small); Text(msg) }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(.vertical, 12)
    }

    // Host-key TOFU / change warning
    private func hostKey(_ info: HostKeyInfo, changed: Bool, previous: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if changed {
                Label("The remote's SSH host key has CHANGED", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.headline)
                Text("This can mean the remote was reinstalled — or that someone is impersonating it (man-in-the-middle). Only continue if you expect this change.")
                    .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let previous {
                    Text("Previously: \(previous)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            } else {
                Text("First time connecting to \(model.connectDisplayName). Verify this fingerprint matches the remote (Preferences → Remote Access shows it):")
                    .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text(info.fingerprint)
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(changed ? "Trust New Key & Continue" : "Trust & Continue") { model.trustHostKey(info) }
                    .keyboardShortcut(.defaultAction)
                    .tint(changed ? .red : .accentColor)
            }
        }
    }

    // Password fallback with inline retry + shake
    private func passwordStep(_ error: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This Mac isn't authorized on \(model.connectDisplayName) yet. Enter the remote Mac's login user and password to pair — Bromure will remember this Mac so you won't be asked again.")
                .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
            // Editable here, not just in the add form: the guessed default is
            // THIS Mac's user name, and the remote's ("admin", say) routinely
            // differs — with no field, a peer connect had no way to fix it.
            field("Remote user", text: $model.user, placeholder: NSUserName())
            SecureField("Password", text: $model.password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submitPassword() }
                .modifier(Shake(animatableData: CGFloat(model.shakes)))
                .animation(.default, value: model.shakes)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button("Show this Mac's key") { showClientKey() }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Sign In") { model.submitPassword() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.password.isEmpty)
            }
        }
    }

    private func unreachable(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Can't connect", systemImage: "wifi.exclamationmark").font(.headline)
            Text(msg).foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Back") { model.phase = .editing }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func showClientKey() {
        let key = model.clientPublicKey
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
        let a = NSAlert()
        a.messageText = "This Mac's public key (copied)"
        a.informativeText = "To authorize this Mac without a password, run on the remote:\n\n  bromure-ac remote key add '\(key)'"
        a.runModal()
    }
}
