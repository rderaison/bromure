import Foundation
import Testing
@testable import ACLinux

/// The OCSF export on Linux: macOS's keys (here registered in memory only:
/// nothing written to this user's ~/.config), the daemon's state dir by
/// default.
@Suite("OCSF export on Linux", .serialized)
struct OCSFExportLinuxTests {
    @Test func theDefaultDirectoryIsTheStateDirsOwn() throws {
        let state = try shortTempDir()
        let dir = OCSFExporter.makeDefaultDirectory(stateDir: state)
        #expect(dir.path == state + "/ocsf")
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func anEventIsRecordedOnceEnabled() async throws {
        let out = try shortTempDir() + "/export"
        let pid = UUID()
        OCSFExporter.shared.record(profileID: pid, workspace: "w", eventType: "network.connection.denied",
                                   eventData: ["host": .string("example.com"), "port": .int(443)])
        UserDefaults.standard.register(defaults: [OCSFExporter.enabledKey: true, OCSFExporter.directoryKey: out])
        defer { UserDefaults.standard.register(defaults: [OCSFExporter.enabledKey: false, OCSFExporter.directoryKey: ""]) }
        OCSFExporter.shared.record(profileID: pid, workspace: "w", eventType: "network.connection.denied",
                                   eventData: ["host": .string("example.com"), "port": .int(443)])
        var text = ""
        for _ in 0..<100 {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []
            if let f = files.first(where: { $0.hasSuffix(".jsonl") }),
               let t = try? String(contentsOfFile: out + "/" + f, encoding: .utf8), !t.isEmpty { text = t; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1, "only the one recorded while enabled: \(text)")
        #expect(lines.first?.contains(pid.uuidString.lowercased()) == true || lines.first?.contains(pid.uuidString) == true)
    }
}
