import ArgumentParser
import Foundation
import SandboxEngine

/// `bromure enroll <code>` — redeem a managed-profile enrollment code.
struct Enroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Redeem a managed-profile enrollment code.",
    )

    @Argument(help: "Enrollment code (e.g. acid-aloe-arson-bench-cat-drum).")
    var code: String

    @Option(name: .long, help: "Control-plane server URL (default: http://localhost:3847).")
    var server: String?

    @Option(name: .long, help: "Device name to register with the server.")
    var deviceName: String?

    func run() async throws {
        let serverURL: URL = {
            if let s = server, let url = URL(string: s) { return url }
            return ManagedProfileSync.defaultServerURL
        }()
        let name = deviceName ?? Host.current().localizedName ?? "unnamed"
        print("Enrolling against \(serverURL.absoluteString) as \(name)…")
        let profile = try await ManagedProfileSync.shared.enroll(
            code: code,
            serverURL: serverURL,
            deviceName: name,
        )
        print("Enrolled.")
        print("  org:       \(profile.orgSlug)")
        print("  profile:   \(profile.name) (\(profile.id.uuidString))")
        print("  version:   \(profile.version)")
        print("  assets:    \(profile.assets.count)")
        print("  mTLS:      \(profile.mtls.enabled ? "yes" : "no")")
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
