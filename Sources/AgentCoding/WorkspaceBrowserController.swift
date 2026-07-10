import AppKit
import Foundation
import SandboxEngine
@preconcurrency import Virtualization

// Owns the ephemeral sidecar browser VM for one workspace (agentic web
// browser, phase 2). Boots/claims an Alpine+Chromium VM via SandboxEngine's
// VMPool + EphemeralDisk (CoW), mounts its framebuffer into the pane, and
// tears it all down on close. One instance per workspace (keyed by
// Profile.id), always ephemeral. See BROWSER_PANE_PLAN.md.
//
// Phase 2 scope: prove boot + framebuffer render alongside the workspace's
// Ubuntu VM. Chromium shows its own UI (nativeChrome=false) — the host-drawn
// chrome + CDP tabs/nav land in phase 3, so the pane's BrowserChrome is shown
// only in the placeholder state for now.
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
    /// Default landing page for a fresh ephemeral browser.
    private let homePage = "https://bromure.io/hello"

    init(model: BrowserPaneModel) {
        self.model = model
        model.onReload = { [weak self] in self?.navigate(self?.model.urlText ?? "") }
        model.onNavigate = { [weak self] url in self?.navigate(url) }
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

    /// A minimal ephemeral browser config. nativeChrome off for phase 2 (see
    /// file header); file transfer + automation on so phases 3-4 can wire
    /// downloads and CDP without a reboot.
    private func browserConfig() -> VMConfig {
        VMConfig(
            homePage: homePage,
            enableFileTransfer: true,
            enableAutomation: true,
            nativeChrome: false
        )
    }

    private func attach(_ warm: VMPool.WarmVM) {
        self.warm = warm
        let view = VZVirtualMachineView()
        view.virtualMachine = warm.vm
        view.automaticallyReconfiguresDisplay = true
        self.vmView = view
        model.framebufferContainer.mount(view)
        model.hasFramebuffer = true
        model.placeholderStatus = ""
        state = .running
        let ip = warm.networkReady ? "ready" : "pending"
        print("[browser] view attached; network \(ip). Loading \(homePage)")
        // Land on the home page (serial launch of chromium-browser <url>).
        navigate(homePage)
    }

    /// Navigate the guest browser. Phase 2 uses the serial path Bromure Web
    /// uses (launch `chromium-browser <url>` as the chrome user) — CDP-driven
    /// navigation replaces this in phase 3.
    private func navigate(_ raw: String) {
        guard state == .running, let warm else { return }
        let url = BrowserPaneModel.normalize(raw.isEmpty ? homePage : raw)
        model.urlText = url
        let inner = "DISPLAY=:0 chromium-browser \(Self.shellEscape(url))"
        let cmd = "su chrome -c \(Self.shellEscape(inner)) &\n"
        warm.serialInput.fileHandleForWriting.write(Data(cmd.utf8))
    }

    /// Tear the browser VM down and clear the pane. Idempotent.
    func stop() {
        model.hasFramebuffer = false
        model.placeholderStatus = ""
        model.framebufferContainer.unmountAll()
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

    /// Single-quote a string for `sh -c` (wrap in '…', escape embedded quotes).
    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
