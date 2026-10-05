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
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async { lastPong.set(Date()) }
                if Date().timeIntervalSince(lastPong.get()) > 4 {
                    print("HANG: the main thread has not answered for 4 s (layout loop)")
                    fflush(stdout)
                    _exit(3)
                }
            }
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let provider: BeautifiedTranscriptProvider = grow
                ? GrowingTranscriptProvider(transcript: data, step: Int(value("--grow-step") ?? 2))
                : FixtureTranscriptProvider(accent: .blue, transcript: data, working: working)
            let model = BeautifiedSessionModel(provider: provider)
            model.start()
            let host = NSHostingView(rootView: BeautifiedSessionView(model: model,
                                                                     parts: args.contains("--composer") ? .all : .transcript)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
            let height = CGFloat(value("--height") ?? 760)
            host.frame = NSRect(x: 0, y: 0, width: 720, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.contentView = host
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

/// A tiny lock-guarded value for the watchdog thread.
private final class OSAllocatedUnfairLockBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
#endif
