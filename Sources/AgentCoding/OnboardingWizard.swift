import SwiftUI

// MARK: - First-run onboarding wizard
//
// Replaces the bare "Get Started" screen with a guided first run:
//
//   1. Welcome
//   2. Install the base image      (skipped when one is already present)
//   3. Offer to scan for credentials
//   4. Pick which discovered files to import (plus any .env chosen by hand)
//   5. Models — the global Models pane, so every provider the user wants is
//      signed in (or keyed) before the first workspace exists (first run only)
//   6. Done — the first workspace is created silently on the way out
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
        /// Review / add model providers (first run only — a new-workspace run
        /// inherits the global settings already in place).
        case models
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

    /// A provider sign-in running from the Models step. Same shape as the
    /// chat's sign-in card: the host does the OAuth in a hidden throwaway
    /// machine and the user only sees progress — never a terminal. The URL /
    /// device code are lifted from that machine's screen for the CLIs whose
    /// browser hand-off doesn't reach the host on its own.
    struct SignIn: Equatable {
        let provider: ModelProvider
        var providerName: String
        var status: String?
        var error: String?
        var authURL: String?
        var deviceCode: String?
        var succeeded = false
    }
    var signIn: SignIn?

    init(needsImage: Bool, purpose: Purpose = .firstRun) {
        self.needsImage = needsImage
        self.purpose = purpose
        step = purpose == .newWorkspace ? .scanOffer : .welcome
    }

    /// Where a rail step sits relative to the current one, so the list can show
    /// a tick, a filled dot, or a hollow dot.
    enum StepState { case done, current, upcoming }

    /// Linear order used only for the rail's progress rendering.
    private var order: [Step] { [.welcome, .installing, .scanOffer, .pick, .models, .done] }

    /// Whether this run shows the Models step: first run only.
    var showsModels: Bool { purpose == .firstRun }

    func state(of s: Step) -> StepState {
        guard let a = order.firstIndex(of: s), let b = order.firstIndex(of: step) else {
            return .upcoming
        }
        return a < b ? .done : (a == b ? .current : .upcoming)
    }

    /// Ticked rows — what the Import button counts. Deliberately rows and not
    /// credentials: a .gitconfig contributing only an identity carries no
    /// credential, yet it is plainly one of the items the user ticked.
    var selectedCount: Int { findings.filter(\.include).count }

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
//
// Classic macOS setup-assistant chrome: an artwork rail down the left with the
// step list over it, the current step's content on the right, and a fixed
// button bar along the bottom. The rail art is the marketing site's hero photo
// (day/night, matched to the system appearance) cropped vertical, under a
// gradient scrim so the step list stays legible over any part of the image.

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
    /// Sign-in / log-out / model-list hooks for the Models step (nil hides
    /// the sign-in buttons — the pane still takes API keys).
    var modelsHooks: ModelsSubscriptionHooks? = nil
    /// Abandon the sign-in running from the Models step (tears the hidden
    /// throwaway machine down).
    var onCancelSignIn: () -> Void = {}
    /// Dismiss a finished (succeeded or failed) sign-in card.
    var onDismissSignIn: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    /// Wizard content size. The window is fixed, so the root carries a definite
    /// frame — an `.infinity` max height reads as "as tall as possible" to
    /// NSHostingView, which AppKit then clamps to the whole screen. Tall enough
    /// for the Models board (sources column + six agent rows) without scrolling.
    static let contentSize = CGSize(width: 780, height: 600)

    var body: some View {
        HStack(spacing: 0) {
            rail
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                buttonBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .background(.background)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    }

    // MARK: Rail

    /// Steps shown in the rail. The install step is hidden when there's nothing
    /// to install, so the list never advertises work that won't happen.
    private var railSteps: [(step: OnboardingWizardModel.Step, label: String)] {
        var s: [(OnboardingWizardModel.Step, String)] = []
        // Explicit NSLocalizedString, not a bare literal: these travel as
        // `String` into `Text(label)`, and Text only auto-localizes a literal.
        if model.purpose == .firstRun {
            s.append((.welcome, NSLocalizedString("Welcome", comment: "wizard step")))
        }
        if model.needsImage {
            s.append((.installing, NSLocalizedString("Install", comment: "wizard step")))
        }
        s.append((.scanOffer, NSLocalizedString("Credentials", comment: "wizard step")))
        s.append((.pick, NSLocalizedString("Choose", comment: "wizard step")))
        if model.showsModels {
            s.append((.models, NSLocalizedString("Models", comment: "wizard step")))
        }
        s.append((.done, NSLocalizedString("Done", comment: "wizard step")))
        return s
    }

    private var railImage: Image? {
        let name = scheme == .dark ? "wizard-night" : "wizard-day"
        // Ships in the SPM resource bundle, like every other asset here — a
        // hand copy into Contents/Resources only exists on machines whose
        // build script put it there, which is how this came to render as a
        // bare gradient elsewhere. Bundle.main is kept as a fallback so app
        // bundles laid out the old way still find it.
        let url = acResourceBundle.url(forResource: name, withExtension: "jpg",
                                       subdirectory: "ac")
            ?? Bundle.main.url(forResource: name, withExtension: "jpg")
        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: img)
    }

    private var rail: some View {
        // The step list is the PRIMARY view here; the photo and scrim are
        // backgrounds behind it. That matters for layout: a background is sized
        // to its primary view, so the rail's height comes from the window
        // rather than from the image (a GeometryReader here has no intrinsic
        // height and blows the hosting view up to thousands of points).
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable().interpolation(.high)
                        .frame(width: 26, height: 26)
                }
                Text("Bromure")
                    .font(.headline).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(railSteps.enumerated()), id: \.offset) { _, entry in
                    stepRow(entry.step, entry.label)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(width: 208, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Bottom-anchored: the lower half of the photo (lake, reflection,
        // campfire) is the interesting part, so an overflowing fill should lose
        // sky, not subject.
        // One background holding both layers: stacked `.background` modifiers
        // go progressively FURTHER back, so a second one would put the scrim
        // behind the photo instead of over it.
        .background {
            ZStack(alignment: .bottom) {
                if let railImage {
                    railImage.resizable().scaledToFill()
                } else {
                    // No artwork (unbundled dev build) — a flat tint still
                    // reads as a rail rather than a broken layout.
                    Color.accentColor.opacity(0.85)
                }
                // Scrim: heaviest at the top where the wordmark and step list
                // sit, easing off so the image shows through lower down.
                LinearGradient(
                    colors: [.black.opacity(0.80), .black.opacity(0.55), .black.opacity(0.25)],
                    startPoint: .top, endPoint: .bottom)
            }
            .clipped()
        }
        .clipped()
    }

    private func stepRow(_ step: OnboardingWizardModel.Step, _ label: String) -> some View {
        let state = model.state(of: step)
        return HStack(spacing: 9) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
                case .current:
                    Image(systemName: "circle.fill").foregroundStyle(.white)
                        .font(.system(size: 8))
                        .frame(width: 13, height: 13)
                        .background(Circle().stroke(.white, lineWidth: 1.5))
                case .upcoming:
                    Image(systemName: "circle").foregroundStyle(.white.opacity(0.45))
                }
            }
            .font(.system(size: 13))
            .frame(width: 16)
            Text(label)
                .font(.system(size: 13, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(state == .upcoming ? .white.opacity(0.55) : .white)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:    welcome
        case .installing: installing
        case .scanOffer:  scanOffer
        case .pick:       pick
        case .models:     models
        case .done:       done
        }
    }

    /// Shared heading so every step lines up on the same baseline.
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 21, weight: .semibold))
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(NSLocalizedString("Welcome to Bromure", comment: ""),
                    NSLocalizedString("Let's get started.", comment: ""))
            Text(model.needsImage
                 ? NSLocalizedString("Bromure runs your coding agents inside disposable Linux VMs. First we'll install the base image, then optionally bring over the credentials you already have on this Mac.", comment: "")
                 : NSLocalizedString("Bromure runs your coding agents inside disposable Linux VMs. Your base image is ready — next we can bring over the credentials you already have on this Mac.", comment: ""))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(28)
    }

    private var installing: some View {
        InitializingView(model: installProgress,
                         title: NSLocalizedString("Setting up the base image", comment: ""),
                         subtitle: NSLocalizedString(
                            "Downloading the image and applying patches. This is the one-time install — don't close the window.",
                            comment: ""),
                         onCancel: onCancelInstall)
    }

    private var scanOffer: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(model.purpose == .newWorkspace
                    ? NSLocalizedString("Set up from your existing credentials?", comment: "")
                    : NSLocalizedString("Import your existing credentials?", comment: ""),
                    NSLocalizedString("Bromure can read the config files already on this Mac and offer to bring them in.", comment: ""))

            // What we look at, so "scan my Mac" isn't a blank cheque.
            VStack(alignment: .leading, spacing: 6) {
                sourceLine("arrow.triangle.branch",
                           NSLocalizedString("git config, saved passwords, GitHub & GitLab CLIs",
                                             comment: "wizard: what the scan reads"))
                sourceLine("shippingbox.fill",
                           NSLocalizedString("Docker, npm, PyPI, crates.io",
                                             comment: "wizard: what the scan reads"))
                sourceLine("cloud.fill",
                           NSLocalizedString("AWS, Kubernetes, DigitalOcean",
                                             comment: "wizard: what the scan reads"))
                sourceLine("sparkles",
                           NSLocalizedString("Claude, ChatGPT, Grok & Kimi logins and API keys",
                                             comment: "wizard: what the scan reads"))
                sourceLine("key.horizontal.fill",
                           NSLocalizedString("SSH keys, .env files",
                                             comment: "wizard: what the scan reads"))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            Label {
                Text("Real values never leave this Mac. The VM receives only a fake, which the proxy swaps back on outbound requests.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield.fill").foregroundStyle(.green)
            }
            Spacer()
        }
        .padding(28)
    }

    private func sourceLine(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
            Text(text).font(.caption)
            Spacer()
        }
    }

    private var pick: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(NSLocalizedString("Here's what I found", comment: ""),
                    model.findings.isEmpty && !model.scanning
                    ? NSLocalizedString("Nothing to import — you can still add a .env file by hand.", comment: "")
                    : NSLocalizedString("Tick what to bring in. Each secret stays on this Mac; the VM only ever sees a fake.", comment: ""))

            if model.scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.findings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.folder")
                        .font(.title).foregroundStyle(.tertiary)
                    Text("No config files found.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach($model.findings) { $f in FindingRow(finding: $f) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 4)
    }

    /// The global Models board, exactly as in Preferences: whatever the scan
    /// imported already shows as signed in / keyed; the user adds the rest
    /// here so the first workspace starts with every agent it needs.
    private var models: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading(NSLocalizedString("Your models", comment: ""),
                    NSLocalizedString("Sign in to the providers you want to use, or paste API keys. Each agent then runs its provider’s default model — pick a specific one on the right if you like, now or later in Preferences → Models.", comment: ""))
                .padding(.horizontal, 28)
                .padding(.top, 28)
            if let signIn = model.signIn {
                WizardSignInCard(signIn: signIn,
                                 onCancel: onCancelSignIn,
                                 onDismiss: onDismissSignIn,
                                 onOpenURL: { url in
                                     if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                                 })
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
            }
            ScrollView {
                GlobalModelsSettingsView(subscription: modelsHooks, showsTitle: false)
                    .padding(.horizontal, 10)
            }
            // One sign-in at a time: the board waits until it settles.
            .disabled(model.signIn.map { !$0.succeeded && $0.error == nil } ?? false)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.green)
                heading(NSLocalizedString("You're all set", comment: ""),
                        model.summary.map(\.headline)
                            ?? (model.showsModels
                                ? NSLocalizedString("Your first machine is ready — start a session and pick any agent.", comment: "")
                                : NSLocalizedString("Enjoy — add credentials any time from a workspace's Credentials pane.", comment: "")))
            }
            if let d = model.summary?.detail, !d.isEmpty {
                Text(d).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(28)
    }

    // MARK: Button bar

    @ViewBuilder
    private var buttonBar: some View {
        HStack(spacing: 10) {
            if model.step == .pick {
                Button {
                    addEnvFile()
                } label: {
                    Label("Add .env file…", systemImage: "plus")
                }
            }
            Spacer()
            switch model.step {
            case .welcome:
                Button(model.needsImage ? "Get Started" : "Continue") {
                    model.advanceFromWelcome()
                    if model.step == .installing { onStartInstall() }
                }
                .keyboardShortcut(.defaultAction)
            case .installing:
                // The installer view owns its own cancel affordance on error.
                EmptyView()
            case .scanOffer:
                Button("Not Now") { onFinish([]) }
                Button("Scan This Mac") { model.beginScan() }
                    .keyboardShortcut(.defaultAction)
            case .pick:
                Button("Skip") { onFinish([]) }
                Button(model.selectedCount == 0
                       ? NSLocalizedString("Continue", comment: "")
                       : String(format: NSLocalizedString("Import %d", comment: "n items"),
                                model.selectedCount)) {
                    onFinish(model.findings.filter(\.include))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.scanning)
            case .models:
                Button("Continue") { model.step = .done }
                    .keyboardShortcut(.defaultAction)
                    // Not while a sign-in is mid-flight: leaving would strand
                    // the hidden machine and lose the tokens it's about to get.
                    .disabled(model.signIn.map { !$0.succeeded && $0.error == nil } ?? false)
            case .done:
                Button("Start Using Bromure", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .buttonStyle(.automatic)
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
}

// MARK: - Sign-in card (Models step)

/// The chat's host sign-in card, for the wizard: explainer, progress, and —
/// when the CLI's browser hand-off didn't reach the host — the sign-in URL
/// and device code lifted from the hidden machine's screen. No terminal.
private struct WizardSignInCard: View {
    let signIn: OnboardingWizardModel.SignIn
    let onCancel: () -> Void
    let onDismiss: () -> Void
    let onOpenURL: (String) -> Void

    private var inFlight: Bool { !signIn.succeeded && signIn.error == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: signIn.succeeded ? "checkmark.circle.fill" : "person.badge.key.fill")
                .font(.system(size: 15))
                .foregroundStyle(signIn.succeeded ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(signIn.succeeded
                     ? String(format: NSLocalizedString("Signed in to %@", comment: "wizard sign-in"), signIn.providerName)
                     : String(format: NSLocalizedString("Sign in to %@", comment: "wizard sign-in"), signIn.providerName))
                    .font(.system(size: 12.5, weight: .semibold))
                if inFlight {
                    Text(String(format: NSLocalizedString(
                        "Bromure signs you in on this Mac and keeps your %@ account out of every machine — agents only ever see a stand-in key.",
                        comment: "wizard sign-in"), signIn.providerName))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let status = signIn.status {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                    if let url = signIn.authURL {
                        Button { onOpenURL(url) } label: {
                            Label(NSLocalizedString("Open sign-in page", comment: "wizard sign-in"),
                                  systemImage: "arrow.up.right.square.fill")
                        }
                        .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
                    }
                    if let code = signIn.deviceCode {
                        HStack(spacing: 6) {
                            Text(NSLocalizedString("Your code:", comment: "wizard sign-in"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(code)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } else if let error = signIn.error {
                    Text(error)
                        .font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(NSLocalizedString("Your account stays on this Mac; every machine can use it.", comment: "wizard sign-in"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if inFlight {
                Button(NSLocalizedString("Cancel", comment: "wizard sign-in"), action: onCancel)
                    .controlSize(.small)
            } else {
                Button(NSLocalizedString("OK", comment: "wizard sign-in"), action: onDismiss)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill((signIn.succeeded ? Color.green : Color.orange).opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder((signIn.succeeded ? Color.green : Color.orange).opacity(0.3)))
    }
}

// MARK: - One discovered file

private struct FindingRow: View {
    @Binding var finding: ConfigScan.Finding

    var body: some View {
        Toggle(isOn: $finding.include) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: finding.symbol)
                    .foregroundStyle(.tint).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(finding.title).font(.system(size: 12, weight: .medium))
                        Text(finding.displayPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text(finding.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }
}
