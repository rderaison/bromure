import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Browser-MCP relay client (fat-client side)

/// Runs on the fat client. Opens a `browser-mcp <vm>` SSH channel to the remote
/// host and speaks the line-delimited JSON-RPC the remote workspace agent emits,
/// answering with a local `BrowserMCPServer` that drives THIS machine's browser
/// pane. So the remote agent's `browser_*` tools act on the Chromium VM the user
/// sees locally. Reconnects on drop (the guest shim reconnects forever, so a
/// re-dial re-establishes the relay).
@MainActor
final class BrowserMCPRelayClient {
    private let host: RemoteHost
    private let vm: String
    private let server: BrowserMCPServer
    /// Set on the main actor, read from the pump thread — lock-protected
    /// (MainActor.assumeIsolated off the main thread is a runtime trap).
    private let runningState = OSAllocatedUnfairLock(initialState: false)
    private var running: Bool {
        get { runningState.withLock { $0 } }
        set { runningState.withLock { $0 = newValue } }
    }
    /// Set on the dial thread, read from stop() — boxed in a Sendable lock like
    /// `runningState` so nonisolated access compiles under actor isolation.
    private let fdState = OSAllocatedUnfairLock<Int32>(initialState: -1)

    init(host: RemoteHost, vm: String,
         browser: @escaping () -> WorkspaceBrowserController?) {
        self.host = host
        self.vm = vm
        self.server = BrowserMCPServer(browser: browser,
                                       ensureBrowser: { browser()?.ensureRunning() })
    }

    func start() {
        guard !running else { return }
        running = true
        let host = self.host, vm = self.vm
        Thread.detachNewThread { [weak self] in
            while self?.runningSnapshot() == true {
                guard let raw = RemoteTransport.browserMCPDial(host: host, vm: vm), raw >= 0 else {
                    Thread.sleep(forTimeInterval: 1.0); continue
                }
                // Atomic vs stop(): if stop() raced the dial, close and exit —
                // otherwise the fd is adopted with no closer and pump() parks.
                guard self?.adoptFD(raw) == true else { Darwin.close(raw); break }
                FDGuard.adopt(raw, "browser-mcp-relay")
                self?.pump(raw)          // blocks until the channel drops
                // Clear before closing so stop() can't act on a stale number;
                // this is the sole close — stop() only shuts down.
                self?.clearFD(raw)
                FDGuard.close(raw, "browser-mcp-relay")
                if self?.runningSnapshot() == true { Thread.sleep(forTimeInterval: 0.5) }
            }
        }
    }

    func stop() {
        running = false
        let f = fdState.withLock { (cur: inout Int32) -> Int32 in
            let prev = cur; cur = -1; return prev
        }
        // shutdown wakes the pump's read; the dial thread then does the only
        // close — closing here too would double-close a possibly-recycled fd.
        if f >= 0 { Darwin.shutdown(f, SHUT_RDWR) }
    }

    /// Atomically adopt a freshly-dialed fd, unless stop() already ran.
    /// Lock order is fdState → runningState; stop() takes fdState only.
    private nonisolated func adoptFD(_ v: Int32) -> Bool {
        fdState.withLock { (cur: inout Int32) -> Bool in
            guard runningState.withLock({ $0 }) else { return false }
            cur = v; return true
        }
    }

    private nonisolated func clearFD(_ v: Int32) {
        fdState.withLock { if $0 == v { $0 = -1 } }
    }

    private nonisolated func runningSnapshot() -> Bool {
        runningState.withLock { $0 }
    }

    /// Read JSON-RPC request lines from the channel, answer each via the local
    /// BrowserMCPServer (on the main actor), write the response line back.
    private nonisolated func pump(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var pending = Data()
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            // Pool per read batch: this raw Thread never drains its implicit
            // pool, so the bridged-string/JSON temporaries of every request
            // line would pin for the relay's lifetime (same bug StateStream
            // had, which grew the mirror to tens of GB).
            autoreleasepool {
                pending.append(contentsOf: buf[0..<n])
                while let nl = pending.firstIndex(of: 0x0A) {
                    let lineData = Data(pending[pending.startIndex..<nl])
                    pending = Data(pending[(nl + 1)...])
                    guard !lineData.isEmpty,
                          let line = String(data: lineData, encoding: .utf8) else { continue }
                    let sem = DispatchSemaphore(value: 0)
                    var response: String?
                    Task { @MainActor [weak self] in
                        response = await self?.server.handle(line: line)
                        sem.signal()
                    }
                    sem.wait()   // MCP is serial per connection → keep responses ordered
                    if let response {
                        var out = Data(response.utf8); out.append(0x0A)
                        out.withUnsafeBytes { raw in
                            guard let base = raw.baseAddress else { return }
                            var off = 0, rem = raw.count
                            while rem > 0 {
                                let w = Darwin.write(fd, base.advanced(by: off), rem)
                                if w <= 0 { break }
                                off += w; rem -= w
                            }
                        }
                    }
                }
            }
            if pending.count > 16 * 1024 * 1024 { break }   // pathological
        }
    }
}
