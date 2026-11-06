import AppKit
import ObjectiveC

/// Which views lay out the most, logged every 5 s, when the app is started
/// with BROMURE_LAYOUT_STATS=1. A main thread busy in layout names no view in a
/// sample (SwiftUI's hosting views show as NSHostingView<A>); this names them,
/// by type, so the one laid out on every frame can be found on the machine
/// where it happens. Off, it does nothing at all.
enum LayoutStats {
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var original: IMP?

    @MainActor static func startIfAsked() {
        guard ProcessInfo.processInfo.environment["BROMURE_LAYOUT_STATS"] == "1", original == nil,
              let method = class_getInstanceMethod(NSView.self, #selector(NSView.layout)) else { return }
        typealias Layout = @convention(c) (NSView, Selector) -> Void
        original = method_getImplementation(method)
        let counted: @convention(block) (NSView) -> Void = { view in
            counts[String(describing: type(of: view)), default: 0] += 1
            unsafeBitCast(original, to: Layout.self)(view, #selector(NSView.layout))
        }
        method_setImplementation(method, imp_implementationWithBlock(counted))
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            let top = counts.sorted { $0.value > $1.value }.prefix(12)
            counts = [:]
            let line = top.map { "\($0.value / 5)/s \($0.key)" }.joined(separator: " | ")
            FileHandle.standardError.write(Data("[layout-stats] \(line)\n".utf8))
        }
    }
}
