import ArgumentParser
import AppKit
import Foundation
import SandboxEngine
import Virtualization
import IOSurface
import Darwin

/// Explicit experimental entry point; normal browser/profile sessions remain single-GPU.
struct MultiGPUBrowser: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "multi-gpu-browser",
        abstract: "Open accelerated browser windows backed by one Linux VM.")
    @Option(name: .long) var storageDir: String
    @Option(name: .long) var seconds: Int = 0
    @Option(name: .long) var gpuCount: Int = 2
    @Option(name: .long) var memoryGB: Int = 4
    @Option(name: .long) var url: String = "https://www.slashdot.org"
    @Option(name: .long) var guestProbe: String?
    @Flag(name: .long) var allowOlderTestImage = false
    @Flag(name: .long) var frameTrace = false
    @Flag(name: .long) var requireGPUCheck = false
    @Flag(name: .long) var inputCheck = false

    func validate() throws {
        guard (0...3600).contains(seconds) else { throw ValidationError("Duration must be 0 (interactive) through 3600 seconds") }
        guard (2...16).contains(gpuCount), (4...32).contains(memoryGB) else {
            throw ValidationError("GPU count must be 2 through 16; memory must be 4 through 32 GiB")
        }
        if requireGPUCheck && (guestProbe == nil || seconds < 30) {
            throw ValidationError("GPU acceptance needs a guest probe and at least 30 seconds")
        }
    }

    func run() throws {
        guard #available(macOS 27.0, *) else { throw ValidationError("Multiple custom GPUs require macOS 27") }
        setbuf(stdout, nil)
        let options = self
        Task { @MainActor in
            do { try await options.browse(); Darwin.exit(0) }
            catch { fputs("Multi-GPU browser failed: \(error)\n", stderr); Darwin.exit(1) }
        }
        RunLoop.main.run()
    }

    @MainActor private func browse() async throws {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["vm.displayScale"] = 2; arguments["vm.traceGPUFrames"] = frameTrace
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        var config = VMConfig()
        config.enableGPU = true; config.enableWebGL = true; config.enableMetalRenderer = true
        config.nativeChrome = false; config.nativeChromeInset = 0
        config.experimentalGPUCount = gpuCount
        config.memorySize = UInt64(memoryGB) * 1024 * 1024 * 1024
        config.extraKernelOptions += " bromure.experimental_multigpu=\(gpuCount)"
        config.homePage = url
        let pool = VMPool(config: config, storageDir: URL(fileURLWithPath: storageDir),
                          requireImageVersion: !allowOlderTestImage, experimentalGPU: true)
        try await pool.warmUp()
        guard let warm = await pool.claim(config: config) else {
            await pool.shutdown(); throw ValidationError("VM claim failed")
        }
        let sessions = warm.graphicsSessions
        guard sessions.count == gpuCount, sessions.allSatisfy({ $0.backendName == "virgl" }) else {
            await pool.retire(warm); await pool.shutdown()
            throw ValidationError("All requested custom GPU devices must initialize; no software fallback in this experiment")
        }
        warm.serialWaiter.observer = { print("[multi-GPU guest] " + $0, terminator: "") }
        let owner = MultiGPUWindowOwner(warm: warm)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.delegate = owner
        owner.installMenu()
        do {
            try owner.openWindows()
            NSApplication.shared.activate(ignoringOtherApps: true)
            let deadline = seconds == 0 ? Date.distantFuture : Date().addingTimeInterval(TimeInterval(seconds))
            let check = requireGPUCheck ? Task { await warm.serialWaiter.probe(for: "BROMURE_MULTIGPU_ACCEPTANCE_PASS", timeout: Double(max(seconds - 5, 1))) } : nil
            let probeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let guestProbe, let data = try? Data(contentsOf: URL(fileURLWithPath: guestProbe)) else { return }
                let encoded = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                let script = "base64 -d > /tmp/multigpu-probe.py <<'BROMURE_MULTIGPU_EOF'\n" + encoded + "\nBROMURE_MULTIGPU_EOF\npython3 /tmp/multigpu-probe.py\n"
                warm.serialInput.fileHandleForWriting.write(Data(script.utf8))
            }
            let inputTask = inputCheck ? Task { @MainActor in
                let ready = await warm.serialWaiter.probe(for: "BROMURE_MULTIGPU_FIXTURES_READY", timeout: 60)
                if !ready { return false }
                do { try await owner.checkInput(); return true }
                catch { print("[multi-GPU] host input check failed: \(error)"); return false }
            } : nil
            var lastLog = Date()
            while owner.hasWindows && warm.vm.state != .stopped && Date() < deadline {
                if Date().timeIntervalSince(lastLog) >= 10 {
                    for (index, graphics) in sessions.enumerated() {
                        print("[multi-GPU] device=\(index) frames=\(graphics.deliveredFrameCount) running=\(graphics.isRendererRunning)")
                        graphics.logResourceUsage()
                    }
                    lastLog = Date()
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            probeTask.cancel()
            let guestAccepted = await check?.value ?? true
            let inputAccepted = await inputTask?.value ?? true
            let accepted = guestAccepted && inputAccepted
            check?.cancel()
            if accepted && inputCheck { try await owner.checkLifecycle() }
            owner.closeAll()
            for (index, graphics) in sessions.enumerated() {
                print("[multi-GPU] final device=\(index) frames=\(graphics.deliveredFrameCount)")
            }
            if !accepted { throw ValidationError("Multi-GPU guest acceptance failed") }
        } catch {
            owner.closeAll(); await pool.retire(warm); await pool.shutdown(); throw error
        }
        await pool.retire(warm); await pool.shutdown()
        NSApplication.shared.delegate = nil
    }
}

@MainActor
private final class MultiGPUWindowOwner: NSObject, NSWindowDelegate, NSApplicationDelegate {
    private let warm: VMPool.WarmVM
    private var windows: [NSWindow] = []
    private var views: [Int: MultiGPUVMView] = [:]
    private var input: MultiGPUInputBridge?
    private var surfaces: [Int: IOSurface] = [:]
    var hasWindows: Bool { !windows.isEmpty }
    init(warm: VMPool.WarmVM) { self.warm = warm }

    func installMenu() {
        let menu = NSMenu(); let app = NSMenu(); let item = NSMenuItem(); item.submenu = app; menu.addItem(item)
        let quit = NSMenuItem(title: "Quit Multi-GPU Browser", action: #selector(closeAll), keyEquivalent: "q")
        quit.target = self; app.addItem(quit); NSApplication.shared.mainMenu = menu
    }

    func openWindows() throws {
        if let socket = warm.vm.socketDevices.first as? VZVirtioSocketDevice {
            input = MultiGPUInputBridge(socketDevice: socket)
        }
        for (index, graphics) in warm.graphicsSessions.enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 60 + index * 100, y: 100 + index * 60, width: 960, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Bromure · Metal GPU \(index + 1) · Shared VM"
            window.isReleasedWhenClosed = false; window.delegate = self; window.acceptsMouseMovedEvents = true
            let view = MultiGPUVMView(display: index, bridge: input)
            view.frame = window.contentView!.bounds; view.autoresizingMask = [.width, .height]
            view.virtualMachine = warm.vm; view.capturesSystemKeys = false; view.automaticallyReconfiguresDisplay = false
            let frame = try HostGPUFrameView(gpuFrame: view.bounds)
            frame.autoresizingMask = [.width, .height]; frame.guestDisplayScale = 2
            frame.displaySizeChanged = { [weak graphics] width, height in graphics?.resizeDisplay(width: width, height: height) }
            view.addSubview(frame); view.gpuView = frame; window.contentView = view
            graphics.observeFrames { [weak self, weak frame] surface in
                DispatchQueue.main.async {
                    self?.surfaces[index] = surface
                    if let surface { try? frame?.present(surface) } else { frame?.discardFrame() }
                }
            }
            graphics.observeCursor { [weak frame] cursor in DispatchQueue.main.async { frame?.presentCursor(cursor) } }
            windows.append(window); views[window.windowNumber] = view
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
            print("[multi-GPU] window=\(window.windowNumber) device=\(index) vm=\(ObjectIdentifier(warm.vm))")
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let view = views[window.windowNumber] else { return }
        view.releaseButtons(); input?.focus(display: view.display)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let view = views.removeValue(forKey: window.windowNumber) else { return }
        view.releaseButtons(); view.virtualMachine = nil
        warm.graphicsSessions[view.display].observeFrames { _ in }
        warm.graphicsSessions[view.display].observeCursor { _ in }
        surfaces.removeValue(forKey: view.display)
        window.delegate = nil; windows.removeAll { $0 === window }
        print("[multi-GPU] closed device=\(view.display), remaining=\(windows.count); shared VM retained")
    }

    func checkInput() async throws {
        for _ in 0..<50 {
            if input?.isConnected == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard input?.isConnected == true else { throw ValidationError("Input service is not connected") }
        for index in 0..<warm.graphicsSessions.count {
            guard let window = windows.first(where: { views[$0.windowNumber]?.display == index }),
                  let view = views[window.windowNumber], let surface = surfaces[index] else {
                throw ValidationError("Missing GPU window or surface")
            }
            IOSurfaceLock(surface, .readOnly, nil)
            let x = IOSurfaceGetWidth(surface) / 4, y = IOSurfaceGetHeight(surface) * 3 / 4
            let pixel = IOSurfaceGetBaseAddress(surface).advanced(by: y * IOSurfaceGetBytesPerRow(surface) + x * 4)
            let colour = Array(UnsafeBufferPointer(start: pixel.assumingMemoryBound(to: UInt8.self), count: 3))
            IOSurfaceUnlock(surface, .readOnly, nil)
            let expected: [UInt8] = [UInt8(40 + (index * 71) % 180), UInt8(40 + (index * 53) % 180), UInt8(40 + (index * 37) % 180)]
            guard zip(colour, expected).allSatisfy({ abs(Int($0)-Int($1)) <= 1 }) else {
                throw ValidationError("GPU \(index) has wrong fixture pixels: \(colour)")
            }
            print("[multi-GPU] source pixel PASS device=\(index) BGRA=\(colour)")
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
            let point = view.convert(NSPoint(x: view.bounds.width * 0.25, y: view.bounds.height * 0.4), to: nil)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
            try await Task.sleep(for: .milliseconds(500))
            let character = "a"
            for type: NSEvent.EventType in [.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: 0)!
                if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
            }
            input?.send(display: index, x: 0.25, y: 0.6, buttons: 0, wheelY: 240)
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let first = windows.first(where: { views[$0.windowNumber]?.display == 0 }),
              let view = views[first.windowNumber] else { throw ValidationError("Missing first display") }
        first.makeKeyAndOrderFront(nil); first.makeFirstResponder(view)
        input?.focus(display: 0)
        try await Task.sleep(for: .milliseconds(500))
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: first.windowNumber,
                context: nil, characters: "c", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: 8)!
            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
        print("[multi-GPU] host input events sent with focus 0→1→0")
    }

    func checkLifecycle() async throws {
        guard windows.count == warm.graphicsSessions.count else { throw ValidationError("Expected all GPU windows for lifecycle check") }
        let first = windows[0], second = windows[1]
        let original = surfaces.mapValues { (IOSurfaceGetWidth($0), IOSurfaceGetHeight($0)) }
        first.setContentSize(NSSize(width: 800, height: 500))
        second.setContentSize(NSSize(width: 1100, height: 640))
        var resized = false
        for _ in 0..<150 {
            if (0..<2).allSatisfy({ index in
                guard let surface = surfaces[index], let old = original[index] else { return false }
                return IOSurfaceGetWidth(surface) != old.0 || IOSurfaceGetHeight(surface) != old.1
            }) { resized = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard resized else { throw ValidationError("Both GPU windows must receive resized surfaces") }
        first.close()
        try await Task.sleep(for: .seconds(2))
        guard windows.count == warm.graphicsSessions.count - 1, warm.vm.state == .running,
              warm.graphicsSessions.allSatisfy({ $0.isRendererRunning }) else {
            throw ValidationError("Closing one window stopped the shared VM or a renderer")
        }
        print("[multi-GPU] lifecycle PASS: both displays resized; closing one retains shared VM")
    }

    @objc func closeAll() {
        for window in Array(windows) { window.close() }
        input?.stop(); input = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        closeAll(); return .terminateCancel
    }
}

@MainActor
private final class MultiGPUVMView: VZVirtualMachineView {
    let display: Int
    weak var bridge: MultiGPUInputBridge?
    weak var gpuView: HostGPUFrameView?
    private var buttons = 0
    private var tracking: NSTrackingArea?
    init(display: Int, bridge: MultiGPUInputBridge?) { self.display = display; self.bridge = bridge; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Use display initializer") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    func releaseButtons() { buttons = 0; bridge?.release() }
    private func pointer(_ event: NSEvent, button: Int = 0, down: Bool? = nil, wheel: Bool = false) {
        guard let bridge else { return }
        if let down { if down { buttons |= button } else { buttons &= ~button } }
        let point = convert(event.locationInWindow, from: nil)
        let normalized = gpuView?.normalizedGuestPoint(convert(point, to: gpuView)) ??
            (x: Double(point.x / max(bounds.width, 1)), y: Double(1 - point.y / max(bounds.height, 1)))
        bridge.send(display: display, x: normalized.x, y: normalized.y, buttons: buttons,
                    focus: down == true, wheelX: wheel ? -Double(event.scrollingDeltaX) : 0,
                    wheelY: wheel ? -Double(event.scrollingDeltaY) : 0, coalescingMotion: down == nil && !wheel)
    }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, button: 1, down: true) }
    override func mouseUp(with event: NSEvent) { pointer(event, button: 1, down: false) }
    override func rightMouseDown(with event: NSEvent) { pointer(event, button: 2, down: true) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, button: 2, down: false) }
    override func otherMouseDown(with event: NSEvent) { pointer(event, button: 4, down: true) }
    override func otherMouseUp(with event: NSEvent) { pointer(event, button: 4, down: false) }
    override func scrollWheel(with event: NSEvent) { pointer(event, wheel: true) }
}
