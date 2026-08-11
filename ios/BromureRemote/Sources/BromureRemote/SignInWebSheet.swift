#if os(visionOS)
import SwiftUI
import WebKit

// MARK: - Embedded bromure.io sign-in (visionOS)
//
// The in-app sign-in for the spatial shell: a full-size WKWebView sheet over
// the main window that loads the bromure.io enroll page and intercepts the
// `bromure://enroll` redirect itself — the exact interception the iOS
// ASWebAuthenticationSession does. That session's visionOS presentation is a
// fixed compact card that clips the login form, and handing the page to Safari
// bounces the user out of the app (an App Review rejection). So this sheet IS
// the sign-in surface here; `P2PEnrollmentCoordinator.webSignIn` drives it.

struct SignInWebSheet: View {
    let request: P2PEnrollmentCoordinator.WebSignIn

    @State private var loading = true
    @State private var loadError: String?
    /// Incremented to make the web view reload after a failed page load.
    @State private var reloadTick = 0

    var body: some View {
        NavigationStack {
            ZStack {
                EnrollWebView(url: request.url,
                              reloadTick: reloadTick,
                              loading: $loading,
                              loadError: $loadError) { callbackURL in
                    P2PEnrollmentCoordinator.shared.completeWebSignIn(callbackURL)
                }
                .opacity(loadError == nil ? 1 : 0)

                if let loadError {
                    ContentUnavailableView {
                        Label("Can't Reach bromure.io", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") {
                            self.loadError = nil
                            reloadTick += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if loading {
                    ProgressView()
                }
            }
            .navigationTitle("Sign in to bromure.io")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        P2PEnrollmentCoordinator.shared.cancelWebSignIn()
                    }
                }
            }
        }
        // A comfortable login-page size; without it the sheet collapses to the
        // web view's (nonexistent) intrinsic size.
        .frame(width: 760, height: 900)
    }
}

// MARK: - WKWebView wrapper

private struct EnrollWebView: UIViewRepresentable {
    let url: URL
    let reloadTick: Int
    @Binding var loading: Bool
    @Binding var loadError: String?
    /// Called with the `bromure://enroll?…&state=…` redirect the page issues
    /// once the user has signed in and authorized this device.
    let onCallback: (URL) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // The default persistent store, mirroring the iOS session's shared
        // cookies as closely as WKWebView can: a repeat sign-in on this device
        // finds the existing bromure.io session instead of a blank form.
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        context.coordinator.lastReloadTick = reloadTick
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastReloadTick != reloadTick {
            context.coordinator.lastReloadTick = reloadTick
            uiView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: EnrollWebView
        var lastReloadTick = 0
        init(_ parent: EnrollWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The enroll callback: WKWebView would report the custom scheme as
            // an unsupported-URL failure, so claim it before it navigates.
            if let u = navigationAction.request.url, u.scheme == "bromure" {
                decisionHandler(.cancel)
                parent.onCallback(u)
                return
            }
            decisionHandler(.allow)
        }

        /// A target=_blank link (an IdP popup): there's no second window in
        /// this sheet, so load it in place.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            parent.loading = false
            // A cancelled load (the redirect interception above, or a rapid
            // in-page navigation) is not a page failure.
            let ns = error as NSError
            guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled),
                  !(ns.domain == "WebKitErrorDomain" && ns.code == 102) else { return }
            parent.loadError = error.localizedDescription
        }
    }
}
#endif
