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
        /// Provisioning/boot failed; the pane shows `message`.
        case failed(String)
    }

    private(set) var state: State = .idle

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
    /// Default landing page for a fresh ephemeral browser.
    private let homePage = "https://bromure.io/hello"

    init(model: BrowserPaneModel) {
        self.model = model
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

    private static func hasAllBootFiles(in dir: URL) -> Bool {
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
            fail(NSLocalizedString(
                "No browser image found. Install Bromure Web, or a prebuilt image (coming soon).",
                comment: "browser image missing"))
            return
        }
        state = .booting
        model.hasFramebuffer = false
        model.placeholderStatus = NSLocalizedString("Booting browser…", comment: "")

        let config = browserConfig()
        // isolatePeers: false → the browser VM shares the workspace VMs' subnet
        // (VMNetSwitch.shared, peer bridging on) so the agent and the browser
        // can reach each other. requireImageVersion: false → boot Bromure Web's
        // shared image whatever its version stamp (AC doesn't rebuild it).
        let pool = VMPool(config: config, storageDir: storageDir,
                          isolatePeers: false, requireImageVersion: false)
        self.pool = pool
        print("[browser] booting ephemeral browser VM (storageDir=\(storageDir.path))")

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
            // Ephemeral: no profileID / profileImageDir → the guest's virtio-fs
            // share is disconnected and nothing persists past teardown.
            let warm = await pool.claim(config: config)
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
            nativeChromeInset: VMConfig.defaultNativeChromeInset(forDisplayScale: scale)
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
        bar.onDevTools = { bridge.sendChord("F12") }
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

    /// Ensure the browser is up, rebooting if the previous VM died (e.g. the
    /// user closed the last tab and the guest powered off). Opens the pane.
    func ensureRunning() {
        if state != .idle, !vmAlive { stop() }   // dead VM → reset so start() reboots
        if state == .idle { start() }
    }

    func tabs() -> [TabInfo] { model.tabBar.tabs }

    func navigate(_ raw: String) {
        let url = BrowserPaneModel.normalize(raw)
        if let id = model.tabBar.activeTab?.id {
            model.tabBar.beginNavigating(id)
            tabBridge?.navigate(id: id, url: url)
        } else {
            tabBridge?.newTab(url: url)
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

    /// Tear the browser VM down and clear the pane. Idempotent.
    func stop() {
        model.hasFramebuffer = false
        model.placeholderStatus = ""
        model.tabBar.setTabs([])
        model.framebufferContainer.unmountAll()
        tabBridge?.stop()
        tabBridge = nil
        cdp?.stop()
        cdp = nil
        vmView?.virtualMachine = nil
        vmView = nil
        if let warm {
            self.warm = nil
            Task { await Self.tearDown(warm) }
        }
        pool = nil
        state = .idle
    }

    private func fail(_ message: String) {
        state = .failed(message)
        model.hasFramebuffer = false
        model.placeholderStatus = message
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
