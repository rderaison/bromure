import Foundation
import Testing
@testable import bromure_ac

/// e2e 34 (OpenShell sandbox, strict): a strict workspace whose policy has no
/// `process` section had Landlock and nothing else -- `NoNewPrivs: 0`,
/// `Seccomp: 0`, memfd / ptrace / user namespaces allowed. agentd's root script
/// starts the supervisor before it marks the revocation done, and the process
/// layer needed that marker too when the policy had no `process` section.
@Suite("The strict sandbox brings the process layer, process section or not")
struct StrictSandboxProcessLayerTests {
    private static let setup = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")

    @Test("strict requested is enough; the supervisor starts before the revocation is marked")
    func requestedIsEnough() throws {
        let sandboxd = try String(contentsOf: Self.setup.appendingPathComponent("bromure-sandboxd"), encoding: .utf8)
        #expect(sandboxd.contains("    apply_seccomp = strict_applied or strict_requested\n"))
        #expect(!sandboxd.contains("(policy.process.present or strict_applied)"))
        // A process section without strict still only warns (it would kill sudo).
        #expect(sandboxd.contains("if policy.process.present and not (strict_applied or strict_requested):"))
        // The boot order this covers: the supervisor starts, THEN the marker.
        let agentd = try String(contentsOf: Self.setup.appendingPathComponent("bromure-agentd.py"), encoding: .utf8)
        let start = try #require(agentd.range(of: "systemd-run --unit=bromure-sandboxd"))
        let marked = try #require(agentd.range(of: "touch %(done)s"))
        #expect(start.lowerBound < marked.lowerBound)
    }
}
