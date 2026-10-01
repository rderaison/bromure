import ArgumentParser
import AppKit
import Foundation
import SandboxEngine
import Darwin

/// Runs the real browser session against an explicitly chosen experimental image.
struct GPUBrowser: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gpu-browser",
        abstract: "Run a browser with the experimental sandboxed VirGL/Metal device.")
    @Option(name: .long) var storageDir: String
    @Option(name: .long) var seconds: Int = 120
    @Option(name: .customLong("simultaneous-vms")) var simultaneousVMs: Int = 1
    @Option(name: .long) var guestProbe: String?
    @Option(name: .long) var chromeFlags: String?
    @Option(name: .long) var saveUpdatedImage: String?
    @Flag(name: .long) var requireGPUCheck = false
    @Flag(name: .long) var interactive = false
    @Flag(name: .long) var nativeChrome = false
    @Flag(name: .long) var resizeCheck = false
    @Flag(name: .long) var cursorCheck = false
    @Flag(name: .long) var menuCheck = false
    @Flag(name: .long, help: "Verify postinstall imports the validated guest graphics marker in the selected test image.")
    var postinstallCheck = false
    @Flag(name: .long, help: "Benchmark Apple’s built-in Virtio graphics device without the custom VirGL renderer.")
    var appleVirtioGPU = false
    @Option(name: .long) var checkTimeout: Int = 30
    @Option(name: .long) var url: String = "chrome://gpu"

    func validate() throws {
        guard (1...4).contains(simultaneousVMs) else { throw ValidationError("Simultaneous VMs must be between 1 and 4") }
        guard (1...3600).contains(seconds) else { throw ValidationError("Invalid duration") }
        guard (1...3600).contains(checkTimeout), checkTimeout <= seconds else { throw ValidationError("Invalid check timeout") }
        if let saveUpdatedImage, FileManager.default.fileExists(atPath: saveUpdatedImage) {
            throw ValidationError("Updated image output must be a new directory")
        }
        if requireGPUCheck && (guestProbe == nil || seconds < 30) {
            throw ValidationError("GPU acceptance requires a guest probe and at least 30 seconds")
        }
    }

    func run() throws {
        setbuf(stdout, nil)
        if let chromeFlags {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["vm.extraChromeFlags"] = chromeFlags
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        guard #available(macOS 27.0, *) else { throw ValidationError("Requires macOS 27") }
        let options = self
        Task { @MainActor in
            do { try await options.browse(); Darwin.exit(0) }
            catch { fputs("GPU browser failed: \(error)\n", stderr); Darwin.exit(1) }
        }
        RunLoop.main.run()
    }

    @MainActor private func browse() async throws {
        if postinstallCheck {
            let manager = LinuxImageManager(storageDir: URL(fileURLWithPath: storageDir))
            try await manager.applyPostinstallSteps([
                PostinstallStep(uuid: UUID().uuidString, seq: 0,
                                description: "Verify graphics metadata export", command: ":")
            ]) { print(String(describing: $0)) }
            guard manager.supportsExperimentalVirgl else {
                throw ValidationError("Postinstall did not import a validated graphics marker")
            }
            print("BROMURE_POSTINSTALL_GRAPHICS_PASS")
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        var config = VMConfig()
        config.homePage = url
        config.enableGPU = true
        config.enableWebGL = true
        config.nativeChrome = nativeChrome
        if nativeChrome { config.nativeChromeInset = VMConfig.defaultNativeChromeInset(forDisplayScale: VMConfig.resolvedDisplayScale()) }
        let pool = VMPool(config: config, storageDir: URL(fileURLWithPath: storageDir), experimentalGPU: !appleVirtioGPU)
        try await pool.warmUp()
        guard let warm = await pool.claim(config: config),
              appleVirtioGPU ? warm.graphicsSession == nil : warm.graphicsSession?.backendName == "virgl" else {
            await pool.shutdown()
            throw ValidationError("VM did not select the experimental GPU")
        }
        warm.serialWaiter.observer = { text in print(text, terminator: "") }
        if interactive {
            let serial = warm.serialInput.fileHandleForWriting
            FileHandle.standardInput.readabilityHandler = { input in
                let data = input.availableData
                if data.isEmpty { input.readabilityHandler = nil }
                else { try? serial.write(contentsOf: data) }
            }
        }
        defer { if interactive { FileHandle.standardInput.readabilityHandler = nil } }
        let session = BrowserSession(warmVM: warm, config: config)
        if saveUpdatedImage != nil { warm.vm.delegate = nil }
        session.show()
        var additional: [(VMPool, VMPool.WarmVM, BrowserSession)] = []
        for _ in 1..<simultaneousVMs {
            let extraPool = VMPool(config: config, storageDir: URL(fileURLWithPath: storageDir), experimentalGPU: !appleVirtioGPU)
            try await extraPool.warmUp()
            guard let extra = await extraPool.claim(config: config),
                  appleVirtioGPU ? extra.graphicsSession == nil : extra.graphicsSession?.backendName == "virgl" else {
                await extraPool.shutdown(); throw ValidationError("Additional VM did not select the GPU")
            }
            let extraSession = BrowserSession(warmVM: extra, config: config)
            extraSession.show()
            additional.append((extraPool, extra, extraSession))
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let acceptanceTask: Task<Bool, Never>? = requireGPUCheck ? Task {
            await warm.serialWaiter.probe(for: "BROMURE_GPU_ACCEPTANCE_PASS", timeout: TimeInterval(checkTimeout))
        } : nil
        defer { acceptanceTask?.cancel() }
        let diagnosticTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard warm.vm.state == .running else { return }
            if let guestProbe, let script = try? Data(contentsOf: URL(fileURLWithPath: guestProbe)) {
                let encoded = script.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                let command = "base64 -d > /tmp/bromure-gpu-probe.py <<'BROMURE_GPU_PROBE_EOF'\n" + encoded + "\nBROMURE_GPU_PROBE_EOF\npython3 /tmp/bromure-gpu-probe.py\n"
                warm.serialInput.fileHandleForWriting.write(Data(command.utf8))
            }
            let diagnostic = "echo BROMURE_GPU_DIAGNOSTIC; DISPLAY=:0 XAUTHORITY=/home/chrome/.Xauthority /usr/local/bin/graphics-diagnostics.py; python3 -c 'import runpy,json,urllib.request; m=runpy.run_path(\"/usr/local/bin/tab-agent.py\"); v=json.load(urllib.request.urlopen(\"http://127.0.0.1:9222/json/version\")); print(json.dumps(m[\"cdp_ws_call\"](v[\"webSocketDebuggerUrl\"],\"SystemInfo.getInfo\")))'; cat /tmp/startx.log | grep -E '(GL implementation|EGL|egl|ANGLE|Gpu|gpu_process|GL context)' | tail -30; echo BROMURE_GPU_DIAGNOSTIC_END\n"
            warm.serialInput.fileHandleForWriting.write(Data(diagnostic.utf8))
        }
        defer { diagnosticTask.cancel() }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        let resizeAt = Date().addingTimeInterval(28)
        var resized = false
        while Date() < deadline, warm.vm.state != .stopped {
            if resizeCheck, !resized, Date() >= resizeAt {
                session.window.setContentSize(NSSize(width: 800, height: 500))
                resized = true
                print("[GPU browser] Resize requested: 800x500 points")
            }
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                             inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            NSApplication.shared.updateWindows()
            try await Task.sleep(for: .milliseconds(2))
        }
        let menuOK: Bool
        if menuCheck {
            let delegate = GUIAppDelegate(state: AppState(previewStorage: FileManager.default.temporaryDirectory.appendingPathComponent("bromure-menu-check-" + UUID().uuidString)))
            delegate.sessions = [session] + additional.map { $0.2 }
            delegate.setupMenu()
            let item = NSApp.mainMenu?.items.last
            let toggle = item?.submenu?.items.first(where: { $0.title == "Use Metal Renderer" })
            menuOK = item?.title == (appleVirtioGPU ? "Software" : "Metal") && toggle?.isEnabled == MetalRendererPreference.isSupported
            print("[GPU browser] Menu renderer: \(item?.title ?? "missing"), Metal option enabled: \(toggle?.isEnabled ?? false)")
        } else { menuOK = true }
        let frames = warm.graphicsSession?.deliveredFrameCount ?? 0
        let accepted = await acceptanceTask?.value ?? true
        print("[GPU browser] Frames delivered: \(frames)")
        print("[GPU browser] Cursor images: \(warm.graphicsSession?.deliveredCursorCount ?? 0), cursor moves: \(warm.graphicsSession?.cursorMoveCount ?? 0)")
        func cursorImages(in view: NSView) -> Int {
            if let frame = view as? HostGPUFrameView { return frame.nativeCursorImageCount }
            return view.subviews.reduce(0) { $0 + cursorImages(in: $1) }
        }
        let hostCursorImages = session.window.contentView.map { cursorImages(in: $0) } ?? 0
        print("[GPU browser] Native host cursor images: \(hostCursorImages)")
        let cursorOK = !cursorCheck || ((warm.graphicsSession?.deliveredCursorCount ?? 0) > 0 &&
                                       (warm.graphicsSession?.cursorMoveCount ?? 0) > 0 && hostCursorImages > 0)
        var additionalOK = true
        for (index, (extraPool, extra, extraSession)) in additional.enumerated() {
            let extraFrames = extra.graphicsSession?.deliveredFrameCount ?? 0
            print("[GPU browser] VM \(index + 2) backend=\(extra.graphicsSession?.backendName ?? "apple") frames=\(extraFrames)")
            additionalOK = additionalOK && (appleVirtioGPU || extraFrames > 0)
            await extraPool.retire(extra); await extraPool.shutdown()
            withExtendedLifetime(extraSession) {}
        }

        do {
        if let saveUpdatedImage {
            // Keep the developer image snapshot alive until our explicit retirement.
            warm.vm.delegate = nil
            if warm.vm.state == .running {
                warm.serialInput.fileHandleForWriting.write(Data("sync; pkill -9 -x squid; poweroff\n".utf8))
                let shutdownDeadline = Date().addingTimeInterval(120)
                while warm.vm.state != .stopped, Date() < shutdownDeadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            guard warm.vm.state == .stopped else {
                throw ValidationError("Guest must shut down cleanly before saving its disk")
            }
            let output = URL(fileURLWithPath: saveUpdatedImage, isDirectory: true)
            let source = URL(fileURLWithPath: storageDir, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: warm.ephemeralDisk.ephemeralURL,
                                             to: output.appendingPathComponent("linux-base.img"))
            for name in ["vmlinuz", "initrd", "image-version", "image-state.json", "graphics-capabilities.json", "build-info.json"] {
                let path = source.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: path.path) {
                    try FileManager.default.copyItem(at: path, to: output.appendingPathComponent(name))
                }
            }
            print("[GPU browser] Updated image saved: \(output.path)")
        }
        } catch {
            await pool.retire(warm)
            await pool.shutdown()
            throw error
        }
        await pool.retire(warm)
        await pool.shutdown()
        withExtendedLifetime(session) {}
        guard appleVirtioGPU || frames > 0, accepted, additionalOK, cursorOK, menuOK else { throw ValidationError("Browser GPU acceptance failed") }
    }
}
