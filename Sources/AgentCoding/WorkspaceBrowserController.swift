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
        } else {
            print("[browser] no vsock device — tabs/navigation disabled")
        }
        print("[browser] view attached; network \(warm.networkReady ? "ready" : "pending")")
    }

    private func wireTabBridge(_ bridge: TabBridge) {
        tabBridge = bridge
        bridge.onTabsChanged = { [weak self] tabs in
            guard let self else { return }
            self.model.tabs = tabs
            let active = tabs.first(where: { $0.active })
            self.model.activeTabID = active?.id
            // Reflect the active tab's URL unless the user is editing the field.
            if !self.model.urlFieldEditing, let url = active?.url {
                self.model.urlText = url
            }
        }
        bridge.onShortcut = { [weak self] key in
            guard let self else { return }
            switch key {
            case "t": bridge.newTab(url: "")
            case "w": bridge.closeActive()
            case "r": if let id = self.model.activeTabID { bridge.reload(id: id) }
            case "l": self.model.urlFieldEditing = true   // ⌘L focuses the address bar
            default: break
            }
        }
        // Host chrome → guest, via the bridge.
        model.onNavigate = { [weak self] raw in
            guard let self else { return }
            let url = BrowserPaneModel.normalize(raw)
            self.model.urlText = url
            if let id = self.model.activeTabID {
                bridge.navigate(id: id, url: url)
            } else {
                bridge.newTab(url: url)
            }
        }
        model.onBack = { [weak self] in if let id = self?.model.activeTabID { bridge.back(id: id) } }
        model.onForward = { [weak self] in if let id = self?.model.activeTabID { bridge.forward(id: id) } }
        model.onReload = { [weak self] in if let id = self?.model.activeTabID { bridge.reload(id: id) } }
        model.onNewTab = { bridge.newTab(url: "") }
        model.onSelectTab = { id in bridge.activate(id: id) }
        model.onCloseTab = { id in bridge.close(id: id) }
    }

    /// Tear the browser VM down and clear the pane. Idempotent.
    func stop() {
        model.hasFramebuffer = false
        model.placeholderStatus = ""
        model.tabs = []
        model.activeTabID = nil
        model.framebufferContainer.unmountAll()
        tabBridge?.stop()
        tabBridge = nil
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
