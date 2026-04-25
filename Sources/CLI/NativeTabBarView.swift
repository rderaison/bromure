import AppKit
import SandboxEngine
import Security
import SecurityInterface
import SwiftUI

/// Observable model behind the native tab bar. Fed by ``TabBridge`` events
/// on the main actor; consumed by ``NativeTabBarView`` via `@Bindable`.
@MainActor @Observable
final class NativeTabBarModel {
    var tabs: [TabInfo] = []
    var pendingAddress: String = ""
    var editingAddress: Bool = false

    /// Per-tab URL drafts so that typing in tab #1's address bar doesn't
    /// stomp on what the user had in tab #0. Keyed by tab id; entries are
    /// dropped when the guest reports a real navigation in that tab (the
    /// canonical URL takes over) or when the tab itself is closed.
    private var drafts: [String: String] = [:]

    /// Set when the user requests a new tab via ⌘T or `+`. The next time
    /// the active tab changes (i.e. the guest acks the new target), we
    /// fire ``onAddressFocusRequested`` so the host can put keyboard focus
    /// on the new tab's URL field. Cleared after firing.
    var pendingFocusOnActiveChange: Bool = false


    /// What to show in the URL field while the active tab is NOT being
    /// edited. Strips the scheme (so "macbidouille.com/news/…" instead
    /// of "https://macbidouille.com/news/…") for a cleaner read, but
    /// keeps the path/query/fragment so two tabs on the same host stay
    /// distinguishable. The full URL with scheme is still swapped in on
    /// focus for editing/copying.
    static func displayValue(for tab: TabInfo?) -> String {
        guard let tab, !tab.url.isEmpty else { return "" }
        guard let url = URL(string: tab.url), let host = url.host else {
            return tab.url
        }
        var s = host
        let path = url.path
        if !path.isEmpty && path != "/" { s += path }
        if let q = url.query, !q.isEmpty { s += "?" + q }
        if let f = url.fragment, !f.isEmpty { s += "#" + f }
        return s
    }

    /// Called when the user clicks a tab or picks one via keyboard.
    var onActivate: ((String) -> Void)?

    /// Optional async fetcher for the DER-encoded cert chain serving an
    /// origin. Wired by ``BrowserSession`` to ``TabBridge.fetchCertificate``.
    /// SiteInfoPopover invokes this when the user opens it on an HTTPS site.
    var fetchCertificate: ((String) async -> [Data])?

    /// Called when the user presses the close "×" on a tab.
    var onClose: ((String) -> Void)?

    /// Called when the user clicks the "+" button or presses ⌘T.
    var onNewTab: (() -> Void)?

    /// Called when the user confirms the address bar (Enter key).
    var onNavigate: ((String) -> Void)?

    /// Called when the user hits ⌘R / the reload button.
    var onReload: ((String) -> Void)?

    /// Called when the user clicks the back button.
    var onBack: ((String) -> Void)?

    /// Called when the user clicks the forward button.
    var onForward: ((String) -> Void)?

    init() {}

    var activeTab: TabInfo? { tabs.first(where: { $0.active }) }

    /// Push a fresh list of tabs from the bridge. Preserves the current
    /// address-bar edit state so we don't stomp on user typing mid-load.
    ///
    /// Also preserves the host's local view of "which tab is active" when
    /// the guest doesn't report one — the xdotool-based active-window
    /// detection in tab-agent can miss on title-empty or during navigation
    /// transitions, and without this override the URL bar would point at
    /// nothing and the user would lose their navigation target.
    func setTabs(_ newTabs: [TabInfo]) {
        let wasEditing = editingAddress
        let oldActiveID = activeTab?.id
        let oldActiveURL = activeTab?.url

        var merged = newTabs
        if !merged.contains(where: { $0.active }), let stickyID = oldActiveID,
           let idx = merged.firstIndex(where: { $0.id == stickyID }) {
            merged[idx].active = true
        }
        if !merged.contains(where: { $0.active }), !merged.isEmpty {
            merged[0].active = true
        }

        // Drop drafts for tabs that no longer exist.
        let liveIDs = Set(merged.map(\.id))
        drafts = drafts.filter { liveIDs.contains($0.key) }

        tabs = merged

        let newActiveID = activeTab?.id

        if oldActiveID != newActiveID {
            // The guest just told us a different tab is active (e.g. it
            // raced an upsert with the user's click). Save the in-flight
            // draft for the previous active and load whatever's stashed
            // for the new one (else fall back to the domain display).
            if let oldID = oldActiveID, !pendingAddress.isEmpty,
               pendingAddress != oldActiveURL {
                drafts[oldID] = pendingAddress
            }
            pendingAddress = newActiveID.flatMap { drafts[$0] }
                ?? Self.displayValue(for: activeTab)
            // The pending-focus flag is consumed by ActiveTabPill →
            // AddressField when the new field's makeNSView sees it set;
            // we intentionally don't dispatch a focus side-effect here
            // because that races SwiftUI's render of the new pill (the
            // field doesn't exist in the responder chain yet).
            return
        }

        // Same active tab. If the user isn't editing and the canonical URL
        // changed (guest-side navigation completed), drop the draft and
        // sync the field to the new URL's domain.
        if oldActiveURL != activeTab?.url {
            if let id = newActiveID {
                drafts.removeValue(forKey: id)
            }
            if !wasEditing {
                pendingAddress = Self.displayValue(for: activeTab)
            }
            return
        }

        if !wasEditing, pendingAddress.isEmpty {
            pendingAddress = Self.displayValue(for: activeTab)
        }
    }

    /// Optimistically mark a tab active without waiting for the guest to
    /// echo it back. Saves the previous active tab's in-flight draft and
    /// restores any draft already stashed for the newly-selected tab.
    func markActiveLocally(_ id: String) {
        let oldID = activeTab?.id
        let oldURL = activeTab?.url
        if let oldID, oldID != id, !pendingAddress.isEmpty,
           pendingAddress != oldURL {
            drafts[oldID] = pendingAddress
        }

        var updated = tabs
        for i in updated.indices {
            updated[i].active = (updated[i].id == id)
        }
        tabs = updated

        if oldID != id {
            pendingAddress = drafts[id] ?? Self.displayValue(for: activeTab)
        }
    }
}

// MARK: - SwiftUI: compact-mode bar (Safari Compact tab layout)
//
// Safari's Compact Tab Bar (macOS Sequoia/Tahoe) puts every tab on the
// titlebar row, with the active tab acting as the URL bar — its title is
// replaced by an inline address field, and it's wider than its neighbours.
// Inactive tabs show favicon + truncated title. Clicking an inactive tab
// activates it; clicking the active tab focuses the URL field.

struct NativeCompactBarView: View {
    @Bindable var model: NativeTabBarModel

    var body: some View {
        HStack(spacing: 6) {
            // Safari Compact has only back/forward in the global nav area;
            // reload moved inside the active tab (it's URL-scoped, not
            // window-scoped, so it travels with the focused tab).
            navButton("chevron.backward", help: "Back (⌘[)") {
                if let id = model.activeTab?.id { model.onBack?(id) }
            }
            navButton("chevron.forward", help: "Forward (⌘])") {
                if let id = model.activeTab?.id { model.onForward?(id) }
            }

            // The outer grey capsule sizes to its content (no maxWidth on
            // the HStack), and trailing Spacers in the OUTER row push the
            // capsule + new-tab button towards the centre/right. Each tab
            // pill shares space equally inside the capsule via
            // `frame(maxWidth: .infinity)` with low minWidths so they
            // shrink as more tabs open; once an inactive pill is too
            // narrow for its title, its `ViewThatFits` collapses to a
            // favicon-only layout.
            Spacer(minLength: 0)

            HStack(spacing: 1) {
                ForEach(model.tabs) { tab in
                    if tab.active {
                        ActiveTabPill(model: model, tab: tab)
                            .frame(minWidth: 100, idealWidth: 280, maxWidth: 320)
                            .layoutPriority(2)
                            .id(tab.id)
                    } else {
                        InactiveTabPill(model: model, tab: tab)
                            .frame(minWidth: 36, idealWidth: 180, maxWidth: 240)
                            .layoutPriority(1)
                            .id(tab.id)
                    }
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.gray.opacity(0.18)))

            Spacer(minLength: 0)

            Button(action: { model.onNewTab?() }) {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")

            shareButton
        }
        .padding(.horizontal, 8)
    }

    /// Standard macOS share menu (Mail, Messages, AirDrop, Safari Reading
    /// List, …). `ShareLink` requires a non-nil item, so we hand it
    /// `about:blank` as a placeholder when there's no active tab and
    /// disable the button — that avoids the `Optional` initialiser
    /// constraints while keeping the affordance always visible.
    private var shareButton: some View {
        let activeURL = model.activeTab.flatMap { URL(string: $0.url) }
            ?? URL(string: "about:blank")!
        return ShareLink(item: activeURL) {
            Image(systemName: "square.and.arrow.up")
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(model.activeTab?.url.isEmpty ?? true)
        .help("Share")
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(model.activeTab == nil && model.tabs.isEmpty)
    }
}

/// The wide pill: close ◯ × on left, favicon, URL field (centered), reload
/// on right. Lives inside the outer grey capsule as a white inner capsule;
/// no individual stroke since the outer container is the only border.
private struct ActiveTabPill: View {
    @Bindable var model: NativeTabBarModel
    let tab: TabInfo
    @State private var showSiteInfo = false

    var body: some View {
        HStack(spacing: 6) {
            CloseDot { model.onClose?(tab.id) }

            // Click the favicon to open a site-info popover (Chromium's
            // native page-info bubble lives in the hidden chrome UI and
            // isn't reachable via CDP, so we render our own with the data
            // we have).
            FaviconView(data: tab.faviconPNG)
                .frame(width: 14, height: 14)
                .overlay(alignment: .bottomTrailing) {
                    MediaIndicatorDot(camera: tab.usingCamera, microphone: tab.usingMicrophone)
                        .offset(x: 2, y: 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { showSiteInfo.toggle() }
                .popover(isPresented: $showSiteInfo, arrowEdge: .bottom) {
                    SiteInfoPopover(model: model, url: tab.url, title: tab.title)
                }

            AddressField(
                text: $model.pendingAddress,
                isEditing: $model.editingAddress,
                centered: true,
                shouldFocusOnAppear: model.pendingFocusOnActiveChange,
                onFocusConsumed: { model.pendingFocusOnActiveChange = false },
                onBeginEditing: {
                    // Swap the domain display for the editable full URL,
                    // unless the user is mid-draft (we already preserved
                    // their typed text in pendingAddress).
                    if let url = model.activeTab?.url, !url.isEmpty,
                       model.pendingAddress == NativeTabBarModel.displayValue(for: model.activeTab) {
                        model.pendingAddress = url
                    }
                },
                onEndEditing: {
                    // User clicked away without submitting. Revert to the
                    // domain display so the field looks like a label again.
                    model.pendingAddress = NativeTabBarModel.displayValue(for: model.activeTab)
                },
                onSubmit: { model.onNavigate?(model.pendingAddress) }
            )
            .frame(maxWidth: .infinity)

            Button(action: { model.onReload?(tab.id) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(0.65)
            .help("Reload (⌘R)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
        // Blue stroke only while editing — otherwise no border (the white
        // capsule against the outer grey is contrast enough).
        .overlay(
            Group {
                if model.editingAddress {
                    Capsule().stroke(Color.accentColor, lineWidth: 2)
                }
            }
        )
    }
}

/// The narrow pill: favicon + title, centered, no background, no border.
/// Sits on the outer grey capsule. Tapping activates this tab. As tabs
/// pile up the pill shrinks; below the threshold for the title to fit,
/// the inner `ViewThatFits` collapses to a favicon-only rendering so a
/// gazillion tabs each remain at least clickable.
private struct InactiveTabPill: View {
    @Bindable var model: NativeTabBarModel
    let tab: TabInfo

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Full layout: favicon + title, centred. The Text's frame caps
            // its `idealWidth` at 80pt so ViewThatFits doesn't reject the
            // full layout for long titles ("What Is My IP Address? — …" or
            // similar would otherwise report ~200pt natural width and lose
            // out to the compact variant). With this cap the fit-check
            // becomes "does at least 80pt of label fit?" which is what we
            // actually care about — anything above 80pt looks like a
            // proper tab; anything below is unreadable.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                FaviconView(data: tab.faviconPNG)
                    .frame(width: 14, height: 14)
                    .overlay(alignment: .bottomTrailing) {
                        MediaIndicatorDot(camera: tab.usingCamera, microphone: tab.usingMicrophone)
                            .offset(x: 2, y: 2)
                    }
                Text(displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, idealWidth: 80, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }

            // Compact layout: favicon only, centred.
            HStack {
                Spacer(minLength: 0)
                FaviconView(data: tab.faviconPNG)
                    .frame(width: 14, height: 14)
                    .overlay(alignment: .bottomTrailing) {
                        MediaIndicatorDot(camera: tab.usingCamera, microphone: tab.usingMicrophone)
                            .offset(x: 2, y: 2)
                    }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { model.onActivate?(tab.id) }
    }

    private var displayTitle: String {
        if !tab.title.isEmpty { return tab.title }
        if let url = URL(string: tab.url), let host = url.host { return host }
        return tab.url.isEmpty ? "New Tab" : tab.url
    }
}

/// Site-info popover. Chromium's page-info bubble lives in the hidden
/// chrome UI and isn't exposed via CDP, so we render our own — connection
/// security, host, full URL, copy action, plus the X.509 certificate
/// summary fetched on demand from the guest. "View Full Certificate"
/// opens the system `SFCertificatePanel` with the full cert chain.
private struct SiteInfoPopover: View {
    @Bindable var model: NativeTabBarModel
    let url: String
    let title: String

    @State private var certInfo: CertificateSummary?
    @State private var certChain: [SecCertificate] = []
    @State private var certError: String?
    @State private var loadingCert = false

    private var parsed: URL? { URL(string: url) }
    private var scheme: String { parsed?.scheme?.lowercased() ?? "" }
    private var host: String { parsed?.host ?? url }
    private var isSecure: Bool { scheme == "https" }
    private var schemeKnown: Bool { !scheme.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: securityIcon)
                    .font(.title2)
                    .foregroundStyle(securityColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(securityTitle).font(.headline)
                    Text(securityDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Site").font(.subheadline.weight(.medium))
                HStack {
                    Text(host).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Copy URL")
                }
            }

            if isSecure {
                Divider()
                certificateSection
            }

            if !title.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page Title").font(.subheadline.weight(.medium))
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Full URL").font(.subheadline.weight(.medium))
                Text(url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(width: 340)
        .task(id: url) {
            await loadCertificate()
        }
    }

    @ViewBuilder
    private var certificateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Certificate").font(.subheadline.weight(.medium))
            if loadingCert {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let info = certInfo {
                certificateRow("Issued to", info.subject)
                certificateRow("Issued by", info.issuer)
                if let from = info.notBefore, let to = info.notAfter {
                    certificateRow("Valid", "\(formatDate(from)) – \(formatDate(to))")
                }
                Button("View Full Certificate\u{2026}") {
                    openCertificatePanel()
                }
                .controlSize(.small)
                .padding(.top, 4)
            } else if let err = certError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func certificateRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    private func loadCertificate() async {
        guard isSecure, let parsed,
              let scheme = parsed.scheme, let host = parsed.host
        else {
            certInfo = nil
            certChain = []
            return
        }
        let origin = "\(scheme)://\(host)"
        loadingCert = true
        defer { loadingCert = false }
        guard let fetcher = model.fetchCertificate else {
            certError = "Certificate inspection isn\u{2019}t available."
            return
        }
        let derList = await fetcher(origin)
        guard !derList.isEmpty else {
            certError = "Couldn\u{2019}t fetch the certificate chain."
            return
        }
        let chain = derList.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        certChain = chain
        certInfo = chain.first.flatMap(CertificateSummary.from(certificate:))
        certError = certInfo == nil ? "Couldn\u{2019}t parse the certificate." : nil
    }

    private func openCertificatePanel() {
        guard !certChain.isEmpty,
              let panel = SFCertificatePanel.shared() else { return }
        panel.setPolicies(SecPolicyCreateSSL(true, host as CFString))
        panel.beginSheet(
            for: nil,
            modalDelegate: nil,
            didEnd: nil,
            contextInfo: nil,
            certificates: certChain,
            showGroup: true
        )
    }

    private var securityIcon: String {
        if !schemeKnown { return "questionmark.circle.fill" }
        return isSecure ? "lock.fill" : "exclamationmark.triangle.fill"
    }

    private var securityColor: Color {
        if !schemeKnown { return .secondary }
        return isSecure ? .green : .orange
    }

    private var securityTitle: LocalizedStringKey {
        if !schemeKnown { return "Connection details unavailable" }
        return isSecure ? "Connection is secure" : "Connection is not secure"
    }

    private var securityDetail: LocalizedStringKey {
        if !schemeKnown {
            return "This page doesn\u{2019}t use a standard web URL."
        }
        return isSecure
            ? "Information you send to this site (passwords, credit card numbers) is encrypted."
            : "Information you send to this site can be intercepted by others."
    }
}

/// Red recording dot overlaid on a tab's favicon when the tab is using
/// the webcam or microphone. Mirrors what Chromium shows in its own tab
/// strip (which is hidden on our side via the cropping). Sized to match
/// the favicon's bottom-right corner.
private struct MediaIndicatorDot: View {
    let camera: Bool
    let microphone: Bool

    var body: some View {
        if camera || microphone {
            Circle()
                .fill(Color.red)
                .overlay(Circle().stroke(Color.white, lineWidth: 0.75))
                .frame(width: 6, height: 6)
                .help(helpText)
        }
    }

    private var helpText: String {
        switch (camera, microphone) {
        case (true, true):  return "This tab is using the camera and microphone"
        case (true, false): return "This tab is using the camera"
        case (false, true): return "This tab is using the microphone"
        default:            return ""
        }
    }
}

/// Cherry-picked summary of an X.509 cert for display in the popover.
/// Full details (extensions, public key, fingerprints, …) are reachable
/// via the system's SFCertificatePanel.
private struct CertificateSummary: Equatable {
    var subject: String
    var issuer: String
    var notBefore: Date?
    var notAfter: Date?

    static func from(certificate cert: SecCertificate) -> CertificateSummary? {
        let subject = (SecCertificateCopySubjectSummary(cert) as String?) ?? ""

        let oids = [
            kSecOIDX509V1IssuerName,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter,
        ] as CFArray
        let values = SecCertificateCopyValues(cert, oids, nil) as? [CFString: Any] ?? [:]

        let issuer = commonName(from: values[kSecOIDX509V1IssuerName])
            ?? "Unknown issuer"
        let notBefore = date(from: values[kSecOIDX509V1ValidityNotBefore])
        let notAfter = date(from: values[kSecOIDX509V1ValidityNotAfter])

        return CertificateSummary(
            subject: subject,
            issuer: issuer,
            notBefore: notBefore,
            notAfter: notAfter
        )
    }

    private static func commonName(from raw: Any?) -> String? {
        // Each OID's value comes back as a dict { "type": ..., "value": [...]
        // }. For X.500 names, .value is an array of [{"label":"CN","value":...}, …].
        guard let dict = raw as? [String: Any],
              let entries = dict["value"] as? [[String: Any]]
        else { return nil }
        for entry in entries {
            if let label = entry["label"] as? String, label == "CN",
               let value = entry["value"] as? String, !value.isEmpty {
                return value
            }
        }
        // Fall back to organisation name if no CN.
        for entry in entries {
            if let label = entry["label"] as? String, label == "O",
               let value = entry["value"] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func date(from raw: Any?) -> Date? {
        guard let dict = raw as? [String: Any] else { return nil }
        if let date = dict["value"] as? Date { return date }
        // SecCertificateCopyValues sometimes returns absolute time as NSNumber.
        if let interval = dict["value"] as? Double {
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        return nil
    }
}

/// Black filled circle with a white × on top — Safari Compact's tab close
/// affordance. Only used inside the active pill: inactive tabs don't show
/// a close button at all.
private struct CloseDot: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help("Close tab (⌘W)")
    }
}

private struct FaviconView: View {
    let data: Data?

    var body: some View {
        if let data, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Address bar (NSTextField under the hood so we get proper field-editor
// behaviour — selection, undo, paste — without rebuilding it in SwiftUI).

private struct AddressField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    /// When true, the field's text alignment is centred — used for the
    /// non-editing "domain" display so it visually sits in the middle of
    /// the active pill, Safari-style. While editing we left-align so the
    /// cursor doesn't jump as the user types.
    var centered: Bool = false
    /// One-shot: when true, the field grabs keyboard focus right after it
    /// gets attached to the window. Used by `ActiveTabPill` so a tab that
    /// just opened via ⌘T or `+` lands the cursor in its address bar
    /// without requiring an extra click.
    var shouldFocusOnAppear: Bool = false
    /// Called once the focus request above has been honoured, so the
    /// caller can clear its trigger flag.
    var onFocusConsumed: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = BromureAddressField()
        field.delegate = context.coordinator
        // No bezel — the surrounding capsule pill is the visual container.
        // Removing the bezel also drops ~6pt of intrinsic height that the
        // .roundedBezel cell otherwise insists on.
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Search or enter URL"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        // Alignment is set once and never changes. Toggling it dynamically
        // (e.g. `.center` while displaying, `.left` while typing) re-lays
        // out the field editor and clears the active selection, which on
        // the second keystroke after a select-all looks like the field
        // dropped focus.
        field.alignment = centered ? .center : .left
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)

        if shouldFocusOnAppear {
            // Stealing focus from the VZVirtualMachineView is more
            // involved than a single makeFirstResponder call:
            //   1. The field must already be attached to a window — when
            //      makeNSView returns, the NSHostingView -> NSToolbar
            //      mounting chain hasn't always run, so field.window can
            //      still be nil.
            //   2. The current first responder (vmView when the user was
            //      focused on the page) may refuse to resign on the first
            //      try. Calling makeFirstResponder(nil) first forces a
            //      resign, after which our field can grab focus.
            // Retry every 50 ms for up to 1 s; consume the trigger flag
            // once focus actually lands.
            let consumed = onFocusConsumed
            func attempt(_ n: Int, weakField: NSTextField?) {
                guard let field = weakField else { return }
                guard let window = field.window else {
                    if n < 20 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak field] in
                            attempt(n + 1, weakField: field)
                        }
                    }
                    return
                }
                if window.makeFirstResponder(field) {
                    consumed?()
                    return
                }
                // The current responder refused. Force-resign it and try
                // again on the next runloop turn.
                _ = window.makeFirstResponder(nil)
                if n < 20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak field] in
                        attempt(n + 1, weakField: field)
                    }
                } else {
                    // Give up gracefully so the model's flag doesn't get
                    // stuck on (which would race the next legitimate tab
                    // creation).
                    consumed?()
                }
            }
            DispatchQueue.main.async { [weak field] in
                attempt(0, weakField: field)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Refresh the coordinator's view of the parent struct so closures
        // and bindings dispatched from delegate callbacks see the current
        // values, not the snapshot taken at makeCoordinator time.
        context.coordinator.parent = self

        // Only sync stringValue when the field is NOT being edited. While
        // the user is typing, the field editor is the source of truth:
        // every keystroke fires `controlTextDidChange`, which updates the
        // binding, which re-runs `updateNSView` — at which point the
        // binding's text and the field's stringValue agree. But if SwiftUI
        // re-renders mid-keystroke (any other observable property changing
        // on the model would do it) and our binding hasn't been observed
        // yet, `text` here is stale and we'd overwrite the user's input.
        if !isEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        // Set in `submit`, consumed in `controlTextDidEndEditing`. Without
        // this, the end-editing notification (which fires after the action)
        // would call the host's "revert to domain" handler and stomp on the
        // URL the user just navigated to, until the guest catches up.
        var didSubmit = false

        init(_ parent: AddressField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isEditing = true
            parent.onBeginEditing?()
            // updateNSView won't sync stringValue while editing (to avoid
            // racing with keystrokes), so if onBeginEditing pushed a new
            // value through the binding (the typical "domain → full URL"
            // swap on focus) we apply it directly here. parent.text is a
            // Binding, so this read sees whatever the closure just wrote.
            if let field = obj.object as? NSTextField,
               field.stringValue != parent.text {
                field.stringValue = parent.text
                if let editor = field.currentEditor() as? NSTextView {
                    editor.selectAll(nil)
                }
            }
        }
        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isEditing = false
            if !didSubmit {
                parent.onEndEditing?()
            }
            didSubmit = false
        }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
        }
        @objc func submit(_ sender: Any) {
            if let field = sender as? NSTextField {
                parent.text = field.stringValue
            }
            didSubmit = true
            parent.isEditing = false
            parent.onSubmit()
        }
    }
}

/// NSTextField subclass that selects all contents on focus (Safari-style).
private final class BromureAddressField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView {
            editor.selectAll(nil)
        }
        return ok
    }
}

// MARK: - AppKit integration
//
// Safari Compact layout: one NSToolbar item on the unified titlebar row
// holds every control (nav buttons, tabs, URL field, +). `toolbarStyle =
// .unified` merges the toolbar with the titlebar so the traffic lights sit
// on the same line. No bottom accessory — everything on one row.

private let compactBarItemID = NSToolbarItem.Identifier("io.bromure.nativeTabs.compactBar")

/// Owns the `NSToolbar` that implements the native-tabs titlebar. One
/// instance per browser session window; call ``install(on:)`` once after
/// the window has its content view.
@MainActor
final class NativeTabBarChrome {
    let model: NativeTabBarModel
    let toolbar: NSToolbar
    private let toolbarDelegate: CompactBarToolbarDelegate

    init(model: NativeTabBarModel) {
        self.model = model

        let delegate = CompactBarToolbarDelegate(model: model)
        self.toolbarDelegate = delegate

        let toolbar = NSToolbar(identifier: "io.bromure.nativeTabs")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        self.toolbar = toolbar
    }

    /// Install the native tabs chrome onto `window`. Hides the window title
    /// text, makes the titlebar transparent, mounts the toolbar. Safe to call
    /// exactly once per window.
    func install(on window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = toolbar
    }
}

/// Vends the single flexible-width NSToolbarItem holding the SwiftUI compact
/// bar. Kept separate from the chrome object so NSToolbarDelegate methods
/// stay dispatch-legal (AppKit calls them synchronously off arbitrary paths).
final class CompactBarToolbarDelegate: NSObject, NSToolbarDelegate {
    let model: NativeTabBarModel

    init(model: NativeTabBarModel) {
        self.model = model
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [compactBarItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [compactBarItemID]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == compactBarItemID else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        // Constraint-driven sizing. The hosting view reports
        // `NSView.noIntrinsicMetric` for width so NSToolbar doesn't size the
        // item to the SwiftUI content's intrinsic width — with many tabs
        // that intrinsic width sums to thousands of points, NSToolbar
        // decides "doesn't fit" and demotes the whole bar to the overflow
        // (»») chevron. With no intrinsic width, NSToolbar gives the item
        // whatever toolbar space is left and the inner ScrollView clips.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let hosting = FlexibleHostingView(rootView: NativeCompactBarView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 30),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        item.view = container
        item.visibilityPriority = .high
        item.label = ""
        item.paletteLabel = "Bromure"
        return item
    }
}

/// `NSHostingView` subclass that hides its width from AppKit so NSToolbar
/// doesn't size the toolbar item to the SwiftUI content's natural width
/// (which grows linearly with tab count). The view still picks up height
/// from its content; only width is delegated to constraints / parent.
final class FlexibleHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        let inner = super.intrinsicContentSize
        return NSSize(width: NSView.noIntrinsicMetric, height: inner.height)
    }
}
