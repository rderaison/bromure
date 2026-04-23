import SwiftUI
import SandboxEngine

/// Sheet-style window prompting the user for an enterprise enrollment code.
///
/// Presented from the app menu — intentionally not surfaced in the main
/// window's chrome so that consumer users don't see an enterprise-looking
/// affordance on first launch. Bromure can be enrolled in multiple orgs at
/// the same time, so this view always adds a new enrollment rather than
/// replacing any existing one.
struct EnrollmentView: View {
    let state: AppState
    let onDone: () -> Void

    @State private var code: String = ""
    @State private var serverURL: String = ""
    @State private var deviceName: String = Host.current().localizedName ?? ""
    @State private var inFlight: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Enroll in Enterprise Management",
                                       comment: "Enrollment window title"))
                    .font(.title2).bold()
                Text(NSLocalizedString("Your administrator will give you a 6-word enrollment code. Paste it below to receive managed profiles for this organization.",
                                       comment: "Enrollment window subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Enrollment Code",
                                       comment: "Enrollment code label"))
                    .font(.headline)
                TextField("six-word-enrollment-code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true)
                    .frame(minWidth: 360)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Device Name",
                                       comment: "Device name label in enrollment"))
                    .font(.headline)
                TextField("", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(minWidth: 360)
                Text(NSLocalizedString("Shown to your administrator so they can recognize this device.",
                                       comment: "Device name help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(NSLocalizedString("Advanced",
                                              comment: "Advanced section in enrollment")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Server URL (optional)",
                                           comment: "Server URL label"))
                        .font(.subheadline)
                    TextField(ManagedProfileSync.defaultServerURL.absoluteString,
                              text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disableAutocorrection(true)
                        .frame(minWidth: 360)
                }
                .padding(.top, 4)
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) {
                    onDone()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    submit()
                } label: {
                    if inFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(NSLocalizedString("Enroll",
                                               comment: "Submit button in enrollment window"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inFlight || trimmedCode.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 440)
    }

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        errorMessage = nil
        inFlight = true
        let code = trimmedCode
        let urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlString.isEmpty ? nil : URL(string: urlString)
        let device = deviceName
        Task { @MainActor in
            defer { inFlight = false }
            do {
                try await state.enrollManagedProfile(
                    code: code, serverURL: url, deviceName: device)
                onDone()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
