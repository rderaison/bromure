import Foundation
import Darwin
@preconcurrency import Virtualization

/// A custom scanout has no VZ display/input association. Use the guest's
/// standard uinput absolute mouse while retaining VZ's keyboard and scroll path.
@MainActor
public final class GuestPointerBridge {
    public static let vsockPort: UInt32 = 5821
    public private(set) var isConnected = false
    private weak var device: VZVirtioSocketDevice?
    private var connection: VZVirtioSocketConnection?
    private var connecting = false
    private var stopped = false
    private var retryCount = 0
    private var descriptor: Int32 = -1
    private var pending: (Double, Double, Int)?
    private var flushTask: DispatchWorkItem?

    public init(socketDevice: VZVirtioSocketDevice) {
        device = socketDevice
        connect()
    }

    public func stop() {
        stopped = true
        flushTask?.cancel()
        flushTask = nil
        pending = nil
        connection = nil
        descriptor = -1
        isConnected = false
    }

    public func send(x: Double, y: Double, buttons: Int, immediately: Bool = false) {
        guard !stopped, x.isFinite, y.isFinite else { return }
        pending = (min(max(x, 0), 1), min(max(y, 0), 1), buttons & 7)
        if immediately {
            flushTask?.cancel(); flushTask = nil
            flush()
        } else if flushTask == nil {
            let task = DispatchWorkItem { [weak self] in
                self?.flushTask = nil
                self?.flush()
            }
            flushTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0, execute: task)
        }
    }

    private func flush() {
        guard isConnected, descriptor >= 0, let value = pending else { connect(); return }
        pending = nil
        let line = "{\"x\":\(value.0),\"y\":\(value.1),\"buttons\":\(value.2)}\n"
        let written = line.withCString { Darwin.write(descriptor, $0, line.utf8.count) }
        if written != line.utf8.count {
            connection = nil; descriptor = -1; isConnected = false
            connect()
        }
    }

    private func connect() {
        guard !stopped, !connecting, !isConnected, retryCount < 60, let device else { return }
        connecting = true; retryCount += 1
        device.connect(toPort: Self.vsockPort) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.connecting = false
                switch result {
                case .success(let connection):
                    let fd = connection.fileDescriptor
                    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
                          fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { return }
                    self.connection = connection; self.descriptor = fd
                    self.isConnected = true; self.retryCount = 0
                    self.flush()
                case .failure:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.connect() }
                }
            }
        }
    }
}
