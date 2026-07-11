import AppKit
import BrowserBridges
import Foundation
import SandboxEngine
@preconcurrency import Virtualization

// Owns the ephemeral sidecar browser VM for one workspace (agentic web
// browser, phase 2). Boots/claims an Alpine+Chromium VM via SandboxEngine's
// VMPool + EphemeralDisk (CoW), mounts its framebuffer into the pane, and
// tears it all down on close. One instance per workspace (keyed by
// Profile.id), always ephemeral. See BROWSER_PANE_PLAN.md.
//
// Native-chrome mode (phase 3a): Chromium's own tab strip/omnibox are cropped
// out of the framebuffer and the host BrowserPane chrome is the browser's
// chrome. Navigation currently uses the serial launch path; CDP-driven tab
// control, the full key monitor, MCP, and the devtools button land in phases
// 3c-e.
//
// Runtime-untested: nested virtualization isn't available in the dev sandbox,
// so this is build-verified only; it runs for real on a Mac host.

@MainActor
final class WorkspaceBrowserController {
    enum State: Equatable {
        case idle
        case booting
        case running
        /// VM paused in memory (collapsed >10s) — resumes on demand.
        case suspended
        /// Provisioning/boot failed; the pane shows `message`.
        case failed(String)
    }

    /// Collapsed (not visible) this long → suspend the VM in memory.
    private static let suspendAfter: TimeInterval = 10
    /// Collapsed this long → tear the VM down entirely.
    private static let shutdownAfter: TimeInterval = 300

    private(set) var state: State = .idle
    /// True while `installImageThenStart` awaits the shared image
    /// installer — cleared by `stop()` so a teardown mid-download can't
    /// boot a VM for a closed pane when the install completes.
    private var installWait = false

    private let model: BrowserPaneModel
    private var pool: VMPool?
    private var warm: VMPool.WarmVM?
    private var vmView: VZVirtualMachineView?
    /// Native-tabs bridge (vsock 5810) — the shared machinery that streams the
    /// guest's tab list/favicons and drives navigate/activate/close/back/…
    private var tabBridge: TabBridge?
    /// CDP driver (vsock 5200) for screenshot/eval/page-text — what TabBridge
    /// can't do. Exposed for the browser MCP server + devtools.
    private(set) var cdp: BrowserCDP?
    /// Network trace (vsock 5900) — the guest trace extension's request log,
    /// backing browser_network. Nil until the VM attaches.
    private var trace: TraceBridge?
    /// Default landing page for a fresh ephemeral browser — blank, so an
    /// agent-driven navigate reuses the tab with no homepage flash, and a
    /// manual open starts clean.
    private let homePage = "about:blank"

    /// The workspace this browser belongs to — keys its persistent profile disk.
    private let workspaceID: UUID
    /// When true, Chromium's user-data-dir lives on an encrypted per-workspace
    /// disk so logins/cookies survive teardown (set from Profile.browserPersistent).
    let persistent: Bool

    init(model: BrowserPaneModel, workspaceID: UUID, persistent: Bool) {
        self.model = model
        self.workspaceID = workspaceID
        self.persistent = persistent
    }

    /// Per-workspace persistent browser profile dir (shared into the guest as
    /// Chromium's user-data-dir when `persistent`):
    /// `~/Library/Application Support/BromureAC/browser-profiles/<id>/image/`.
    static func browserProfileImageDir(for id: UUID) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("browser-profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("image", isDirectory: true)
    }

    // MARK: - Image resolution (shared / AC-owned)

    /// The three files the browser VM boots from, all in one storage dir
    /// (LinuxImageManager derives them from `storageDir`).
    private static let bootFiles = ["linux-base.img", "vmlinuz", "initrd"]

    /// AC-owned browser storage dir: `~/Library/Application Support/BromureAC/browser`.
    /// Used when AC downloads its own image (phase 2b). Ephemeral CoW clones
    /// live in the temp dir regardless, so we never write into the shared dir.
    static var browserStorageDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
    }

    // Internal (not private): BrowserImageInstaller reports image
    // presence with the same check.
    static func hasAllBootFiles(in dir: URL) -> Bool {
        let fm = FileManager.default
        return bootFiles.allSatisfy {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Pick the storage dir that has a complete boot set: Bromure Web's shared
    /// dir if present, else AC's own (downloaded) dir. nil when neither is
    /// complete. The pool only READS these; clones go to temp, so sharing the
    /// Web dir never writes into it.
    private func resolveStorageDir() -> URL? {
        let shared = VMConfig.defaultStorageDirectory   // ~/…/Bromure
        if Self.hasAllBootFiles(in: shared) {
            print("[browser] using shared Bromure image dir: \(shared.path)")
            return shared
        }
        let acDir = Self.browserStorageDir
        if Self.hasAllBootFiles(in: acDir) {
            print("[browser] using AC-owned browser image dir: \(acDir.path)")
            return acDir
        }
        let fm = FileManager.default
        let missing = Self.bootFiles.filter {
            !fm.fileExists(atPath: shared.appendingPathComponent($0).path)
        }
        print("[browser] no complete image — shared dir \(shared.path) missing: \(missing.joined(separator: ", "))")
        return nil
    }

    // MARK: - Lifecycle

    /// Boot the ephemeral browser and mount its framebuffer. Idempotent while
    /// already booting/running.
    func start() {
        guard state == .idle else {
            print("[browser] start ignored (state=\(state))")
            return
        }
        guard let storageDir = resolveStorageDir() else {
            // Phase 2b: no image anywhere — download it (prebuilt from
            // dl.bromure.io/browser-images/, postinstall + personalisation
            // applied), then boot. The pane placeholder renders the shared
            // installer's live progress meanwhile.
            installImageThenStart()
            return
        }
        state = .booting
        model.hasFramebuffer = false
        model.showRetry = false
        model.imageInstall = nil
        model.placeholderStatus = NSLocalizedString("Booting browser…", comment: "")

        let config = browserConfig()
        // isolatePeers: false → the browser VM shares the workspace VMs' subnet
        // (VMNetSwitch.shared, peer bridging on) so the agent and the browser
        // can reach each other. requireImageVersion: false → boot Bromure Web's
        // shared image whatever its version stamp (AC doesn't rebuild it).
        let pool = VMPool(config: config, storageDir: storageDir,
                          isolatePeers: false, requireImageVersion: false)
        self.pool = pool

        // Persistent profiles: an encrypted per-workspace disk holds Chromium's
        // user-data-dir so logins/cookies survive teardown. Failure to set it up
        // degrades gracefully to ephemeral rather than blocking the browser.
        var profileImageDir: URL?
        var profileDiskKey: String?
        if persistent {
            let imageDir = Self.browserProfileImageDir(for: workspaceID)
            let diskURL = imageDir.appendingPathComponent("profile.img")
            do {
                try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
                if !ProfileDisk.diskExists(at: diskURL) {
                    try ProfileDisk.createDisk(profileID: workspaceID, at: diskURL)
                    print("[browser] created persistent profile disk at \(diskURL.path)")
                }
                profileImageDir = imageDir
                profileDiskKey = try ProfileDisk.keyForProfile(id: workspaceID)
            } catch {
                print("[browser] persistent disk setup failed — ephemeral fallback: \(error)")
            }
        }
        let claimProfileID: UUID? = profileImageDir != nil ? workspaceID : nil
        print("[browser] booting \(profileImageDir != nil ? "persistent" : "ephemeral") "
            + "browser VM (storageDir=\(storageDir.path))")

        Task { [weak self] in
            // Boot explicitly first so the real error surfaces — claim()
            // swallows warmUp() failures (`try?`) and only logs the generic
            // "no warm VM available".
            do {
                try await pool.warmUp()
            } catch {
                print("[browser] warmUp failed: \(error)")
                self?.fail(String(
                    format: NSLocalizedString("The browser VM did not start: %@", comment: ""),
                    "\(error)"))
                return
            }
            // Persistent → the per-workspace encrypted disk is shared in as
            // Chromium's user-data-dir; ephemeral → no share, nothing survives.
            let warm = await pool.claim(config: config, profileID: claimProfileID,
                                        profileImageDir: profileImageDir,
                                        profileDiskKey: profileDiskKey)
            guard let self else {
                if let warm { await Self.tearDown(warm) }
                return
            }
            guard let warm else {
                print("[browser] claim returned nil after warmUp — see [VMPool] logs")
                self.fail(NSLocalizedString("The browser VM did not start (claim failed).", comment: ""))
                return
            }
            print("[browser] claim ok (vm state=\(warm.vm.state.rawValue)) — attaching view")
            self.attach(warm)
        }
    }

    /// The ephemeral browser config. nativeChrome on: Chromium's own tab
    /// strip/omnibox are cropped out of the framebuffer and our host chrome
    /// (BrowserPane) is the browser's chrome. Clipboard + file transfer +
    /// automation on so ⌘C/⌘V bridge to the host (SPICE vdagent) and CDP
    /// (needed by native-chrome tab state, and phases 3c-e) are available.
    private func browserConfig() -> VMConfig {
        let scale = VMConfig.resolvedDisplayScale()
        return VMConfig(
            homePage: homePage,
            enableFileTransfer: true,
            enableClipboardSharing: true,
            directConnection: true,   // no proxy — Chromium connects straight out
            enableAutomation: true,
            nativeChrome: true,
            nativeChromeInset: VMConfig.defaultNativeChromeInset(forDisplayScale: scale),
            // Level 2 (headers) loads the trace extension so the agent can read
            // the network log (browser_network). It uses only chrome.webRequest,
            // so — unlike level 3 — it never attaches chrome.debugger and can't
            // fight our own CDP connection over port 9222.
            traceLevel: .headers
        )
    }

    private func attach(_ warm: VMPool.WarmVM) {
        self.warm = warm
        let view = VZVirtualMachineView()
        view.virtualMachine = warm.vm
        view.automaticallyReconfiguresDisplay = true
        // Keep capturing ⌘-keys so ⌘C/⌘V (and other in-page chords) reach
        // Chromium — paired with the SPICE clipboard bridge this makes
        // host↔guest copy/paste work. Tradeoff vs. Web's native-chrome key
        // monitor: ⌘Q/⌘Tab are also captured while this view has focus (click
        // the terminal/sidebar to regain them). The full monitor + CDP-driven
        // tab shortcuts land with phase 3c.
        view.capturesSystemKeys = true
        self.vmView = view
        // Native chrome: crop Chromium's own chrome out of the top of the
        // framebuffer; the host BrowserPane chrome is the only chrome. The
        // device inset must match the one baked into the config's scanout.
        let deviceInset = VMConfig.defaultNativeChromeInset(
            forDisplayScale: VMConfig.resolvedDisplayScale())
        let cropper = NativeChromeCropper()
        cropper.clip(view, deviceInset: deviceInset)
        model.framebufferContainer.mount(cropper)
        model.hasFramebuffer = true
        model.placeholderStatus = ""
        state = .running

        // Native-tabs bridge: the guest's tab-agent (started by native-chrome
        // mode) connects on vsock 5810 and streams the tab list; our host
        // chrome drives it. Chromium already opens on the config home page.
        if let socketDevice = warm.vm.socketDevices.first as? VZVirtioSocketDevice {
            wireTabBridge(TabBridge(socketDevice: socketDevice))
            // CDP driver shares the same vsock device (different port, 5200).
            cdp = BrowserCDP(socketDevice: socketDevice)
            // Network trace: the guest trace-agent (native-messaging → vsock
            // 5900) streams the request log into an in-memory SQLite store the
            // browser_network MCP tool queries. Ephemeral, like the VM.
            trace = TraceBridge(socketDevice: socketDevice, inMemory: true)
        } else {
            print("[browser] no vsock device — tabs/navigation disabled")
        }
        print("[browser] view attached; network \(warm.networkReady ? "ready" : "pending")")
    }

    private func wireTabBridge(_ bridge: TabBridge) {
        tabBridge = bridge
        let bar = model.tabBar
        bridge.onTabsChanged = { tabs in bar.setTabs(tabs) }
        bridge.onShortcut = { key in
            switch key {
            case "t": bar.onNewTab?()
            case "w": if let id = bar.activeTab?.id { bar.onClose?(id) }
            case "r": if let id = bar.activeTab?.id { bar.onReload?(id) }
            case "l": bar.pendingFocusOnActiveChange = true   // ⌘L → focus the address bar
            default: break
            }
        }
        // Host chrome (NativeTabBarModel) → guest, via the bridge. onNavigate
        // gets the raw address-bar text; normalize it to a URL/search.
        bar.onNavigate = { [weak bar] raw in
            let url = BrowserPaneModel.normalize(raw)
            if let id = bar?.activeTab?.id {
                bar?.beginNavigating(id)
                bridge.navigate(id: id, url: url)
            } else {
                bridge.newTab(url: url)
            }
        }
        bar.onBack = { id in bridge.back(id: id) }
        bar.onForward = { id in bridge.forward(id: id) }
        bar.onReload = { id in bridge.reload(id: id) }
        bar.onNewTab = {
            bridge.newTab(url: "")
            bar.pendingFocusOnActiveChange = true   // land the cursor in the new tab's URL bar
        }
        bar.onActivate = { [weak bar] id in
            bar?.markActiveLocally(id)   // optimistic; the guest echo confirms
            bridge.activate(id: id)
        }
        bar.onClose = { [weak self] id in self?.closeTab(id) }
        bar.onDevTools = { [weak self] in self?.toggleDevTools() }
        bar.onPickElement = { [weak self] in self?.userPickElement() }
        // Site-info popover's on-demand certificate fetch.
        bar.fetchCertificate = { origin in await bridge.fetchCertificate(origin: origin) }
    }

    // MARK: - Browser tools (MCP surface)
    //
    // navigate/tabs/history go through TabBridge; screenshot/eval/text through
    // BrowserCDP. `isReady` gates calls before the guest agents connect.

    var isReady: Bool { state == .running && tabBridge != nil && vmAlive }

    private var vmAlive: Bool {
        guard let s = warm?.vm.state else { return false }
        return s == .running || s == .paused
    }

    /// Ensure the browser is up: boot if idle, resume if suspended, reboot if
    /// the previous VM died (e.g. the user closed the last tab and the guest
    /// powered off). Counts as activity, so it cancels the idle timers.
    func ensureRunning() {
        cancelIdleTimers()
        if state != .idle, state != .suspended, !vmAlive { stop() }   // dead VM → reboot
        switch state {
        case .idle: start()
        case .suspended: resume()
        default: break
        }
    }

    func tabs() -> [TabInfo] { model.tabBar.tabs }

    func navigate(_ raw: String) {
        let url = BrowserPaneModel.normalize(raw)
        // Reuse the current tab. On a fresh cold boot Chromium has already
        // opened the home-page tab but tab-agent may not have reported it yet;
        // wait briefly so we navigate THAT tab instead of opening a duplicate.
        Task { @MainActor [weak self] in
            for _ in 0..<80 {   // ~8s
                guard let self, self.tabBridge != nil else { return }
                if let id = self.model.tabBar.activeTab?.id {
                    self.model.tabBar.beginNavigating(id)
                    self.tabBridge?.navigate(id: id, url: url)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.tabBridge?.newTab(url: url)   // no tab appeared — open one
        }
    }

    /// Toggle Chromium DevTools by synthesizing F12 straight to the VM view —
    /// host-side, so it doesn't depend on the guest tab-agent's chord
    /// allowlist (which is baked into the image and may not include F12).
    private func toggleDevTools() {
        guard let view = vmView, let window = view.window else { return }
        _ = window.makeFirstResponder(view)
        let ch = String(UnicodeScalar(0xF70F)!)   // NSF12FunctionKey
        let keyCode: UInt16 = 0x6F                 // kVK_F12
        let ts = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ts, windowNumber: window.windowNumber, context: nil,
            characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: keyCode) {
            view.keyDown(with: down)
        }
        if let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
            timestamp: ts, windowNumber: window.windowNumber, context: nil,
            characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: keyCode) {
            view.keyUp(with: up)
        }
    }

    func newTab(_ raw: String) { tabBridge?.newTab(url: raw.isEmpty ? "" : BrowserPaneModel.normalize(raw)) }
    func activateTab(_ id: String) { model.tabBar.markActiveLocally(id); tabBridge?.activate(id: id) }
    /// Close a tab. Closing the LAST tab would quit Chromium and power off the
    /// browser VM, so open a fresh tab first to keep the browser alive.
    func closeTab(_ id: String) {
        if model.tabBar.tabs.count <= 1 { tabBridge?.newTab(url: "") }
        tabBridge?.close(id: id)
    }
    func back() { if let id = model.tabBar.activeTab?.id { tabBridge?.back(id: id) } }
    func forward() { if let id = model.tabBar.activeTab?.id { tabBridge?.forward(id: id) } }
    func reload() { if let id = model.tabBar.activeTab?.id { tabBridge?.reload(id: id) } }

    func screenshot(fullPage: Bool) async throws -> Data {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        return try await cdp.screenshot(fullPage: fullPage)
    }
    func evaluate(_ js: String) async throws -> Any? {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        return try await cdp.evaluate(js)
    }
    func pageText() async throws -> String {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        return try await cdp.pageText()
    }
    func click(selector: String) async throws -> Bool {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        return try await cdp.click(selector: selector)
    }
    func fill(selector: String, value: String) async throws -> Bool {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        return try await cdp.fill(selector: selector, value: value)
    }
    func type(selector: String, text: String, clear: Bool, submit: Bool) async throws {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        try await cdp.type(selector: selector, text: text, clear: clear, submit: submit)
    }
    func pressKey(_ key: String) async throws {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        try await cdp.pressKey(key)
    }
    func html(selector: String) async throws -> String {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        return try await cdp.html(selector: selector)
    }
    func links(selector: String) async throws -> String {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        return try await cdp.links(selector: selector)
    }
    func waitFor(selector: String, timeoutMs: Int) async throws {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        try await cdp.waitFor(selector: selector, timeoutMs: timeoutMs)
    }

    // MARK: - Network trace (browser_network)

    /// Recorded network requests matching `filter`, oldest first.
    func networkEvents(filter: TraceFilter) -> [TraceEvent] {
        trace?.store.queryEvents(filter: filter) ?? []
    }
    /// Distinct hostnames seen, for the network summary.
    func networkHostnames() -> [String] { trace?.distinctHostnames() ?? [] }
    /// Drop the recorded requests (fresh baseline before an action).
    func clearNetwork() { trace?.clearTrace() }

    // MARK: - Console (browser_console)

    /// Register the console-capture hook (idempotent). Called before the first
    /// navigate so page-load errors land in the buffer.
    func ensureConsoleHook() async { await cdp?.ensureConsoleHook() }
    func consoleLogs(clear: Bool) async throws -> [[String: Any]] {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        return try await cdp.consoleLogs(clear: clear)
    }

    // MARK: - Element picker

    /// The most recently picked element's CSS selector (button or MCP driven).
    private(set) var lastPickedSelector: String?

    /// Arm the picker and return the element the user clicks (or nil). Records
    /// the selector for `lastPickedSelector`. Shared by the button + MCP tool.
    func pickElement() async throws -> [String: Any]? {
        guard let cdp else { throw BrowserCDP.CDPError.notReady }
        model.tabBar.picking = true
        defer { model.tabBar.picking = false }
        let picked = try await cdp.pickElement()
        if let sel = picked?["selector"] as? String, !sel.isEmpty { lastPickedSelector = sel }
        return picked
    }

    /// Button/⇧⌘S handler: pick an element, then put its selector on the
    /// pasteboard (which the clipboard bridge mirrors into the guest, so it's
    /// paste-ready for the in-VM agent) and flash a confirmation.
    func userPickElement() {
        guard isReady else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let picked = try? await self.pickElement(),
                  let sel = picked["selector"] as? String, !sel.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(sel, forType: .string)
            await self.cdp?.showToast(String(
                format: NSLocalizedString("Copied selector: %@", comment: "element picker toast"), sel))
        }
    }

    // MARK: - Collapse lifecycle (suspend / shutdown / resume)

    private(set) var isVisible = false
    private var suspendWork: DispatchWorkItem?
    private var shutdownWork: DispatchWorkItem?

    /// Called by the window when this workspace's browser becomes shown/hidden
    /// (pane opened/closed, or the workspace selected/deselected). Visible →
    /// resume/boot and cancel timers; hidden → arm the suspend + shutdown
    /// timers. An MCP tool call resolves through `ensureRunning`, which also
    /// resumes, so agent activity keeps a collapsed-but-in-use browser alive.
    func setVisible(_ v: Bool) {
        isVisible = v
        if v {
            cancelIdleTimers()
            switch state {
            case .suspended: resume()
            case .idle: start()
            default: break
            }
        } else {
            armIdleTimers()
        }
    }

    private func armIdleTimers() {
        cancelIdleTimers()
        guard state == .running || state == .suspended else { return }
        let s = DispatchWorkItem { [weak self] in
            guard let self, !self.isVisible else { return }
            self.suspend()
        }
        let d = DispatchWorkItem { [weak self] in
            guard let self, !self.isVisible else { return }
            print("[browser] collapsed \(Int(Self.shutdownAfter))s — shutting down")
            self.stop()
        }
        suspendWork = s
        shutdownWork = d
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.suspendAfter, execute: s)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownAfter, execute: d)
    }

    private func cancelIdleTimers() {
        suspendWork?.cancel(); suspendWork = nil
        shutdownWork?.cancel(); shutdownWork = nil
    }

    /// Pause the VM in memory (not to disk). Keeps the ephemeral disk +
    /// bridges; resume brings it back instantly.
    private func suspend() {
        guard state == .running, let warm, warm.vm.state == .running else { return }
        state = .suspended
        model.placeholderStatus = ""
        print("[browser] collapsed \(Int(Self.suspendAfter))s — suspending VM")
        let vm = warm.vm
        Task { @MainActor in
            do { try await vm.pause() }
            catch { print("[browser] suspend failed: \(error)") }
        }
    }

    /// Resume a suspended VM.
    private func resume() {
        guard state == .suspended, let warm else { return }
        state = .running
        print("[browser] resuming suspended VM")
        let vm = warm.vm
        Task { @MainActor [weak self] in
            do { try await vm.resume() }
            catch { print("[browser] resume failed: \(error)"); self?.stop() }
        }
    }

    /// Tear the browser VM down and clear the pane. Idempotent. (An
    /// in-flight image download is NOT cancelled — it's shared app-wide
    /// state; only this pane's wait on it ends.)
    func stop() {
        cancelIdleTimers()
        installWait = false
        model.hasFramebuffer = false
        model.placeholderStatus = ""
        model.imageInstall = nil
        model.showRetry = false
        model.tabBar.setTabs([])
        model.framebufferContainer.unmountAll()
        tabBridge?.stop()
        tabBridge = nil
        cdp?.stop()
        cdp = nil
        trace?.stop()
        trace = nil
        vmView?.virtualMachine = nil
        vmView = nil
        if let warm {
            self.warm = nil
            Task { await Self.tearDown(warm) }
        }
        pool = nil
        state = .idle
    }

    /// Download the browser image via the shared installer, then boot.
    /// Every trigger funnels here (pane click, MCP ensureRunning, other
    /// workspaces) and joins the same in-flight install; the Settings →
    /// Browser button shows the same progress through the same installer.
    private func installImageThenStart() {
        state = .booting
        installWait = true
        model.hasFramebuffer = false
        model.showRetry = false
        model.placeholderStatus = ""
        model.imageInstall = BrowserImageInstaller.shared
        print("[browser] no image — downloading via BrowserImageInstaller")
        Task { [weak self] in
            let ok = await BrowserImageInstaller.shared.ensureInstalled()
            guard let self, self.installWait else { return }   // torn down meanwhile
            self.installWait = false
            self.model.imageInstall = nil
            self.state = .idle
            if ok {
                self.start()
            } else {
                self.fail(BrowserImageInstaller.shared.lastError
                    ?? NSLocalizedString("The browser image could not be downloaded.",
                                         comment: "browser image download failed"))
            }
        }
    }

    /// Re-attempt after a failure (the pane placeholder's Retry button).
    func retry() {
        guard case .failed = state else { return }
        state = .idle
        start()
    }

    private func fail(_ message: String) {
        state = .failed(message)
        model.hasFramebuffer = false
        model.imageInstall = nil
        model.placeholderStatus = message
        model.showRetry = true
        model.onRetry = { [weak self] in self?.retry() }
    }

    // MARK: - Helpers

    /// Mirror of VMPool.tearDown (private there): stop the VM, close pipes,
    /// destroy the ephemeral disk, release the MAC and network filter.
    nonisolated private static func tearDown(_ warm: VMPool.WarmVM) async {
        if let mac = warm.macAddress { MACAddressPool.shared.release(mac) }
        warm.networkFilter?.stop()
        if warm.vm.state == .running || warm.vm.state == .paused {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { warm.vm.stop { _ in cont.resume() } }
            }
        }
        warm.serialOutput.fileHandleForReading.readabilityHandler = nil
        try? warm.serialOutput.fileHandleForReading.close()
        try? warm.serialOutput.fileHandleForWriting.close()
        try? warm.serialInput.fileHandleForReading.close()
        try? warm.serialInput.fileHandleForWriting.close()
        try? warm.ephemeralDisk.destroy()
    }
}
