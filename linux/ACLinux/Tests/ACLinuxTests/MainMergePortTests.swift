import Foundation
import Testing
@testable import ACLinux

/// What the Linux daemon took from main's merge (2871a5de): Claude Code's
/// dangerous-rm bypass exported only with no host folder shared in, the
/// workspace row's browser settings, the DNS names the network lineage
/// reads, and the host-sleep measure behind the clock resync.
@Suite("Ports after the main merge")
struct MainMergePortTests {
    /// api_key.env exports `claudeYoloEnv` when asked, and not otherwise.
    @Test func apiKeyEnvExportsTheYoloEnvOnlyWhenAsked() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let meta = URL(fileURLWithPath: dir + "/meta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        let store = ProfileStore(rootDir: URL(fileURLWithPath: dir + "/profiles", isDirectory: true))
        let p = Profile(name: "y", tool: .claude, authMode: .token)
        let line = "export \(SessionDisk.claudeYoloEnv)=1"
        try Daemon.writeCredentialFiles(p, plan: nil, registration: false, meta: meta, kubeYAML: nil,
                                        claudeYolo: true, store: store, seedStandIns: { _, _ in })
        let on = try String(contentsOf: meta.appendingPathComponent("api_key.env"), encoding: .utf8)
        #expect(on.contains(line), "\(on)")
        try Daemon.writeCredentialFiles(p, plan: nil, registration: false, meta: meta, kubeYAML: nil,
                                        store: store, seedStandIns: { _, _ in })
        let off = try String(contentsOf: meta.appendingPathComponent("api_key.env"), encoding: .utf8)
        #expect(!off.contains(SessionDisk.claudeYoloEnv), "\(off)")
    }

    @Test func theWorkspaceRowCarriesItsBrowserSettings() {
        var p = Profile(name: "b", tool: .claude, authMode: .token)
        p.browserDisabled = true
        let f = Daemon.browserRowFields(p)
        #expect(f["browserDisabled"] == true)
        #expect(Set(f.keys) == ["browserDisabled", "browserPersistent", "browserAllowUploads",
                                "browserAllowDownloads", "browserWebcam", "browserMicrophone"])
    }

    @Test func dottedIPv4Parses() {
        #expect(Daemon.ipv4("10.0.2.15") == 0x0A00_020F)
        #expect(Daemon.ipv4("256.0.0.1") == nil)
        #expect(Daemon.ipv4("::1") == nil)
        #expect(Daemon.ipv4("1.2.3") == nil)
    }

    @Test func timeSleptIsNeverNegative() {
        #expect(Daemon.sleptSinceBoot() >= 0)
    }
}

extension DaemonGlobalSuites {
    /// Claude Code's dangerous-rm bypass on a daemon's VM: by its host shares.
    @Suite("The yolo env and host shares", .serialized)
    struct YoloHostShareTests {
        /// A VM with a host folder shared in never gets it, even after its
        /// folders are dropped (the share stays until a restart); one without
        /// does.
        @Test func theYoloEnvFollowsTheHostShares() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            var rec = DrainTests.rec("y")
            try FileManager.default.createDirectory(atPath: await d.vmDir(rec.id), withIntermediateDirectories: true)
            await d.noteHostShares(rec)
            #expect(await d.exportsClaudeYoloEnv(rec), "no shares: exported")
            rec.folders = [dir]
            await d.noteHostShares(rec)
            #expect(await !d.exportsClaudeYoloEnv(rec), "a host folder shared in: not exported")
            rec.folders = []
            #expect(await !d.exportsClaudeYoloEnv(rec), "dropped live, still attached: still not")
            await d.noteHostShares(rec)
            #expect(await d.exportsClaudeYoloEnv(rec), "relaunched without: exported again")
        }
    }
}
