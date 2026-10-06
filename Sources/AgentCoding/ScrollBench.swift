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
        // `@table[:rows]` — a built-in fixture: a Kimi reply carrying a
        // markdown table, streamed in small parts (S3-1: the app hung while
        // one grew). Run with `--chat --grow --grow-step 6 --width W`.
        let fixture = args.first(where: { $0.hasPrefix("@table") }).map { spec -> Data in
            let rows = Int(spec.split(separator: ":").dropFirst().first ?? "") ?? 40
            return tableReplyFixture(rows: rows)
        }
        let valueFlags: Set<String> = ["--width", "--seconds", "--height", "--grow-step", "--shot"]
        let positional = args.enumerated().first(where: { i, a in
            !a.hasPrefix("--") && !(i > 0 && valueFlags.contains(args[i - 1]))
        })?.element
        guard let path = positional,
              let data = fixture ?? FileManager.default.contents(atPath: path) else {
            print("usage: __bench-scroll <transcript.jsonl | @table[:rows]> [--lazy] [--flat]"); return
        }
        if args.contains("--chat") { ChatLayoutCheck.run(path: path, data: data, args: args); return }
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

/// `bromure-ac __bench-scroll <transcript.jsonl> --chat [--width 180]
/// [--seconds 20] [--working] [--hover] [--expand]` — the REAL chat view (BeautifiedSessionView,
/// fed the file by a fixture provider) in an offscreen window that opens
/// wide and is then squeezed to `--width` (the chat column with the browser
/// and files panes open), stepping through narrow widths and scrolling about
/// meanwhile. A watchdog thread pings the main queue: a layout that never
/// converges (B23: the app froze in one SwiftUI transaction placing the
/// lazy stack) prints HANG and exits 3. Exit 0 = every phase laid out.
/// `--hover` keeps the pointer moving over the chat (rows hover as the
/// layout shifts under it); `--expand` opens every long message of yours
/// in full (S1-1: a 20 KB paste was one row screens tall and froze it).
/// `--paste KB [--send]` instead pastes that much into the composer (needs
/// `--composer`), types on it, sends it, and prints each step's frame time
/// and the CPU burnt idling after it (P0: the transcript's bottom anchor
/// looped on a paste or a send — with `--working`, the "Thinking…" cue
/// landing at the end hung it). `--real-host` mounts the view as the app
/// does (constraints, no sizing), `--host-width W` sets its width,
/// `--linger S` idles at the end (to `sample` it), `BENCH_KEYS=N` types N
/// keys after the paste.
enum ChatLayoutCheck {
    static func run(path: String, data: Data, args: [String]) {
        func value(_ flag: String) -> Double? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        let narrow = CGFloat(value("--width") ?? 180)
        let seconds = value("--seconds") ?? 20
        let working = args.contains("--working")
        let grow = args.contains("--grow")
        // The pointer resting over the chat (rows under it hover as the
        // layout moves): a mouse-moved event at the middle, every pump beat.
        let hover = args.contains("--hover")
        // The watchdog: the main queue must answer within 4 s, always.
        let lastPong = OSAllocatedUnfairLockBox(Date())
        // `BENCH_HANG_SECONDS` (default 4): longer, to `sample` a hang.
        let hangAfter = Double(ProcessInfo.processInfo.environment["BENCH_HANG_SECONDS"] ?? "") ?? 4
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async { lastPong.set(Date()) }
                if Date().timeIntervalSince(lastPong.get()) > hangAfter {
                    print("HANG: the main thread has not answered for 4 s (layout loop)")
                    fflush(stdout)
                    _exit(3)
                }
            }
        }
        if args.contains("--switch") {
            MainActor.assumeIsolated { runSwitch(data: data, args: args, value: value) }
            exit(0)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let provider: BeautifiedTranscriptProvider = grow
                ? GrowingTranscriptProvider(transcript: data, step: Int(value("--grow-step") ?? 2))
                : args.contains("--paste")
                    ? TypingFixtureProvider(FixtureTranscriptProvider(accent: .blue, transcript: data, working: working)) as BeautifiedTranscriptProvider
                    : FixtureTranscriptProvider(accent: .blue, transcript: data, working: working)
            let model = BeautifiedSessionModel(provider: provider)
            model.start()
            let host = NSHostingView(rootView: BeautifiedSessionView(model: model,
                                                                     parts: args.contains("--composer") ? .all : .transcript)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
            let height = CGFloat(value("--height") ?? 760)
            host.frame = NSRect(x: 0, y: 0, width: CGFloat(value("--host-width") ?? 720), height: height)
            let window: NSWindow = args.contains("--key")
                ? BenchKeyWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                : NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            if args.contains("--real-host") {
                // As the app mounts it (SessionPane.mountBeautified): pinned
                // by constraints inside a container, never sizing the window.
                let container = NSView(frame: host.frame)
                host.sizingOptions = []
                host.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(host)
                NSLayoutConstraint.activate([
                    host.topAnchor.constraint(equalTo: container.topAnchor),
                    host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ])
                window.contentView = container
            } else {
                window.contentView = host
            }
            window.acceptsMouseMovedEvents = true
            window.orderFront(nil)
            func hoverMove() {
                let p = NSPoint(x: host.bounds.midX + CGFloat.random(in: -2...2),
                                y: host.bounds.midY + CGFloat.random(in: -2...2))
                if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 0, pressure: 0) {
                    window.sendEvent(e)
                }
            }
            func pump(_ s: Double) {
                let until = Date().addingTimeInterval(s)
                while Date() < until {
                    if hover { hoverMove() }
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                }
            }
            func find(_ v: NSView) -> NSScrollView? {
                if let s = v as? NSScrollView, s.documentView != nil, s.frame.height > 100 { return s }
                for sub in v.subviews { if let s = find(sub) { return s } }
                return nil
            }
            func resize(_ w: CGFloat) {
                window.setContentSize(NSSize(width: w, height: height))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            /// A drag over the chat, as the user's own: TailFollow lets go.
            func userDrag() {
                let p = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
                if let e = NSEvent.mouseEvent(with: .leftMouseDragged, location: p, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                    app.sendEvent(e)
                }
            }
            pump(2.5)   // the poll loads the file, the history settles
            print("items \(model.items.count)")
            // `--scroll-timing [--all]`: the real chat scrolled top to
            // bottom in 40-pt steps, each step's main-thread CPU (`--all`:
            // the whole history laid out, not the default window).
            if args.contains("--scroll-timing") {
                if args.contains("--all") {
                    model.renderLimit = .max / 2
                    model.renderChars = .max / 2
                    pump(1.5)
                }
                guard let scroll = find(host), let doc = scroll.documentView else { print("no scroll view"); exit(1) }
                func threadCPU() -> Double {
                    var ts = timespec()
                    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
                    return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
                }
                var cpu: [Double] = []
                var y: CGFloat = 0
                let end = doc.frame.height - scroll.contentView.bounds.height
                while y < end {
                    let c = threadCPU()
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.current.run(mode: .default, before: Date())
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    cpu.append(threadCPU() - c)
                    y += 40
                }
                let cs = cpu.sorted()
                func pct(_ p: Double) -> Double { cs.isEmpty ? 0 : cs[min(cs.count - 1, Int(Double(cs.count) * p))] }
                let shown = BeautifiedSessionView.renderWindow(model.items, limit: model.renderLimit, chars: model.renderChars)
                print(String(format: "rendered %d/%d items (%d chars), doc %.0f pt — %d steps: CPU mean %.2f ms  p50 %.2f  p95 %.2f  max %.2f",
                             shown.count, model.items.count, BeautifiedSessionView.renderWeight(shown), doc.frame.height,
                             cpu.count, cpu.reduce(0, +) / Double(max(1, cpu.count)), pct(0.5), pct(0.95), cs.last ?? 0))
                // A pane opening and closing beside the chat: the re-flow.
                for w in [480.0, 965.0, 360.0] as [CGFloat] {
                    let t = Date()
                    window.setContentSize(NSSize(width: w, height: height))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    pump(0.3)
                    print(String(format: "resize to %.0f pt: %.0f ms (incl. 300 ms idle)", w, Date().timeIntervalSince(t) * 1000))
                }
                exit(0)
            }
            // `--paste KB [--send]`: paste that much text into the composer
            // the way ⌘V does (into its text view), then send it (P0: a
            // 5–20 KB paste and its send froze the app).
            if let kb = value("--paste") {
                runPaste(kb: Int(kb), send: args.contains("--send"), host: host, window: window, model: model, pump: pump)
                if let linger = value("--linger") { print("lingering"); fflush(stdout); pump(linger) }
                exit(0)
            }
            // Every long message of yours opened in full (Show all).
            if args.contains("--expand") {
                model.expandedMessages = Set(model.items.compactMap { i -> Int? in
                    if case .userText = i.kind { return i.id } else { return nil }
                })
                pump(0.5)
            }
            // Panes opening: a few widths in a row, then the squeeze.
            let steps: [CGFloat] = [560, 420, 300, narrow, narrow + 60, narrow]
            for w in steps { resize(w); pump(0.4) }
            let t0 = Date()
            var phase = 0
            while Date().timeIntervalSince(t0) < seconds {
                if phase % 5 == 2 { userDrag() }
                if let scroll = find(host), let doc = scroll.documentView {
                    let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
                    // Up a little (reading), back to the end, a jump to the top.
                    let ys: [CGFloat] = [maxY - 300, maxY, maxY * 0.5, maxY, 0, maxY]
                    let y = max(0, ys[phase % ys.count])
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                if phase % 7 == 3 { resize(narrow + 24) } else if phase % 7 == 4 { resize(narrow) }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                pump(0.5)
                phase += 1
            }
            let g = model.debugGeometry
            print("items \(model.items.count), \(model.items.map(\.approximateLength).reduce(0, +)) chars shown")
            print(String(format: "OK: %.0f s at %.0f pt — viewport %.0f content %.0f tailY %.0f watchdog %.0f",
                         seconds, narrow, g["viewport"] ?? -1, g["content"] ?? -1, g["tailY"] ?? -2,
                         g["watchdog"] ?? 0))
            if let i = args.firstIndex(of: "--shot"), i + 1 < args.count,
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
    }

    /// Lines like the QA's paste: numbered, quotes, backslashes, unicode.
    static func pasteFixture(kb: Int) -> String {
        var s = ""
        var i = 0
        while s.utf8.count < kb * 1024 {
            i += 1
            s += String(format: "L%04d ", i) + String(repeating: "abcdefghij", count: 4)
                + " | tabs\tand \"quotes\" 'single' `tick` $HOME \\backslash ünïcødé €\n"
        }
        return s
    }

    /// `--switch N [--also <fixture>]… [--seed S] [--composer] [--warm]
    /// [--select] [--no-select]` — what a QA session does to the chat: N
    /// rounds of mounting a fresh chat (a session picked in the sidebar,
    /// as `SessionPane.mountBeautified` does), then a burst of what
    /// happens on screen — Working ↔ Ready (the "Thinking…" cue in and
    /// out, animated as an interrupt does), the Files pane opening and
    /// closing (a width change), scrolling, Show all, the composer
    /// growing, a text selection dragged over the rows — and unmounting
    /// it. Seeded, so a HANG replays. `--warm` gives each fixture a
    /// history cache key (the second mount starts from cached history).
    @MainActor
    static func runSwitch(data: Data, args: [String], value: (String) -> Double?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var fixtures = [data]
        for (i, a) in args.enumerated() where a == "--also" && i + 1 < args.count {
            if let d = FileManager.default.contents(atPath: args[i + 1]) { fixtures.append(d) }
        }
        var rng = UInt64(value("--seed") ?? 1) &* 6364136223846793005 &+ 1442695040888963407
        func rand(_ n: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(max(1, n)))
        }
        func randD(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(rand(1000)) / 1000 }
        let rounds = Int(value("--switch") ?? 20)
        let height = CGFloat(value("--height") ?? 760)
        let frame = NSRect(x: 0, y: 0, width: 720, height: height)
        let window: NSWindow = args.contains("--key")
            ? BenchKeyWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: height))
        window.contentView = container
        window.acceptsMouseMovedEvents = true
        window.orderFront(nil)
        func pump(_ s: Double) {
            let until = Date().addingTimeInterval(s)
            while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func find(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView, s.documentView != nil, s.frame.height > 100 { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint, in host: NSView, post: Bool = false) {
            let w = host.convert(p, to: nil)
            if let e = NSEvent.mouseEvent(with: type, location: w, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) {
                if post { app.postEvent(e, atStart: false) } else { app.sendEvent(e) }
            }
        }
        let select = !args.contains("--no-select")
        func composerView(_ v: NSView) -> ComposerNSTextView? {
            if let t = v as? ComposerNSTextView { return t }
            for sub in v.subviews { if let t = composerView(sub) { return t } }
            return nil
        }
        let widths: [CGFloat] = [720, 480, 965, 700, 560, 360]
        var log: [String] = []
        for round in 0..<rounds {
            let fx = rand(fixtures.count)
            let provider = SwitchFixtureProvider(transcript: fixtures[fx], working: rand(2) == 0,
                                                 cacheKey: args.contains("--warm") ? "bench-fx-\(fx)" : nil)
            let model = BeautifiedSessionModel(provider: provider)
            model.start()
            let host = NSHostingView(rootView: BeautifiedSessionView(model: model,
                                                                     parts: args.contains("--composer") ? .all : .transcript))
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: container.topAnchor),
                host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            window.makeFirstResponder(host)
            log = ["round \(round) fixture \(fx) working \(provider.working)"]
            pump(randD(0.05, 0.9))
            for _ in 0..<(4 + rand(8)) {
                let action = [0, 1, 2, 3, 4, 5, 6, 7, 11, 12, 11, 8, 9, 10][rand(args.contains("--composer") ? 14 : 11)]
                print("  r\(round) action \(action)"); fflush(stdout)
                switch action {
                case 0:
                    provider.working.toggle()
                    log.append("poll-working \(provider.working)")
                case 1:
                    let on = !model.working
                    withAnimation(.easeOut(duration: 0.15)) { model.working = on; model.workingSince = on ? Date() : nil }
                    log.append("animated-working \(on)")
                case 2:
                    let w = widths[rand(widths.count)]
                    window.setContentSize(NSSize(width: w, height: height))
                    log.append("width \(Int(w))")
                case 3:
                    if let s = find(host), let doc = s.documentView {
                        let maxY = max(0, doc.frame.height - s.contentView.bounds.height)
                        let y = [maxY, maxY - 400, maxY * 0.5, 0][rand(4)]
                        s.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                        s.reflectScrolledClipView(s.contentView)
                        log.append("scroll \(Int(y))/\(Int(maxY))")
                    }
                case 4:
                    if model.expandedMessages.isEmpty {
                        model.expandedMessages = Set(model.items.compactMap { i -> Int? in
                            if case .userText = i.kind { return i.id } else { return nil }
                        })
                        log.append("expand")
                    } else {
                        model.expandedMessages = []
                        log.append("collapse")
                    }
                case 5:
                    let lines = rand(12)
                    model.composerText = (0..<lines).map { "line \($0) of a growing draft" }.joined(separator: "\n")
                    log.append("composer \(lines) lines")
                case 6 where select:
                    let b = host.bounds
                    let a = NSPoint(x: b.minX + 60 + CGFloat(rand(Int(max(1, b.width - 120)))),
                                    y: b.minY + 40 + CGFloat(rand(Int(max(1, b.height - 200)))))
                    // The drag and the release queued first: a text view
                    // tracks the drag in its own event loop on the down.
                    for k in 1...4 {
                        mouse(.leftMouseDragged, NSPoint(x: a.x + CGFloat(k * 30), y: a.y + CGFloat(k * 25)), in: host, post: true)
                    }
                    mouse(.leftMouseUp, NSPoint(x: a.x + 120, y: a.y + 100), in: host, post: true)
                    mouse(.leftMouseDown, a, in: host)
                    pump(0.05)
                    let fr = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    let sel = (window.firstResponder as? NSTextView)?.selectedRange().length ?? -1
                    log.append("select at \(Int(a.x)),\(Int(a.y)) → \(fr) sel \(sel)")
                case 7:
                    model.renderLimit += BeautifiedSessionModel.renderStep
                    model.renderChars += BeautifiedSessionModel.renderCharStep
                    log.append("show earlier")
                case 8, 9, 10:
                    // ⌘V of a big text into the composer (its own path),
                    // or the field cleared again.
                    if let tv = composerView(host) {
                        if model.composerText.utf8.count > 5000 {
                            model.composerText = ""
                            log.append("composer cleared")
                        } else {
                            window.makeFirstResponder(tv)
                            let kb = [5, 12, 21, 30][rand(4)]
                            let pb = NSPasteboard(name: NSPasteboard.Name("io.bromure.bench-paste"))
                            pb.clearContents()
                            pb.setString(pasteFixture(kb: kb), forType: .string)
                            _ = tv.readSelection(from: pb)
                            tv.scrollRangeToVisible(tv.selectedRange())
                            log.append("paste \(kb) KB")
                        }
                    }
                case 11:
                    // A poll that brought something: the chat follows the tail.
                    model.revision += 1
                    log.append("revision")
                case 12:
                    model.localRevision += 1
                    log.append("local revision")
                default:
                    break
                }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                pump(randD(0.0, 0.5))
            }
            model.stop()
            host.removeFromSuperview()
            print(log.joined(separator: " | "))
            fflush(stdout)
        }
        print("OK: \(rounds) switches settled")
    }

    @MainActor
    private static func runPaste(kb: Int, send: Bool, host: NSView, window: NSWindow,
                                 model: BeautifiedSessionModel, pump: (Double) -> Void) {
        func findText(_ v: NSView) -> ComposerNSTextView? {
            if let t = v as? ComposerNSTextView { return t }
            for sub in v.subviews { if let t = findText(sub) { return t } }
            return nil
        }
        guard let tv = findText(host) else { print("no composer"); exit(1) }
        /// CPU the process burns over 2 s of idling: a layout loop that
        /// never lets go shows as ~100 %.
        func busy(_ label: String) {
            func cpu() -> Double {
                var u = rusage(); getrusage(RUSAGE_SELF, &u)
                return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
            }
            let c0 = cpu()
            pump(2)
            print(String(format: "idle CPU %@: %.0f %%", label, (cpu() - c0) / 2 * 100))
        }
        window.makeFirstResponder(tv)
        let env = ProcessInfo.processInfo.environment
        let text = env["BENCH_PASTE_FILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            ?? pasteFixture(kb: kb)
        let t0 = Date()
        if env["BENCH_CMDV"] != nil {
            // ⌘V's own path (paste: → readSelection(from:)), off a private
            // pasteboard so the user's clipboard is left alone.
            let pb = NSPasteboard(name: NSPasteboard.Name("io.bromure.bench-paste"))
            pb.clearContents()
            pb.setString(text, forType: .string)
            _ = tv.readSelection(from: pb)
            // What paste: does after the insert.
            tv.scrollRangeToVisible(tv.selectedRange())
        } else {
            tv.insertText(text, replacementRange: tv.selectedRange())
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        print(String(format: "paste %d KB: first frame %.0f ms (composer %d chars)",
                     kb, Date().timeIntervalSince(t0) * 1000, model.composerText.count))
        pump(1)
        busy("after the paste")
        // A few keystrokes on top of it (each one a composer change).
        let t1 = Date()
        let keys = Int(ProcessInfo.processInfo.environment["BENCH_KEYS"] ?? "") ?? 3
        for c in String(repeating: "abc", count: max(1, keys / 3)) {
            tv.insertText(String(c), replacementRange: tv.selectedRange())
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date())
        }
        print(String(format: "%d keystrokes after the paste: %.0f ms", max(1, keys / 3) * 3, Date().timeIntervalSince(t1) * 1000))
        pump(1)
        if send {
            print("before send: working \(model.working) dialogOpen \(model.dialogOpen)")
            let t2 = Date()
            tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            print(String(format: "send: first frame %.0f ms", Date().timeIntervalSince(t2) * 1000))
            pump(1)
            busy("after the send")
            print("items \(model.items.count), composer \(model.composerText.count) chars, queued \(model.queued.count)")
        }
        let g = model.debugGeometry
        print(String(format: "geometry: viewport %.0f content %.0f tailY %.0f pinned %.0f watchdog %.0f",
                     g["viewport"] ?? -1, g["content"] ?? -1, g["tailY"] ?? -2, g["pinned"] ?? -1, g["watchdog"] ?? 0))
        print("OK: paste\(send ? " + send" : "") settled")
    }
}

extension ScrollBench {
    /// A Kimi wire journal: a question, then a reply holding a `rows`-row
    /// table (inline code, bold, a long unbreakable word per row) and a
    /// second small table, as ~30-character content parts of one step —
    /// the reply grows in place, poll after poll, the way a live one does.
    static func tableReplyFixture(rows: Int, part: Int = 30) -> Data {
        var reply = "Here is a comparison of the options you asked about.\n\n"
        reply += "| # | Option | Strengths | Weaknesses | Verdict |\n|---|:------|:---------:|-----------|--------:|\n"
        for i in 0..<max(1, rows) {
            reply += "| \(i) | **Option \(i)** with `code_\(i)` | Fast, simple, well documented and widely used "
                + "| Edge cases around very_long_unbreakable_identifier_\(i)_xxxxxxxxxxxxxxxx | \(i % 2 == 0 ? "Fair" : "Good") |\n"
        }
        reply += "\nIn short, pick the one that matches your constraints.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let t0 = 1_759_600_000_000.0
        var lines: [[String: Any]] = [
            ["type": "metadata", "protocol_version": "1", "time": t0],
            ["type": "context.append_message", "time": t0 + 1,
             "message": ["role": "user", "content": [["type": "text", "text": "Compare the options in a table."]]]],
        ]
        let chars = Array(reply)
        var k = 0
        while k < chars.count {
            let piece = String(chars[k..<min(chars.count, k + part)])
            lines.append(["type": "context.append_loop_event", "time": t0 + 10 + Double(k),
                          "event": ["type": "content.part", "stepUuid": "step-1",
                                    "part": ["type": "text", "text": piece]]])
            k += part
        }
        lines.append(["type": "turn.ended", "time": t0 + 1_000_000, "reason": "done"])
        var out = Data()
        for l in lines {
            if let d = try? JSONSerialization.data(withJSONObject: l) { out += d + Data([0x0a]) }
        }
        return out
    }
}

/// Serves a transcript as if the agent were writing it: a few more lines
/// at every poll, "working" until the file is whole.
@MainActor
final class GrowingTranscriptProvider: BeautifiedTranscriptProvider {
    let accent: Color = .blue
    private let lines: [Data]
    private var shown = 0
    /// Lines added at every poll.
    private let step: Int
    private static let path = "/home/ubuntu/.claude/projects/-home-ubuntu-demo/grow.jsonl"

    init(transcript: Data, step: Int = 2) {
        lines = transcript.split(separator: UInt8(ascii: "\n")).map { Data($0) + Data([0x0a]) }
        self.step = max(1, step)
        shown = min(lines.count, 3)
    }

    func activeTabIndex() -> Int? { 1 }
    func isWorking() -> Bool { shown < lines.count }
    func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }

    func execGuest(_ command: String, timeout: Int) async -> String? {
        if command.contains("pane_current_path") { return "/home/ubuntu/demo\n0\n" }
        guard command.hasPrefix("f=\"\";") else { return nil }
        // The client's cursor: `python3 - "$f" <known> <offset> <bytes> tail`.
        var known = "", off = -1
        if let r = command.range(of: #"python3 - "\$f" (\S*) (-?\d+) (\d+) (tail|earlier)"#,
                                 options: .regularExpression) {
            let parts = command[r].split(separator: " ")
            if parts.count >= 6 { known = String(parts[3]).trimmingCharacters(in: CharacterSet(charactersIn: "'")); off = Int(parts[4]) ?? -1 }
        }
        let body = lines.prefix(shown).reduce(Data(), +)
        shown = min(lines.count, shown + step)
        let size = body.count
        let start = (known == Self.path && off >= 0 && off <= size) ? off : 0
        return "\(Self.path)\n\n\(size)\n\(start)\n\(size)\n" + String(decoding: body[start...], as: UTF8.self)
    }
}

/// The fixture, with typing that "goes in": every command that isn't a
/// transcript read answers as a guarded type that went all the way
/// (`__bench-scroll --paste … --send` exercises the real send path).
@MainActor
final class TypingFixtureProvider: BeautifiedTranscriptProvider {
    private let base: FixtureTranscriptProvider
    init(_ base: FixtureTranscriptProvider) { self.base = base }
    var accent: Color { base.accent }
    func activeTabIndex() -> Int? { base.activeTabIndex() }
    func isWorking() -> Bool { base.isWorking() }
    func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
    func execGuest(_ command: String, timeout: Int) async -> String? {
        if command.contains("pane_current_path") || command.hasPrefix("f=\"\";") {
            return await base.execGuest(command, timeout: timeout)
        }
        return PaneTypeGuard.typedMarker + "\n"
    }
}

/// The fixture as a session picked in the sidebar: working or not as the
/// bench says, and (`cacheKey`) a history cache shared between mounts.
@MainActor
final class SwitchFixtureProvider: BeautifiedTranscriptProvider {
    private let base: FixtureTranscriptProvider
    var working: Bool
    let historyCacheKey: String?
    init(transcript: Data, working: Bool, cacheKey: String?) {
        base = FixtureTranscriptProvider(accent: .blue, transcript: transcript, working: false)
        self.working = working
        historyCacheKey = cacheKey
    }
    var accent: Color { base.accent }
    func activeTabIndex() -> Int? { base.activeTabIndex() }
    func isWorking() -> Bool { working }
    func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
    func execGuest(_ command: String, timeout: Int) async -> String? {
        if command.contains("pane_current_path") || command.hasPrefix("f=\"\";") {
            return await base.execGuest(command, timeout: timeout)
        }
        return PaneTypeGuard.typedMarker + "\n"
    }
}

/// A window that reads as the key, active one (`--key`): selectable text
/// and focus rings draw as they do in the app's front window.
final class BenchKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A tiny lock-guarded value for the watchdog thread.
private final class OSAllocatedUnfairLockBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
#endif
