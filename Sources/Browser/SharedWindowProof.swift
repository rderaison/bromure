import AppKit
import Foundation
import IOSurface
import SandboxEngine
import Virtualization

/// Private-image proof only. Production BrowserSession ownership and menu routing
/// are deliberately not inferred from this display/controller integration check.
@MainActor
final class SharedWindowProof {
    let window: NSWindow
    let graphics: HostGraphicsSession
    let controller: SharedWindowControllerBridge
    private var latestSurface: IOSurface?
    private init(window: NSWindow, graphics: HostGraphicsSession, controller: SharedWindowControllerBridge) {
        self.window = window; self.graphics = graphics; self.controller = controller
    }
    func close() { graphics.stop(); window.close() }

    @available(macOS 27.0, *)
    static func run(warm: VMPool.WarmVM) async throws -> SharedWindowProof {
        guard let gpu = warm.graphicsSession as? MacOS27GPUSession, gpu.scanoutCount == 2,
              let socket = warm.vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw failure("Two shared scanouts are required")
        }
        let controller = SharedWindowControllerBridge(socketDevice: socket)
        var listing: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            do {
                listing = try await controller.request("list", fields: ["expectedScanouts": 2])
                if listing["ok"] as? Bool == true, let windows = listing["windows"] as? [[String: Any]], !windows.isEmpty { break }
                print("[shared-window] waiting: \(listing)")
            } catch { print("[shared-window] waiting: \(error)") }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("[shared-window] initial state: \(listing)")
        guard listing["ok"] as? Bool == true,
              let outputs = listing["outputs"] as? [[String: Any]], outputs.count == 2,
              let windows = listing["windows"] as? [[String: Any]], windows.count == 1,
              let primaryID = windows[0]["windowId"] as? Int else { throw failure("Initial browser/mapping unavailable") }
        let topology: [[String: Any]] = try (0..<2).map { index in
            guard let output = outputs.first(where: { $0["scanout"] as? Int == index })?["output"] as? String else {
                throw failure("Missing authoritative connector mapping")
            }
            var row: [String: Any] = ["scanout": index, "output": output, "x": index * 1280,
                                     "y": 0, "width": 1280, "height": 900, "enabled": true]
            if index == 0 { row["windowId"] = primaryID }
            return row
        }
        try await gpu.publishOutputs((0..<2).map {
            .init(index: $0, x: $0 * 1280, y: 0, width: 1280, height: 900, enabled: true)
        })
        let attached = try await controller.request("attachPrimary", fields: ["scanout": 0, "windowId": primaryID, "topology": topology])
        print("[shared-window] attach: \(attached)")
        guard attached["ok"] as? Bool == true else { throw failure("Primary attach failed") }
        let created = try await controller.request("create", fields: ["scanout": 1, "url": "about:blank", "topology": topology])
        print("[shared-window] create: \(created)")
        guard created["ok"] as? Bool == true, let secondID = created["windowId"] as? Int,
              secondID != primaryID, let graphics = gpu.outputSession(index: 1, onResize: { _, _ in }) else {
            throw failure("Second browser window creation failed")
        }
        let window = NSWindow(contentRect: NSRect(x: 700, y: 100, width: 640, height: 450),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Bromure · Shared Chromium · Output 2"
        window.isReleasedWhenClosed = false
        let frame = try HostGPUFrameView(gpuFrame: NSRect(x: 0, y: 0, width: 640, height: 450))
        frame.autoresizingMask = [.width, .height]; frame.guestDisplayScale = 2
        window.contentView = frame
        let proof = SharedWindowProof(window: window, graphics: graphics, controller: controller)
        graphics.observeFrames { [weak frame, weak proof] surface in
            DispatchQueue.main.async {
                proof?.latestSurface = surface
                if let surface { try? frame?.present(surface) } else { frame?.discardFrame() }
            }
        }
        graphics.observeCursor { [weak frame] cursor in DispatchQueue.main.async { frame?.presentCursor(cursor) } }
        window.makeKeyAndOrderFront(nil)
        let frameDeadline = Date().addingTimeInterval(15)
        while graphics.deliveredFrameCount == 0, Date() < frameDeadline { try await Task.sleep(for: .milliseconds(100)) }
        guard graphics.deliveredFrameCount > 0 else { proof.close(); throw failure("Second output received no frames") }
        print("BROMURE_SHARED_WINDOW_CORE_PASS primary=\(primaryID) secondary=\(secondID) VM=\(ObjectIdentifier(warm.vm)) frames=\(graphics.deliveredFrameCount)")
        return proof
    }
    func verifySecondOutputColor() throws {
        guard let surface = latestSurface else { throw Self.failure("No second output surface") }
        IOSurfaceLock(surface, .readOnly, nil); defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        guard width == 1280, height == 900 else {
            throw Self.failure("Unexpected second output surface geometry")
        }
        let address = IOSurfaceGetBaseAddress(surface)
        let pixel = address.advanced(by: height / 2 * IOSurfaceGetBytesPerRow(surface) + width / 2 * 4)
            .assumingMemoryBound(to: UInt8.self)
        let rgb = [pixel[2], pixel[1], pixel[0]]
        guard rgb == [32, 84, 210] else { throw Self.failure("Second output source pixels incorrect: \(rgb)") }
        print("BROMURE_SHARED_WINDOW_SOURCE_PIXEL_PASS RGB=\(rgb)")
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "BromureSharedWindowProof", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
