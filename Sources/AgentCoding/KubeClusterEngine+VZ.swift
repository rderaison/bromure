#if os(macOS)
import Foundation
import SandboxEngine
import Virtualization

// The macOS machine host of the Kubernetes engine (KubeEngineHost): node,
// registry and connector machines are synthetic profiles booted through the
// same SessionDisk + UbuntuSandboxVM path as a workspace, registered in
// `runningSessions` so the CLI (`vm exec k8s-dev-1 -- kubectl get nodes`),
// the forward resolver and the quit drain all see them.
extension ACAppDelegate: KubeEngineHost {
    /// The synthetic profile a managed machine runs as.
    static func kubeMachineProfile(_ m: KubeClusterEngine.MachineSpec) -> Profile {
        var profile = Profile(id: m.record.id, name: m.record.name, tool: .claude, authMode: .token,
                              homeModel: .virtiofs)
        profile.memoryGB = m.memoryGB
        profile.memoryMB = m.memoryMB
        return profile
    }

    /// The profile a managed machine boots as: kubeMachineProfile plus how
    /// it closes, looks and what it shares.
    static func kubeMachineBootProfile(_ m: KubeClusterEngine.MachineSpec) -> Profile {
        var profile = Self.kubeMachineProfile(m)
        // Quitting the app suspends the machine (RAM snapshot, like a
        // workspace), and the next start resumes it. It used to shut down on
        // quit with the workspace's 15 s grace: a k3s node (containerd, etcd,
        // Longhorn) routinely takes longer, was force-stopped mid-shutdown,
        // and came back with a dirty filesystem. An explicit Stop still
        // shuts down (with a longer grace — see stopSession).
        profile.closeAction = .suspend
        profile.color = .gray
        profile.nativeTerminal = true
        profile.comments = m.comment
        profile.folderPaths = m.folders
        return profile
    }

    func makeKubeMachine(_ m: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime,
                         fsFailure: KubeClusterEngine.BootFSFailure, engine: KubeClusterEngine) throws {
        let id = m.ownerID
        let node = m.record
        let nodes = engine.nodeStore(id)
        let profile = Self.kubeMachineBootProfile(m)

        let sessionDisk = SessionDisk(profile: profile, store: nodes, baseDiskURL: imageManager.baseDiskURL)
        sessionDisk.tokenPlan = nil
        if let mitm = mitmEngine, let scriptURL = bridgeScriptURL {
            sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                caCertificatePEM: mitm.ca.certificatePEM,
                bridgeScriptURL: scriptURL,
                awsCredsHelperURL: awsCredsHelperURL,
                claudeTokenAgentURL: claudeTokenAgentURL,
                codexTokenAgentURL: codexTokenAgentURL,
                shellAgentURL: shellAgentURL,
                loopbackRelayAgentURL: loopbackRelayAgentURL,
                agentdURL: agentdURL)
        }
        let sandbox = UbuntuSandboxVM(imageManager: imageManager, sessionDisk: sessionDisk)
        sandbox.cpuCountOverride = m.cpus
        if let gb = m.dataDiskGB {
            let dataURL = nodes.profileDirectory(for: profile).appendingPathComponent("data.img")
            try KubeClusterEngine.ensureSparseImage(at: dataURL, gigabytes: gb)
            sandbox.extraDiskURLs = [dataURL]
        }
        runtime.machine = sandbox

        sandbox.onIPUpdate = { [weak self] ip in
            Task { @MainActor in
                guard let self else { return }
                runtime.ip = ip
                self.runningSessions[node.id]?.lastIP = ip
            }
        }
        sandbox.onStopped = { [weak engine] error in
            Task { @MainActor in engine?.nodeStopped(clusterID: id, nodeID: node.id, error: error) }
        }
        // The console scanner (the workspace path's detector) reports a
        // boot dying on filesystem errors; the engine repairs and reboots.
        sandbox.onBootFilesystemFailure = { detail in
            Task { @MainActor in if fsFailure.detail == nil { fsFailure.detail = detail } }
        }
    }

    func startKubeMachine(_ m: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime,
                          repairAttempted: Bool, engine: KubeClusterEngine) async throws {
        let id = m.ownerID
        let node = m.record
        let nodes = engine.nodeStore(id)
        let profile = Self.kubeMachineBootProfile(m)
        guard let sandbox = runtime.machine as? UbuntuSandboxVM, let sessionDisk = sandbox.sessionDisk else {
            throw KubeClusterEngine.KubeError.message("\(node.name): not laid out")
        }
        try nodes.prepareHomeDirectory(for: profile, terminalDefaults: terminalDefaults)
        try sandbox.prepare()
        try KubeClusterEngine.stageScripts(m.scripts, into: nodes.profileDirectory(for: profile))
        if sandbox.hasSavedState, m.restoreSavedState, !repairAttempted {
            do {
                try await sandbox.restore()
                engine.log(id, "\(node.name) resumed from its saved state")
            } catch {
                // Same fallback as a workspace: a snapshot that won't restore
                // (an app or base-image update since the quit, VZ refused)
                // can't come back by any path — boot fresh from the disk.
                let drift = sandbox.lastRestoreDrift.map { " (configuration changed: \($0))" }
                    ?? " (\(error.localizedDescription))"
                engine.log(id, "\(node.name): saved state didn't restore\(drift) — booting fresh")
                sessionDisk.clearSavedState()
                // Stop the failed instance first: it may hold the disk, and
                // its late stop mustn't read as the fresh boot's.
                await sandbox.discardFailedRestore()
                try sandbox.prepare()
                // prepare() lays the meta share out again: the scripts staged
                // above are gone with it (a connector booted without its
                // bromure-msgbridge.sh can't start).
                try KubeClusterEngine.stageScripts(m.scripts, into: nodes.profileDirectory(for: profile))
                try await sandbox.start()
            }
        } else {
            sessionDisk.clearSavedState()
            try await sandbox.start()
        }

        guard let dev = sandbox.socketDevice else {
            throw KubeClusterEngine.KubeError.message("\(node.name): no vsock device")
        }
        // Egress through the host MITM (apt, the k3s installer, image pulls)
        // with an empty swap map — nothing to substitute on a node.
        mitmEngine?.register(socketDevice: dev, profileID: node.id)
        shellBridges[node.id] = ShellBridge(socketDevice: dev)
        let session = registerSession(sandbox, profile: profile)
        session.kubeClusterID = id
    }

    func kubeHostIPv4() -> String? { HostNetwork.primaryIPv4() }

    func parseKubeLANPool(_ text: String) -> [UInt32]? { KubeLANPool.parse(text) }

    func makeKubeLoadBalancer(engine: KubeClusterEngine, clusterID: UUID, serverNodeID: UUID,
                              serverIP: String, hostIP: String?, pool: [UInt32]) -> (any KubeServicePublisher)? {
        KubeLoadBalancer(engine: engine, clusterID: clusterID, serverNodeID: serverNodeID,
                         serverIP: serverIP, hostIP: hostIP, pool: pool)
    }

    func kubeMachineAnswers(_ nodeID: UUID) -> Bool { (shellBridges[nodeID]?.poolSize ?? 0) > 0 }

    func setKubeMachineIP(_ nodeID: UUID, _ ip: String) { runningSessions[nodeID]?.lastIP = ip }

    func stopKubeMachine(_ nodeID: UUID) async { await stopSession(nodeID, action: .shutdown) }

    func kubeMachineStopped(_ nodeID: UUID) { handleSessionStopped(profileID: nodeID) }

    /// Take a machine wedged in its emergency shell down for a disk repair
    /// (the engine already dropped it from its runtime), forgetting any
    /// snapshot (it's worthless, and invalid once the disk changes).
    func stopKubeMachineForRepair(_ runtime: KubeClusterEngine.NodeRuntime) async {
        let nodeID = runtime.record.id
        guard let sandbox = runtime.machine as? UbuntuSandboxVM else { return }
        sandbox.sessionDisk?.clearSavedState()
        if let vm = sandbox.vm, vm.state != .stopped {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                vm.stop { _ in cont.resume() }
            }
        }
        handleSessionStopped(profileID: nodeID)
    }

    /// Replay the journal and repair the machine's system disk — and its
    /// data disk (Longhorn / registry storage), which the guest checks at
    /// boot too — with the Mac-side ext4 checker the workspaces use.
    /// True when every ext4 image came out clean or repaired.
    func repairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec) async -> Bool {
        let profile = Self.kubeMachineProfile(m), ownerID = m.ownerID
        let nodes = kubeClusterEngine.nodeStore(ownerID)
        var ok = true
        var images = [nodes.diskURL(for: profile)]
        let data = nodes.profileDirectory(for: profile).appendingPathComponent("data.img")
        if FileManager.default.fileExists(atPath: data.path) { images.append(data) }
        for url in images {
            let path = url.path
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Ext4Fsck.Result, Error> in
                do { return .success(try Ext4Fsck.check(imagePath: path, autoFix: true)) }
                catch { return .failure(error) }
            }.value
            switch result {
            case .success(let r):
                if !(r.clean || r.repaired) { ok = false }
                kubeClusterEngine.log(ownerID, "fsck \(url.lastPathComponent): \(r.summary)")
                FileHandle.standardError.write(Data(
                    "[kube] fsck \(profile.name) \(url.lastPathComponent): \(r.summary)\n\(r.output)\n".utf8))
            case .failure(let error):
                // A data disk the guest never formatted is not ext4 yet —
                // nothing to check there.
                kubeClusterEngine.log(ownerID, "fsck \(url.lastPathComponent): skipped (\(error))")
            }
        }
        return ok
    }

    /// e2fsck in the guest, over every ext4 filesystem in the images it is
    /// given (whole-disk or partitioned, attached as loop devices AFTER boot).
    /// Exit 0-3 = consistent now; 4+ = errors left.
    static let kubeRescueFsckScript = #"""
    set -u
    rc=0
    for img in "$@"; do
      [ -f "$img" ] || continue
      L=$(sudo losetup -fP --show "$img") || { echo "fsck: cannot attach $img"; rc=8; continue; }
      sudo udevadm settle 2>/dev/null || sleep 1
      for dev in "$L" "$L"p*; do
        [ -b "$dev" ] || continue
        [ "$(sudo blkid -p -o value -s TYPE "$dev" 2>/dev/null)" = ext4 ] || continue
        sudo e2fsck -fy "$dev" >/tmp/bromure-fsck.log 2>&1; r=$?
        echo "fsck: $(basename "$img") $(basename "$dev") exit=$r"
        tail -n 3 /tmp/bromure-fsck.log | sed 's/^/  /'
        [ "$r" -ge 4 ] && rc=4
      done
      sudo losetup -d "$L"
    done
    sync
    exit $rc
    """#

    /// The Mac-side checker only replays journals and clears the error flag;
    /// anything past that needs the real e2fsck. Boot a throwaway machine
    /// from the base image with the damaged machine's folder shared in, and
    /// check its images through loop devices set up after boot — never as
    /// block devices at boot: every clone of the base carries the same
    /// filesystem UUID and label, so the rescue could come up on the damaged
    /// disk. The throwaway is deleted afterwards either way.
    func deepRepairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec, engine: KubeClusterEngine) async throws {
        let profile = Self.kubeMachineProfile(m), ownerID = m.ownerID
        let nodes = engine.nodeStore(ownerID)
        let dir = nodes.profileDirectory(for: profile)
        var names = ["disk.img"]
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("data.img").path) {
            names.append("data.img")
        }
        let rescue = KubeNodeRecord(name: "rescue-\(profile.name)", role: .agent, index: 0)
        let scratch = KubeClusterEngine.ClusterRuntime(id: ownerID)   // keep it out of the cluster's node list
        defer {
            try? FileManager.default.removeItem(at: nodes.profileDirectory(
                for: Profile(id: rescue.id, name: rescue.name, tool: .claude, authMode: .token, homeModel: .virtiofs)))
            MACBindings.shared.release(profileID: rescue.id)
        }
        do {
            _ = try await engine.bootMachine(KubeClusterEngine.MachineSpec(
                ownerID: ownerID, record: rescue, cpus: 2, memoryGB: 2, dataDiskGB: nil,
                comment: "Disk repair for \(profile.name) — managed by Bromure, deleted when done.",
                scripts: [], ipCommand: "hostname -I | awk '{print $1}'",
                restoreSavedState: false, folders: [dir.path]), rt: scratch, repairAttempted: true)
            let args = names.map { "/mnt/bromure-share-1/\($0)" }.joined(separator: " ")
            let b64 = Data(Self.kubeRescueFsckScript.utf8).base64EncodedString()
            let out = try await engine.exec(rescue.id,
                "echo \(b64) | base64 -d > /tmp/bromure-rescue-fsck.sh && bash /tmp/bromure-rescue-fsck.sh \(args); echo \"rc=$?\"",
                timeout: 900)
            for line in out.split(separator: "\n") where line.hasPrefix("fsck:") { kubeClusterEngine.log(ownerID, String(line)) }
            FileHandle.standardError.write(Data("[kube] rescue e2fsck for \(profile.name):\n\(out)\n".utf8))
            await stopSession(rescue.id, action: .shutdown)
            if out.contains("rc=4") || out.contains("rc=8") {
                throw KubeClusterEngine.KubeError.message("e2fsck couldn't make \(profile.name)'s disk consistent")
            }
        } catch {
            if runningSessions[rescue.id] != nil { await stopSession(rescue.id, action: .shutdown) }
            throw error
        }
    }

    /// Same path the fat-client forward resolver uses (the app process can't
    /// TCP-dial its own guests; the guest's loopback relay can).
    /// Same path the fat-client forward resolver uses (the app process can't
    /// TCP-dial its own guests; the guest's loopback relay can).
    func openKubeRelay(nodeID: UUID, target: String, completion: @escaping @Sendable (Int32) -> Void) {
        guard let session = runningSessions[nodeID], let dev = session.sandbox.socketDevice else {
            completion(-1); return
        }
        dev.connect(toPort: 5010) { result in
            switch result {
            case .success(let conn):
                let vfd = conn.fileDescriptor
                let header = "\(target)\n"
                let sent = header.withCString { Darwin.write(vfd, $0, strlen($0)) }
                guard sent > 0 else { completion(-1); return }
                let dupFD = dup(vfd)
                // Keep the VZ connection object alive for as long as the
                // splice uses the dup'd descriptor.
                KubeRelayRetain.hold(conn, forFD: dupFD)
                completion(dupFD)
            case .failure:
                completion(-1)
            }
        }
    }
}

#endif
