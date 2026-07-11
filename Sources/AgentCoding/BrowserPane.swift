import AppKit
import BrowserBridges
import SandboxEngine
import SwiftUI
import Virtualization

// The agentic web browser pane: a right-hand split in the workspace window
// (agent/terminal on the left, live Chromium on the right — see browser.png).
// It renders its own browser chrome (tab strip + URL bar) above a framebuffer
// container that hosts the sidecar browser VM's VZVirtualMachineView. The tab
// list, favicons and navigation are driven by the shared TabBridge (vsock
// 5810) — the same native-tabs machinery Bromure Web uses — wired in by
// WorkspaceBrowserController through the `on*` callbacks. With no VM attached
// it shows a globe placeholder.
//
// See BROWSER_PANE_PLAN.md.

@MainActor
@Observable
final class BrowserPaneModel {
    /// The Safari-compact native-tabs model (ported from Bromure Web), driven
    /// by TabBridge in WorkspaceBrowserController. Owns the tab list, address
    /// field state, and nav callbacks.
    let tabBar = NativeTabBarModel()
    /// True once the VM controller has mounted a framebuffer into
    /// `framebufferContainer`; drives placeholder vs. live view.
    var hasFramebuffer = false
    /// Subtitle under the placeholder globe (e.g. "Booting browser…").
    var placeholderStatus = ""
    /// Non-nil while the browser image is being downloaded (first open) —
    /// the placeholder renders the shared installer's live progress
    /// instead of the plain status line.
    var imageInstall: BrowserImageInstaller?
    /// True while the placeholder shows the install-consent card ("the
    /// browser isn't installed — download it?"). The download only
    /// starts after `onAcceptInstall`.
    var installPrompt = false
    /// Consent-card actions, wired by WorkspaceBrowserController.
    var onAcceptInstall: (() -> Void)?
    var onDeclineInstall: (() -> Void)?
    /// Optional action button under the placeholder status (e.g. "Retry"
    /// after a failure, "Install the Browser…" after a declined prompt).
    var actionLabel: String?
    var onAction: (() -> Void)?

    /// Stable AppKit view the VM controller mounts the VZVirtualMachineView
    /// into. Kept alive by the model so the SwiftUI side can wrap it without
    /// owning the VM's view lifecycle.
    let framebufferContainer = BrowserFramebufferContainer()

    /// Normalize address-bar input to a URL / search (used by the controller's
    /// onNavigate handler). Prepend https:// for a bare host; treat a
    /// spaces-or-no-dot string as a search.
    static func normalize(_ raw: String) -> String {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Already has a scheme (http/https/chrome/about/file/view-source/…) →
        // pass through untouched. `scheme:` (with or without //) counts, so
        // chrome://version and about:blank aren't turned into searches.
        if let colon = raw.firstIndex(of: ":") {
            let scheme = raw[raw.startIndex..<colon]
            if !scheme.isEmpty, scheme.first!.isLetter,
               scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
               !scheme.contains(" ") {
                return raw
            }
        }
        let looksLikeURL = (raw.contains(".") && !raw.contains(" "))
            || raw.hasPrefix("localhost")
        if looksLikeURL { return "https://" + raw }
        let q = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        return "https://www.google.com/search?q=\(q)"
    }
}

/// The AppKit view the browser VM's `VZVirtualMachineView` is added into.
/// Plain container: the controller mounts/unmounts the framebuffer as a
/// full-bleed subview; empty, it's transparent so the SwiftUI placeholder
/// shows through.
@MainActor
final class BrowserFramebufferContainer: NSView {
    override var isFlipped: Bool { true }

    /// Hover (mouseMoved) delivery to the guest — the element picker's
    /// highlight depends on it — requires the window to dispatch
    /// mouse-moved events. Without this it only starts flowing after a
    /// window resize forces AppKit to recompute tracking.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    /// Mount (or replace) the framebuffer view, pinned to fill.
    func mount(_ view: NSView) {
        subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func unmountAll() {
        subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Clips Chromium's own chrome (tab strip + omnibox) out of the top of the
/// framebuffer in native-chrome mode. The guest scanout is `displayHeight +
/// inset` tall and Chromium maximizes into it with its chrome in the top
/// `inset` DEVICE-pixel rows; this view is `masksToBounds` and the VZ view is
/// pinned to its bottom with `height == cropper.height + insetPoints`, so the
/// top `insetPoints` extends above the cropper and is clipped. Ported from
/// Bromure Web's NativeChromeCropper.
@MainActor
final class NativeChromeCropper: NSView {
    /// The scanout inset in DEVICE pixels (== VMConfig.nativeChromeInset,
    /// `nativeChromeCSSHeight * displayScale`). The crop in POINTS is this
    /// divided by the view's actual backing scale — 86pt on a 2× display
    /// whose inset was baked at 2×, but different on a 1× display or when the
    /// window moves between displays, so it's recomputed live.
    private var deviceInset: CGFloat = 0
    private var insetConstraint: NSLayoutConstraint?

    func clip(_ vzView: NSView, deviceInset: Int) {
        self.deviceInset = CGFloat(deviceInset)
        wantsLayer = true
        layer?.masksToBounds = true
        subviews.forEach { $0.removeFromSuperview() }
        vzView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vzView)
        let inset = vzView.heightAnchor.constraint(
            equalTo: heightAnchor, constant: insetPoints())
        insetConstraint = inset
        NSLayoutConstraint.activate([
            vzView.leadingAnchor.constraint(equalTo: leadingAnchor),
            vzView.trailingAnchor.constraint(equalTo: trailingAnchor),
            vzView.bottomAnchor.constraint(equalTo: bottomAnchor),
            inset,
        ])
    }

    /// Device inset → points via the live backing scale (2 on retina, 1 on a
    /// non-retina display).
    private func insetPoints() -> CGFloat {
        let dpr = max(window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
        return deviceInset / dpr
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        insetConstraint?.constant = insetPoints()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        insetConstraint?.constant = insetPoints()
    }
}

// MARK: - SwiftUI

/// Bridges the stable framebuffer container into SwiftUI.
///
/// Wraps the model's container instead of BEING it: a workspace switch
/// swaps the pane's rootView to a same-typed BrowserPaneView, which
/// SwiftUI treats as an update of this representable (makeNSView is NOT
/// called again) — updateNSView re-mounts the new workspace's container,
/// or the previous workspace's framebuffer would stay on screen.
private struct FramebufferHost: NSViewRepresentable {
    let container: BrowserFramebufferContainer

    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView()
        embed(in: wrapper)
        return wrapper
    }

    func updateNSView(_ wrapper: NSView, context: Context) {
        guard container.superview !== wrapper else { return }
        wrapper.subviews.forEach { $0.removeFromSuperview() }
        embed(in: wrapper)
    }

    private func embed(in wrapper: NSView) {
        container.frame = wrapper.bounds
        container.autoresizingMask = [.width, .height]
        wrapper.addSubview(container)
    }
}

/// The pane content: browser chrome over the framebuffer / placeholder.
struct BrowserPaneView: View {
    @Bindable var model: BrowserPaneModel

    var body: some View {
        VStack(spacing: 0) {
            // The exact Safari-compact tab bar from Bromure Web. Native-chrome
            // mode crops Chromium's own chrome out of the framebuffer, so this
            // is the browser's only chrome.
            NativeCompactBarView(model: model.tabBar)
                .frame(minHeight: 34)
                .padding(.vertical, 3)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        ZStack {
            Color.black
            placeholder.opacity(model.hasFramebuffer ? 0 : 1)
            if model.hasFramebuffer {
                FramebufferHost(container: model.framebufferContainer)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: model.imageInstall != nil ? "arrow.down.circle" : "globe")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            if let installer = model.imageInstall {
                imageInstallCard(installer)
            } else if model.installPrompt {
                installPromptCard
            } else {
                if !model.placeholderStatus.isEmpty {
                    Text(model.placeholderStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                if let label = model.actionLabel {
                    Button {
                        model.onAction?()
                    } label: {
                        Label(label, systemImage: "arrow.clockwise")
                    }
                    .controlSize(.regular)
                }
            }
        }
        .padding(24)
    }

    /// Consent card shown before the one-time browser download starts —
    /// nothing is fetched until the user accepts.
    private var installPromptCard: some View {
        VStack(spacing: 10) {
            Text("Install the browser?")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Chromium runs in its own disposable VM. One-time download (\(BrowserImageInstaller.shared.downloadSizeDescription)), installed to your Library folder.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 10) {
                Button("Not Now") {
                    model.onDeclineInstall?()
                }
                Button {
                    model.onAcceptInstall?()
                } label: {
                    Label("Download & Install", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
    }

    /// One-time browser-image download: title + live status pill +
    /// determinate bar with a percentage, driven by the shared
    /// BrowserImageInstaller (Settings → Browser mirrors the same run).
    private func imageInstallCard(_ installer: BrowserImageInstaller) -> some View {
        VStack(spacing: 10) {
            Text("Setting up the browser")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("One-time download — Chromium runs in its own disposable VM.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(installer.progress.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(String(format: "%.0f%%", installer.progress.progress * 100))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: installer.progress.progress, total: 1.0)
                    .progressViewStyle(.linear)
            }
            .frame(width: 320)
        }
    }
}
