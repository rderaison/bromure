import Foundation
import Testing
@testable import bromure_ac

@Suite("Mermaid fence rendering")
struct MermaidFenceTests {

    @Test("Bundled mermaid.js is present and is the pinned esbuild IIFE") func bundlePresent() {
        let s = MermaidBundle.script
        #expect(s != nil)
        #expect(s?.hasPrefix("\"use strict\";var __esbuild_esm_mermaid_nm") == true)
    }

    @Test("Diagram source is HTML-escaped so labels survive verbatim") func escaping() {
        // The exact constructs the markdown path mangled: <br/>, -->, [( )], &.
        let src = "A --> ID[(Pocket ID<br/>passkey identity)] & B"
        let html = MermaidRenderer.html(source: src, dark: false)
        #expect(html.contains("A --&gt; ID[(Pocket ID&lt;br/&gt;passkey identity)] &amp; B"))
        #expect(!html.contains("<br/>passkey"))              // never raw HTML in the page
        #expect(html.contains("window.__dark = false"))
        #expect(MermaidRenderer.html(source: "x", dark: true).contains("window.__dark = true"))
    }

    @Test("Init script resolves the esbuild namespace and reports size/error") func initScript() {
        let js = MermaidRenderer.initScript
        #expect(js.contains("__esbuild_esm_mermaid_nm"))
        #expect(js.contains("messageHandlers.mermaidSize"))
        #expect(js.contains("messageHandlers.mermaidError"))
        #expect(js.contains("securityLevel: 'strict'"))
    }
}
