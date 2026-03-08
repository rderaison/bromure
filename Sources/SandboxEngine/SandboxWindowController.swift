import Cocoa
import Virtualization

/// Hosts a VZVirtualMachineView in a native macOS window.
///
/// This provides the graphical output for the sandboxed macOS guest.
/// The guest's framebuffer is rendered via the paravirtualized GPU
/// into this NSView — no VNC, no remote desktop, native performance.
public final class SandboxWindowController: NSWindowController {
    private let sandboxVM: SandboxVM
    private let vmView: VZVirtualMachineView

    public init(sandboxVM: SandboxVM) {
        self.sandboxVM = sandboxVM

        let view = VZVirtualMachineView()
        view.virtualMachine = sandboxVM.vm
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        self.vmView = view

        // Create the host window
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: CGFloat(sandboxVM.config.displayWidth) / 2,  // logical pixels
                height: CGFloat(sandboxVM.config.displayHeight) / 2
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bromure"
        window.contentView = view
        window.contentMinSize = NSSize(width: 800, height: 600)
        window.center()

        // Set the window to release when closed
        window.isReleasedWhenClosed = false

        super.init(window: window)

        // When the user closes the window, tear down the VM
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    @objc private func windowWillClose(_ notification: Notification) {
        Task {
            try? await sandboxVM.teardown()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Connect the view to the running VM's framebuffer.
    /// Call this after `vm.start()` succeeds and the event loop is active.
    public func connectVM() {
        vmView.virtualMachine = sandboxVM.vm
    }

    /// Show the window and bring the application to front.
    public func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
