#if os(macOS)
import Foundation

// MARK: - Infrastructure MCP (per workspace)
//
// What every agent in a workspace needs to know about the machines Bromure
// runs for it: the Kubernetes clusters its access list allows (context
// name, state, nodes, storage classes and what backs them, how Services of
// type LoadBalancer get an address, ingress, image registries it can pull
// from) and the container registries it may push to (address, how docker is
// already configured). Agents can also create a cluster or a registry —
// shared resources, so anything created is visible to every workspace.
//
// Same transport as the automations MCP: a stdio shim in the guest
// (bromure-infra-mcp.py) pipes JSON-RPC lines over vsock (port 5834) to this
// handler, one bridge per machine; the workspace is fixed by the VM the
// connection came from.

@MainActor
final class KubeMCPServer: MCPLineHandler {
    private let profileID: Profile.ID
    private let store: () -> KubeClusterStore?
    private let engine: () -> KubeClusterEngine?

    init(profileID: Profile.ID,
         store: @escaping () -> KubeClusterStore?,
         engine: @escaping () -> KubeClusterEngine?) {
        self.profileID = profileID
        self.store = store
        self.engine = engine
    }

    // MARK: JSON-RPC

    func handle(line: String, branch: String?) async -> String? {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return respond(id: id, result: [
                "protocolVersion": "2025-03-26",
                "serverInfo": ["name": "bromure-infrastructure", "version": "1.0.0"],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": Self.serverInstructions,
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return respond(id: id, result: [:])
        case "tools/list":
            return respond(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return respond(id: id, result: callTool(name: name, args: args))
        default:
            guard id != nil else { return nil }
            return respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tools

    static let serverInstructions = """
    Bromure runs infrastructure for this workspace on the same Mac: Kubernetes \
    clusters (k3s in VMs, already in ~/.kube/config) and private container \
    registries (docker in this workspace already trusts them; \
    $BROMURE_REGISTRY holds the first one's address). Call \
    infrastructure_overview before doing anything with kubectl, docker push \
    or deployments: it tells you which clusters and registries exist, their \
    kubeconfig contexts, which storage classes are available and what backs \
    them, how Services of type LoadBalancer get an address, and the exact \
    commands to build, push and run an image. cluster_status and \
    registry_status give live detail; cluster_create and registry_create \
    make new ones (shared by every workspace; provisioning takes minutes — \
    poll cluster_status / registry_status until the phase is running). When \
    more than one cluster or registry is available, ask the user which one \
    to deploy to or push to before acting — never choose one silently.
    """

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "infrastructure_overview",
            "description": "Everything available to this workspace: Kubernetes clusters (context names, state, nodes, storage classes, load balancer, ingress) and container registries (address, how to push), with usage instructions. Start here.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "cluster_status",
            "description": "Live detail for one cluster: phase, nodes, pods, services with their external addresses, storage, warnings, the last provisioning log lines.",
            "inputSchema": ["type": "object",
                            "properties": ["name": ["type": "string", "description": "The cluster's name or kubeconfig context."]],
                            "required": ["name"]],
        ],
        [
            "name": "cluster_create",
            "description": "Create a new Kubernetes cluster (k3s) in fresh VMs, shared by every workspace. Provisioning takes a few minutes: poll cluster_status until phase is running; the kubeconfig context appears in this workspace automatically.",
            "inputSchema": ["type": "object", "properties": [
                "name": ["type": "string"],
                "nodes": ["type": "integer", "description": "Total nodes, 1-8 (node 1 is the control plane and also runs workloads). Default 1."],
                "cpusPerNode": ["type": "integer", "description": "vCPUs per node (default 2)."],
                "memoryGBPerNode": ["type": "integer", "description": "RAM per node in GB (default 4)."],
                "storage": ["type": "boolean", "description": "Longhorn replicated block storage on a data disk per node, as the default storage class (default true). Off = node-local local-path only."],
                "storageDiskGB": ["type": "integer", "description": "Data disk per node in GB when storage is on (default 40)."],
                "loadBalancer": ["type": "string", "enum": ["bromure", "metallb", "none"],
                                 "description": "How LoadBalancer Services get an address (default bromure: published on this Mac's LAN)."],
                "lanPool": ["type": "string", "description": "bromure load balancer: spare LAN addresses to give Services, e.g. \"10.0.0.20-10.0.0.29\". Empty = share the Mac's own address by port."],
                "ingress": ["type": "boolean", "description": "Keep k3s's Traefik ingress controller (default true)."],
                "awsEmulator": ["type": "boolean", "description": "Install floci, a local AWS emulator (S3, DynamoDB, SQS, SNS, Lambda, API Gateway, …) reachable from every workspace (default false)."],
                "azureEmulator": ["type": "boolean", "description": "Install floci-az, a local Azure emulator (Blob/Queue/Table Storage, Cosmos DB, Key Vault, Service Bus, Event Hubs, Functions, …) reachable from every workspace (default false)."],
                "gcpEmulator": ["type": "boolean", "description": "Install floci-gcp, a local Google Cloud emulator (Cloud Storage, Pub/Sub, Firestore, Secret Manager, Cloud Run, Cloud Functions, BigQuery, …) reachable from every workspace (default false)."],
                "ociEmulator": ["type": "boolean", "description": "Install floci-oci, a local Oracle Cloud emulator (Object Storage, Queue, Streaming, Vault, KMS, Functions, …) reachable from every workspace (default false)."],
                "emulatorVersions": ["type": "object", "additionalProperties": ["type": "string"],
                                     "description": "Pin an emulator's version instead of the latest release on Docker Hub at setup: keys aws, azure, gcp, oci; values a tag (\"2.1.0\") or a full image reference."],
            ], "required": ["name"]],
        ],
        [
            "name": "cluster_start",
            "description": "Boot a stopped cluster (its VMs). Poll cluster_status until running.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        ],
        [
            "name": "registry_status",
            "description": "One container registry: address, whether it answers, the images it holds (repositories and tags), disk usage.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        ],
        [
            "name": "registry_create",
            "description": "Create a private container registry in its own VM, shared by every workspace: docker in this workspace and every cluster trust it automatically once it's up (a minute or two; poll registry_status).",
            "inputSchema": ["type": "object", "properties": [
                "name": ["type": "string"],
                "memoryGB": ["type": "integer", "description": "RAM for the registry VM (default 1)."],
                "diskGB": ["type": "integer", "description": "Space for image layers in GB (default 40, sparse)."],
            ], "required": ["name"]],
        ],
        [
            "name": "registry_start",
            "description": "Boot a stopped registry. Poll registry_status until running.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        ],
    ]

    // MARK: Scope

    private func visibleClusters(_ store: KubeClusterStore) -> [KubeCluster] {
        store.clusters(for: profileID).sorted { $0.createdAt < $1.createdAt }
    }

    private func visibleRegistries(_ store: KubeClusterStore) -> [KubeRegistry] {
        store.registries(for: profileID).sorted { $0.createdAt < $1.createdAt }
    }

    private func cluster(named raw: Any?, in store: KubeClusterStore) -> KubeCluster? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        return visibleClusters(store).first { $0.name.lowercased() == s || $0.contextName == s || $0.id.uuidString.lowercased() == s }
    }

    private func registry(named raw: Any?, in store: KubeClusterStore) -> KubeRegistry? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        return visibleRegistries(store).first { $0.name.lowercased() == s || $0.slug == s || $0.id.uuidString.lowercased() == s }
    }

    private func callTool(name: String, args: [String: Any]) -> [String: Any] {
        guard let store = store() else { return errorResult("infrastructure unavailable") }
        switch name {
        case "infrastructure_overview":
            return textResult(Self.overviewText(clusters: visibleClusters(store), registries: visibleRegistries(store),
                                                status: { store.status($0) }, hostIP: HostNetwork.primaryIPv4()))
        case "cluster_status":
            guard let c = cluster(named: args["name"], in: store) else { return errorResult("no cluster with that name is available to this workspace") }
            return textResult(Self.clusterDetail(c, status: store.status(c.id)))
        case "cluster_create":
            guard let engine = engine() else { return errorResult("infrastructure unavailable") }
            guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return errorResult("name is required") }
            var spec = KubeClusterSpec()
            if let v = args["nodes"] as? Int { spec.nodeCount = v }
            if let v = args["cpusPerNode"] as? Int { spec.cpusPerNode = v }
            if let v = args["memoryGBPerNode"] as? Int { spec.memoryGBPerNode = v }
            if let v = args["storage"] as? Bool { spec.storageEnabled = v }
            if let v = args["storageDiskGB"] as? Int { spec.storageDiskGB = v }
            if let v = args["loadBalancer"] as? String {
                guard let kind = KubeLoadBalancerKind(rawValue: v) else { return errorResult("loadBalancer must be bromure, metallb or none") }
                spec.loadBalancer = kind
            }
            if let v = args["lanPool"] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                guard KubeLANPool.parse(v) != nil else { return errorResult("lanPool must look like 10.0.0.20-10.0.0.29, 10.0.0.32/28 or a comma list") }
                spec.lanPool = v
            }
            if let v = args["ingress"] as? Bool { spec.ingress = v }
            for kind in KubeCloudEmulator.allCases {
                if let v = args[kind.rawValue + "Emulator"] as? Bool { spec[kind] = v }
            }
            if let pins = args["emulatorVersions"] as? [String: Any] {
                for kind in KubeCloudEmulator.allCases {
                    guard let v = pins[kind.rawValue] as? String else { continue }
                    guard KubeCloudEmulator.isValidPin(v) else {
                        return errorResult("emulatorVersions.\(kind.rawValue) must be a tag such as 2.1.0 or a full image reference")
                    }
                    spec.setEmulatorVersion(v, for: kind)
                }
            }
            let created = engine.create(name: name, spec: spec.clamped, access: .all, autoStart: true)
            BACDebug.log("k8s", "cluster “\(created.name)” created via MCP")
            return textResult("Creating cluster “\(created.name)” (\(created.spec.nodeCount) node(s), \(created.spec.cpusPerNode) vCPU / \(created.spec.memoryGBPerNode) GB each). Provisioning takes a few minutes; poll cluster_status \"\(created.name)\" until phase is running. Its kubeconfig context will be “\(created.contextName)”.")
        case "cluster_start":
            guard let engine = engine(), let c = cluster(named: args["name"], in: store) else { return errorResult("no cluster with that name is available to this workspace") }
            let phase = store.status(c.id).phase
            if phase.isUp { return textResult("“\(c.name)” is already running.") }
            if phase.isBusy { return textResult("“\(c.name)” is \(phase.displayName.lowercased()) — poll cluster_status.") }
            engine.start(c.id)
            return textResult("Starting “\(c.name)”. Poll cluster_status until phase is running.")
        case "registry_status":
            guard let r = registry(named: args["name"], in: store) else { return errorResult("no registry with that name is available to this workspace") }
            return textResult(Self.registryDetail(r, status: store.status(r.id)))
        case "registry_create":
            guard let engine = engine() else { return errorResult("infrastructure unavailable") }
            guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return errorResult("name is required") }
            let created = engine.createRegistry(name: name, access: .all,
                                                memoryGB: (args["memoryGB"] as? Int) ?? 1,
                                                diskGB: (args["diskGB"] as? Int) ?? 40, autoStart: true)
            BACDebug.log("k8s", "registry “\(created.name)” created via MCP")
            return textResult("Creating registry “\(created.name)”. It takes a minute or two; poll registry_status \"\(created.name)\" until phase is running — its address will then be in $BROMURE_REGISTRY of new shells and docker will trust it.")
        case "registry_start":
            guard let engine = engine(), let r = registry(named: args["name"], in: store) else { return errorResult("no registry with that name is available to this workspace") }
            let phase = store.status(r.id).phase
            if phase.isUp { return textResult("“\(r.name)” is already running.") }
            if phase.isBusy { return textResult("“\(r.name)” is \(phase.displayName.lowercased()) — poll registry_status.") }
            engine.startRegistry(r.id)
            return textResult("Starting “\(r.name)”. Poll registry_status until phase is running.")
        default:
            return errorResult("Unknown tool: \(name)")
        }
    }

    // MARK: Documentation text (pure — unit-tested)

    /// Storage classes a cluster ends up with, in the order they matter:
    /// (name, what backs it, is default).
    static func storageClasses(of cluster: KubeCluster) -> [(name: String, backing: String, isDefault: Bool)] {
        var out: [(String, String, Bool)] = []
        let syn = cluster.spec.synology?.isConfigured == true ? cluster.spec.synology : nil
        if let syn {
            for (i, name) in syn.storageClassNames.enumerated() {
                let vol = syn.volumes.isEmpty ? "a DSM volume chosen by the NAS" : syn.volumes[i]
                out.append((name, "Synology NAS \(syn.host) via the Synology CSI driver (\(syn.protocolKind == .iscsi ? "iSCSI LUNs" : "SMB shares") on \(vol), \(syn.fsType))", i == 0))
            }
        }
        if cluster.spec.storageEnabled {
            out.append(("bromure-longhorn", "Longhorn replicated block storage on the nodes' data disks (iSCSI-backed, \(cluster.spec.storageReplicas) replica(s), ReadWriteOnce; RWX via NFS)", syn == nil))
            out.append(("longhorn", "Longhorn with 3 replicas (degraded on clusters smaller than 3 nodes)", false))
        }
        out.append(("local-path", "node-local hostPath directories (not replicated, pod is pinned to the node)", syn == nil && !cluster.spec.storageEnabled))
        return out
    }

    static func loadBalancerText(_ cluster: KubeCluster, status: KubeClusterStatus, hostIP: String?) -> String {
        switch cluster.spec.loadBalancer {
        case .bromure:
            var s = "Services of type LoadBalancer get an address automatically (TCP and UDP), public on the Mac's LAN by default: "
            if let pool = cluster.spec.lanPool, !pool.isEmpty {
                s += "their own LAN address from the pool \(pool) (ARP-announced by Bromure)"
                if let ip = status.hostIP ?? hostIP { s += "; when the pool is exhausted, ports are published on the Mac's own address \(ip)" }
            } else if let ip = status.hostIP ?? hostIP {
                s += "each port is published on the Mac's own LAN address \(ip) (ports must not clash across Services)"
            } else {
                s += "published on the Mac's LAN address once it has one"
            }
            s += ". EXTERNAL-IP appears within ~15 s of creating the Service. Annotations on the Service control this:"
            s += " `bromure.io/scope: vm` makes it PRIVATE — an address on the VM network"
            if let r = cluster.metallbRange { s += " (from \(r))" }
            s += " reachable from every workspace and this Mac but never from the LAN; `bromure.io/scope: lan` (the default) makes it public."
            s += " `bromure.io/loadBalancerIP: <ip>` (or spec.loadBalancerIP) asks for a specific address"
            s += (cluster.spec.lanPool?.isEmpty == false) ? " — one from the LAN pool, or from the VM range with scope vm." : " from the VM range with scope vm."
            s += " Example: `metadata: {annotations: {bromure.io/scope: vm}}` on a `type: LoadBalancer` Service. Prefer private unless the user wants the service reachable from the LAN."
            if !status.lbEndpoints.isEmpty {
                let live = status.lbEndpoints.filter(\.bound).map { e in
                    "\(e.namespace)/\(e.service) \(e.ip ?? status.hostIP ?? "?"):\(e.port)/\(e.protocolName)" + (e.isVMScoped ? " (private, VM network)" : " (public, LAN)")
                }
                if !live.isEmpty { s += " Currently published: " + live.joined(separator: ", ") + "." }
                let broken = status.lbEndpoints.filter { !$0.bound }.map { "\($0.namespace)/\($0.service):\($0.port) — \($0.error ?? "pending")" }
                if !broken.isEmpty { s += " Not published: " + broken.joined(separator: ", ") + "." }
            }
            return s
        case .metallb:
            var s = "MetalLB (layer 2) hands Services of type LoadBalancer an address from \(cluster.metallbRange ?? "a pool on the VM network") — VM network only: reachable from this workspace and the Mac, never from the LAN. EXTERNAL-IP appears within seconds of creating the Service. `spec.loadBalancerIP` or the annotation `metallb.io/loadBalancerIPs: <ip>` asks for a specific address in that range; there is no public/LAN option on this cluster."
            let live = (status.probe?.services ?? []).filter { $0.isLoadBalancer && !$0.ingress.isEmpty }
                .map { svc in "\(svc.namespace)/\(svc.name) " + svc.ingress.joined(separator: ",") + " (" + svc.ports.map { "\($0.port)/\($0.protocolName)" }.joined(separator: ", ") + ")" }
            if !live.isEmpty { s += " Currently assigned: " + live.joined(separator: "; ") + "." }
            return s
        case .none:
            return "No LoadBalancer implementation: Services of type LoadBalancer stay pending — use NodePort (reachable at <node ip>:<nodePort> from this workspace) or ClusterIP."
        }
    }

    /// A cloud emulator's line: where it answers from a workspace and how
    /// to point that cloud's CLI/SDKs at it.
    static func emulatorText(_ kind: KubeCloudEmulator, cluster: KubeCluster, status: KubeClusterStatus) -> String {
        let eps = status.emulatorEndpoints(kind, for: cluster)
        let addon = status.probe?.emulator(kind)
        guard let ep = eps.vmNetwork ?? eps.lan else {
            return status.phase == .running
                ? (addon?.ready == true ? "installed, its address is being published — call cluster_status in a moment." : "installed and starting — call cluster_status in a moment.")
                : "starts with the cluster."
        }
        var s = "\(ep) from this workspace"
        if let lan = eps.lan, lan != ep { s += " (\(lan) from the Mac and its LAN — also reachable from here, and the base of the URLs the emulator returns)" }
        s += ". Point the \(kind.cloudName) CLI and SDKs at it: `\(kind.clientSetup(endpoint: ep))`. \(kind.credentialsNote) Emulates \(kind.services) and more; state persists on the cluster's storage. Services that spawn containers (\(kind.containerBackedServices)) are best effort. Never point real \(kind.cloudName) work at it."
        if let tag = addon?.imageTag { s += " Version: \(kind.project) \(tag)." }
        if addon?.ready == false { s += " (Its pod is still starting.)" }
        return s
    }

    static func overviewText(clusters: [KubeCluster], registries: [KubeRegistry],
                             status: (UUID) -> KubeClusterStatus, hostIP: String?) -> String {
        var out = "# Bromure infrastructure available to this workspace\n\n"
        out += "## Kubernetes clusters\n"
        if clusters.isEmpty {
            out += "None yet. cluster_create makes one (shared by every workspace); its kubeconfig context lands in ~/.kube/config here automatically.\n"
        }
        let running = clusters.filter { status($0.id).phase == .running }
        for c in clusters {
            let st = status(c.id)
            out += "\n### \(c.name)\n"
            out += "- Phase: \(st.phase.displayName)"
            if st.phase == .running, let p = st.probe, p.reachable, !p.version.isEmpty {
                out += " — \(p.version), \(p.readyNodes)/\(max(p.nodes.count, c.spec.nodeCount)) nodes Ready, \(p.podSummary.running) pods running"
            } else if st.phase == .running {
                out += " (just came up; live figures follow within a minute)"
            }
            out += ".\n"
            out += "- kubectl: already configured. Context `\(c.contextName)`"
            if let ip = c.serverIP { out += " → https://\(ip):6443" }
            out += clusters.count > 1 ? " (`kubectl config use-context \(c.contextName)`, or `kubectl --context \(c.contextName) …`).\n" : " (the current context).\n"
            out += "- Size: \(c.spec.nodeCount) node(s), \(c.spec.cpusPerNode) vCPU / \(c.spec.memoryGBPerNode) GB each"
            out += c.nodes.map { n in n.lastIP.map { " · \(n.name) \($0)" } ?? "" }.joined() + ".\n"
            out += "- Storage classes:\n"
            for sc in storageClasses(of: c) {
                out += "  - `\(sc.name)`\(sc.isDefault ? " (default — PVCs without storageClassName use it)" : ""): \(sc.backing)\n"
            }
            out += "- Load balancer: " + loadBalancerText(c, status: st, hostIP: hostIP) + "\n"
            out += c.spec.ingress
                ? "- Ingress: Traefik (k3s bundled) is a LoadBalancer Service in kube-system on ports 80/443; Ingress resources are served there.\n"
                : "- Ingress: none installed (Traefik was left out).\n"
            for kind in c.spec.emulators {
                out += "- \(kind.displayName) (\(kind.project)): " + emulatorText(kind, cluster: c, status: st) + "\n"
            }
            if !registries.isEmpty {
                out += "- Images: the cluster pulls from the registries below without extra configuration (containerd mirrors are set up); reference them as <address>/<repo>:<tag>.\n"
            }
            if st.phase == .error, let m = st.message { out += "- Last error: \(m)\n" }
        }
        if clusters.count > 1 {
            out += "\n**Several clusters are available. Before you deploy, apply manifests or run kubectl against one, ask the user which cluster to use — never pick one silently.**\n"
        }
        if !running.isEmpty && running.count < clusters.count {
            out += "\nStopped clusters can be booted with cluster_start.\n"
        }
        out += "\n## Container registries\n"
        if registries.isEmpty {
            out += "None yet. registry_create makes one; docker here and every cluster then trust it automatically.\n"
        }
        for r in registries {
            let st = status(r.id)
            out += "\n### \(r.name)\n"
            out += "- Phase: \(st.phase.displayName)"
            if let a = st.address ?? r.address { out += " — address \(a) (plain HTTP on the VM network)" }
            out += ".\n"
            if let a = st.address ?? r.address {
                out += "- docker in this workspace already trusts \(a) (insecure-registries); `$BROMURE_REGISTRY` holds the first registry's address in new shells.\n"
                out += "- Build and push: `docker build -t \(a)/myapp:dev . && docker push \(a)/myapp:dev`\n"
                out += "- Run in a cluster: `kubectl run myapp --image=\(a)/myapp:dev` (or the same image reference in a Deployment). Images must be built for linux/arm64.\n"
            }
            if let info = st.registry, !info.repositories.isEmpty {
                out += "- Images held: " + info.repositories.map { "\($0.name) [\($0.tags.joined(separator: ", "))]" }.joined(separator: "; ") + "\n"
            }
        }
        if registries.count > 1 {
            out += "\n**Several registries are available. Before you build or push an image, ask the user which registry to use — never pick one silently.**\n"
        }
        out += "\nAll of this runs in VMs on this Mac; nothing here is reachable from outside its LAN unless a LoadBalancer Service publishes it.\n"
        return out
    }

    static func clusterDetail(_ c: KubeCluster, status st: KubeClusterStatus) -> String {
        var d: [String: Any] = [
            "name": c.name, "context": c.contextName, "phase": st.phase.rawValue,
            "nodes": c.nodes.map { ["name": $0.name, "role": $0.role.rawValue, "ip": $0.lastIP ?? ""] },
            "spec": ["nodeCount": c.spec.nodeCount, "cpusPerNode": c.spec.cpusPerNode, "memoryGBPerNode": c.spec.memoryGBPerNode,
                     "longhorn": c.spec.storageEnabled, "synology": c.spec.synology?.isConfigured == true,
                     "loadBalancer": c.spec.loadBalancer.rawValue, "lanPool": c.spec.lanPool ?? "", "ingress": c.spec.ingress,
                     "awsEmulator": c.spec.awsEmulator, "azureEmulator": c.spec.azureEmulator,
                     "gcpEmulator": c.spec.gcpEmulator, "ociEmulator": c.spec.ociEmulator,
                     "emulatorVersions": c.spec.emulatorVersions],
            "storageClasses": storageClasses(of: c).map { ["name": $0.name, "default": $0.isDefault, "backing": $0.backing] },
        ]
        if let m = st.message { d["message"] = m }
        if let step = st.step { d["step"] = step }
        if let p = st.probe {
            d["kubernetesVersion"] = p.version
            d["nodesReady"] = p.readyNodes
            d["pods"] = ["running": p.podSummary.running, "pending": p.podSummary.pending, "failed": p.podSummary.failed, "total": p.podSummary.total]
            d["services"] = p.services.filter { $0.type != "ClusterIP" || $0.namespace == "default" }.map { s in
                ["namespace": s.namespace, "name": s.name, "type": s.type, "clusterIP": s.clusterIP,
                 "externalIPs": s.ingress, "ports": s.ports.map { "\($0.port)→\($0.targetPort)/\($0.protocolName)" + ($0.nodePort > 0 ? " nodePort \($0.nodePort)" : "") }]
            }
            if let lh = p.longhorn { d["longhorn"] = ["ready": lh.ready, "availableBytes": lh.storageAvailableBytes, "maximumBytes": lh.storageMaximumBytes] }
            if let syn = p.synology { d["synologyDriver"] = ["ready": syn.ready, "pods": syn.pods] }
            if !p.warnings.isEmpty { d["recentWarnings"] = p.warnings.prefix(6).map { "\($0.reason) \($0.namespace)/\($0.object): \($0.message)" } }
        }
        for kind in c.spec.emulators {
            let eps = st.emulatorEndpoints(kind, for: c)
            let addon = st.probe?.emulator(kind)
            var e: [String: Any] = ["project": kind.project, "ready": addon?.ready ?? false,
                                    "endpointFromWorkspace": eps.vmNetwork ?? "", "endpointLAN": eps.lan ?? "",
                                    "credentials": kind.credentialsNote]
            if let ep = eps.vmNetwork ?? eps.lan { e["clientSetup"] = kind.clientSetup(endpoint: ep) }
            if let image = addon?.image { e["image"] = image }
            d[kind.rawValue + "Emulator"] = e
        }
        if !st.lbEndpoints.isEmpty {
            d["loadBalancerEndpoints"] = st.lbEndpoints.map { ["service": "\($0.namespace)/\($0.service)", "address": ($0.ip ?? st.hostIP ?? "") + ":\($0.port)", "protocol": $0.protocolName, "bound": $0.bound, "error": $0.error ?? "", "scope": $0.isVMScoped ? "vm (private)" : "lan (public)"] }
        }
        if !st.log.isEmpty { d["recentLog"] = Array(st.log.suffix(12)) }
        return jsonPretty(d)
    }

    static func registryDetail(_ r: KubeRegistry, status st: KubeClusterStatus) -> String {
        var d: [String: Any] = ["name": r.name, "phase": st.phase.rawValue, "address": st.address ?? r.address ?? ""]
        if let m = st.message { d["message"] = m }
        if let info = st.registry {
            d["reachable"] = info.reachable
            d["repositories"] = info.repositories.map { ["name": $0.name, "tags": $0.tags] }
            d["diskUsedBytes"] = info.diskUsedBytes
            d["diskTotalBytes"] = info.diskTotalBytes
        }
        if let a = st.address ?? r.address {
            d["push"] = "docker build -t \(a)/<repo>:<tag> . && docker push \(a)/<repo>:<tag>"
        }
        if !st.log.isEmpty { d["recentLog"] = Array(st.log.suffix(8)) }
        return jsonPretty(d)
    }

    // MARK: JSON helpers (board MCP conventions)

    private static func jsonPretty(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .prettyPrinted]),
              let s = String(data: data, encoding: .utf8) else { return "\(v)" }
        return s
    }

    private func textResult(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
    }

    private func errorResult(_ msg: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(msg)"]], "isError": true]
    }

    private func respond(id: Any?, result: [String: Any]) -> String? {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id } else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func respondError(id: Any?, code: Int, message: String) -> String? {
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { msg["id"] = id } else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
#endif
