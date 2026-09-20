import SwiftUI
import WebKit
import MarkdownUI

// MARK: - Mermaid diagrams for ```mermaid fences in the beautified transcript
//
// Agents emit architecture/flow diagrams as mermaid fences; showing those as a
// wall of `A --> B[(…)]` text (or worse, letting the markdown renderer soft-wrap
// the lines and eat the `<br/>`s) isn't "parsed". A native flowchart layout
// engine would be brittle (subgraphs, shapes, `<br/>`, unicode labels…), so we
// render with the real mermaid.js — bundled and pinned (Resources/mermaid,
// PROVENANCE.md), injected into an offline WKWebView (no network, no CDN),
// with the page reporting its rendered height back so the diagram sits inline
// like any other block. Anything that can't render (missing bundle on the iOS
// client, a mermaid parse error) falls back to the plain code fence, so a
// diagram can never make a message unreadable.

/// The bundled library, read once. nil when this bundle doesn't ship it (the
/// iOS client) → callers fall back to the code fence.
enum MermaidBundle {
    static let script: String? = {
        guard let url = acResourceBundle.url(forResource: "mermaid.min", withExtension: "js",
                                             subdirectory: "mermaid"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s
    }()
}

/// Builds the self-contained page a fence renders in. The diagram source sits
/// HTML-escaped in a hidden <pre> (so `<br/>`, `-->`, `[…]` in labels survive
/// verbatim), mermaid renders it to inline SVG, and the page posts its height
/// (or the error) to Swift.
enum MermaidRenderer {
    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Resolves the library however the pinned esbuild IIFE exposes it, renders,
    /// sizes, and posts back. Kept free of Swift interpolation on purpose.
    static let initScript = """
    (async () => {
      try {
        const ns = window.__esbuild_esm_mermaid_nm;
        const m = window.mermaid
              || (ns && ns.mermaid && (ns.mermaid.default || ns.mermaid));
        if (!m || typeof m.render !== 'function') throw new Error('mermaid library not found');
        m.initialize({ startOnLoad: false,
                       theme: window.__dark ? 'dark' : 'default',
                       securityLevel: 'strict',
                       fontFamily: '-apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif' });
        const src = document.getElementById('src').textContent;
        const { svg } = await m.render('bromure-mermaid', src);
        const host = document.getElementById('d');
        host.innerHTML = svg;
        const s = host.querySelector('svg');
        if (s) { s.style.maxWidth = '100%'; s.style.height = 'auto'; s.removeAttribute('height'); }
        const h = Math.ceil(host.getBoundingClientRect().height) + 4;
        window.webkit.messageHandlers.mermaidSize.postMessage(h);
      } catch (e) {
        window.webkit.messageHandlers.mermaidError.postMessage(String((e && e.message) || e));
      }
    })();
    """

    static func html(source: String, dark: Bool) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
          #d, #d svg { display: block; }
        </style></head>
        <body><div id="d"></div><pre id="src" hidden>\(escapeHTML(source))</pre>
        <script>window.__dark = \(dark ? "true" : "false");</script>
        <script>\(initScript)</script>
        </body></html>
        """
    }
}

/// Bridges the page's size/error messages back to SwiftUI and blocks
/// navigation away (a link inside a diagram must not hijack the transcript).
final class MermaidWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let onHeight: (CGFloat) -> Void
    let onError: (String) -> Void
    private var loaded: (source: String, dark: Bool)?

    init(onHeight: @escaping (CGFloat) -> Void, onError: @escaping (String) -> Void) {
        self.onHeight = onHeight
        self.onError = onError
    }

    /// Load (or reload on a source / color-scheme change); no-op otherwise, so
    /// the transcript's periodic re-renders don't re-run mermaid.
    func load(_ wv: WKWebView, source: String, dark: Bool) {
        if let l = loaded, l.source == source, l.dark == dark { return }
        loaded = (source, dark)
        wv.loadHTMLString(MermaidRenderer.html(source: source, dark: dark), baseURL: nil)
    }

    static func configure(_ cfg: WKWebViewConfiguration, coordinator: MermaidWebCoordinator) {
        let ucc = WKUserContentController()
        if let lib = MermaidBundle.script {
            ucc.addUserScript(WKUserScript(source: lib, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        }
        ucc.add(coordinator, name: "mermaidSize")
        ucc.add(coordinator, name: "mermaidError")
        cfg.userContentController = ucc
    }

    static func teardown(_ wv: WKWebView) {
        let ucc = wv.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "mermaidSize")
        ucc.removeScriptMessageHandler(forName: "mermaidError")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "mermaidSize":
            if let n = message.body as? NSNumber { onHeight(CGFloat(truncating: n)) }
        case "mermaidError":
            onError(String(describing: message.body))
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
    }
}

#if canImport(AppKit)
struct MermaidWebView: NSViewRepresentable {
    let source: String
    let dark: Bool
    let onHeight: (CGFloat) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> MermaidWebCoordinator {
        MermaidWebCoordinator(onHeight: onHeight, onError: onError)
    }
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        MermaidWebCoordinator.configure(cfg, coordinator: context.coordinator)
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.underPageBackgroundColor = .clear   // let the card color show through (public API)
        wv.navigationDelegate = context.coordinator
        context.coordinator.load(wv, source: source, dark: dark)
        return wv
    }
    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.load(wv, source: source, dark: dark)
    }
    static func dismantleNSView(_ wv: WKWebView, coordinator: MermaidWebCoordinator) {
        MermaidWebCoordinator.teardown(wv)
    }
}
#elseif canImport(UIKit)
struct MermaidWebView: UIViewRepresentable {
    let source: String
    let dark: Bool
    let onHeight: (CGFloat) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> MermaidWebCoordinator {
        MermaidWebCoordinator(onHeight: onHeight, onError: onError)
    }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        MermaidWebCoordinator.configure(cfg, coordinator: context.coordinator)
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.navigationDelegate = context.coordinator
        context.coordinator.load(wv, source: source, dark: dark)
        return wv
    }
    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.load(wv, source: source, dark: dark)
    }
    static func dismantleUIView(_ wv: WKWebView, coordinator: MermaidWebCoordinator) {
        MermaidWebCoordinator.teardown(wv)
    }
}
#endif

/// A ```mermaid fence rendered as a diagram, sized to its content. Falls back
/// to `fallback` (the plain code fence) when the library isn't bundled or the
/// diagram fails to parse.
struct MermaidFence<Fallback: View>: View {
    let source: String
    let bodySize: CGFloat
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 96
    @State private var failed = false

    var body: some View {
        if MermaidBundle.script == nil || failed {
            fallback()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("mermaid")
                        .font(.system(size: bodySize * 0.7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider().opacity(0.4)
                MermaidWebView(source: source, dark: colorScheme == .dark,
                               onHeight: { h in if h > 0 { height = h } },
                               onError: { _ in failed = true })
                    .frame(height: height)
                    .padding(8)
            }
            .transcriptCard()   // same chrome as the code fences
        }
    }
}

#if os(macOS)
/// Collects the page's size / error message for the snapshot hook. File-scope
/// because Swift forbids a local type inside a closure in a generic context.
private final class MermaidSnapshotSink: NSObject, WKScriptMessageHandler {
    var height: CGFloat?
    var error: String?
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "mermaidSize", let n = m.body as? NSNumber { height = CGFloat(truncating: n) }
        if m.name == "mermaidError" { error = String(describing: m.body) }
    }
}

extension MermaidFence where Fallback == EmptyView {
    /// Hidden verification hook (`bromure-ac __shot-mermaid <png> [srcfile]`):
    /// render a mermaid source through the SAME page + injected library the
    /// transcript uses, snapshot the web view to a PNG, print the reported
    /// height (or the parse error), and exit. Standalone: no app delegate,
    /// servers, or VMs — safe alongside a live instance.
    static func renderSnapshot(source: String, dark: Bool, to path: String) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            guard let lib = MermaidBundle.script else {
                print("error=mermaid.min.js is not in the resource bundle"); exit(2)
            }
            let sink = MermaidSnapshotSink()
            let cfg = WKWebViewConfiguration()
            let ucc = WKUserContentController()
            ucc.addUserScript(WKUserScript(source: lib, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            ucc.add(sink, name: "mermaidSize")
            ucc.add(sink, name: "mermaidError")
            cfg.userContentController = ucc

            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: cfg)
            let window = NSWindow(contentRect: wv.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = wv
            window.makeKeyAndOrderFront(nil)
            wv.loadHTMLString(MermaidRenderer.html(source: source, dark: dark), baseURL: nil)

            func pump(until deadline: Date, while cond: () -> Bool) {
                while cond() && Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
            }
            pump(until: Date().addingTimeInterval(20)) { sink.height == nil && sink.error == nil }
            if let e = sink.error { print("error=\(e)"); exit(1) }
            guard let h = sink.height else { print("error=timeout waiting for the size message"); exit(1) }
            wv.frame.size.height = max(h, 40)
            pump(until: Date().addingTimeInterval(0.8)) { true }

            let snap = WKSnapshotConfiguration()
            snap.rect = wv.bounds
            var done = false
            wv.takeSnapshot(with: snap) { img, err in
                if let img, let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("height=\(Int(h)) png=\(path)")
                } else {
                    print("error=snapshot failed: \(err?.localizedDescription ?? "unknown")")
                }
                done = true
            }
            pump(until: Date().addingTimeInterval(10)) { !done }
            exit(done ? 0 : 1)
        }
    }

    /// Hidden end-to-end hook (`bromure-ac __shot-transcript-md <png> [mdfile]`):
    /// host a markdown string through the transcript's OWN reader theme, so a
    /// ```mermaid fence takes the real path (theme hook → MermaidFence →
    /// MermaidWebView inside SwiftUI, height message and all), let it render,
    /// and capture the window's composited pixels. `cacheDisplay` can't see
    /// WKWebView content, so this proves the embedded diagram, not just the page.
    static func renderTranscriptSnapshot(markdown: String, to path: String) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let root = ScrollView {
                Markdown(markdown)
                    .markdownTheme(transcriptReaderTheme(bodySize: 13, serif: false))
                    .padding(16)
            }
            .frame(width: 760, height: 900)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)

            // Drive AppKit's real event/display cycle (a bare RunLoop.run never
            // lays out or composites the window), and wait for the embedded web
            // view to report its size back: the moment SwiftUI applies the
            // diagram's height is the crux of the embedding.
            func pump(_ seconds: TimeInterval) {
                let until = Date().addingTimeInterval(seconds)
                while Date() < until {
                    if let ev = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                              inMode: .default, dequeue: true) {
                        app.sendEvent(ev)
                    }
                    app.updateWindows()
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
            }
            func findWebView(_ v: NSView) -> WKWebView? {
                if let w = v as? WKWebView { return w }
                for s in v.subviews { if let w = findWebView(s) { return w } }
                return nil
            }
            func savePNG(_ rep: NSBitmapImageRep, _ p: String) -> Bool {
                guard let png = rep.representation(using: .png, properties: [:]) else { return false }
                try? png.write(to: URL(fileURLWithPath: p))
                return true
            }

            let deadline = Date().addingTimeInterval(8)
            var web: WKWebView?
            repeat {
                pump(0.2)
                web = findWebView(host)
                if let w = web, w.frame.height > 100 { break }   // > the 96-pt placeholder: size applied
            } while Date() < deadline
            pump(0.5)

            let base = (path as NSString).deletingPathExtension

            // 1. The whole layout via cacheDisplay — prose, card chrome, and
            //    (because a real event loop composited it) the diagram itself.
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if savePNG(rep, base + "-layout.png") { print("layout=\(base)-layout.png") }
                _ = savePNG(rep, path)   // default output; overwritten by the web snapshot below
            }
            // 2. The embedded diagram alone, AS LAID OUT inside SwiftUI: snapshot
            //    the embedded WKWebView itself (WebKit snapshots work out-of-process).
            if let w = web {
                print("embeddedWebView=\(Int(w.frame.width))x\(Int(w.frame.height)) (placeholder is 96 tall)")
                var done = false
                let snap = WKSnapshotConfiguration()
                snap.rect = w.bounds
                w.takeSnapshot(with: snap) { img, err in
                    if let img, let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff), savePNG(rep, path) {
                        print("png=\(path) capture=embeddedWebView")
                    } else {
                        print("error=web snapshot: \(err?.localizedDescription ?? "unknown")")
                    }
                    done = true
                }
                let d2 = Date().addingTimeInterval(10)
                while !done && Date() < d2 { pump(0.05) }
            } else {
                print("embeddedWebView=none (fell back to the code fence)")
            }
            exit(0)
        }
    }
}
#endif
