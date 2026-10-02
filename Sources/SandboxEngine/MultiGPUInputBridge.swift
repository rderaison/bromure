import Foundation
import Darwin
@preconcurrency import Virtualization

/// Experimental input connection shared by all windows of one multi-GPU VM.
/// Every snapshot names an X screen; production pointer port 5821 is untouched.
@MainActor
public final class MultiGPUInputBridge {
    public static let vsockPort: UInt32 = 5830
    public private(set) var isConnected = false
    private weak var device: VZVirtioSocketDevice?
    private var connection: VZVirtioSocketConnection?
    private var descriptor: Int32 = -1
    private let outgoing = PointerWireQueue()
    private var reconnectTask: DispatchWorkItem?
    private var flushTask: DispatchWorkItem?
    private var connecting = false
    private var stopped = false
    private var lastDisplay = 0
    private var lastX = 0.5
    private var lastY = 0.5
    private var buttons = 0

    public init(socketDevice: VZVirtioSocketDevice) { device = socketDevice; connect() }

    public func send(display: Int, x: Double, y: Double, buttons: Int,
                     focus: Bool = false, wheelX: Double = 0, wheelY: Double = 0,
                     coalescingMotion: Bool = false) {
        guard !stopped, (0..<16).contains(display), x.isFinite, y.isFinite,
              wheelX.isFinite, wheelY.isFinite else { return }
        lastDisplay = display; lastX = min(max(x, 0), 1); lastY = min(max(y, 0), 1)
        self.buttons = buttons & 7
        var message: [String: Any] = ["display":display,"x":lastX,"y":lastY,"buttons":self.buttons]
        if focus { message["focus"] = true }
        if wheelX != 0 { message["wheelX"] = min(max(wheelX, -2048), 2048) }
        if wheelY != 0 { message["wheelY"] = min(max(wheelY, -2048), 2048) }
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
        data.append(10)
        guard outgoing.enqueueFrame(data, coalescingMotion: coalescingMotion && !focus && wheelX == 0 && wheelY == 0) else {
            // Disconnect releases guest-held buttons; do not drop the final release.
            reconnect(replay: false); release(); return
        }
        drain()
    }

    public func focus(display: Int) {
        if buttons != 0 { release() }
        send(display: display, x: display == lastDisplay ? lastX : 0.5,
             y: display == lastDisplay ? lastY : 0.5, buttons: 0, focus: true)
    }

    public func release() {
        send(display: lastDisplay, x: lastX, y: lastY, buttons: 0)
    }

    public func stop() {
        if stopped { return }
        release(); stopped = true
        flushTask?.cancel(); reconnectTask?.cancel()
        outgoing.clear(); connection = nil; descriptor = -1; isConnected = false
    }

    private func drain() {
        guard !stopped else { return }
        guard isConnected, descriptor >= 0 else { connect(); return }
        do {
            if try !outgoing.drain(to: descriptor), flushTask == nil {
                let task = DispatchWorkItem { [weak self] in self?.flushTask = nil; self?.drain() }
                flushTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: task)
            }
        } catch { reconnect(replay: true) }
    }

    private func reconnect(replay: Bool) {
        flushTask?.cancel(); flushTask = nil
        if replay { outgoing.rewindPartialFrame() } else { outgoing.clear() }
        connection = nil; descriptor = -1; isConnected = false
        connect()
    }

    private func connect() {
        guard !stopped, !connecting, !isConnected, let device else { return }
        reconnectTask?.cancel(); reconnectTask = nil; connecting = true
        device.connect(toPort: Self.vsockPort) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.connecting = false
                switch result {
                case .success(let connection):
                    let fd = connection.fileDescriptor
                    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
                          fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { self.retry(); return }
                    self.connection = connection; self.descriptor = fd; self.isConnected = true
                    self.drain()
                case .failure: self.retry()
                }
            }
        }
    }

    private func retry() {
        guard !stopped else { return }
        let task = DispatchWorkItem { [weak self] in self?.reconnectTask = nil; self?.connect() }
        reconnectTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }
}
