import Foundation
import SandboxEngine
import Testing
@testable import bromure_ac

// Kubernetes clusters: the persisted record + access list, the probe the
// guest emits, the /state round-trip the fat client mirrors, and the
// kubeconfig material handed to workspaces.

@Suite("Kubernetes clusters")
@MainActor
struct KubeClusterTests {
    private func tempStore() -> KubeClusterStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kube-\(UUID().uuidString)")
            .appendingPathComponent("clusters.json")
        return KubeClusterStore(fileURL: url)
    }

    @Test("slugs are DNS-label safe and stable")
    func slugs() {
        #expect(KubeCluster.slug(for: "Dev Cluster") == "dev-cluster")
        #expect(KubeCluster.slug(for: "  Ünïcode!! stuff ") == "n-code-stuff")
        #expect(KubeCluster.slug(for: "42") == "k-42")
        #expect(KubeCluster.slug(for: "") == "cluster")
        let c = KubeCluster(name: "My Dev", spec: KubeClusterSpec())
        #expect(c.nodeName(index: 2) == "k8s-my-dev-2")
        #expect(c.contextName == "my-dev")
    }

    @Test("access lists: all vs only, never empty")
    func access() throws {
        let a = UUID(), b = UUID()
        #expect(KubeWorkspaceAccess.all.allows(a))
        let only = KubeWorkspaceAccess.only([a])
        #expect(only.allows(a))
        #expect(!only.allows(b))
        // Removing the last allowed workspace falls back to everyone.
        #expect(only.removing(a) == .all)
        #expect(KubeWorkspaceAccess.only([a, b]).removing(a) == .only([b]))
        // Round-trips; an empty allow-list decodes as .all.
        let enc = JSONEncoder(), dec = JSONDecoder()
        let data = try enc.encode(KubeWorkspaceAccess.only([a, b]))
        #expect(try dec.decode(KubeWorkspaceAccess.self, from: data) == .only([a, b]))
        let empty = Data(#"{"mode":"only","ids":[]}"#.utf8)
        #expect(try dec.decode(KubeWorkspaceAccess.self, from: empty) == .all)
    }

    @Test("spec clamps into its supported ranges")
    func clamp() {
        var s = KubeClusterSpec()
        s.nodeCount = 99; s.cpusPerNode = 0; s.memoryGBPerNode = 1; s.storageDiskGB = 5
        let c = s.clamped
        #expect(c.nodeCount == KubeClusterSpec.nodeRange.upperBound)
        #expect(c.cpusPerNode == KubeClusterSpec.cpuRange.lowerBound)
        #expect(c.memoryGBPerNode == KubeClusterSpec.memoryRange.lowerBound)
        #expect(c.storageDiskGB == KubeClusterSpec.storageRange.lowerBound)
        #expect(c.storageReplicas == 3)
        s.nodeCount = 2
        #expect(s.storageReplicas == 2)
    }

    @Test("store persists clusters and prunes deleted workspaces")
    func persistence() {
        let store = tempStore()
        let ws1 = UUID(), ws2 = UUID()
        var c = KubeCluster(name: "dev", spec: KubeClusterSpec(), access: .only([ws1, ws2]))
        c.nodes = [KubeNodeRecord(name: "k8s-dev-1", role: .server, index: 1, lastIP: "192.168.64.7")]
        store.upsert(c)
        #expect(store.clusters(for: ws1).count == 1)
        #expect(store.clusters(for: UUID()).isEmpty)
        store.workspaceDeleted(ws1)
        #expect(store.cluster(c.id)?.access == .only([ws2]))
        store.workspaceDeleted(ws2)
        #expect(store.cluster(c.id)?.access == .all)

        // A fresh store on the same file sees the saved record.
        let reopened = KubeClusterStore(fileURL: storeFileURL(store))
        #expect(reopened.cluster(c.id)?.name == "dev")
        #expect(reopened.cluster(c.id)?.serverIP == "192.168.64.7")
    }

    /// The store keeps its file URL private; recover it from a save.
    private func storeFileURL(_ store: KubeClusterStore) -> URL {
        // Mirror of KubeClusterStore's default path logic isn't needed: the
        // temp store was created with an explicit URL — reuse the snapshot
        // round-trip instead.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kube-reopen-\(UUID().uuidString).json")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        struct Payload: Codable { var version = 1; var clusters: [KubeCluster] }
        try? enc.encode(Payload(clusters: store.clusters)).write(to: url)
        return url
    }

    @Test("/state snapshot round-trips into a mirror store")
    func snapshotRoundTrip() {
        let host = tempStore()
        let c = KubeCluster(name: "prod", spec: KubeClusterSpec(), access: .all)
        host.upsert(c)
        host.setStatus(c.id) {
            $0.phase = .running
            $0.hostIP = "10.0.0.5"
            $0.lbEndpoints = [KubeLBEndpoint(namespace: "default", service: "web", port: 80,
                                             nodePort: 31080, protocolName: "TCP", bound: true)]
            $0.appendLog("hello")
        }
        let snapshot = host.snapshot()
        // Through JSON, as the control socket would carry it.
        let data = try! JSONSerialization.data(withJSONObject: snapshot)
        let back = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let decoded = KubeClusterStore.decodeSnapshot(back)
        let mirror = KubeClusterStore(mirror: true)
        mirror.mirror(clusters: decoded.clusters, status: decoded.status)
        #expect(mirror.cluster(c.id)?.name == "prod")
        #expect(mirror.status(c.id).phase == .running)
        #expect(mirror.status(c.id).hostIP == "10.0.0.5")
        #expect(mirror.status(c.id).lbEndpoints.first?.nodePort == 31080)
        #expect(mirror.status(c.id).log == ["hello"])
    }

    @Test("probe JSON decodes and aggregates")
    func probe() throws {
        let json = """
        {"at":"2026-09-19T10:00:00Z","reachable":true,"version":"v1.31.4+k3s1","full":true,
         "nodes":[{"name":"k8s-dev-1","ready":true,"roles":["control-plane","master"],"ip":"192.168.64.7",
                   "version":"v1.31.4+k3s1","cpuCapacityM":2000,"memCapacityBytes":4000000000,
                   "cpuUsedM":500,"memUsedBytes":1000000000,"pods":9,"unschedulable":false,"pressure":[]},
                  {"name":"k8s-dev-2","ready":false,"roles":[],"ip":"192.168.64.8","version":"v1.31.4+k3s1",
                   "cpuCapacityM":2000,"memCapacityBytes":4000000000,"cpuUsedM":100,"memUsedBytes":500000000,
                   "pods":2,"unschedulable":false,"pressure":["MemoryPressure"]}],
         "podSummary":{"total":11,"running":10,"pending":1,"failed":0,"succeeded":0,"unknown":0},
         "podsByNamespace":{"kube-system":9,"default":2},
         "services":[{"namespace":"default","name":"web","type":"LoadBalancer","clusterIP":"10.43.0.9",
                      "ports":[{"name":"http","port":80,"nodePort":31080,"protocol":"TCP","targetPort":"8080"}],
                      "ingress":[],"lbClass":""}],
         "deployments":{"total":3,"available":2},
         "longhorn":{"installed":true,"ready":true,"volumes":[],"nodes":[{"name":"k8s-dev-1","ready":true,
                     "schedulable":true,"storageMaximumBytes":40000000000,"storageAvailableBytes":30000000000}]},
         "pods":[],"pvcs":[],"warnings":[],"probeMillis":420}
        """
        let p = try #require(KubeProbe.decode(Data(json.utf8)))
        #expect(p.readyNodes == 1)
        #expect(p.nodes.first?.isControlPlane == true)
        #expect(p.cpuCapacityM == 4000)
        #expect(p.cpuUsedM == 600)
        #expect(abs(p.cpuPercent - 15) < 0.01)
        #expect(p.loadBalancerServices.count == 1)
        #expect(p.loadBalancerServices.first?.ports.first?.nodePort == 31080)
        #expect(p.longhorn?.storageAvailableBytes == 30_000_000_000)
        // A later light probe keeps the heavy tables of the last full one.
        var lightJSON = json.replacingOccurrences(of: "\"full\":true", with: "\"full\":false")
        lightJSON = lightJSON.replacingOccurrences(of: "\"warnings\":[]", with: "\"warnings\":[{\"at\":\"x\",\"reason\":\"BackOff\",\"message\":\"m\",\"object\":\"pod/a\",\"namespace\":\"default\",\"count\":3}]")
        var fullProbe = p
        fullProbe.warnings = [KubeProbe.Warning(at: "t", reason: "Failed", message: "boom", object: "pod/x", namespace: "ns", count: 1)]
        let light = try #require(KubeProbe.decode(Data(lightJSON.utf8)))
        let merged = light.mergingDetails(from: fullProbe)
        #expect(merged.warnings.first?.reason == "Failed")
        #expect(merged.full == false)
    }

    @Test("LAN pools parse ranges, CIDRs and singles")
    func lanPool() {
        let range = KubeLANPool.parse("10.163.15.20-10.163.15.23")
        #expect(range?.count == 4)
        #expect(range?.first.map(VMNetSwitch.ipString) == "10.163.15.20")
        let cidr = KubeLANPool.parse("10.0.0.32/30")
        #expect(cidr?.map(VMNetSwitch.ipString) == ["10.0.0.33", "10.0.0.34"])
        #expect(KubeLANPool.parse("10.0.0.5")?.count == 1)
        #expect(KubeLANPool.parse("10.0.0.9-10.0.0.1") == nil)
        #expect(KubeLANPool.parse("nope") == nil)
        #expect(KubeLANPool.parse("") == nil)
        // Endpoints carry the address they're answered on.
        let e = KubeLBEndpoint(namespace: "default", service: "web", port: 80, nodePort: 31080,
                               protocolName: "TCP", bound: true, ip: "10.163.15.22")
        let data = try! JSONEncoder().encode(e)
        #expect(try! JSONDecoder().decode(KubeLBEndpoint.self, from: data).ip == "10.163.15.22")
    }

    @Test("ARP and Ethernet frames are laid out on the wire")
    func arpFrame() {
        let mac: [UInt8] = [0x02, 0x62, 0x00, 0x00, 0x00, 0x01]
        let f = KubeLANAnnouncer.arpFrame(op: 2, senderMAC: mac, senderIP: 0x0AA30F16,
                                          targetMAC: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff], targetIP: 0x0AA30F16,
                                          dstMAC: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        #expect(f.count == 42)
        #expect(Array(f[12..<14]) == [0x08, 0x06])            // ethertype ARP
        #expect(Array(f[20..<22]) == [0x00, 0x02])            // reply
        #expect(Array(f[22..<28]) == mac)                     // sender MAC
        #expect(Array(f[28..<32]) == [10, 163, 15, 22])       // sender IP
    }

    @Test("UDP relay frames carry the flow's return info")
    func udpFrame() {
        let f = KubeUDPRelay.frame(srcIP: 0x0AA30F05, srcPort: 40000, dstPort: 31053, payload: [1, 2, 3][...])
        #expect(f.count == 2 + 8 + 3)
        #expect(Array(f[0..<2]) == [0, 11])                 // body length
        #expect(Array(f[2..<6]) == [10, 163, 15, 5])        // src IP
        #expect(UtunPacket.u16(f, 6) == 40000)
        #expect(UtunPacket.u16(f, 8) == 31053)
        #expect(Array(f[10...]) == [1, 2, 3])
    }

    @Test("registries: containerd mirrors, records, and the NAS driver files")
    func registriesAndSynology() throws {
        let yaml = KubeRegistriesConfig.yaml(addresses: ["172.28.153.5:5000"])
        #expect(yaml.contains("\"172.28.153.5:5000\":"))
        #expect(yaml.contains("- \"http://172.28.153.5:5000\""))
        #expect(yaml.contains("insecure_skip_verify: true"))
        #expect(KubeRegistriesConfig.yaml(addresses: []) == "mirrors: {}\n")

        var r = KubeRegistry(name: "Team Registry", memoryGB: 2, diskGB: 80)
        #expect(r.node.name == "registry-team-registry")
        #expect(r.address == nil)
        r.node.lastIP = "172.28.153.5"
        #expect(r.address == "172.28.153.5:5000")
        let store = tempStore()
        store.upsert(r)
        #expect(store.registries(for: UUID()).count == 1)
        store.removeRegistry(r.id)
        #expect(store.registries.isEmpty)

        var syn = KubeSynologySpec()
        #expect(!syn.isConfigured)
        syn.host = "nas.local"; syn.username = "k8s"; syn.https = true; syn.port = 5001
        #expect(syn.isConfigured)
        let info = syn.clientInfoYAML(password: "p\"w")
        #expect(info.contains("host: \"nas.local\""))
        #expect(info.contains("https: true"))
        #expect(info.contains("password: \"p\\\"w\""))
        // No volume named → one unpinned class (DSM picks the volume).
        var sc = syn.storageClassesYAML()
        #expect(sc.contains("provisioner: csi.san.synology.com"))
        #expect(sc.contains("protocol: 'iscsi'"))
        #expect(sc.contains("name: bromure-synology\n"))
        #expect(!sc.contains("location:"))
        #expect(sc.contains("is-default-class: \"true\""))
        // Two volumes → two classes, the first default; SMB adds the node-stage secret.
        syn.location = "/volume1, volume3"
        syn.protocolKind = .smb
        #expect(syn.volumes == ["/volume1", "/volume3"])
        #expect(syn.storageClassNames == ["bromure-synology-volume1", "bromure-synology-volume3"])
        sc = syn.storageClassesYAML()
        #expect(sc.components(separatedBy: "kind: StorageClass").count == 3)
        #expect(sc.contains("location: '/volume3'"))
        #expect(sc.contains("is-default-class: \"false\""))
        #expect(sc.contains("node-stage-secret-name: 'synology-smb-credentials'"))
        syn.protocolKind = .iscsi
        var spec = KubeClusterSpec()
        spec.storageEnabled = false
        #expect(!spec.needsISCSI)
        spec.synology = syn
        #expect(spec.needsISCSI)
        // The spec (with a NAS) round-trips without the password.
        let data = try JSONEncoder().encode(spec)
        #expect(!String(decoding: data, as: UTF8.self).contains("p\"w"))
        #expect(try JSONDecoder().decode(KubeClusterSpec.self, from: data).synology?.host == "nas.local")
    }

    @Test("specs decode with defaults for fields that didn't exist yet")
    func specDecodeDefaults() throws {
        let old = try JSONDecoder().decode(KubeClusterSpec.self, from: Data("{\"nodeCount\":2,\"storageEnabled\":false}".utf8))
        #expect(old.nodeCount == 2)
        #expect(old.storageEnabled == false)
        #expect(old.ingress == true)
        #expect(old.awsEmulator == false)
        #expect(old.azureEmulator == false && old.gcpEmulator == false && old.ociEmulator == false)
        #expect(old.emulators.isEmpty)
        #expect(old.emulatorVersions.isEmpty)
        #expect(old.loadBalancer == .bromure)
        // A new spec keeps to the VM network unless the owner opens it up.
        #expect(KubeClusterSpec().loadBalancer == .metallb)
        var spec = KubeClusterSpec(); spec.awsEmulator = true; spec[.oci] = true
        spec.setEmulatorVersion(" 0.4.1 ", for: .oci)
        let round = try JSONDecoder().decode(KubeClusterSpec.self, from: JSONEncoder().encode(spec))
        #expect(round.awsEmulator == true)
        #expect(round.emulators == [.aws, .oci])
        #expect(round.emulatorVersions == ["oci": "0.4.1"])
    }

    @Test("an emulator's image is the owner's pin — a tag or a full reference — else the latest release")
    func emulatorImagePins() {
        var spec = KubeClusterSpec()
        spec[.azure] = true
        #expect(spec.emulatorImage(.azure) == nil)
        spec.setEmulatorVersion("0.13.0", for: .azure)
        #expect(spec.emulatorImage(.azure) == "floci/floci-az:0.13.0")
        spec.setEmulatorVersion("registry.local:5000/mirror/floci-az:0.13.0", for: .azure)
        #expect(spec.emulatorImage(.azure) == "registry.local:5000/mirror/floci-az:0.13.0")
        spec.setEmulatorVersion("", for: .azure)
        #expect(spec.emulatorImage(.azure) == nil)
        #expect(spec.emulatorVersions.isEmpty)
        #expect(KubeCloudEmulator.gcp.image(tag: "0.9.0") == "floci/floci-gcp:0.9.0")
        // Pins travel to the node as a `kind=image` comma list: no spaces, commas or "=".
        #expect(KubeCloudEmulator.isValidPin(nil) && KubeCloudEmulator.isValidPin("") && KubeCloudEmulator.isValidPin(" 2.1.0 "))
        #expect(KubeCloudEmulator.isValidPin("ghcr.io/floci-io/floci@sha256:0123abcd"))
        #expect(!KubeCloudEmulator.isValidPin("2.1.0,azure=x") && !KubeCloudEmulator.isValidPin("a=b") && !KubeCloudEmulator.isValidPin("2.1 .0") && !KubeCloudEmulator.isValidPin("é"))
        #expect(KubeCloudEmulator.aws.imageReference(pin: "2.1.0,x") == nil)
    }

    @Test("the latest release is the highest x.y.z among Docker Hub tags; nightlies and variants don't count")
    func latestReleaseTag() {
        let tags = ["nightly-09202026-compat", "nightly", "2.0.9", "latest", "2.1.0-rc1", "2.1.0", "2.0.10", "nightly-09192026", "1.99.99"]
        #expect(KubeEmulatorReleases.latestRelease(among: tags) == "2.1.0")
        #expect(KubeEmulatorReleases.latestRelease(among: ["0.9.0", "0.10.0", "0.8.5"]) == "0.10.0")
        #expect(KubeEmulatorReleases.latestRelease(among: ["v0.4.1", "0.4.0"]) == "v0.4.1")
        #expect(KubeEmulatorReleases.latestRelease(among: ["nightly", "latest"]) == nil)
        #expect(KubeEmulatorReleases.latestRelease(among: []) == nil)
    }

    @Test("the AWS emulator's endpoints come from the load balancer and the NodePort")
    func awsEmulatorEndpoints() throws {
        var spec = KubeClusterSpec(); spec.awsEmulator = true
        var c = KubeCluster(name: "aws", spec: spec)
        c.nodes = [KubeNodeRecord(name: "k8s-aws-1", role: .server, index: 1, lastIP: "172.28.153.2")]
        let probeJSON = """
        {"reachable":true,"version":"v1.36.4+k3s1","services":[{"namespace":"floci","name":"floci","type":"LoadBalancer","clusterIP":"10.43.0.9","ports":[{"name":"aws","port":4566,"nodePort":31566,"protocol":"TCP","targetPort":"4566"}],"ingress":[],"lbClass":""}],"emulators":{"aws":{"installed":true,"ready":true,"pods":1,"image":"floci/floci:2.1.0"}}}
        """
        var st = KubeClusterStatus(); st.phase = .running; st.hostIP = "10.163.15.54"
        st.probe = try JSONDecoder().decode(KubeProbe.self, from: Data(probeJSON.utf8))
        #expect(st.probe?.emulator(.aws)?.ready == true)
        #expect(st.probe?.emulator(.aws)?.imageTag == "2.1.0")
        #expect(st.probe?.emulator(.azure) == nil)
        // No LB endpoint yet: only the NodePort answers.
        var eps = st.emulatorEndpoints(.aws, for: c)
        #expect(eps.lan == nil)
        #expect(eps.vmNetwork == "http://172.28.153.2:31566")
        st.lbEndpoints = [KubeLBEndpoint(namespace: "floci", service: "floci", port: 4566, nodePort: 31566, protocolName: "TCP", bound: true)]
        eps = st.emulatorEndpoints(.aws, for: c)
        #expect(eps.lan == "http://10.163.15.54:4566")
        let text = KubeMCPServer.overviewText(clusters: [c], registries: [], status: { _ in st }, hostIP: "10.163.15.54")
        #expect(text.contains("AWS emulator (floci): http://172.28.153.2:31566 from this workspace (http://10.163.15.54:4566 from the Mac and its LAN"))
        #expect(text.contains("AWS_ENDPOINT_URL=http://172.28.153.2:31566"))
        #expect(text.contains("Version: floci 2.1.0."))
        #expect(!text.contains("Azure emulator"))
        // Off: nothing.
        let plain = KubeCluster(name: "p", spec: KubeClusterSpec())
        #expect(st.emulatorEndpoints(.aws, for: plain).vmNetwork == nil)
    }

    @Test("a probe from before the emulator family still reports floci")
    func legacyFlociProbe() throws {
        let probeJSON = """
        {"reachable":true,"floci":{"installed":true,"ready":false,"pods":1}}
        """
        let p = try JSONDecoder().decode(KubeProbe.self, from: Data(probeJSON.utf8))
        #expect(p.emulator(.aws)?.installed == true)
        #expect(p.emulator(.aws)?.ready == false)
        #expect(p.emulator(.aws)?.imageTag == nil)
    }

    @Test("the other clouds get their own Service, port and client setup")
    func otherCloudEmulators() throws {
        var spec = KubeClusterSpec(); spec[.azure] = true; spec[.gcp] = true; spec[.oci] = true
        var c = KubeCluster(name: "clouds", spec: spec)
        c.nodes = [KubeNodeRecord(name: "k8s-clouds-1", role: .server, index: 1, lastIP: "172.28.153.2")]
        #expect(KubeCloudEmulator.azure.port == 4577 && KubeCloudEmulator.gcp.port == 4588 && KubeCloudEmulator.oci.port == 4599)
        let probeJSON = """
        {"reachable":true,"services":[
          {"namespace":"floci-az","name":"floci-az","type":"LoadBalancer","clusterIP":"10.43.0.10","ports":[{"name":"azure","port":4577,"nodePort":31577,"protocol":"TCP","targetPort":"4577"}],"ingress":[],"lbClass":""},
          {"namespace":"floci-gcp","name":"floci-gcp","type":"LoadBalancer","clusterIP":"10.43.0.11","ports":[{"name":"gcp","port":4588,"nodePort":31588,"protocol":"TCP","targetPort":"4588"}],"ingress":["172.28.153.230"],"lbClass":""}],
         "emulators":{"azure":{"installed":true,"ready":true,"pods":1,"image":"floci/floci-az:0.13.0"},"gcp":{"installed":true,"ready":false,"pods":1,"image":"floci/floci-gcp:latest"}}}
        """
        var st = KubeClusterStatus(); st.phase = .running; st.hostIP = "10.163.15.54"
        st.probe = try JSONDecoder().decode(KubeProbe.self, from: Data(probeJSON.utf8))
        st.lbEndpoints = [KubeLBEndpoint(namespace: "floci-az", service: "floci-az", port: 4577, nodePort: 31577, protocolName: "TCP", bound: true)]
        let az = st.emulatorEndpoints(.azure, for: c)
        #expect(az.lan == "http://10.163.15.54:4577")
        #expect(az.vmNetwork == "http://172.28.153.2:31577")
        // MetalLB-style: the Service's own ingress address stands in for the LAN one.
        let gcp = st.emulatorEndpoints(.gcp, for: c)
        #expect(gcp.lan == "http://172.28.153.230:4588")
        #expect(gcp.vmNetwork == "http://172.28.153.2:31588")
        // Not installed yet: no endpoint, the briefing says so.
        #expect(st.emulatorEndpoints(.oci, for: c) == (nil, nil))
        let text = KubeMCPServer.overviewText(clusters: [c], registries: [], status: { _ in st }, hostIP: "10.163.15.54")
        #expect(text.contains("Azure emulator (floci-az): http://172.28.153.2:31577 from this workspace"))
        #expect(text.contains("AZURE_STORAGE_CONNECTION_STRING=\"DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;"))
        #expect(text.contains("BlobEndpoint=http://172.28.153.2:31577/devstoreaccount1"))
        #expect(text.contains("Version: floci-az 0.13.0."))
        #expect(text.contains("Google Cloud emulator (floci-gcp): http://172.28.153.2:31588 from this workspace"))
        #expect(text.contains("PUBSUB_EMULATOR_HOST=172.28.153.2:31588"))
        #expect(text.contains("STORAGE_EMULATOR_HOST=http://172.28.153.2:31588"))
        #expect(text.contains("(Its pod is still starting.)"))
        #expect(text.contains("Oracle Cloud emulator (floci-oci): installed and starting"))
        #expect(!text.contains("AWS emulator"))
        #expect(KubeCloudEmulator.oci.clientSetup(endpoint: "http://h:4599").hasPrefix("oci --endpoint http://h:4599"))
    }

    @Test("with several clusters or registries the MCP tells the agent to ask which one")
    func mcpAsksWhenSeveral() {
        let a = KubeCluster(name: "a", spec: KubeClusterSpec())
        let b = KubeCluster(name: "b", spec: KubeClusterSpec())
        let r1 = KubeRegistry(name: "r1"), r2 = KubeRegistry(name: "r2")
        let one = KubeMCPServer.overviewText(clusters: [a], registries: [r1], status: { _ in KubeClusterStatus() }, hostIP: nil)
        #expect(!one.contains("ask the user which cluster"))
        #expect(!one.contains("ask the user which registry"))
        let two = KubeMCPServer.overviewText(clusters: [a, b], registries: [r1, r2], status: { _ in KubeClusterStatus() }, hostIP: nil)
        #expect(two.contains("ask the user which cluster to use"))
        #expect(two.contains("ask the user which registry to use"))
        #expect(KubeMCPServer.serverInstructions.contains("ask the user which one"))
    }

    @Test("the infrastructure MCP tells agents what exists and how to use it")
    func mcpOverview() {
        var spec = KubeClusterSpec()
        spec.loadBalancer = .bromure   // the LAN load balancer is what this text describes
        spec.lanPool = "10.163.15.20-10.163.15.23"
        var syn = KubeSynologySpec(); syn.host = "nas.local"; syn.username = "k8s"; syn.location = "/volume1, /volume3"
        spec.synology = syn
        var c = KubeCluster(name: "Dev", spec: spec)
        c.nodes = [KubeNodeRecord(name: "k8s-dev-1", role: .server, index: 1, lastIP: "172.28.153.2")]
        var cs = KubeClusterStatus(); cs.phase = .running; cs.hostIP = "10.163.15.54"
        cs.lbEndpoints = [KubeLBEndpoint(namespace: "default", service: "web", port: 80, nodePort: 31080, protocolName: "TCP", bound: true, ip: "10.163.15.20"),
                          KubeLBEndpoint(namespace: "default", service: "db", port: 5432, nodePort: 31432, protocolName: "TCP", bound: true, ip: "172.28.153.230", scope: "vm")]
        c.metallbRange = "172.28.153.230-172.28.153.249"
        var r = KubeRegistry(name: "reg"); r.node.lastIP = "172.28.153.5"
        var rs = KubeClusterStatus(); rs.phase = .running; rs.address = "172.28.153.5:5000"
        let text = KubeMCPServer.overviewText(clusters: [c], registries: [r],
                                              status: { $0 == c.id ? cs : rs }, hostIP: "10.163.15.54")
        #expect(text.contains("Context `dev`"))
        #expect(text.contains("https://172.28.153.2:6443"))
        #expect(text.contains("`bromure-synology-volume1` (default"))
        #expect(text.contains("`bromure-longhorn`"))
        #expect(text.contains("pool 10.163.15.20-10.163.15.23"))
        #expect(text.contains("default/web 10.163.15.20:80/TCP (public, LAN)"))
        #expect(text.contains("default/db 172.28.153.230:5432/TCP (private, VM network)"))
        #expect(text.contains("`bromure.io/scope: vm`"))
        #expect(text.contains("from 172.28.153.230-172.28.153.249"))
        #expect(text.contains("`bromure.io/loadBalancerIP: <ip>`"))
        // Endpoint records without the scope key (older servers) decode as public.
        let old = try? JSONDecoder().decode(KubeLBEndpoint.self, from: Data("{\"namespace\":\"a\",\"service\":\"b\",\"port\":1,\"nodePort\":2,\"protocolName\":\"TCP\",\"bound\":true}".utf8))
        #expect(old?.isVMScoped == false)
        #expect(text.contains("docker push 172.28.153.5:5000/myapp:dev"))
        #expect(text.contains("Traefik"))
        // Storage class order: NAS classes first (default), then Longhorn, then local-path.
        let classes = KubeMCPServer.storageClasses(of: c).map(\.name)
        #expect(classes == ["bromure-synology-volume1", "bromure-synology-volume3", "bromure-longhorn", "longhorn", "local-path"])
        #expect(KubeMCPServer.storageClasses(of: c).filter(\.isDefault).count == 1)
        // Without any storage add-on, local-path is the default.
        let plain = KubeCluster(name: "p", spec: { var s = KubeClusterSpec(); s.storageEnabled = false; return s }())
        #expect(KubeMCPServer.storageClasses(of: plain).first?.name == "local-path")
        #expect(KubeMCPServer.storageClasses(of: plain).first?.isDefault == true)
    }

    @Test("k3s.yaml becomes a direct kubeconfig pointed at the node")
    func k3sYAML() throws {
        let yaml = """
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority-data: Q0FEQVRB
            server: https://127.0.0.1:6443
          name: default
        contexts:
        - context:
            cluster: default
            user: default
          name: default
        current-context: default
        kind: Config
        preferences: {}
        users:
        - name: default
          user:
            client-certificate-data: Q0VSVA==
            client-key-data: S0VZ
        """
        let d = try #require(KubeDirectCluster.fromK3sYAML(yaml, contextName: "dev", serverIP: "192.168.64.7"))
        #expect(d.serverURL == "https://192.168.64.7:6443")
        #expect(d.caData == "Q0FEQVRB")
        #expect(d.clientKeyData == "S0VZ")
        #expect(d.standaloneYAML.contains("current-context: dev"))
        #expect(d.standaloneYAML.contains("server: https://192.168.64.7:6443"))
        #expect(KubeDirectCluster.fromK3sYAML("kind: Config\n", contextName: "x", serverIP: "1.2.3.4") == nil)
    }

    @Test("the materializer emits direct contexts and keeps imported ones current")
    func materializer() {
        let direct = KubeDirectCluster(contextName: "dev", serverURL: "https://192.168.64.7:6443",
                                       caData: "Q0E=", clientCertData: "Q0VSVA==", clientKeyData: "S0VZ")
        var profile = Profile(name: "ws", tool: .claude, authMode: .token)
        var m = KubeconfigMaterializer().materialize(profile: profile, bromureCAPEM: "PEM", directClusters: [direct])
        #expect(m.yaml.contains("current-context: dev"))
        #expect(m.yaml.contains("server: https://192.168.64.7:6443"))
        #expect(m.yaml.contains("name: dev-admin"))
        #expect(m.bearerSwaps.isEmpty)
        // An imported context keeps the current-context slot.
        profile.kubeconfigs = [KubeconfigEntry(name: "cloud", serverURL: "https://k8s.example.com",
                                               auth: .bearerToken("t"))]
        m = KubeconfigMaterializer().materialize(profile: profile, bromureCAPEM: "PEM", directClusters: [direct])
        #expect(m.yaml.contains("current-context: cloud"))
        #expect(m.yaml.contains("- name: dev\n"))
    }
}
