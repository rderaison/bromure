import Foundation
import Network
import Testing
@testable import bromure_ac

/// The ws-relay listener (P2P/WSRelay.swift) end to end on loopback: a fake
/// bromure.io relay (a WebSocket server) and a fake sshd (a TCP echo server).
/// Bytes the "dialer" sends through the relay must reach the sshd, and the
/// sshd's reply must come back through the relay, verbatim and in order.
@Suite("ws-relay listener")
struct WSRelayTests {

    final class FakeRelay: @unchecked Sendable {
        let listener: NWListener
        var conn: NWConnection?
        var received = Data()
        var authHeader: String?
        let lock = NSLock()
        let ready = DispatchSemaphore(value: 0)

        init() throws {
            let ws = NWProtocolWebSocket.Options()
            ws.setClientRequestHandler(DispatchQueue.global()) { _, headers in
                let auth = headers.first { $0.name.lowercased() == "authorization" }?.value
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil,
                                                    additionalHeaders: auth.map { [("x-seen-auth", $0)] } ?? [])
            }
            let params = NWParameters.tcp
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                self.lock.withLock { self.conn = c }
                c.start(queue: .global())
                self.ready.signal()
                self.receive(c)
            }
            listener.start(queue: .global())
        }
        var port: UInt16 {
            for _ in 0..<100 { if let p = listener.port?.rawValue, p != 0 { return p }; usleep(20_000) }
            return 0
        }
        func receive(_ c: NWConnection) {
            c.receiveMessage { [weak self] data, _, _, err in
                guard let self, err == nil else { return }
                if let data { self.lock.withLock { self.received.append(data) } }
                self.receive(c)
            }
        }
        func send(_ d: Data) {
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let ctx = NWConnection.ContentContext(identifier: "bin", metadata: [meta])
            lock.withLock { conn }?.send(content: d, contentContext: ctx, isComplete: true, completion: .idempotent)
        }
    }

    final class EchoServer: @unchecked Sendable {
        let listener: NWListener
        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { c in
                c.start(queue: .global())
                func loop() {
                    c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                        if let data, !data.isEmpty {
                            c.send(content: Data("echo:".utf8) + data, completion: .idempotent)
                        }
                        if err == nil && !done { loop() }
                    }
                }
                loop()
            }
            listener.start(queue: .global())
        }
        var port: UInt16 {
            for _ in 0..<100 { if let p = listener.port?.rawValue, p != 0 { return p }; usleep(20_000) }
            return 0
        }
    }

    @Test("refuses malformed connection ids")
    func rejectsMalformed() {
        for id in ["", "..", "a/b", "../../devices", "x?y", "a b"] {
            #expect(!WSRelayListener.isValidConnectionId(id))
        }
        #expect(WSRelayListener.isValidConnectionId("3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
    }

    @Test("splices relay bytes to the local sshd and back")
    func splices() throws {
        let relay = try FakeRelay()
        let echo = try EchoServer()
        let relayPort = relay.port, echoPort = echo.port
        #expect(relayPort != 0 && echoPort != 0)
        let ep = try ControlPlaneEndpoint(base: "http://127.0.0.1:\(relayPort)")
        WSRelayListener.join(connectionId: "conn-test-1", endpoint: ep, bearer: "tok", sshPort: Int(echoPort))
        #expect(relay.ready.wait(timeout: .now() + 5) == .success)
        relay.send(Data("SSH-2.0-test\r\n".utf8))
        let deadline = Date().addingTimeInterval(5)
        var got = Data()
        while Date() < deadline {
            got = relay.lock.withLock { relay.received }
            if got.count >= 19 { break }
            usleep(20_000)
        }
        #expect(String(decoding: got, as: UTF8.self) == "echo:SSH-2.0-test\r\n")
        relay.listener.cancel(); echo.listener.cancel()
    }
}
