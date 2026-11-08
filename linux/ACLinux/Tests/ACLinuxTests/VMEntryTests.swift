import Foundation
import Testing
@testable import ACLinux

/// A running VM's /vms entry carries macOS's fields: its workspace's, its
/// disk, its listening ports and docker state from the outbox (containers
/// with their stats and arch merged by short id).
@Suite("VM entry fields")
struct VMEntryTests {
    @Test func aRunningVMsEntryHasMacOSsFields() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var rec = RepairMarksTests.stopped(UUID().uuidString.lowercased())
        rec.state = .running
        rec.kube = "cluster-1"
        try await d.registerForTesting(rec)
        let outbox = await d.vmDir(rec.id) + "/outbox/"
        try FileManager.default.createDirectory(atPath: outbox, withIntermediateDirectories: true)
        func put(_ name: String, _ s: String) throws { try s.write(toFile: outbox + name, atomically: true, encoding: .utf8) }
        try put("ports.txt", "tcp LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:* users:((\"node\",pid=9,fd=3))\nudp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:*\n")
        try put("docker.txt", #"{"ID":"0123456789abcdef","Names":"web","Image":"nginx","Status":"Up 2 minutes","State":"running","Ports":"80/tcp"}"# + "\n")
        try put("docker-stats.txt", #"{"ID":"0123456789ab","CPUPerc":"1.5%","MemUsage":"10MiB / 1GiB"}"# + "\n")
        try put("docker-arch.txt", "0123456789ab\tamd64\n")
        try put("docker-images.txt", #"{"ID":"sha256:1","Repository":"nginx","Tag":"latest","Size":"50MB"}"# + "\n")
        try put("docker-volumes.txt", #"{"Name":"data","Driver":"local"}"# + "\n")
        try put("docker-binfmt.txt", "arm64 riscv64\n")
        guard case .object(let o) = await d.vmEntry(rec) else { Issue.record("not an object"); return }
        #expect(o["kubeClusterID"] == .string("cluster-1"))
        #expect(o["diskPath"] == .string(await d.vmDir(rec.id) + "/disk.raw"))
        #expect(o["diskAllocatedBytes"] == .number(0), "no disk yet")
        guard case .array(let ports)? = o["listeningPorts"] else { Issue.record("no ports"); return }
        #expect(ports.count == 2)
        #expect(ports.first == ["proto": "udp", "addr": "127.0.0.53", "port": .number(53), "process": ""])
        guard case .array(let cs)? = o["dockerContainers"], case .object(let c)? = cs.first else { Issue.record("no containers"); return }
        #expect(c["name"] == "web" && c["state"] == "running")
        #expect(c["cpuPerc"] == "1.5%" && c["memUsage"] == "10MiB / 1GiB" && c["arch"] == "amd64", "stats and arch merged by short id")
        #expect(o["dockerBinfmt"] == .array(["arm64", "riscv64"]))
        guard case .array(let im)? = o["dockerImages"], case .array(let vols)? = o["dockerVolumes"] else { Issue.record("no images/volumes"); return }
        #expect(im.count == 1 && vols.count == 1)
        // GET /vms/<id> is the same entry, as on macOS.
        let r = await d.getVM(rec)
        guard case .object(let g) = r.body else { Issue.record("not an object"); return }
        #expect(g["dockerBinfmt"] == .array(["arm64", "riscv64"]))
        await d.shutdown()
    }
}
