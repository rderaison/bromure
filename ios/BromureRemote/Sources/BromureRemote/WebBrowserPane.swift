import SwiftUI
import WebKit

// MARK: - Workspace web browser (iOS)
//
// A lightweight in-app browser for the currently-attached workspace VM: it lists
// the VM's listening TCP ports (from the /state poll) and, on tap, loads the dev
// server in a WKWebView — tunnelled to the VM over the P2P connection, no public
// exposure. The SAME view also renders pages an agent opens through the browser
// MCP: both the manual tap and the agent's browser_navigate go through the
// shared MobileBrowserBridge, which owns the loopback tunnel and the URL shown.

struct WebBrowserPane: View {
    let controller: RemoteHostController
    let profileID: Profile.ID
    @ObservedObject var bridge: MobileBrowserBridge

    @StateObject private var nav = WebNav()

    private var model: TabsModel? { controller.tabsModel(for: profileID) }
    private var vmIP: String? {
        let ip = model?.ipAddress
        return (ip?.isEmpty ?? true) ? nil : ip
    }
    private var ports: [ListeningPort] {
        (model?.vmListeningPorts ?? [])
            .filter { $0.proto == "tcp" && $0.port > 0 }
            .sorted { $0.port < $1.port }
    }

    var body: some View {
        Group {
            if let url = bridge.displayURL {
                browser(url)
            } else {
                portList
            }
        }
        // Register this pane's WebView nav so the agent's back/forward/reload
        // drive the live WKWebView; cleared implicitly (weak) when it's gone.
        .onAppear { bridge.nav = nav }
    }

    // MARK: Port list

    private var portList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open a dev server running inside this workspace. It's reached over your private connection — nothing is exposed publicly.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                if vmIP == nil {
                    hint("Waiting for the VM's network address…")
                } else if ports.isEmpty {
                    hint("No listening TCP ports yet. Start a dev server in the workspace (e.g. on :3000) and it'll appear here.")
                } else {
                    ForEach(ports, id: \.port) { p in
                        Button { open(p) } label: { portRow(p) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func portRow(_ p: ListeningPort) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.16)).frame(width: 42, height: 42)
                Image(systemName: "globe").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                // `verbatim:` — a plain Text("\(int)") is a LocalizedStringKey and
                // renders the port with grouping separators (11,434).
                Text(verbatim: ":\(p.port)").font(.body.weight(.semibold)).monospacedDigit()
                Text(portSubtitle(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    private func portSubtitle(_ p: ListeningPort) -> String {
        var s = p.process.isEmpty ? "listening" : p.process
        if p.addr == "127.0.0.1" || p.addr == "[::1]" { s += " · localhost" }
        return s
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    // MARK: Browser

    private func browser(_ url: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { bridge.close() } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                }
                Button { nav.goBack() } label: { Image(systemName: "arrow.left") }
                    .disabled(!nav.canGoBack)
                Button { nav.goForward() } label: { Image(systemName: "arrow.right") }
                    .disabled(!nav.canGoForward)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green)
                    Text(verbatim: nav.title.isEmpty ? bridge.displayTitle : nav.title)
                        .font(.footnote).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                if nav.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { nav.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            WebView(url: url, nav: nav)
        }
    }

    private func open(_ p: ListeningPort) {
        guard let vmIP else { return }
        bridge.navigate("http://\(vmIP):\(p.port)")
    }
}

// MARK: - WKWebView wrapper

/// Observable navigation state so the SwiftUI chrome (back/forward/reload) — and
/// the agent's MCP tools, via MobileBrowserBridge — can drive and reflect the
/// WKWebView.
final class WebNav: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var title = ""
    fileprivate weak var webView: WKWebView?
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

struct WebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var nav: WebNav

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()   // an ephemeral session per VM
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        nav.webView = wv
        context.coordinator.lastLoaded = url
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        nav.webView = uiView
        // Load when the requested URL changes (the agent navigated again) — the
        // view instance is reused so back/forward history is preserved.
        if context.coordinator.lastLoaded != url {
            context.coordinator.lastLoaded = url
            uiView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(nav: nav) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let nav: WebNav
        var lastLoaded: URL?
        init(nav: WebNav) { self.nav = nav }
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { sync(w) }
        func webView(_ w: WKWebView, didCommit n: WKNavigation!) { sync(w) }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { sync(w) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { sync(w) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { sync(w) }
        private func sync(_ w: WKWebView) {
            DispatchQueue.main.async {
                self.nav.canGoBack = w.canGoBack
                self.nav.canGoForward = w.canGoForward
                self.nav.isLoading = w.isLoading
                self.nav.title = w.title ?? ""
            }
        }
    }
}
