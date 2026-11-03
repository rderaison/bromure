import Foundation

/// The Sidecar delegation shim's one stream to the hub (`__mcp-delegation`),
/// and who may end it. Shared with Bromure AC's tests (the Sidecar target
/// has none).
///
/// Only the reader opens a stream (`open`) and closes one (`ended`). A
/// writer whose write failed, and the watchdog, only shut down the stream
/// they saw — and only while it's still the current one, fd AND generation —
/// so the reader sees its EOF and settles every call it held. Before, any
/// thread closed "fd 7": a reconnect reuses the number, so a late drop from
/// a stream already replaced closed the new one, a call written on it left
/// pending on a socket nobody read (a `delegate` or a file copy for ever,
/// never overdue) while the hub had already run it.
final class DelegationShimStream: @unchecked Sendable {
    /// What a write came to. `stale`: the stream isn't the current one any
    /// more — nothing written, nothing to close, just write again on the
    /// current one. `failed`: the write didn't go through; the stream is shut
    /// down and the call taken back, to be written again. `ownedByReader`:
    /// the stream ended first and the reader holds the call.
    enum Sent: Equatable { case sent, stale, failed, ownedByReader }

    private let cond = NSCondition()
    /// One writer at a time, and a stream is never closed (its number free
    /// for the next) while a write to it is under way.
    private let writeLock = NSLock()
    private var sock: Int32 = -1
    private var generation = 0
    /// The generation the reader is on, until its `ended` (0: between
    /// streams). Its calls are its own to settle — a reply may already sit in
    /// its buffer, even after the stream was shut down.
    private var readerGen = 0
    private var pending = DelegationShimCalls()
    private var localGenerations: Set<Int> = []
    private var inputOpen = true
    private let writeLine: (Data, Int32) -> Bool

    init(writeLine: @escaping (Data, Int32) -> Bool = DelegationShimStream.writeAll) {
        self.writeLine = writeLine
    }

    static func writeAll(_ data: Data, _ fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var base = raw.baseAddress else { return true }
            var rem = raw.count
            while rem > 0 {
                let w = write(fd, base, rem)
                if w <= 0 { return false }
                base += w; rem -= w
            }
            return true
        }
    }

    // MARK: Reader

    /// The reader connected: `fd` is the current stream now. Its generation.
    func open(_ fd: Int32) -> Int {
        cond.lock(); defer { cond.unlock() }
        sock = fd
        generation += 1
        readerGen = generation
        if !inputOpen { shutdown(fd, SHUT_WR) }
        cond.broadcast()
        return generation
    }

    /// The hub said this stream is its local fallback: nothing on it runs.
    func markLocal(_ gen: Int) {
        cond.lock(); localGenerations.insert(gen); cond.unlock()
    }

    func answered(_ line: Data) {
        cond.lock(); pending.answered(line); cond.unlock()
    }

    /// The reader's stream ended (EOF or error). Closed here — the one place
    /// a stream is, once no write is under way and no one can pick it up —
    /// and every call it held is handed back: to send again (a local
    /// stream) or to answer as lost, delegate and file copies included.
    func ended(_ fd: Int32, _ gen: Int) -> (wasLocal: Bool, held: [DelegationShimCalls.Call], inputOpen: Bool) {
        writeLock.lock(); defer { writeLock.unlock() }
        cond.lock()
        if sock == fd, generation == gen { sock = -1 }
        if readerGen == gen { readerGen = 0 }
        let wasLocal = localGenerations.remove(gen) != nil
        let held = pending.take(gen: gen)
        let open = inputOpen
        cond.unlock()
        close(fd)
        return (wasLocal, held, open)
    }

    // MARK: Writers

    /// The current stream, waiting while the reader reconnects. nil past
    /// `timeout` (tests).
    func current(timeout: TimeInterval = .infinity) -> (fd: Int32, gen: Int)? {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while sock < 0 {
            if timeout.isFinite { guard cond.wait(until: deadline) else { return nil } } else { cond.wait() }
        }
        return (sock, generation)
    }

    /// Write `data` on stream `gen`, recording it as in flight there.
    func send(_ data: Data, _ fd: Int32, _ gen: Int) -> Sent {
        writeLock.lock(); defer { writeLock.unlock() }
        cond.lock()
        let live = sock == fd && generation == gen
        if live { pending.sent(data, on: gen) }
        cond.unlock()
        guard live else { return .stale }
        if writeLine(data, fd) { return .sent }
        cond.lock(); defer { cond.unlock() }
        abandonLocked(fd, gen)
        guard let key = DelegationShimCalls.requestKey(data) else { return .failed }   // not a call: just again
        return pending.take(key: key) != nil ? .failed : .ownedByReader
    }

    /// Shut stream (`fd`, `gen`) down if it's still the current one: its
    /// reader sees EOF. Never a close: the number stays taken until the
    /// reader is done with it.
    func abandon(_ fd: Int32, _ gen: Int) {
        cond.lock(); abandonLocked(fd, gen); cond.unlock()
    }

    private func abandonLocked(_ fd: Int32, _ gen: Int) {
        guard sock == fd, generation == gen else { return }
        shutdown(fd, SHUT_RDWR)
        sock = -1
    }

    /// Claude closed stdin: no more calls — the hub hears it.
    func inputClosed() {
        cond.lock()
        inputOpen = false
        if sock >= 0 { shutdown(sock, SHUT_WR) }
        cond.unlock()
    }

    // MARK: Watchdog

    /// Calls past their deadline: on the stream the reader is on, that
    /// stream is shut down (once — the reader answers them at its EOF, after
    /// any reply it already read); on one the reader has left, answered here
    /// (`orphans`). Checked and done under one lock, so it's never a stream
    /// that replaced the one it looked at.
    func watchdog(now: Date = Date()) -> (orphans: [DelegationShimCalls.Call], late: DelegationShimCalls.Call?) {
        cond.lock(); defer { cond.unlock() }
        let overdue = pending.overdue(now: now).filter { !localGenerations.contains($0.gen) }
        let orphans = overdue.filter { $0.gen != readerGen }.compactMap { pending.take(key: $0.key) }
        let live = sock >= 0 && generation == readerGen
        let late = live ? overdue.first(where: { $0.gen == readerGen }) : nil
        if late != nil { abandonLocked(sock, generation) }
        return (orphans, late)
    }

    /// What's in flight (tests).
    var inFlight: [DelegationShimCalls.Call] { cond.lock(); defer { cond.unlock() }; return pending.calls }
}
