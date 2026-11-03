import Foundation
import Testing

/// The iOS client compiles a subset of Sources/AgentCoding (scripts/
/// gen-ios-sources.py). 0f048335 made the shared Profile.swift store
/// `MintedCredential` and the shared guardrail policy call
/// `AWSResigner.isAWSHost` -- both declared in mac-only proxy files -- and
/// the iOS app stopped building; a fresh resolve then also picked SwiftTerm
/// 1.99 (v2's pre-release, `getTerminal()` gone).
@Suite("iOS shared sources stay buildable")
struct IOSSharedSourcesTests {
    static let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }

    static func sharedFiles() throws -> [String] {
        let gen = try src("scripts/gen-ios-sources.py")
        let start = try #require(gen.range(of: "SHARED = ["))
        let end = try #require(gen[start.upperBound...].range(of: "\n]"))
        return gen[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let close = t.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(t[t.index(after: t.startIndex)..<close])
        }
    }

    /// The text outside `#if os(macOS)` / `#if canImport(AppKit)` blocks
    /// (their `#else` branch kept): what the iOS compiler reads.
    static func withoutMacOnlyBlocks(_ text: String) -> String {
        var out: [Substring] = [], stack: [Bool] = []   // true: a mac-only branch is skipping
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if") {
                stack.append(t == "#if os(macOS)" || t == "#if canImport(AppKit)")
                continue
            }
            if t.hasPrefix("#else") || t.hasPrefix("#elseif") { if !stack.isEmpty { stack[stack.count - 1] = false }; continue }
            if t.hasPrefix("#endif") { _ = stack.popLast(); continue }
            if !stack.contains(true) { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    @Test("the minted-credential record and the AWS host test are shared; the mint engine and resigner aren't needed")
    func mintedCredentialShared() throws {
        let shared = try Self.sharedFiles()
        #expect(shared.contains("Mitm/MintedCredential.swift"))
        #expect(shared.contains("Mitm/AWSHosts.swift"))
        #expect(!shared.contains("Mitm/AWSResigner.swift") && !shared.contains("Mitm/CredentialMint.swift"))
        // Mac-only proxy types a shared file must not name.
        for file in shared {
            let s = Self.withoutMacOnlyBlocks(try Self.src("Sources/AgentCoding/" + file))
            for macOnly in ["AWSResigner.", "CredentialMint.", "TokenMap"] {
                #expect(!s.contains(macOnly), "\(file) uses mac-only \(macOnly)")
            }
        }
    }

    @Test("SwiftTerm stays on 1.20.x, below v2's 1.99 pre-release")
    func swiftTermPinned() throws {
        #expect(try Self.src("ios/BromureRemote/Package.swift").contains(#"SwiftTerm.git", .upToNextMinor(from: "1.20.0"))"#))
        #expect(try Self.src("scripts/gen-ios-project.py").contains(#""upToNextMinorVersion", "1.20.0"),"#))
    }
}
