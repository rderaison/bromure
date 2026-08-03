import SwiftUI

// MARK: - First-run onboarding wizard
//
// Replaces the bare "Get Started" screen with a guided first run:
//
//   1. Welcome
//   2. Install the base image      (skipped when one is already present)
//   3. Offer to scan for credentials — declining ends the wizard
//   4. Pick which discovered files to import (plus any .env chosen by hand)
//   5. Done
//
// Everything imported lands in a workspace draft, so the credentials the user
// already has on their Mac are carried in as *faked* credentials: the real
// values stay host-side and the VM only ever sees a swap token. That is the
// whole reason the scan is worth offering — it is strictly safer than the
// files it reads from, where the secrets sit in cleartext.

@MainActor
@Observable
final class OnboardingWizardModel {
    enum Step: Equatable {
        case welcome
        case installing
        case scanOffer
        case pick
        case done
    }

    /// Why the wizard is open. First run walks the whole flow; a
    /// new-workspace run (option-click on New Workspace) skips the welcome and
    /// install and goes straight to the credential scan, because the user
    /// already knows what Bromure is and asked for exactly this.
    enum Purpose { case firstRun, newWorkspace }
    let purpose: Purpose

    var step: Step = .welcome
    /// Discovered config files, in scan order. `include` drives the checkboxes.
    var findings: [ConfigScan.Finding] = []
    /// True while `ConfigScan.scan()` is running (it touches the filesystem).
    var scanning = false
    /// Set once the import has been applied — drives the summary on `.done`.
    var summary: ConfigScan.Summary?
    /// The workspace this run created or filled, so leaving can open its editor.
    var createdProfileID: UUID?
    /// Whether a base image already exists, so step 2 can be skipped.
    let needsImage: Bool

    init(needsImage: Bool, purpose: Purpose = .firstRun) {
        self.needsImage = needsImage
        self.purpose = purpose
        step = purpose == .newWorkspace ? .scanOffer : .welcome
    }

    var selectedCount: Int { findings.filter(\.include).count }
    var totalCredentials: Int {
        findings.filter(\.include).reduce(0) { $0 + $1.credentialCount }
    }

    /// Welcome → install (first run) or straight to the scan offer.
    func advanceFromWelcome() {
        step = needsImage ? .installing : .scanOffer
    }

    func beginScan() {
        scanning = true
        step = .pick
        // Off the main actor: reads a dozen files under the home directory.
        Task.detached(priority: .userInitiated) {
            let found = ConfigScan.scan()
            await MainActor.run {
                self.findings = found
                self.scanning = false
            }
        }
    }

    /// Add a hand-picked .env file to the list (already-listed paths are a
    /// no-op so a double-add can't duplicate a row).
    func addEnvFile(_ url: URL) {
        guard !findings.contains(where: { $0.path == url }) else { return }
        if let f = ConfigScan.envFinding(at: url) { findings.append(f) }
    }
}

// MARK: - Wizard view

struct OnboardingWizardView: View {
    @Bindable var model: OnboardingWizardModel
    /// Step 2's live install progress (reuses the existing installer view).
    let installProgress: InitProgressModel
    let onStartInstall: () -> Void
    let onCancelInstall: () -> Void
    /// Called on finish with the files the user chose (possibly empty).
    let onFinish: ([ConfigScan.Finding]) -> Void
    /// Leave setup and land on the workspace home.
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch model.step {
            case .welcome:    welcome
            case .installing: installing
            case .scanOffer:  scanOffer
            case .pick:       pick
            case .done:       done
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 1 — Welcome

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: { $0.size = NSSize(width: 96, height: 96); return $0 }(icon))
                    .resizable().interpolation(.high)
                    .frame(width: 96, height: 96)
            }
            Text("Welcome to Bromure").font(.title2.bold())
            Text("Let's get started.").font(.title3).foregroundStyle(.secondary)
            Text(model.needsImage
                 ? "Bromure runs your coding agents inside disposable Linux VMs. First we'll install the base image, then optionally bring over the credentials you already have on this Mac."
                 : "Bromure runs your coding agents inside disposable Linux VMs. Your base image is ready — next we can bring over the credentials you already have on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)

            Button {
                model.advanceFromWelcome()
                if model.step == .installing { onStartInstall() }
            } label: {
                Label(model.needsImage ? "Get Started" : "Continue",
                      systemImage: "arrow.right.circle.fill")
                    .frame(width: 180)
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(24)
    }

    // MARK: 2 — Install (reuses the existing installer surface)

    private var installing: some View {
        InitializingView(model: installProgress,
                         title: NSLocalizedString("Setting up the base image", comment: ""),
                         subtitle: NSLocalizedString(
                            "Downloading the image and applying patches. This is the one-time install — don't close the window.",
                            comment: ""),
                         onCancel: onCancelInstall)
    }

    // MARK: 3 — Offer the scan

    private var scanOffer: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text(model.purpose == .newWorkspace
                 ? "Set up this workspace from your existing credentials?"
                 : "Import your existing credentials?")
                .font(.title3.bold())
            Text("Bromure can look through the config files already on this Mac — git, Docker, AWS, Kubernetes, npm, the GitHub and GitLab CLIs, your agent logins, and more — and offer to bring them in.\n\nReal values never leave your Mac: each one is stored here and the VM receives only a fake, which the proxy swaps back on outbound requests. Nothing is read until you say yes, and nothing is imported until you pick it on the next screen.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 480)

            HStack(spacing: 12) {
                Button("No thanks") { onFinish([]) }
                    .controlSize(.large)
                Button {
                    model.beginScan()
                } label: {
                    Label("Scan my Mac", systemImage: "magnifyingglass")
                        .frame(width: 160)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: 4 — Pick what to import

    private var pick: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Here's what I found").font(.title3.bold())
            if model.scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.findings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.folder")
                        .font(.title).foregroundStyle(.secondary)
                    Text("No config files found.").font(.subheadline.weight(.medium))
                    Text("You can still add a .env file by hand, or skip and configure credentials later in the workspace editor.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Tick what you'd like to bring in. Each secret stays on this Mac — the VM only ever sees a fake.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($model.findings) { $f in
                            FindingRow(finding: $f)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Button {
                    addEnvFile()
                } label: {
                    Label("Add .env file…", systemImage: "plus")
                }
                .controlSize(.small)
                Spacer()
                Button("Skip") { onFinish([]) }
                Button {
                    onFinish(model.findings.filter(\.include))
                } label: {
                    Text(model.selectedCount == 0
                         ? "Continue"
                         : "Import \(model.totalCredentials) credential\(model.totalCredentials == 1 ? "" : "s")")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.scanning)
            }
        }
        .padding(20)
    }

    private func addEnvFile() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose a .env file", comment: "")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addEnvFile(url)
    }

    // MARK: 5 — Done

    private var done: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52)).foregroundStyle(.green)
            Text("You're all set").font(.title2.bold())
            if let s = model.summary, s.total > 0 {
                Text(s.headline).font(.callout).multilineTextAlignment(.center)
                if !s.detail.isEmpty {
                    Text(s.detail).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                }
            } else {
                Text("Enjoy — you can add credentials any time from a workspace's Credentials pane.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            Button(action: onDone) {
                Label("Start using Bromure", systemImage: "arrow.right.circle.fill")
                    .frame(width: 200)
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - One discovered file

private struct FindingRow: View {
    @Binding var finding: ConfigScan.Finding

    var body: some View {
        Toggle(isOn: $finding.include) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: finding.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(finding.title).font(.body.weight(.medium))
                        Text(finding.displayPath)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(finding.include ? 0.05 : 0)))
    }
}
