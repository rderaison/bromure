import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

@Suite("Sandbox drawer: allowing a path the sandbox refused")
struct SandboxPathAllowTests {
    static let flow = """
    version: 1
    network_policies:
      github:
        endpoints:
          - { host: github.com, port: 443 }
    # keep me
    filesystem_policy:
      include_workdir: true
      read_only: [/bin, /usr, /lib]
      read_write: [/home/ubuntu, /tmp]
    landlock:
      compatibility: best_effort
    """

    @Test("A flow list gets the path appended; comments and other keys stay")
    func flowList() throws {
        let out = try OpenShellPolicy.addingFilesystemPath("/opt/grok", readWrite: false, to: Self.flow)
        #expect(out.contains("read_only: [/bin, /usr, /lib, /opt/grok]"))
        #expect(out.contains("# keep me"))
        #expect(out.contains("read_write: [/home/ubuntu, /tmp]"))
        #expect(try OpenShellPolicy.parse(out).filesystem?.readOnly.contains("/opt/grok") == true)
    }

    @Test("A path already listed comes back unchanged")
    func alreadyListed() throws {
        #expect(try OpenShellPolicy.addingFilesystemPath("/usr", readWrite: false, to: Self.flow) == Self.flow)
    }

    @Test("A block list gets a new item; a missing key is added")
    func blockListAndMissingKey() throws {
        let block = """
        version: 1
        filesystem_policy:
          read_only:
            - /usr
            - /lib
        """
        let out = try OpenShellPolicy.addingFilesystemPath("/srv/data", readWrite: true, to:
            try OpenShellPolicy.addingFilesystemPath("/opt", readWrite: false, to: block))
        let fs = try #require(try OpenShellPolicy.parse(out).filesystem)
        #expect(fs.readOnly == ["/usr", "/lib", "/opt"])
        #expect(fs.readWrite == ["/srv/data"])
    }

    @Test("No filesystem_policy section: refused, not invented")
    func noSection() {
        #expect(throws: (any Error).self) {
            try OpenShellPolicy.addingFilesystemPath("/opt", readWrite: false, to: "version: 1\n")
        }
    }

    @Test("The folder an allow grants: a tool's install folder, or the file's own folder at home")
    func folderGuess() {
        #expect(PolicyDrawer.folder(for: "/opt/grok/downloads/grok-linux-aarch64") == "/opt/grok")
        #expect(PolicyDrawer.folder(for: "/srv") == "/srv")
        #expect(PolicyDrawer.folder(for: "/home/ubuntu/.config/gh/hosts.yml") == "/home/ubuntu/.config/gh")
    }
}

/// Finding (CWE-670): "Sandbox badge stops counting after the drawer has been
/// opened once". The drawer is only hidden when closed, and its 15 s clock
/// (and a workspace switch) marked the workspace on stage as seen anyway,
/// so the toolbar badge stayed at 0 for the window's life.
@Suite("Sandbox drawer: only an open drawer marks blocks as seen")
@MainActor
struct PolicyDrawerSeenTests {
    @Test("closed: the clock and a workspace switch don't mark it seen; open and closing do")
    func seenOnlyWhileOpen() {
        let list = SessionListModel()
        let ws = UUID()
        list.selectedID = ws
        let t0 = Date(timeIntervalSince1970: 1000)
        PolicyDrawer.markSeen(list, now: t0)                  // closed: a hidden drawer's tick
        #expect(list.policyDrawerSeen[ws] == nil)
        list.policyDrawerOpen = true
        PolicyDrawer.markSeen(list, now: t0)
        #expect(list.policyDrawerSeen[ws] == t0)
        list.policyDrawerOpen = false
        PolicyDrawer.markSeen(list, closing: true, now: t0.addingTimeInterval(5))
        #expect(list.policyDrawerSeen[ws] == t0.addingTimeInterval(5))
        PolicyDrawer.markSeen(list, now: t0.addingTimeInterval(60))   // later ticks, closed
        #expect(list.policyDrawerSeen[ws] == t0.addingTimeInterval(5))
        let other = UUID()
        list.selectedID = other                                     // switched, still closed
        PolicyDrawer.markSeen(list, now: t0.addingTimeInterval(70))
        #expect(list.policyDrawerSeen[other] == nil)
    }
}
