import Foundation
import Testing
@testable import bromure_ac

/// Under the strict sandbox (OpenShell's process layer), the main seccomp
/// filter refused `socket(AF_VSOCK, …)`, as OpenShell's does. Bromure's
/// in-guest helpers the agent starts (its MCP servers, the Claude/Codex token
/// agents, the plan driver, the VM bridge) reach the host over vsock, so none
/// of them worked: no Bromure MCP tools, no token-mode sign-in. Until 5.4.3
/// bridges them through agentd, the sandbox lets vsock through; the filter's
/// builder keeps OpenShell's ban as its default, which the differential
/// harness compares against.
@Suite("The strict sandbox lets Bromure's helpers reach the host over vsock")
struct StrictSandboxVsockTests {
    private static let setup = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.setup.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("the filter bans vsock only when asked to; the sandbox doesn't ask")
    func vsockAllowed() throws {
        let osh = try source("bromure_openshell.py")
        // The builder: OpenShell's ban by default, lifted by allow_vsock.
        #expect(osh.contains("def build_main_filter_rules(allow_inet=True, allow_vsock=False):"))
        #expect(osh.contains("blocked_domains = [AF_PACKET, AF_BLUETOOTH]\n    if not allow_vsock:\n        blocked_domains.append(AF_VSOCK)"))
        #expect(!osh.contains("blocked_domains = [AF_PACKET, AF_BLUETOOTH, AF_VSOCK]"))
        // What the sandbox installs: vsock allowed, all the way down.
        #expect(osh.contains("child_hardening=True, allow_vsock=True):"))
        #expect(osh.contains("build_main_filter_rules(allow_inet, allow_vsock)"))
        #expect(osh.contains("child_hardening=True, allow_inet=True, allow_vsock=True):"))
        #expect(osh.contains("allow_vsock=allow_vsock)"))
        let sandboxd = try source("bromure-sandboxd")
        let call = try #require(sandboxd.range(of: "osh.enforce(prepared, outcome, supervisor_tgid=tgid,"))
        #expect(sandboxd[call.upperBound...].prefix(400).contains("allow_vsock=True)"))
        // The other socket bans stay.
        #expect(osh.contains("entry(SYS[\"socket\"]).append([(0, OP_EQ, AF_NETLINK), (2, OP_NE, NETLINK_ROUTE)])"))
    }
}
