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
    @Option(name: .long) var displayScale: Int = 2
    @Option(name: .customLong("simultaneous-vms")) var simultaneousVMs: Int = 1
    @Option(name: .long) var guestProbe: String?
    @Option(name: .long) var profilePickerPreview: String?
    @Option(name: .long) var testProfileDir: String?
    @Option(name: .long) var sharedScanouts: Int = 1
    @Option(name: .long) var chromeFlags: String?
    @Option(name: .long, help: "Extra kernel options for this explicitly selected test image.") var kernelOptions: String?
    @Option(name: .long) var saveUpdatedImage: String?
    @Flag(name: .long) var requireGPUCheck = false
    @Flag(name: .long) var interactive = false
    @Flag(name: .long) var nativeChrome = false
    @Flag(name: .long) var sharedNativeWindows = false
    @Option(name: .long, help: "Initial native windows for a matched shared-VM benchmark.") var sharedNativeWindowCount: Int = 2
    @Flag(name: .long) var sharedInputCheck = false
    @Flag(name: .long) var sharedIMECheck = false
    @Flag(name: .long) var sharedLifecycleCheck = false
    @Flag(name: .long) var sharedQuitCheck = false
    @Flag(name: .long) var sharedMenuCheck = false
    @Flag(name: .long) var sharedMenuRootCloseCheck = false
    @Flag(name: .long) var historyCompletionCheck = false
    @Flag(name: .long) var resizeCheck = false
    @Option(name: .long) var resizeWidth: Int = 800
    @Option(name: .long) var resizeHeight: Int = 500
    @Flag(name: .long) var cursorCheck = false
    @Flag(name: .long) var menuCheck = false
    @Flag(name: .long) var inputCheck = false
    @Flag(name: .long) var frameTrace = false
    @Flag(name: .long) var stressCheck = false
    @Option(name: .long) var stressVcpus: Int?
    @Flag(name: .long) var withoutAudio = false
    @Flag(name: .long) var outputOnlyAudio = false
    @Flag(name: .long) var allowOlderTestImage = false
    @Flag(name: .long, help: "Check a profile opt-out against a Metal-prewarmed pool.") var profileMetalOffCheck = false
    @Flag(name: .long, help: "Verify postinstall imports the validated guest graphics marker in the selected test image.")
    var postinstallCheck = false
    @Flag(name: .long, help: "Benchmark Apple’s built-in Virtio graphics device without the custom VirGL renderer.")
    var appleVirtioGPU = false
    @Option(name: .long) var checkTimeout: Int = 30
    @Option(name: .long) var url: String = "chrome://gpu"

    func validate() throws {
        if sharedNativeWindows && !(1...sharedScanouts).contains(sharedNativeWindowCount) {
            throw ValidationError("Initial window count must fit the shared scanout capacity")
        }
        if sharedQuitCheck && !sharedNativeWindows {
            throw ValidationError("Shared quit check requires native shared windows")
        }
        if historyCompletionCheck && (!sharedNativeWindows || !nativeChrome || seconds < 60) {
            throw ValidationError("History completion check requires shared native chrome and 60 seconds")
        }
        if sharedMenuRootCloseCheck && (!sharedMenuCheck || seconds < 60) {
            throw ValidationError("Root-close menu check requires menu check and at least 60 seconds")
        }
        if sharedMenuCheck && (!sharedNativeWindows || sharedScanouts < 3 || seconds < 40) {
            throw ValidationError("Shared menu check requires at least three scanouts and 40 seconds")
        }
        if sharedInputCheck && (!sharedNativeWindows || !nativeChrome || sharedScanouts != 2 || seconds < 60) {
            throw ValidationError("Shared input check requires native Chrome, two shared native windows and at least 60 seconds")
        }
        if sharedIMECheck && !sharedInputCheck { throw ValidationError("IME check requires shared input check") }
        if sharedLifecycleCheck && (!sharedInputCheck || seconds < 90) { throw ValidationError("Lifecycle check requires shared input check and at least 90 seconds") }
        guard (1...16).contains(sharedScanouts) else { throw ValidationError("Scanouts must be 1 through 16") }
        guard (1...2).contains(displayScale) else { throw ValidationError("Invalid display scale") }
        guard (64...4096).contains(resizeWidth), (64...4096).contains(resizeHeight) else { throw ValidationError("Invalid resize dimensions") }
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
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["vm.displayScale"] = displayScale
        arguments["vm.traceGPUFrames"] = frameTrace
        if withoutAudio { arguments["vm.gpuTestOmitSoundDevice"] = true }
        if outputOnlyAudio { arguments["vm.gpuTestOutputOnlySoundDevice"] = true }
        if let chromeFlags { arguments["vm.extraChromeFlags"] = chromeFlags }
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
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
        if let profilePickerPreview {
            try ProfileEditorController.renderPickerPreview(to: profilePickerPreview)
            print("BROMURE_PROFILE_PICKER_PREVIEW_PASS")
            return
        }
        var config = VMConfig()
        if let stressVcpus { config.cpuCount = max(1, min(stressVcpus, 12)) }
        if withoutAudio { config.enableAudio = false }
        config.sharedWindowScanoutCount = sharedScanouts
        if sharedScanouts > 1 { config.extraKernelOptions += " bromure.shared_windows=16" }
        if let kernelOptions { config.extraKernelOptions += " " + kernelOptions }
        config.homePage = url
        config.enableGPU = true
        config.enableWebGL = true
        config.nativeChrome = nativeChrome
        if nativeChrome { config.nativeChromeInset = VMConfig.defaultNativeChromeInset(forDisplayScale: VMConfig.resolvedDisplayScale()) }
        var testProfile: Profile?
        var testProfileURL: URL?
        if let testProfileDir {
            let directory = URL(fileURLWithPath: testProfileDir, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let metadata = directory.appendingPathComponent("test-profile.json")
            if FileManager.default.fileExists(atPath: metadata.path) {
                testProfile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: metadata))
            } else {
                var settings = ProfileSettings()
                settings.persistent = true; settings.encryptOnDisk = false
                let profile = Profile(name: "Shared window acceptance", color: nil, settings: settings)
                try JSONEncoder().encode(profile).write(to: metadata, options: .atomic)
                testProfile = profile
            }
            let disk = directory.appendingPathComponent("profile.img")
            if !ProfileDisk.diskExists(at: disk), let profile = testProfile {
                _ = profile
                try EphemeralDisk.checkDiskSpace(at: directory.path)
                guard FileManager.default.createFile(atPath: disk.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw ValidationError("Cannot create private acceptance profile disk")
                }
                let file = try FileHandle(forWritingTo: disk)
                try file.truncate(atOffset: 1024 * 1024 * 1024)
                try file.close()
            }
            testProfileURL = directory
        }
        let pool = VMPool(config: config, storageDir: URL(fileURLWithPath: storageDir), requireImageVersion: !allowOlderTestImage, experimentalGPU: !appleVirtioGPU)
        try await pool.warmUp()
        if profileMetalOffCheck {
            let legacy = try JSONDecoder().decode(ProfileSettings.self, from: Data("{}".utf8))
            guard legacy.enableMetalRenderer && legacy.toVMConfig().enableMetalRenderer else {
                throw ValidationError("Legacy profile did not default to Metal")
            }
            var disabled = legacy
            disabled.enableMetalRenderer = false
            let restored = try JSONDecoder().decode(ProfileSettings.self, from: JSONEncoder().encode(disabled))
            guard !restored.toVMConfig().enableMetalRenderer else {
                throw ValidationError("Profile Metal opt-out did not persist")
            }
            config.enableMetalRenderer = false
        }
        let expectsLegacy = appleVirtioGPU || profileMetalOffCheck
        guard let warm = await pool.claim(config: config, profileID: testProfile?.id, profileImageDir: testProfileURL),
              expectsLegacy ? warm.graphicsSession == nil : warm.graphicsSession?.backendName == "virgl" else {
            await pool.shutdown()
            throw ValidationError("VM did not select the experimental GPU")
        }
        if profileMetalOffCheck { print("BROMURE_PROFILE_METAL_OFF_PASS") }
        warm.serialWaiter.observer = { text in print("[VM 1] " + text, terminator: "") }
        if interactive {
            let serial = warm.serialInput.fileHandleForWriting
            FileHandle.standardInput.readabilityHandler = { input in
                let data = input.availableData
                if data.isEmpty { input.readabilityHandler = nil }
                else { try? serial.write(contentsOf: data) }
            }
        }
        defer { if interactive { FileHandle.standardInput.readabilityHandler = nil } }
        var sharedChildren: [BrowserSession] = []
        let session = BrowserSession(warmVM: warm, config: config, profile: testProfile)
        if saveUpdatedImage != nil { warm.vm.delegate = nil }
        session.show()
        if sharedNativeWindows {
            try session.startSharedWindows { child in sharedChildren.append(child) }
            for _ in 1..<sharedNativeWindowCount { session.createSharedWindow() }
        }
        let sharedTask: Task<SharedWindowProof?, Error>? = sharedScanouts > 1 && !sharedNativeWindows ? Task { @MainActor in
            try await Task.sleep(for: .seconds(14))
            guard #available(macOS 27.0, *) else { throw ValidationError("Shared windows require macOS 27") }
            return try await SharedWindowProof.run(warm: warm)
        } : nil

        if frameTrace || stressCheck { print("[GPU browser] Test window id: \(session.window.windowNumber)") }
        var additional: [(VMPool, VMPool.WarmVM, BrowserSession)] = []
        for vmIndex in 1..<simultaneousVMs {
            let extraPool = VMPool(config: config, storageDir: URL(fileURLWithPath: storageDir), requireImageVersion: !allowOlderTestImage, experimentalGPU: !appleVirtioGPU)
            try await extraPool.warmUp()
            guard let extra = await extraPool.claim(config: config),
                  expectsLegacy ? extra.graphicsSession == nil : extra.graphicsSession?.backendName == "virgl" else {
                await extraPool.shutdown(); throw ValidationError("Additional VM did not select the GPU")
            }
            extra.serialWaiter.observer = { text in print("[VM \(vmIndex + 1)] " + text, terminator: "") }
            let extraSession = BrowserSession(warmVM: extra, config: config)
            extraSession.show()
            if frameTrace || stressCheck { print("[GPU browser] Test window id: \(extraSession.window.windowNumber)") }
            additional.append((extraPool, extra, extraSession))
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let presentationTask: Task<Void,Never>? = ProcessInfo.processInfo.environment["BROMURE_GPU_CAPTURE_TRACE"] == "1" ? Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(10)) } catch { return }
                let rows = ([session] + sharedChildren).map {
                    "window=\($0.window.windowNumber) completed=\($0.graphicsPresentedFrameCount)"
                }
                print("[GPU presentation] t=\(ProcessInfo.processInfo.systemUptime) " + rows.joined(separator:" "))
            }
        } : nil
        defer { presentationTask?.cancel() }
        let acceptanceTasks: [Task<Bool, Never>] = requireGPUCheck ? ([warm] + additional.map { $0.1 }).map { vm in
            Task { await vm.serialWaiter.probe(for: "BROMURE_GPU_ACCEPTANCE_PASS", timeout: TimeInterval(checkTimeout)) }
        } : []
        defer { acceptanceTasks.forEach { $0.cancel() } }
        let diagnosticTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard warm.vm.state == .running else { return }
            if let guestProbe, let script = try? Data(contentsOf: URL(fileURLWithPath: guestProbe)) {
                let encoded = script.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                let command = "stty -echo\nbase64 -d > /tmp/bromure-gpu-probe.py <<'BROMURE_GPU_PROBE_EOF'\n" + encoded + "\nBROMURE_GPU_PROBE_EOF\nstty echo\npython3 /tmp/bromure-gpu-probe.py\n"
                for (index, vm) in ([warm] + additional.map { $0.1 }).enumerated() {
                    let payload = Data(("export BROMURE_TEST_VM=\(index + 1)\n" + command).utf8)
                    // Large diagnostic clips must not flood the guest tty input
                    // buffer faster than its shell can consume the here-document.
                    for offset in stride(from: 0, to: payload.count, by: 4096) {
                        guard !Task.isCancelled, vm.vm.state == .running else { return }
                        vm.serialInput.fileHandleForWriting.write(payload.subdata(in: offset..<min(offset + 4096, payload.count)))
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    }
                }
            }
            if sharedNativeWindows { session.window.makeKeyAndOrderFront(nil) }
            let diagnostic = "echo BROMURE_GPU_DIAGNOSTIC; DISPLAY=:0 XAUTHORITY=/home/chrome/.Xauthority /usr/local/bin/graphics-diagnostics.py; python3 -c 'import runpy,json,urllib.request; m=runpy.run_path(\"/usr/local/bin/tab-agent.py\"); v=json.load(urllib.request.urlopen(\"http://127.0.0.1:9222/json/version\")); print(json.dumps(m[\"cdp_ws_call\"](v[\"webSocketDebuggerUrl\"],\"SystemInfo.getInfo\")))'; cat /tmp/startx.log | grep -E '(GL implementation|EGL|egl|ANGLE|Gpu|gpu_process|GL context)' | tail -30; echo BROMURE_GPU_DIAGNOSTIC_END\n"
            warm.serialInput.fileHandleForWriting.write(Data(diagnostic.utf8))
        }
        defer { diagnosticTask.cancel() }
        let historyTask: Task<Void, Error>? = historyCompletionCheck ? Task { @MainActor in
            try await Task.sleep(for: .seconds(25))
            guard let child = sharedChildren.first else { throw ValidationError("Missing history test child") }
            let childValue = try await child.checkNativeHistoryCompletion("127.0.0.1:8766/fi")
            let rootValue = try await session.checkNativeHistoryCompletion("127.0.0.1:8766/fi")
            print("BROMURE_NATIVE_HISTORY_COMPLETION_PASS child=\(childValue) root=\(rootValue)")
        } : nil
        defer { historyTask?.cancel() }
        let sharedMenuTask: Task<GUIAppDelegate, Error>? = sharedMenuCheck ? Task { @MainActor in
            try await Task.sleep(for: .seconds(25))
            let state = AppState(previewStorage: FileManager.default.temporaryDirectory.appendingPathComponent("bromure-shared-menu-" + UUID().uuidString))
            let delegate = GUIAppDelegate(state: state)
            delegate.sessions = [session] + sharedChildren
            delegate.setupMenu()
            NSApp.delegate = delegate
            guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == NSLocalizedString("File", comment: "") })?.submenu,
                  let item = file.items.first(where: { $0.title == NSLocalizedString("New Window", comment: "") }),
                  let action = item.action,
                  NSApp.sendAction(action, to: item.target ?? delegate, from: item) else {
                throw ValidationError("File New Window action failed")
            }
            print("BROMURE_SHARED_MENU_ACTION_SENT")
            if sharedMenuRootCloseCheck {
                try await Task.sleep(for: .seconds(15))
                session.closeConfirmedWindow()
                print("BROMURE_SHARED_OLDEST_WINDOW_CLOSED")
            }
            return delegate
        } : nil
        defer { sharedMenuTask?.cancel() }
        let sharedInputTask = sharedInputCheck ? Task { @MainActor in
            do {
                let started = ProcessInfo.processInfo.systemUptime
                guard await warm.serialWaiter.probe(for: "BROMURE_SHARED_LIFECYCLE_PASS {\"phase\": \"prepare\"", timeout: 25) else {
                    throw ValidationError("Guest fixture preparation failed; native input and lifecycle actions canceled")
                }
                let remaining = max(0, 25 - (ProcessInfo.processInfo.systemUptime - started))
                try await Task.sleep(for: .seconds(remaining))
                let sessions = [session] + sharedChildren
                guard sessions.count == 2 else { throw ValidationError("Expected two native windows for input check") }
                for (index, selected) in sessions.enumerated() {
                    selected.window.makeKeyAndOrderFront(nil)
                    guard let content = selected.window.contentView else { throw ValidationError("Missing native window content") }
                    content.layoutSubtreeIfNeeded()
                    let centerTarget = content.hitTest(NSPoint(x: content.bounds.midX, y: content.bounds.midY)) ?? content
                    let visible = centerTarget.visibleRect
                    let local = NSPoint(x: visible.minX + 100,
                        y: centerTarget.isFlipped ? visible.minY + 45 : visible.maxY - 45)
                    let location = centerTarget.convert(local, to: nil)
                    for kind in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                        guard let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: selected.window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) else { continue }
                        NSApplication.shared.sendEvent(event)
                    }
                    try await Task.sleep(for: .seconds(2))
                    for kind in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: kind, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: selected.window.windowNumber,
                            context: nil, characters: index == 0 ? "a" : "b", charactersIgnoringModifiers: index == 0 ? "a" : "b",
                            isARepeat: false, keyCode: index == 0 ? 0 : 11) { NSApplication.shared.sendEvent(event) }
                    }
                    if sharedIMECheck {
                        func client(in view: NSView) -> (any NSTextInputClient)? {
                            if String(describing: type(of: view)) == "CJKInputView" {
                                return view as? any NSTextInputClient
                            }
                            for child in view.subviews { if let found = client(in: child) { return found } }
                            return nil
                        }
                        guard let composition = client(in: content) else { throw ValidationError("Missing native composition client") }
                        composition.insertText(index == 0 ? "日本" : "中文", replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -240, wheel2: 0, wheel3: 0) {
                        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                        let screen = selected.window.convertPoint(toScreen: location)
                        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
                        event.location = CGPoint(x: screen.x, y: mainHeight - screen.y)
                        if let scroll = NSEvent(cgEvent: event) { centerTarget.scrollWheel(with: scroll) }
                    }
                    print("BROMURE_SHARED_HOST_INPUT_SENT window=\(index) target=\(type(of: centerTarget))")
                    try await Task.sleep(for: .seconds(2))
                }
                if sharedLifecycleCheck {
                    try await Task.sleep(for: .seconds(10))
                    let child = sessions[1]
                    child.window.makeKeyAndOrderFront(nil)
                    child.performNativeChromeShortcut("t")
                    print("BROMURE_SHARED_HOST_NEW_TAB_SENT")
                    try await Task.sleep(for: .seconds(10))
                    session.window.close()
                    print("BROMURE_SHARED_HOST_PRIMARY_CLOSE_SENT")
                    try await Task.sleep(for: .seconds(15))
                    child.window.close()
                    print("BROMURE_SHARED_HOST_LAST_CLOSE_SENT")
                }
            } catch { print("BROMURE_SHARED_HOST_INPUT_FAILED \(error)") }
        } : nil
        defer { sharedInputTask?.cancel() }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var resizeAt = Date().addingTimeInterval(28)
        var resized = false
        var resizeStep = 0
        let resizeStart = session.window.contentView?.bounds.size ?? NSSize(width: 960, height: 540)
        let clickAt = Date().addingTimeInterval(20)
        var clicked = false
        var clickedAfterResize = false
        var clickedDuringResize = false
        var lastBudgetLog = Date()
        while Date() < deadline, warm.vm.state != .stopped {
            if Date().timeIntervalSince(lastBudgetLog) >= 10 {
                for vm in [warm] + additional.map({ $0.1 }) { vm.graphicsSession?.logResourceUsage() }; lastBudgetLog = Date()
            }
            if inputCheck, resized, !clickedAfterResize, Date() >= resizeAt.addingTimeInterval(7) {
                clicked = false; clickedAfterResize = true
            }
            if inputCheck, !clicked, Date() >= clickAt, let content = session.window.contentView {
                clicked = true
                NSApplication.shared.activate(ignoringOtherApps: true)
                session.window.makeKeyAndOrderFront(nil)
                let point = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil)
                let target = content.hitTest(content.convert(point, from: nil))
                print("[GPU browser] Host click target: \(String(describing: target.map { type(of: $0) }))")
                for clickSession in stressCheck ? [session] + additional.map({ $0.2 }) : [session] {
                    guard let clickContent = clickSession.window.contentView else { continue }
                    clickSession.window.makeKeyAndOrderFront(nil)
                    clickContent.layoutSubtreeIfNeeded()
                    let center = NSPoint(x:clickContent.bounds.midX,y:clickContent.bounds.midY)
                    let target = clickContent.hitTest(center) ?? clickContent
                    let visible = target.visibleRect
                    let offCenter = stressCheck && clickedDuringResize
                    let point = target.convert(NSPoint(x:visible.minX + visible.width * (offCenter ? 0.25 : 0.5),
                                                       y:visible.minY + visible.height * (offCenter ? 0.65 : 0.5)), to:nil)
                    for kind in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: clickSession.window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) {
                            NSApplication.shared.sendEvent(event)
                        }
                    }
                }
            }
            if stressCheck, resized, Date() >= resizeAt.addingTimeInterval(12) {
                resized = false; resizeStep = 0; resizeAt = Date()
                // Repeated trusted geometry changes while independent guests browse.
            }
            if resizeCheck, !resized, Date() >= resizeAt.addingTimeInterval(Double(resizeStep) / 20) {
                resizeStep += 1
                if stressCheck, inputCheck, resizeStep == 8, !clickedDuringResize {
                    clickedDuringResize = true
                    clicked = false
                }
                let fraction = Double(resizeStep) / 16
                let width = resizeStart.width + (Double(resizeWidth) - resizeStart.width) * fraction
                let height = resizeStart.height + (Double(resizeHeight) - resizeStart.height) * fraction
                for resizeSession in stressCheck ? [session] + additional.map({ $0.2 }) : [session] {
                    let wave = stressCheck ? sin(Date().timeIntervalSince1970 / 2) * 100 : 0
                    resizeSession.window.setContentSize(NSSize(width: max(640, width + wave), height: max(400, height + wave / 2)))
                }
                resized = resizeStep == 16
                print("[GPU browser] Resize step \(resizeStep): \(Int(width))x\(Int(height)) points frames=\(warm.graphicsSession?.deliveredFrameCount ?? 0)")
            }
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                             inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            NSApplication.shared.updateWindows()
            try await Task.sleep(for: .milliseconds(2))
        }
        do {
            try await historyTask?.value
            let sharedMenuDelegate = try await sharedMenuTask?.value
            withExtendedLifetime(sharedMenuDelegate) {}
        } catch {
            let surviving = ([session] + sharedChildren).first { $0.hasSharedWindowOwner }
            await surviving?.shutdownSharedWindows()
            try? await session.waitForClosingVMResources()
            if !session.hasReleasedVMResources && !session.isCleaningUpVMResources { await pool.retire(warm) }
            await pool.shutdown()
            throw error
        }
        if sharedQuitCheck {
            let surviving = ([session] + sharedChildren).first { $0.hasSharedWindowOwner }
            await surviving?.shutdownSharedWindows()
        }
        try await session.waitForClosingVMResources()
        let sharedProof = try await sharedTask?.value
        defer { sharedProof?.close() }
        let menuOK: Bool
        if menuCheck {
            let delegate = GUIAppDelegate(state: AppState(previewStorage: FileManager.default.temporaryDirectory.appendingPathComponent("bromure-menu-check-" + UUID().uuidString)))
            delegate.sessions = [session] + additional.map { $0.2 }
            delegate.setupMenu()
            let item = NSApp.mainMenu?.items.last
            let toggle = item?.submenu?.items.first(where: { $0.title == "Use Metal Renderer" })
            menuOK = item?.title == (expectsLegacy ? "Software" : "Metal") && toggle?.isEnabled == MetalRendererPreference.isSupported
            print("[GPU browser] Menu renderer: \(item?.title ?? "missing"), Metal option enabled: \(toggle?.isEnabled ?? false)")
        } else { menuOK = true }
        let frames = warm.graphicsSession?.deliveredFrameCount ?? 0
        var accepted = true
        for task in acceptanceTasks { let passed = await task.value; accepted = accepted && passed }
        try sharedProof?.verifySecondOutputColor()
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
            additionalOK = additionalOK && (expectsLegacy || extraFrames > 0)
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
            if !session.hasReleasedVMResources && !session.isCleaningUpVMResources { await pool.retire(warm) }
            await pool.shutdown()
            throw error
        }
        if !session.hasReleasedVMResources && !session.isCleaningUpVMResources { await pool.retire(warm) }
        await pool.shutdown()
        withExtendedLifetime(session) {}
        guard expectsLegacy || frames > 0, accepted, additionalOK, cursorOK, menuOK else { throw ValidationError("Browser GPU acceptance failed") }
    }
}
