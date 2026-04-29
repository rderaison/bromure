import SwiftUI
import SandboxEngine

/// Sheet prompting the user for an enterprise enrollment code, mirroring
/// the Bromure Web `EnrollmentView`. Triggered from the menu (Window →
/// Enroll in bromure.io…) and on first launch when an admin-issued code
/// is the only way to get BAC streaming session metadata.
struct BACEnrollmentSheet: View {
    let onDone: (BACInstall?) -> Void

    @State private var code: String = ""
    @State private var serverURL: String = ""
    @State private var deviceName: String = Host.current().localizedName ?? ""
    @State private var inFlight: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Enroll in bromure.io",
                                       comment: "BAC enrollment sheet title"))
                    .font(.title2).bold()
                Text(NSLocalizedString("Your administrator will give you a 6-word enrollment code. Once enrolled, Bromure Agentic Coding sends session metadata (tools, files, commands, token usage) to your workspace so admins can review activity. Profiles in private mode never stream.",
                                       comment: "BAC enrollment sheet subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Enrollment Code",
                                       comment: "BAC enrollment code label"))
                    .font(.headline)
                TextField("six-word-enrollment-code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true)
                    .frame(minWidth: 360)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Device Name",
                                       comment: "BAC device name label"))
                    .font(.headline)
                TextField("", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(minWidth: 360)
                Text(NSLocalizedString("Shown to your administrator so they can recognize this Mac.",
                                       comment: "BAC device name help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(NSLocalizedString("Advanced",
                                              comment: "BAC enrollment advanced section")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Server URL (optional)",
                                           comment: "Server URL label"))
                        .font(.subheadline)
                    TextField(BACEnrollment.defaultServerURL.absoluteString,
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
                    onDone(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    submit()
                } label: {
                    if inFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(NSLocalizedString("Enroll",
                                               comment: "BAC enrollment submit button"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inFlight || trimmedCode.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
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
                let install = try await BACEnrollment.shared.enroll(
                    code: code, serverURL: url, deviceName: device,
                )
                onDone(install)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Status panel for the Window menu: "Enrolled to {org} as {email}",
/// "Renew certificate", "Sign out". Surfaces enrollment state without
/// burying it in a settings panel.
struct BACEnrollmentStatusView: View {
    @State private var install: BACInstall? = BACEnrollmentStore.load()
    @State private var leafExpiresAt: Date?
    @State private var renewing = false
    @State private var renewError: String?
    let onUnenroll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let install {
                Text(NSLocalizedString("bromure.io enrollment",
                                       comment: "BAC status panel title"))
                    .font(.title3).bold()
                LabeledRow(label: NSLocalizedString("Workspace", comment: ""),
                           value: install.orgSlug)
                LabeledRow(label: NSLocalizedString("User", comment: ""),
                           value: install.userEmail)
                LabeledRow(label: NSLocalizedString("Device", comment: ""),
                           value: install.deviceName)
                LabeledRow(label: NSLocalizedString("Server", comment: ""),
                           value: install.serverURL.absoluteString)
                LabeledRow(label: NSLocalizedString("Enrolled", comment: ""),
                           value: install.enrolledAt
                            .formatted(date: .abbreviated, time: .shortened))

                if let renewError {
                    Text(renewError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        renew()
                    } label: {
                        if renewing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(NSLocalizedString("Renew certificate", comment: ""))
                        }
                    }
                    .disabled(renewing)
                    Spacer()
                    Button(role: .destructive) {
                        Task { @MainActor in
                            await BACEnrollment.shared.unenroll()
                            install = nil
                            onUnenroll()
                        }
                    } label: {
                        Text(NSLocalizedString("Sign out", comment: ""))
                    }
                }
            } else {
                Text(NSLocalizedString("Not enrolled",
                                       comment: "BAC status — not enrolled state"))
                    .font(.title3).bold()
                Text(NSLocalizedString("Open Window → Enroll in bromure.io… to register this Mac with your workspace.",
                                       comment: "BAC status — not enrolled hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private func renew() {
        renewError = nil
        renewing = true
        Task { @MainActor in
            defer { renewing = false }
            do {
                let notAfter = try await BACEnrollment.shared.fetchLeafCert()
                leafExpiresAt = notAfter
            } catch {
                renewError = error.localizedDescription
            }
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
