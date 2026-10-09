import ArgumentParser
import AppKit
import Foundation
import IOSurface
import SandboxEngine
import Darwin

/// Developer demonstration of Bromure's renderer service and native display.
/// Browser backend selection remains gated until real guest scanout passes.
struct GPUDemo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gpu-demo",
        abstract: "Demonstrate the experimental sandboxed Metal renderer.")

    @Flag(name: .long, help: "Verify the shared frame without opening a window.")
    var headless = false

    @Option(name: .long, help: "How many seconds to display the demonstration.")
    var seconds: Int = 30

    func validate() throws {
        guard (1...3600).contains(seconds) else { throw ValidationError("seconds must be between 1 and 3600") }
    }

    func run() throws {
        guard #available(macOS 27.0, *) else { throw ValidationError("The experimental renderer requires macOS 27") }
        let options = self
        Task { @MainActor in
            do {
                try await options.demonstrate()
                Darwin.exit(0)
            } catch {
                fputs("GPU demonstration failed: \(error)\n", stderr)
                Darwin.exit(1)
            }
        }
        RunLoop.main.run()
    }

    @available(macOS 27.0, *)
    @MainActor
    private func demonstrate() async throws {
        let renderer = try MacOS27RendererClient()
        defer { renderer.stop() }
        var create = [UInt32](repeating: 0, count: 18)
        create[0] = 4; create[2] = 0x74736574
        let resource: [UInt32] = [9, 2, 1, (1 << 1) | (1 << 18), 64, 64, 1, 1, 0, 0, 0, 0]
        let stream: [UInt32] = [
            1 | (8 << 8) | (5 << 16), 11, 9, 1, 0, 0,
            5 | (3 << 16), 1, 0, 11,
            7 | (8 << 16), 4, 0x3f800000, 0, 0, 0x3f800000, 0, 0, 0,
        ]
        let commands = [
            command(0xffff0020, body: [64, 64]),
            command(0x200, context: 7, body: create),
            command(0x204, body: resource), command(0x202, context: 7, body: [9, 0]),
            command(0x207, context: 7, flags: 1, body: [UInt32(stream.count * 4), 0] + stream),
            command(0x103, body: [0, 0, 64, 64, 0, 9]),
            command(0x104, body: [0, 0, 64, 64, 9, 0]),
        ]
        var surface: IOSurface?
        for request in commands {
            let result: MacOS27RendererClient.Reply = try await withCheckedThrowingContinuation { continuation in
                renderer.execute(request) { continuation.resume(with: $0) }
            }
            guard result.command.prefix(4).elementsEqual([0, 0x11, 0, 0]) else {
                throw ValidationError("Renderer rejected a demonstration command")
            }
            if let frame = result.surface { surface = frame }
        }
        guard let surface, IOSurfaceGetWidth(surface) == 64, IOSurfaceGetHeight(surface) == 64,
              IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else {
            throw ValidationError("Shared GPU frame unavailable")
        }
        let pixel = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let correct = pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 255 && pixel[3] == 255
        IOSurfaceUnlock(surface, .readOnly, nil)
        guard correct else { throw ValidationError("GPU frame correctness check failed") }
        print("PASS: Bromure rendered VirGL commands in its sandboxed XPC service and imported the red IOSurface frame")
        if headless { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Bromure — experimental Metal renderer"
        let view = try HostGPUFrameView(gpuFrame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        try view.present(surface)
        window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        print("Displaying the host GPU frame for \(seconds) seconds. Browser acceleration and movie decoding are separate integration gates.")
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while window.isVisible && Date() < deadline {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            app.updateWindows()
            try await Task.sleep(for: .milliseconds(1))
        }
        guard view.presentedFrameCount > 0 else { throw ValidationError("Metal display did not complete a frame") }
        print("PASS: Bromure Metal display completed \(view.presentedFrameCount) frame(s)")
        window.orderOut(nil)
    }

    private func command(_ type: UInt32, context: UInt32 = 0, flags: UInt32 = 0, body: [UInt32]) -> Data {
        let words = [type, flags, 123, 0, context, 0] + body
        var data = Data()
        for value in words {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }
}
