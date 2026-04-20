import ArgumentParser
import Dispatch
import Foundation
import SandboxEngine

/// `bromure enroll <code>` — redeem a managed-profile enrollment code.
///
/// This is a plain `ParsableCommand` (not `AsyncParsableCommand`) because the
/// root `Bromure` command is synchronous; an async subcommand under a sync
/// root never gets its `run()` actually invoked and ArgumentParser prints the
/// subcommand usage instead. We bridge to the async enroll call via a
/// detached Task + semaphore.
struct Enroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Redeem a managed-profile enrollment code.",
    )

    @Argument(help: "Enrollment code (e.g. acid-aloe-arson-bench-cat-drum).")
    var code: String

    @Option(name: .long, help: "Control-plane server URL (default: http://localhost:3847).")
    var server: String?

    @Option(name: .long, help: "Device name to register with the server.")
    var deviceName: String?

    func run() throws {
        let serverURL: URL = {
            if let s = server, let url = URL(string: s) { return url }
            return ManagedProfileSync.defaultServerURL
        }()
        let name = deviceName ?? Host.current().localizedName ?? "unnamed"
        print("Enrolling against \(serverURL.absoluteString) as \(name)…")

        let profiles = try runBlocking {
            try await ManagedProfileSync.shared.enroll(
                code: code,
                serverURL: serverURL,
                deviceName: name,
            )
        }

        print("Enrolled. Received \(profiles.count) managed profile(s):")
        for p in profiles {
            print("  - \(p.name)  v\(p.version)  mTLS=\(p.mtls.enabled ? "yes" : "no")  assets=\(p.assets.count)")
        }
        if profiles.isEmpty {
            print("  (no profiles currently assigned to this user — ask your admin)")
        }
    }
}

/// `bromure unenroll` — clear the managed profile + associated Keychain state.
struct Unenroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove the managed profile and forget the enrollment.",
    )

    func run() throws {
        ManagedProfileSync.shared.destroyLocalState()
        print("Managed profile removed.")
    }
}

// MARK: - Sync-over-async bridge

/// Bridge for calling an async function from a synchronous entry point
/// (like a `ParsableCommand.run()`). Blocks the current thread on a
/// semaphore while the async work runs on Swift Concurrency's cooperative
/// thread pool, then rethrows any error.
private func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        do {
            let value = try await operation()
            box.setValue(.success(value))
        } catch {
            box.setValue(.failure(error))
        }
        sem.signal()
    }
    sem.wait()
    return try box.get()
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?
    func setValue(_ r: Result<T, Error>) {
        lock.lock(); stored = r; lock.unlock()
    }
    func get() throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let r = stored else { fatalError("ResultBox accessed before set") }
        return try r.get()
    }
}
