import AppKit
import SandboxEngine
import SwiftUI
import Virtualization

// The agentic web browser pane: a right-hand split in the workspace window
// (agent/terminal on the left, live Chromium on the right — see browser.png).
// It renders its own browser chrome (tab strip + URL bar) above a framebuffer
// container that hosts the sidecar browser VM's VZVirtualMachineView. Phase 1
// is the shell only: with no VM attached it shows a globe placeholder. The VM
// lifecycle (WorkspaceBrowserController) and the CDP/MCP wiring land in later
// phases; this model is the seam they drive through the `on*` callbacks.
//
// See BROWSER_PANE_PLAN.md.

/// One browser tab as the guest/CDP reports it. `id` is the CDP target /
/// guest tab id; the emoji favicon is a placeholder until real favicons ride
/// in over TabBridge (phase 3).
struct BrowserTab: Identifiable, Equatable {
    let id: Int
    var title: String
    var faviconEmoji: String = "🌐"
}

@MainActor
@Observable
final class BrowserPaneModel {
    /// Editable address-bar text. Distinct from the active tab's committed URL
    /// so typing doesn't fight live navigation updates.
    var urlText: String = ""
    var tabs: [BrowserTab] = []
    var activeTabID: BrowserTab.ID?
    /// Progress spinner in the URL bar while a navigation is in flight.
    var isLoading = false
    /// True once the VM controller has mounted a framebuffer into
    /// `framebufferContainer`; drives placeholder vs. live view.
    var hasFramebuffer = false
    /// Subtitle under the placeholder globe (e.g. "Booting browser…").
    var placeholderStatus = ""

    /// Stable AppKit view the VM controller mounts the VZVirtualMachineView
    /// into. Kept alive by the model so the SwiftUI side can wrap it without
    /// owning the VM's view lifecycle.
    let framebufferContainer = BrowserFramebufferContainer()

    // Actions wired by the window / WorkspaceBrowserController. nil in phase 1.
    var onNavigate: ((String) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onSelectTab: ((BrowserTab.ID) -> Void)?
    var onCloseTab: ((BrowserTab.ID) -> Void)?
    /// Close the whole browser pane (the ✕ in the chrome).
    var onClosePane: (() -> Void)?

    var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// Submit the address bar: prepend https:// for a bare host, treat a
    /// spaces-or-no-dot string as a search. Mirrors a browser omnibox loosely;
    /// the guest ultimately resolves it.
    func submitAddress() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        onNavigate?(Self.normalize(raw))
    }

    static func normalize(_ raw: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        // Looks like a host[:port][/path] → assume https. Otherwise search.
        let looksLikeURL = raw.contains(".") && !raw.contains(" ")
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
private struct FramebufferHost: NSViewRepresentable {
    let container: BrowserFramebufferContainer
    func makeNSView(context: Context) -> BrowserFramebufferContainer { container }
    func updateNSView(_ nsView: BrowserFramebufferContainer, context: Context) {}
}

/// The pane content: browser chrome over the framebuffer / placeholder.
struct BrowserPaneView: View {
    @Bindable var model: BrowserPaneModel

    var body: some View {
        VStack(spacing: 0) {
            // Native-chrome mode crops Chromium's own tab strip/omnibox out of
            // the framebuffer, so our host chrome is always shown and is the
            // browser's only chrome.
            BrowserChrome(model: model)
            Divider().overlay(Color.black.opacity(0.4))
            content
        }
        .background(Color(white: 0.10))
        .environment(\.colorScheme, .dark)   // chrome reads as a browser
    }

    @ViewBuilder private var content: some View {
        ZStack {
            Color(white: 0.14)
            placeholder.opacity(model.hasFramebuffer ? 0 : 1)
            if model.hasFramebuffer {
                FramebufferHost(container: model.framebufferContainer)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.white.opacity(0.35))
            if !model.placeholderStatus.isEmpty {
                Text(model.placeholderStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Tab strip + window buttons + URL bar — the dark browser chrome from
/// browser.png.
private struct BrowserChrome: View {
    @Bindable var model: BrowserPaneModel

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            addressBar
        }
        .background(Color(white: 0.10))
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(model.tabs) { tab in
                tabPill(tab)
            }
            Button {
                model.onNewTab?()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("New tab")
            Spacer()
            windowButtons
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func tabPill(_ tab: BrowserTab) -> some View {
        let active = tab.id == model.activeTabID
        return HStack(spacing: 6) {
            Text(tab.faviconEmoji).font(.system(size: 11))
            Text(tab.title.isEmpty ? "New tab" : tab.title)
                .font(.system(size: 11, weight: active ? .medium : .regular))
                .foregroundStyle(.white.opacity(active ? 0.95 : 0.6))
                .lineLimit(1)
            Button {
                model.onCloseTab?(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(active ? 0.12 : 0.0)))
        .contentShape(Rectangle())
        .onTapGesture { model.onSelectTab?(tab.id) }
    }

    private var windowButtons: some View {
        HStack(spacing: 12) {
            chromeButton("rectangle.righthalf.inset.filled", help: "Layout") {}
            chromeButton("ellipsis", help: "More") {}
            chromeButton("arrow.up.left.and.arrow.down.right", help: "Full width") {}
            chromeButton("xmark", help: "Close browser") { model.onClosePane?() }
        }
    }

    private func chromeButton(_ symbol: String, help: String,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var addressBar: some View {
        HStack(spacing: 10) {
            navButton("chevron.left", help: "Back") { model.onBack?() }
            navButton("chevron.right", help: "Forward") { model.onForward?() }
            HStack(spacing: 6) {
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                TextField("Search or enter address", text: $model.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .onSubmit { model.submitAddress() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.07)))
            navButton("arrow.clockwise", help: "Reload") { model.onReload?() }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func navButton(_ symbol: String, help: String,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
