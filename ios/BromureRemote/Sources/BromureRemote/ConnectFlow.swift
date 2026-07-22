import SwiftUI

// MARK: - Shared connect-phase UI
//
// The non-editing phases of the shared `RemoteConnectModel` state machine —
// contacting, host-key TOFU, password enrollment, unreachable — rendered as
// Form sections. Both the manual "Add Server" flow (ConnectScreen) and the
// bromure.io peer-connect flow (PeerConnectSheet) present these, so a first
// connect over either path runs the identical host-key / key / password
// pipeline.

struct ConnectPhaseView: View {
    @Bindable var model: RemoteConnectModel

    var body: some View {
        switch model.phase {
        case .editing:
            EmptyView()
        case .working(let msg):
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(msg).foregroundStyle(.secondary)
                }
            }
        case .confirmHostKey(let info, let changed, let previous):
            hostKeySection(info, changed: changed, previous: previous)
        case .needPassword(let error):
            passwordSection(error: error)
        case .unreachable(let msg):
            Section { Text(msg).font(.callout).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    func hostKeySection(_ info: HostKeyInfo, changed: Bool, previous: String?) -> some View {
        Section {
            LabeledContent("Fingerprint") {
                Text(info.fingerprint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if changed, let previous {
                Label("This differs from the previously trusted key:\n\(previous)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(changed ? "Host key CHANGED" : "Verify host key")
        } footer: {
            Text(changed
                 ? "Only continue if you expected the server's key to change (a reinstall). Otherwise this could be a machine-in-the-middle."
                 : "Confirm this matches the fingerprint the server shows (Bromure → Remote Access).")
        }
        Section {
            Button(changed ? "Trust the new key" : "Trust & Continue") {
                model.trustHostKey(info)
            }
            .foregroundStyle(changed ? .red : .accentColor)
        }
    }

    @ViewBuilder
    func passwordSection(error: String?) -> some View {
        Section {
            TextField("Remote account username", text: $model.user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
            SecureField("Remote account password", text: $model.password)
                .textContentType(.password)
            Button("Sign In") { model.submitPassword() }
                .disabled(model.password.isEmpty
                          || model.user.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Authorize this device")
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else {
                Text("This device's SSH key isn't authorized on the server yet. Enter the remote Mac's account username and password once to enroll it; subsequent connects are passwordless.")
            }
        }
        .id(model.shakes)   // re-render on a rejected password
    }
}

// MARK: - Peer connect sheet (bromure.io directory)

/// Connects to a bromure.io directory server peer-to-peer, showing the same
/// host-key / password steps as a direct add. Owns a `RemoteConnectModel`,
/// kicks off `connect(toPeer:)` on appear, and dismisses on success (the
/// caller's `onConnected` navigates to the mirror).
struct PeerConnectSheet: View {
    let server: DeviceInfo
    let onConnected: (RemoteHost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: RemoteConnectModel
    @State private var started = false

    init(server: DeviceInfo, onConnected: @escaping (RemoteHost) -> Void) {
        self.server = server
        self.onConnected = onConnected
        _model = State(initialValue: RemoteConnectModel(onConnected: onConnected))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: server.displayName)
                    LabeledContent("Reached via", value: "bromure.io")
                }
                ConnectPhaseView(model: model)

                if case .unreachable = model.phase {
                    Section {
                        Button("Try Again") { model.connect(toPeer: server) }
                    }
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                guard !started else { return }
                started = true
                model.connect(toPeer: server)
            }
        }
    }
}
