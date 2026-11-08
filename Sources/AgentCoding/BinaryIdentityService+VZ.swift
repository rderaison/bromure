import Foundation
import Virtualization

// The attestor channel's vsock listener on a VZ virtual machine; the
// channel itself (BinaryIdentityService.swift) is shared with the Linux
// daemon, whose listener is a Firecracker vsock socket.

extension BinaryIdentityService {
    /// Start listening for a VM's attestor. `secretFile` is host-side storage
    /// for the pinned secret (survives a suspend / restore of the VM).
    @MainActor
    public func attach(profileID: UUID, socketDevice: VZVirtioSocketDevice, secretFile: URL) {
        let bridge = AttestorBridge(profileID: profileID, secretFile: secretFile)
        let l = AttestorVsockListener(bridge: bridge)
        l.listen(on: socketDevice)
        bridge.listener = l
        adoptBridge(bridge, for: profileID)
    }

    @MainActor
    public func detach(profileID: UUID, socketDevice: VZVirtioSocketDevice?) {
        guard let b = dropBridge(profileID) else { return }
        socketDevice?.removeSocketListener(forPort: BinaryIdentityService.vsockPort)
        b.stop()
    }
}

/// Hands each connection on vsock 5840 to its VM's attestor channel.
final class AttestorVsockListener: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    /// Weak: the channel holds its listener.
    private weak var bridge: AttestorBridge?
    private var listener: VZVirtioSocketListener?

    init(bridge: AttestorBridge) { self.bridge = bridge }

    @MainActor func listen(on device: VZVirtioSocketDevice) {
        let l = VZVirtioSocketListener()
        l.delegate = self
        listener = l
        device.setSocketListener(l, forPort: BinaryIdentityService.vsockPort)
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let cfd = dup(connection.fileDescriptor)
        guard cfd >= 0 else { return false }
        Thread.detachNewThread { [weak bridge] in bridge?.handshakeAndServe(cfd, connection: connection) }
        return true
    }
}
