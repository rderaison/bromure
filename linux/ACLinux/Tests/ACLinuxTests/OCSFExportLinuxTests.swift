import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// The OCSF export on Linux: macOS's keys, read here from a suite of the
    /// test's own (registered in memory: no persisted plist can override it,
    /// nothing written to this user's ~/.config), the daemon's state dir by
    /// default. Under DaemonGlobalSuites: the exporter is process-wide, and
    /// other suites emit events.
    @Suite("OCSF export on Linux", .serialized)
    struct OCSFExportLinuxTests {
        @Test func theDefaultDirectoryIsTheStateDirsOwnAndStays0700() throws {
            let state = try shortTempDir()
            let dir = OCSFExporter.makeDefaultDirectory(stateDir: state)
            #expect(dir.path == state + "/ocsf")
            func mode() throws -> Int? { try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int }
            #expect(try mode() == 0o700)
            // Deleted while the daemon runs: made again 0700, whatever the umask.
            try FileManager.default.removeItem(at: dir)
            let old = umask(0o022); defer { umask(old) }
            OCSFExporter.makeDirectory(dir)
            #expect(try mode() == 0o700)
        }

        @Test func anEventIsRecordedOnceEnabled() async throws {
            let out = try shortTempDir() + "/export"
            let suite = "acl-ocsf-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let prior = OCSFExporter.shared.defaults
            OCSFExporter.shared.defaults = defaults
            defer { OCSFExporter.shared.defaults = prior }
            let pid = UUID()
            func record() {
                OCSFExporter.shared.record(profileID: pid, workspace: "w", eventType: "network.connection.denied",
                                           eventData: ["host": .string("example.com"), "port": .int(443)])
            }
            record()   // off: nothing
            defaults.register(defaults: [OCSFExporter.enabledKey: true, OCSFExporter.directoryKey: out])
            record()
            var text = ""
            for _ in 0..<100 {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []
                if let f = files.first(where: { $0.hasSuffix(".jsonl") }),
                   let t = try? String(contentsOfFile: out + "/" + f, encoding: .utf8), !t.isEmpty { text = t; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let lines = text.split(separator: "\n")
            #expect(lines.count == 1, "only the one recorded while enabled: \(text)")
            #expect(lines.first.map { $0.lowercased().contains(pid.uuidString.lowercased()) } == true)
            let mode = try FileManager.default.attributesOfItem(atPath: out)[.posixPermissions] as? Int
            #expect(mode == 0o700, "a set directory made by the export is 0700 too")
            #expect(!FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/\(suite).plist"), "nothing persisted")
        }
    }
}
