import SwiftUI

// MARK: - Manual add-server flow (iOS)
//
// A compact, small-screen connect UI over the SHARED `RemoteConnectModel`
// (FatClientConnect.swift): the same state machine the macOS server-directory
// window drives — reach the host, confirm its SSH host key (TOFU), try key
// auth, fall back to the account password (enrolls this device's key). The
// host-key / password steps are the reusable `ConnectPhaseView`; this screen
// adds the address form for a by-address server.

struct ConnectScreen: View {
    let onConnected: (RemoteHost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: RemoteConnectModel

    init(onConnected: @escaping (RemoteHost) -> Void) {
        self.onConnected = onConnected
        _model = State(initialValue: RemoteConnectModel(onConnected: onConnected))
    }

    var body: some View {
        Form {
            if showsForm {
                detailsSection
            }
            ConnectPhaseView(model: model)
        }
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    /// The address form shows while editing (or after an unreachable result, so
    /// the user can correct the address and retry).
    private var showsForm: Bool {
        switch model.phase {
        case .editing, .unreachable: return true
        default: return false
        }
    }

    @ViewBuilder private var detailsSection: some View {
        Section("Server") {
            TextField("Name (optional)", text: $model.name)
            TextField("Address", text: $model.address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Port", text: $model.port)
                .keyboardType(.numberPad)
            TextField("Remote user", text: $model.user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        Section {
            Button {
                model.begin()
            } label: {
                Label("Connect", systemImage: "bolt.horizontal.circle")
            }
            .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
        } footer: {
            Text("This device authenticates by SSH key. On first connect you'll confirm the server's fingerprint and sign in once with the remote account's password to authorize this device.")
        }
    }

    private var isWorking: Bool {
        if case .working = model.phase { return true }
        return false
    }
}
