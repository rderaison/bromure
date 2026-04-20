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

/// `bromure unenroll` — remove a managed-profile enrollment and its Keychain
/// state. With no arguments, removes every enrollment on this install; pass
/// `--install <id>` or `--org <slug>` to drop a single one.
struct Unenroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a managed-profile enrollment.",
    )

    @Option(name: .long, help: "Install ID to unenroll (see `bromure list-enrollments`).")
    var install: String?

    @Option(name: .long, help: "Org slug to unenroll. If multiple enrollments share the slug, use --install.")
    var org: String?

    @Flag(name: .long, help: "Remove every enrollment on this install.")
    var all: Bool = false

    func run() throws {
        let installs = InstallIdentityStore.loadAll()
        if installs.isEmpty {
            print("No managed enrollments found.")
            return
        }

        if all {
            ManagedProfileSync.shared.destroyLocalState()
            print("All managed enrollments removed (\(installs.count)).")
            return
        }

        let target: InstallIdentity? = {
            if let id = install {
                return installs.first { $0.installId == id }
            }
            if let slug = org {
                let matches = installs.filter { $0.orgSlug == slug }
                if matches.count > 1 {
                    print("Multiple enrollments share org '\(slug)'. Use --install <id>:")
                    for m in matches { print("  \(m.installId)  user=\(m.userEmail)") }
                    return nil
                }
                return matches.first
            }
            return nil
        }()

        if let target {
            ManagedProfileSync.shared.unenroll(installId: target.installId)
            print("Unenrolled from \(target.orgSlug) (install \(target.installId)).")
            return
        }

        if installs.count == 1 {
            let only = installs[0]
            ManagedProfileSync.shared.unenroll(installId: only.installId)
            print("Unenrolled from \(only.orgSlug) (install \(only.installId)).")
            return
        }

        print("Multiple enrollments exist. Specify one:")
        for i in installs {
            print("  --install \(i.installId)   org=\(i.orgSlug)  user=\(i.userEmail)")
        }
        print("Or pass --all to remove every enrollment.")
        throw ExitCode.failure
    }
}

/// `bromure list-enrollments` — print each enrollment's install id, org, and user.
struct ListEnrollments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-enrollments",
        abstract: "List every managed-profile enrollment on this install.",
    )

    func run() throws {
        let installs = InstallIdentityStore.loadAll()
        if installs.isEmpty {
            print("No managed enrollments.")
            return
        }
        for i in installs {
            print("\(i.installId)  org=\(i.orgSlug)  user=\(i.userEmail)  server=\(i.serverURL.absoluteString)  device=\(i.deviceName)")
        }
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
