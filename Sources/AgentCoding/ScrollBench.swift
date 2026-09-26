#if os(macOS)
import AppKit
import SwiftUI

/// `bromure-ac __bench-scroll <transcript.jsonl> [--lazy] [--flat]` — lay a
/// real transcript out with the chat's own row views in an offscreen
/// window, then scroll it top to bottom in 40-pt steps, timing each frame
/// (scroll + layout + display). Standalone: no servers or VMs.
///   --lazy  a LazyVStack instead of the chat's eager VStack
///   --flat  every item on its own row (no activity folding)
private struct BenchChrome: ViewModifier {
    let hover: Bool
    let help: Bool
    func body(content: Content) -> some View {
        if hover { content.onHover { _ in } } else if help { content.help("x") } else { content }
    }
}

enum ScrollBench {
    static func run(_ args: [String]) {
        guard let path = args.first(where: { !$0.hasPrefix("--") }),
              let data = FileManager.default.contents(atPath: path) else {
            print("usage: __bench-scroll <transcript.jsonl> [--lazy] [--flat]"); return
        }
        let lazy = args.contains("--lazy"), flat = args.contains("--flat")
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let items = AgentTranscript.parse(data)
            let hover = args.contains("--hover"), help = args.contains("--help")
            let rows: AnyView = flat
                ? AnyView(ForEach(items) { item in
                    TranscriptItemView(item: item)
                        .modifier(BenchChrome(hover: hover, help: help))
                })
                : AnyView(TranscriptRowsView(items: items))
            let list: AnyView = lazy
                ? AnyView(LazyVStack(alignment: .leading, spacing: 14) { rows })
                : AnyView(VStack(alignment: .leading, spacing: 14) { rows })
            let root = ScrollView {
                list.frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            }
            .background(Color(nsColor: .textBackgroundColor))
            let size = NSSize(width: 1200, height: 900)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)

            let t0 = Date()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let firstLayout = Date().timeIntervalSince(t0) * 1000
            let settle = Date().addingTimeInterval(1.0)
            while Date() < settle { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }

            func find(_ v: NSView) -> NSScrollView? {
                if let s = v as? NSScrollView { return s }
                for sub in v.subviews { if let s = find(sub) { return s } }
                return nil
            }
            guard let scroll = find(host), let doc = scroll.documentView else { print("no scroll view"); exit(1) }
            let height = doc.frame.height
            var times: [Double] = []
            var cpu: [Double] = []
            func threadCPU() -> Double {
                var ts = timespec()
                clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
                return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
            }
            var y: CGFloat = 0
            while y < height - size.height {
                let t = Date()
                let c = threadCPU()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.current.run(mode: .default, before: Date())
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                times.append(Date().timeIntervalSince(t) * 1000)
                cpu.append(threadCPU() - c)
                y += 40
            }
            let sorted = times.sorted()
            func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            print(String(format: "items %d  rows %d  height %.0f pt  first layout %.0f ms", items.count,
                         TranscriptRow.rows(items).count, height, firstLayout))
            print(String(format: "%d scroll steps: mean %.2f ms  p50 %.2f  p95 %.2f  max %.2f  (>16.7 ms: %d)",
                         times.count, times.reduce(0, +) / Double(max(1, times.count)), pct(0.5), pct(0.95),
                         sorted.last ?? 0, times.filter { $0 > 16.7 }.count))
            // Land on the very end (a lazy list's height grows as it
            // measures) and snapshot: the last rows must have drawn.
            if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
                for _ in 0..<6 {
                    let end = max(0, doc.frame.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    let until = Date().addingTimeInterval(0.3)
                    while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
                    host.layoutSubtreeIfNeeded()
                }
                let b = host.bounds
                if let rep = host.bitmapImageRepForCachingDisplay(in: b) {
                    host.cacheDisplay(in: b, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                print(String(format: "end: doc height %.0f, offset %.0f", doc.frame.height, scroll.contentView.bounds.origin.y))
            }
            let cs = cpu.sorted()
            print(String(format: "main-thread CPU per step: mean %.2f ms  p50 %.2f  p95 %.2f  max %.2f",
                         cpu.reduce(0, +) / Double(max(1, cpu.count)),
                         cs.isEmpty ? 0 : cs[cs.count / 2], cs.isEmpty ? 0 : cs[min(cs.count - 1, Int(Double(cs.count) * 0.95))],
                         cs.last ?? 0))
            exit(0)
        }
    }
}
#endif
