import Foundation
import Testing
@testable import SandboxEngine

@Suite("OpenShell boundary check (native)")
struct OpenShellBoundaryTests {
    private func p(_ s: String) throws -> OpenShellPolicy { try OpenShellPolicy.parse(s) }

    static let boundary = """
    version: 1
    filesystem_policy:
      read_only: [/usr, /etc]
      read_write: [/tmp]
    network_policies:
      github:
        endpoints:
          - { host: api.github.com, port: 443, protocol: rest, enforcement: enforce, access: read-write }
          - { host: "**.githubusercontent.com", port: 443 }
        binaries: [{ path: /usr/bin/gh }, { path: /usr/bin/git }]
      registries:
        endpoints:
          - { host: registry.npmjs.org, port: 443 }
          - { host: pypi.org, ports: [443] }
        binaries: [{ path: /usr/bin/node }, { path: "/usr/bin/python3*" }]
      internal:
        endpoints: [{ host: api.internal.example, port: 443, allowed_ips: [10.20.0.0/16] }]
    """

    @Test("A narrower policy is within the boundary")
    func within() throws {
        let c = try p("""
        version: 1
        filesystem_policy:
          read_only: [/usr]
        network_policies:
          gh:
            endpoints:
              - { host: api.github.com, port: 443, protocol: rest, enforcement: enforce, access: read-only }
              - { host: "**.githubusercontent.com", port: 443 }
            binaries: [{ path: /usr/bin/gh }]
          npm:
            endpoints: [{ host: registry.npmjs.org, port: 443 }]
            binaries: [{ path: /usr/bin/node }]
          internal:
            endpoints: [{ host: api.internal.example, port: 443, allowed_ips: [10.20.1.0/24] }]
        """)
        let r = OpenShellBoundary.check(candidate: c, boundary: try p(Self.boundary))
        #expect(r == .withinBoundary, "\(r)")
    }

    @Test("New hosts, ports, methods, writes and binaries exceed it")
    func exceeds() throws {
        let b = try p(Self.boundary)
        func result(_ yaml: String) throws -> OpenShellBoundary.Result {
            OpenShellBoundary.check(candidate: try p("version: 1\n" + yaml), boundary: b)
        }
        let cases = [
            "network_policies:\n  x:\n    endpoints: [{ host: evil.example.com, port: 443 }]\n",
            "network_policies:\n  x:\n    endpoints: [{ host: pypi.org, port: 8443 }]\n    binaries: [{ path: /usr/bin/python3.12 }]\n",
            "network_policies:\n  x:\n    endpoints: [{ host: api.github.com, port: 443, protocol: rest, enforcement: enforce, rules: [{ allow: { method: DELETE, path: /repos/** } }] }]\n    binaries: [{ path: /usr/bin/gh }]\n",
            "network_policies:\n  x:\n    endpoints: [{ host: api.github.com, port: 443 }]\n    binaries: [{ path: /usr/bin/gh }]\n",
            "network_policies:\n  x:\n    endpoints: [{ host: registry.npmjs.org, port: 443 }]\n    binaries: [{ path: /usr/bin/curl }]\n",
            "network_policies:\n  x:\n    endpoints: [{ host: api.internal.example, port: 443, allowed_ips: [10.0.0.0/8] }]\n",
            "filesystem_policy:\n  read_write: [/etc]\n",
        ]
        for c in cases {
            guard case .exceedsBoundary = try result(c) else {
                Issue.record("expected exceeds for:\n\(c)\ngot \(try result(c))")
                continue
            }
        }
    }

    @Test("Undecidable comparisons are unsupported, never a pass")
    func unsupported() throws {
        let b = try p(Self.boundary)
        let exactUnderGlob = try p("version: 1\nnetwork_policies:\n  x:\n    endpoints: [{ host: pypi.org, port: 443 }]\n    binaries: [{ path: /usr/bin/python3.12 }]\n")
        guard case .unsupported = OpenShellBoundary.check(candidate: exactUnderGlob, boundary: b) else {
            Issue.record("exact binary under a glob must be unsupported"); return
        }
        let mcp = try p("version: 1\nnetwork_policies:\n  x:\n    endpoints: [{ host: api.github.com, port: 443, protocol: mcp, rules: [{ allow: { method: tools/list } }] }]\n")
        guard case .unsupported = OpenShellBoundary.check(candidate: mcp, boundary: b) else {
            Issue.record("mcp must be unsupported"); return
        }
        // Prover rule: an exact host under a wildcard without allowed_ips is undecidable.
        let underWildcard = try p("version: 1\nnetwork_policies:\n  x:\n    endpoints: [{ host: raw.githubusercontent.com, port: 443 }]\n")
        guard case .unsupported = OpenShellBoundary.check(candidate: underWildcard, boundary: b) else {
            Issue.record("exact host under wildcard must be unsupported"); return
        }
        let nested = try p("version: 1\nfilesystem_policy:\n  read_write: [/tmp/cache]\n")
        guard case .unsupported = OpenShellBoundary.check(candidate: nested, boundary: b) else {
            Issue.record("nested path must be unsupported"); return
        }
    }
}
