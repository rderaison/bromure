import ArgumentParser
import Foundation
import SandboxEngine

// CLI counterparts to the Window → "Enroll in bromure.io…" sheet.
// Same backing store, same network calls — useful when standing up a
// new device from a script (Apple Configurator-style provisioning) or
// from `ssh` without poking the GUI.

struct Enroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Enroll this Mac with a bromure.io workspace using a 6-word code."
    )

    @Option(name: .long, help: "Enrollment code minted by an admin (6 dashed words).")
    var code: String

    @Option(name: .long,
            help: "bromure.io API base URL. Defaults to BROMURE_MANAGED_URL or https://bromure.io/api.")
    var serverURL: String?

    @Option(name: .long,
            help: "Device name shown to admins. Defaults to the host's localized name.")
    var deviceName: String?

    func run() throws {
        let url = serverURL.flatMap(URL.init(string:))
        let device = deviceName

        var result: Result<BACInstall, Error>?
        Task {
            do {
                let install = try await BACEnrollment.shared.enroll(
                    code: code, serverURL: url, deviceName: device,
                )
                result = .success(install)
            } catch {
                result = .failure(error)
            }
        }
        // Same RunLoop pump pattern as Init/Reset — sync entry, async
        // body, can't hand back to MainActor without driving the loop
        // ourselves.
        while result == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        switch result! {
        case .success(let install):
            FileHandle.standardOutput.write(Data("""
                Enrolled \(install.userEmail) at \(install.orgSlug)
                Install ID: \(install.installId)
                Server:     \(install.serverURL.absoluteString)
                Device:     \(install.deviceName)

                """.utf8))
        case .failure(let err):
            FileHandle.standardError.write(Data("enroll failed: \(err)\n".utf8))
            throw ExitCode.failure
        }
    }
}

struct Unenroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign out of the bromure.io workspace this Mac is enrolled in."
    )

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var force: Bool = false

    func run() throws {
        guard let install = BACEnrollmentStore.load() else {
            FileHandle.standardError.write(Data("not enrolled — nothing to do\n".utf8))
            return
        }
        if !force {
            FileHandle.standardOutput.write(Data(
                "Sign out of \(install.orgSlug) (\(install.userEmail))? [y/N]: ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                FileHandle.standardError.write(Data("aborted\n".utf8))
                throw ExitCode.failure
            }
        }
        var done = false
        Task {
            await BACEnrollment.shared.unenroll()
            done = true
        }
        while !done {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        FileHandle.standardOutput.write(Data("signed out\n".utf8))
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the current bromure.io enrollment state."
    )

    func run() throws {
        guard let install = BACEnrollmentStore.load() else {
            FileHandle.standardOutput.write(Data("not enrolled\n".utf8))
            // Exit cleanly — automation shouldn't see this as a failure.
            return
        }
        let cert = BACEnrollmentStore.loadLeafCertPem()
        let bearer = BACEnrollmentStore.loadInstallToken() != nil ? "present" : "missing"
        FileHandle.standardOutput.write(Data("""
            Enrolled
              workspace:  \(install.orgSlug)
              user:       \(install.userEmail)
              install id: \(install.installId)
              device:     \(install.deviceName)
              server:     \(install.serverURL.absoluteString)
              enrolled:   \(install.enrolledAt.formatted(.iso8601))
              bearer:     \(bearer)
              leaf cert:  \(cert == nil ? "not yet issued" : "present")

            """.utf8))
    }
}
