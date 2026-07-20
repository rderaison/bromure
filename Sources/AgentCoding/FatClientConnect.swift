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
    func trustHostKey(_ info: HostKeyInfo) {
        host.pinnedHostKey = info.fingerprint
        let host = self.host
        phase = .working("Connecting…")
        work.async {
            RemoteTransport.pinHostKey(address: host.address, port: host.port, info: info)
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
        RemoteHostStore.shared.upsert(host)
        onConnected(host)
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

    /// Server picker selection (the Screen Sharing-style list).
    @State private var selectedID: UUID?
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
        .frame(width: 460)
    }

    /// Picker first (like Screen Sharing) when there are saved servers; the
    /// details form only for adding or editing one.
    @ViewBuilder private var editing: some View {
        if showingForm || savedHosts.isEmpty {
            form
        } else {
            picker
        }
    }

    // MARK: Server picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mirror another Mac running Bromure — its grid, workspaces, tabs and automations — over SSH.")
                .foregroundStyle(.secondary).font(.callout)
            List(selection: $selectedID) {
                ForEach(savedHosts) { h in
                    serverRow(h).tag(h.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12)))
            .onAppear { if selectedID == nil { selectedID = savedHosts.first?.id } }
            HStack(spacing: 10) {
                ControlGroup {
                    Button {
                        model.prefill(RemoteHost(name: "", address: "", user: NSUserName()))
                        showingForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add a server")
                    Button {
                        if let id = selectedID {
                            RemoteHostStore.shared.remove(id)
                            selectedID = savedHosts.first?.id
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedID == nil)
                    .help("Remove the selected server")
                }
                .frame(width: 70)
                Button("Show this Mac's key") { showClientKey() }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Connect") {
                    if let h = savedHosts.first(where: { $0.id == selectedID }) {
                        model.connect(to: h)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
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
            selectedID = h.id
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
                if selectedID == h.id { selectedID = nil }
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
                if !savedHosts.isEmpty {
                    Button("Back") { showingForm = false }
                }
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
        HStack(spacing: 12) { ProgressView().controlSize(.small); Text(msg) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
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
                Text("First time connecting to \(model.address). Verify this fingerprint matches the remote (Preferences → Remote Access shows it):")
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
            Text("This Mac isn't authorized on \(model.address) yet. Enter the remote Mac's login password for “\(model.user)” to pair — Bromure will remember this Mac so you won't be asked again.")
                .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
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
