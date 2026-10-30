import Foundation
import Testing
@testable import bromure_ac

@Suite("Per-state settings")
struct ACDefaultsTests {
    /// Sources/AgentCoding, found from this file.
    static let sourcesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding", isDirectory: true)

    static func swiftFiles() -> [URL] {
        guard let e = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("Every setting goes through ACDefaults.standard (no UserDefaults.standard outside SupportDirectory.swift)")
    func noStandardDefaults() throws {
        let files = Self.swiftFiles()
        try #require(!files.isEmpty, "Sources/AgentCoding not found at \(Self.sourcesDir.path)")
        var offenders: [String] = []
        // SupportDirectory.swift defines ACDefaults; StateStore.swift copies and
        // removes other states' domains by name (persistentDomain(forName:)).
        let allowed: Set<String> = ["SupportDirectory.swift", "StateStore.swift"]
        for f in files where !allowed.contains(f.lastPathComponent) {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("//") { continue }
                if l.contains("UserDefaults.standard") {
                    offenders.append("\(f.lastPathComponent):\(i + 1): UserDefaults.standard")
                }
                if l.contains("@AppStorage(") && !l.contains("store:") {
                    offenders.append("\(f.lastPathComponent):\(i + 1): @AppStorage without store:")
                }
            }
        }
        #expect(offenders.isEmpty, "A state's settings would leak into the bundle's shared domain:\n\(offenders.joined(separator: "\n"))")
    }

    @Test("The default state uses the bundle's own domain; another state a suite named after it")
    func suiteNames() {
        #expect(ACDefaults.suiteName(forState: "work") == nil)
        #expect(ACDefaults.suiteName(forState: "repro-42") == "\(ACDefaults.bundleDomain).state.repro-42")
        // The test process runs on the default state.
        #expect(ACDefaults.suiteName == nil)
        #expect(ACDefaults.standard === UserDefaults.standard)
    }

    @Test("A state suite is a real, separate store")
    func suiteIsSeparate() throws {
        let suite = "io.bromure.test.state.\(UUID().uuidString.prefix(8))"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(42, forKey: "automation.port")
        #expect(d.integer(forKey: "automation.port") == 42)
        #expect(UserDefaults.standard.integer(forKey: "automation.port") != 42 || UserDefaults.standard.object(forKey: "automation.port") == nil)
    }
}
