import Foundation

/// How many VMs boot or restore at once, app-wide.
///
/// A panic on a Mac starting five workspaces together (beside two Parallels VMs)
/// caught the APFS container's transaction flusher, every VM's disk and
/// virtio-fs threads, and logd all waiting on one event for two minutes, until
/// the watchdog rebooted the machine. No thread held it: the disk work behind it
/// just never finished. Starts are where that burst comes from: a restore reads
/// the whole saved RAM image, and a fresh boot writes and flushes the most. The
/// launch restore already went one workspace at a time; starts from anywhere
/// else (a click, an automation, a delegate) did not.
///
/// A slot is held through the start and a little past it: a restore until its
/// RAM image is read and the guest resumed, plus `restoreSettle`; a fresh boot
/// until its guest reports an address (`ip.txt`, written once it's up), capped
/// at `bootSettleCap` so a guest that never says so can't hold it for good.
/// The caps keep a queue of starts well inside the boot timeouts (180 s).
@MainActor
final class VMStartGate {
    static let shared = VMStartGate(limit: 2)

    static let restoreSettle: TimeInterval = 5
    static let bootSettleCap: TimeInterval = 30

    let limit: Int
    private(set) var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    var waiting: Int { waiters.count }

    /// Wait for a slot. Each `acquire` needs exactly one `release`.
    func acquire() async {
        if inUse < limit { inUse += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        // The slot was handed over by `release` (inUse unchanged).
    }

    func release() {
        if waiters.isEmpty {
            inUse = max(0, inUse - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Release the slot once `settled` says so (polled every half second, off
    /// the main thread: it reads the guest's outbox), or after `cap`.
    func release(whenSettled settled: @escaping @Sendable () -> Bool, cap: TimeInterval) {
        Task.detached(priority: .utility) {
            let end = Date().addingTimeInterval(cap)
            while Date() < end, !settled() {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await self.release()
        }
    }

    /// Whether the guest wrote `ip.txt` since `since`: its network, and so its
    /// agent, are up.
    nonisolated static func guestReportedAddress(outbox: URL, since: Date) -> Bool {
        let ip = outbox.appendingPathComponent("ip.txt", isDirectory: false)
        guard let m = (try? FileManager.default.attributesOfItem(atPath: ip.path))?[.modificationDate] as? Date
        else { return false }
        return m >= since
    }
}
