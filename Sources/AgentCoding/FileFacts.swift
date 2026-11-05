import Foundation

/// File facts the main thread shows but must never wait for: a workspace's
/// image sizes, its saved RAM state, its compromise mark.
///
/// A stat is normally instant, but it waits for the volume. On a Mac running
/// eight VMs the state snapshot for fat clients spent whole seconds in one
/// `lstat` of `home.img`, the app frozen, and a stackshot during the reboot
/// that followed had the APFS transaction flusher stuck with the VMs' disk
/// threads. So these are read on one background queue, and the main thread only
/// ever sees what was last read: a few seconds old, or nothing yet the first
/// time. One queue, so a volume that stalls holds one read, not a pile of them.
@MainActor
final class FileFacts {
    static let shared = FileFacts()

    struct Facts: Equatable, Sendable {
        var exists: Bool
        var size: Int64 = 0
        var allocated: Int64 = 0
    }

    /// How old a fact may be before it's read again.
    nonisolated static let maxAge: TimeInterval = 5

    private var known: [String: (facts: Facts, at: TimeInterval)] = [:]
    private var reading = Set<String>()
    private let queue = DispatchQueue(label: "io.bromure.file-facts", qos: .utility)
    private let clock: () -> TimeInterval
    private let reader: @Sendable (String) -> Facts

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         reader: @escaping @Sendable (String) -> Facts = FileFacts.read) {
        self.clock = clock
        self.reader = reader
    }

    /// What's known of `url`, without waiting: nil until a first read lands.
    /// A missing or old fact is (re)read in the background.
    func facts(_ url: URL) -> Facts? {
        let path = url.path
        let now = clock()
        let cached = known[path]
        if cached == nil || now - cached!.at >= Self.maxAge, reading.insert(path).inserted {
            let reader = self.reader
            queue.async { [weak self] in
                let facts = reader(path)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.known[path] = (facts, self.clock())
                        self.reading.remove(path)
                    }
                }
            }
        }
        return cached?.facts
    }

    /// Wait for the reads asked for so far (tests).
    nonisolated func drain() { queue.sync {} }

    nonisolated static func read(_ path: String) -> Facts {
        var st = stat()
        guard lstat(path, &st) == 0 else { return Facts(exists: false) }
        return Facts(exists: true, size: Int64(st.st_size), allocated: Int64(st.st_blocks) * 512)
    }
}
