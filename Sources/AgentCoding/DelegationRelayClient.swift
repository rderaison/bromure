import Foundation
import os
import Darwin

// MARK: - Delegation-MCP relay (fat-client side, Bromure Agent Host)

/// Serves the `bromure-delegation` MCP to the agents on a Bromure Agent Host.
/// Keeps one stream slot waiting on the host — a `delegation-mcp` SSH channel
/// (a fat client connected to it) or a parked machine link (the host attached
/// to this app, MachineLinks.swift); the host hands it the next agent's MCP
/// stream (first line `bromure-hello w<window>`), and this app answers it with
/// its own DelegationMCPServer — the delegation records and engine live here,
/// so the host's agents and this app's reach each other exactly like two
/// workspaces do. As soon as one is taken, another waits. Same pump shape as
/// BrowserMCPRelayClient.
///
/// A slot nobody takes within `parkedFor` is dropped and dialed again: over a
/// relayed P2P path the host's end can die (a Sidecar restart) without this
/// side ever seeing EOF — the SSH server's peer is a loopback splice — and a
/// slot waiting on it would keep delegation down until this app restarted.
/// The host skips a dropped slot when it hands out the next stream.
final class DelegationRelayClient: @unchecked Sendable {
    private let dial: @Sendable () -> Int32?
    private let label: String
    private let makeServer: @MainActor () -> DelegationMCPServer?
    private let parkedFor: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: (running: false, fds: Set<Int32>()))

    init(dial: @escaping @Sendable () -> Int32?, label: String, parkedFor: TimeInterval = 180,
         makeServer: @escaping @MainActor () -> DelegationMCPServer?) {
        self.dial = dial
        self.label = label
        self.parkedFor = parkedFor
        self.makeServer = makeServer
    }

    func start() {
        let already = state.withLock { s -> Bool in
            defer { s.running = true }
            return s.running
        }
        guard !already else { return }
        let dial = self.dial, label = self.label, parkedFor = self.parkedFor
        Thread.detachNewThread { [weak self] in
            while self?.isRunning == true {
                guard let fd = dial(), fd >= 0 else {
                    Thread.sleep(forTimeInterval: 2); continue
                }
                guard let self, self.track(fd) else { Darwin.close(fd); return }
                // Parked until an agent opens its MCP: its hello comes first.
                switch Self.readLine(fd, within: parkedFor) {
                case .line(let hello, let rest):
                    FatClientLog.log("delegation-relay: \(label) stream \(hello)")
                    Thread.detachNewThread { [weak self] in
                        self?.pump(fd, hello: hello, pending: rest)
                        self?.release(fd)
                    }
                case .expired:
                    // Maybe a dead end nobody told us about: a fresh one.
                    self.release(fd)
                case .closed:
                    self.release(fd)
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
    }

    func stop() {
        // Under the lock: an fd still tracked hasn't been closed, so its
        // number can't belong to someone else's socket yet.
        state.withLock { s in
            s.running = false
            // Wakes every read; each thread does its own close.
            for fd in s.fds { Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    private var isRunning: Bool { state.withLock { $0.running } }

    private func track(_ fd: Int32) -> Bool {
        state.withLock { s -> Bool in
            guard s.running else { return false }
            s.fds.insert(fd)
            return true
        }
    }

    /// Untrack and close in one step, so `stop()` never shuts down a number
    /// already reused by another socket.
    private func release(_ fd: Int32) {
        state.withLock { s in
            s.fds.remove(fd)
            Darwin.close(fd)
        }
    }

    enum Hello: Equatable {
        case line(String, Data)
        /// Nothing came within the deadline.
        case expired
        /// The slot closed, or sent something else.
        case closed
    }

    /// `bromure-hello <id>`, and whatever followed it in the same reads —
    /// waiting at most `within` for it to start.
    static func readLine(_ fd: Int32, within: TimeInterval) -> Hello {
        var buf = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        let deadline = Date().addingTimeInterval(within)
        while data.count < 4096 {
            if data.isEmpty {
                let ms = Int32(max(0, min(deadline.timeIntervalSinceNow * 1000, Double(Int32.max))))
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let r = poll(&p, 1, ms)
                if r == 0 { return .expired }
                if r < 0 { if errno == EINTR { continue }; return .closed }
            }
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { return .closed }
            data.append(contentsOf: buf[0..<n])
            if let nl = data.firstIndex(of: 0x0A) {
                let line = String(decoding: data[data.startIndex..<nl], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("bromure-hello ") else { return .closed }
                return .line(String(line.dropFirst("bromure-hello ".count)), Data(data[(nl + 1)...]))
            }
        }
        return .closed
    }

    /// JSON-RPC lines in, the local server's answers out, in order.
    private func pump(_ fd: Int32, hello: String, pending initial: Data) {
        let serverBox = OSAllocatedUnfairLock<DelegationMCPServer?>(initialState: nil)
        let sem0 = DispatchSemaphore(value: 0)
        let make = makeServer
        Task { @MainActor in
            let s = make()
            serverBox.withLock { $0 = s }
            sem0.signal()
        }
        sem0.wait()
        guard let server = serverBox.withLock({ $0 }) else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        var pending = initial
        while true {
            let stop = autoreleasepool { () -> Bool in
                while let nl = pending.firstIndex(of: 0x0A) {
                    let lineData = Data(pending[pending.startIndex..<nl])
                    pending = Data(pending[(nl + 1)...])
                    guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
                    let sem = DispatchSemaphore(value: 0)
                    let out = OSAllocatedUnfairLock<String?>(initialState: nil)
                    Task { @MainActor in
                        let r = await server.handle(line: line, branch: hello)
                        out.withLock { $0 = r }
                        sem.signal()
                    }
                    sem.wait()   // MCP is serial per connection: keep answers ordered
                    if let response = out.withLock({ $0 }) {
                        var bytes = Data(response.utf8); bytes.append(0x0A)
                        guard Self.writeAll(fd, bytes) else {
                            Task { @MainActor in server.responseNotWritten(to: line, branch: hello) }
                            return true
                        }
                    }
                }
                if pending.count > 16 << 20 { return true }
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { return true }
                pending.append(contentsOf: buf[0..<n])
                return false
            }
            if stop { return }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var base = raw.baseAddress else { return true }
            var rem = raw.count
            while rem > 0 {
                let w = Darwin.write(fd, base, rem)
                if w <= 0 { return false }
                base += w; rem -= w
            }
            return true
        }
    }
}

// MARK: - The agent host as a delegation party

extension RemoteHostController: AgentHostLink {
    var agentHostID: UUID? { isAgentHost ? listModel.profileRows.first?.id : nil }
    var hostSessions: AgentSessionStore { sessionStore }
    var hostHome: String? { nil }

    func hostExec(_ command: String, timeout: Int) async throws -> String {
        guard let id = agentHostID else { throw ACAppDelegate.GuestExecError.connectionFailed }
        return try await guestExec(id, command: command, timeout: timeout)
    }

    func hostFileOp(_ op: [String: Any], timeout: Int) async throws -> [String: Any] {
        guard let id = agentHostID else { throw ACAppDelegate.GuestExecError.connectionFailed }
        return try await guestFileOp(id, op: op, timeout: timeout)
    }

    func hostTabStatus(window: Int) -> AgentStatus? {
        guard let id = agentHostID else { return nil }
        return listModel.entries.first { $0.id == id }?.model.tabs.first { $0.index == window }?.agentStatus
    }

    func hostSessionCommand(_ id: UUID, _ action: String, _ body: [String: Any]) {
        sessionCommand(id, action, body: body)
    }

    func hostControl(_ method: String, _ path: String, _ body: [String: Any]?) async -> (status: Int, json: [String: Any])? {
        await controlRequest(method, path, body)
    }

    func hostStartSession(tool: Profile.Tool, cwd: String, message: String) async -> UUID? {
        guard let id = agentHostID else { return nil }
        return await startSession(profileID: id, tool: tool, cwd: cwd, cloneURL: nil, message: message)
    }
}
