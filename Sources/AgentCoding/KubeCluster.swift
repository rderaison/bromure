import Foundation
import Observation

// MARK: - Kubernetes clusters (shared models)
//
// A Kubernetes cluster is a SHARED machine resource: a set of node VMs
// bromure boots next to the workspaces on the same virtual LAN, running k3s,
// with the cluster's kubeconfig handed to every workspace the cluster's
// access list allows. These models are pure Foundation + Observation so the
// iOS/visionOS client compiles them and the fat-client mirror can reconcile
// the host's `/state` snapshot into the same store the local sidebar reads.
//
// Persisted: `KubeCluster` (spec, node records, access list) in
// ~/Library/Application Support/BromureAC/kube/clusters.json.
// Runtime: `KubeClusterStatus` (phase, probe, load-balancer endpoints) —
// owned by the host's `KubeClusterEngine`, mirrored to clients.

/// How Services of type LoadBalancer get an address.
public enum KubeLoadBalancerKind: String, Codable, CaseIterable, Sendable {
    /// Bromure's own: the cluster stays on the internal VM LAN, and each
    /// LoadBalancer port is published on this Mac's physical LAN address —
    /// the host listens there and relays into the cluster. Reachable from
    /// the LAN, the Mac, and every workspace.
    case bromure
    /// MetalLB in Layer-2 mode with a pool carved out of the VM subnet.
    /// Reachable from the workspaces and this Mac only.
    case metallb
    /// No LoadBalancer implementation (NodePort / ClusterIP only).
    case none

    public var displayName: String {
        switch self {
        case .bromure: return "Bromure LAN load balancer"
        case .metallb: return "MetalLB (Layer 2, VM network)"
        case .none:    return "None (NodePort only)"
        }
    }
}

/// What the user tunes when creating a cluster.
public struct KubeClusterSpec: Codable, Equatable, Sendable {
    /// Total nodes. Node 1 is the control plane (and schedules workloads
    /// too); the others join as agents.
    public var nodeCount: Int = 1
    public var cpusPerNode: Int = 2
    public var memoryGBPerNode: Int = 4
    /// Longhorn distributed block storage (iSCSI-backed) on a dedicated
    /// data disk per node.
    public var storageEnabled: Bool = true
    /// Size of each node's data disk (sparse — only used blocks cost space).
    public var storageDiskGB: Int = 40
    public var loadBalancer: KubeLoadBalancerKind = .bromure
    /// Keep k3s's bundled Traefik ingress controller.
    public var ingress: Bool = true
    /// Bromure LB only: spare addresses on the Mac's LAN handed to Services
    /// of type LoadBalancer ("10.0.0.20-10.0.0.29", "10.0.0.32/28", or a
    /// comma list). The host answers ARP for them itself, MetalLB-style;
    /// without a pool every Service shares the Mac's own address by port.
    public var lanPool: String? = nil

    public init() {}

    public static let nodeRange = 1...8
    public static let cpuRange = 1...16
    public static let memoryRange = 2...64
    public static let storageRange = 10...2000

    /// Longhorn replica count that fits the cluster (never more than the
    /// node count; three is Longhorn's own default).
    public var storageReplicas: Int { max(1, min(3, nodeCount)) }

    /// Clamp every field into its supported range (the sheet's steppers do,
    /// but a fat client / API caller may not).
    public var clamped: KubeClusterSpec {
        var s = self
        s.nodeCount = min(max(s.nodeCount, Self.nodeRange.lowerBound), Self.nodeRange.upperBound)
        s.cpusPerNode = min(max(s.cpusPerNode, Self.cpuRange.lowerBound), Self.cpuRange.upperBound)
        s.memoryGBPerNode = min(max(s.memoryGBPerNode, Self.memoryRange.lowerBound), Self.memoryRange.upperBound)
        s.storageDiskGB = min(max(s.storageDiskGB, Self.storageRange.lowerBound), Self.storageRange.upperBound)
        return s
    }
}

/// Which workspaces get the cluster's kubeconfig (`~/.kube/config` in their
/// VM). `.all` includes workspaces created later; `.only` is an explicit
/// allow-list and must never be empty — at least one workspace can always
/// reach a cluster.
public enum KubeWorkspaceAccess: Codable, Equatable, Sendable {
    case all
    case only(Set<UUID>)

    public func allows(_ profileID: UUID) -> Bool {
        switch self {
        case .all: return true
        case .only(let ids): return ids.contains(profileID)
        }
    }

    /// Drop a deleted workspace. An allow-list that would become empty falls
    /// back to `.all` (the "at least one workspace" rule).
    public func removing(_ profileID: UUID) -> KubeWorkspaceAccess {
        guard case .only(var ids) = self else { return self }
        ids.remove(profileID)
        return ids.isEmpty ? .all : .only(ids)
    }

    private enum CodingKeys: String, CodingKey { case mode, ids }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "all"
        if mode == "only" {
            let ids = try c.decodeIfPresent([UUID].self, forKey: .ids) ?? []
            self = ids.isEmpty ? .all : .only(Set(ids))
        } else {
            self = .all
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try c.encode("all", forKey: .mode)
        case .only(let ids):
            try c.encode("only", forKey: .mode)
            try c.encode(ids.sorted { $0.uuidString < $1.uuidString }, forKey: .ids)
        }
    }
}

public enum KubeNodeRole: String, Codable, Sendable {
    case server, agent
}

/// One node VM. `id` doubles as the synthetic profile id the VM boots under
/// (stable across boots: it keys the disk, MAC and machine identifier).
public struct KubeNodeRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var role: KubeNodeRole
    public var index: Int
    /// Last DHCP address the guest reported; the switch keeps leases per
    /// MAC so it rarely moves, but the engine re-checks on every boot.
    public var lastIP: String?

    public init(id: UUID = UUID(), name: String, role: KubeNodeRole, index: Int, lastIP: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.index = index
        self.lastIP = lastIP
    }
}

/// The persisted cluster record.
public struct KubeCluster: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var spec: KubeClusterSpec
    public var access: KubeWorkspaceAccess
    public var nodes: [KubeNodeRecord]
    /// Boot the cluster when bromure launches.
    public var autoStart: Bool
    /// Set once provisioning finished at least once — a cluster that never
    /// got there is re-provisioned on the next start instead of just booted.
    public var provisioned: Bool
    /// MetalLB pool ("a.b.c.d-a.b.c.e"), reserved on the switch's DHCP.
    public var metallbRange: String?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(),
                spec: KubeClusterSpec, access: KubeWorkspaceAccess = .all,
                nodes: [KubeNodeRecord] = [], autoStart: Bool = true,
                provisioned: Bool = false, metallbRange: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.spec = spec
        self.access = access
        self.nodes = nodes
        self.autoStart = autoStart
        self.provisioned = provisioned
        self.metallbRange = metallbRange
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, spec, access, nodes, autoStart, provisioned, metallbRange
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        spec = try c.decodeIfPresent(KubeClusterSpec.self, forKey: .spec) ?? KubeClusterSpec()
        access = try c.decodeIfPresent(KubeWorkspaceAccess.self, forKey: .access) ?? .all
        nodes = try c.decodeIfPresent([KubeNodeRecord].self, forKey: .nodes) ?? []
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true
        provisioned = try c.decodeIfPresent(Bool.self, forKey: .provisioned) ?? false
        metallbRange = try c.decodeIfPresent(String.self, forKey: .metallbRange)
    }

    /// DNS-label-safe form of the name: node hostnames, kubeconfig context
    /// names and the on-disk folder all derive from it.
    public var slug: String { Self.slug(for: name) }

    public static func slug(for name: String) -> String {
        var out = ""
        var lastDash = true
        for ch in name.lowercased().unicodeScalars {
            if (ch.value >= 97 && ch.value <= 122) || (ch.value >= 48 && ch.value <= 57) {
                out.unicodeScalars.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { out = "cluster" }
        if let first = out.first, first.isNumber { out = "k-" + out }
        return String(out.prefix(24))
    }

    /// Hostname of node `index` (1-based).
    public func nodeName(index: Int) -> String { "k8s-\(slug)-\(index)" }

    public var server: KubeNodeRecord? { nodes.first { $0.role == .server } }
    public var serverIP: String? { server?.lastIP }

    /// The kubeconfig context name workspaces see for this cluster.
    public var contextName: String { slug }
}

/// Right-click / "⋯" actions on a cluster's sidebar row.
public enum KubeRowAction: Sendable {
    case start, stop, restart, delete, access
}

// MARK: - Runtime status (host-owned, mirrored)

public enum KubeClusterPhase: String, Codable, Sendable {
    case stopped, creating, starting, running, stopping, error, deleting

    public var isBusy: Bool {
        switch self {
        case .creating, .starting, .stopping, .deleting: return true
        default: return false
        }
    }
    public var isUp: Bool { self == .running }

    public var displayName: String {
        switch self {
        case .stopped:  return "Stopped"
        case .creating: return "Setting up…"
        case .starting: return "Starting…"
        case .running:  return "Running"
        case .stopping: return "Stopping…"
        case .error:    return "Error"
        case .deleting: return "Deleting…"
        }
    }
}

/// One published LoadBalancer port on the host (Bromure LB mode).
public struct KubeLBEndpoint: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(namespace)/\(service):\(port)" }
    public var namespace: String
    public var service: String
    public var port: Int
    public var nodePort: Int
    public var protocolName: String
    /// The host really answers on `ip:port` (a LAN pool address) or on the
    /// Mac's own address when `ip` is nil.
    public var bound: Bool
    /// Why it isn't bound (port in use, UDP unsupported, …).
    public var error: String?
    /// The LAN address this Service was given from the cluster's pool.
    public var ip: String?

    public init(namespace: String, service: String, port: Int, nodePort: Int,
                protocolName: String, bound: Bool, error: String? = nil, ip: String? = nil) {
        self.namespace = namespace
        self.service = service
        self.port = port
        self.nodePort = nodePort
        self.protocolName = protocolName
        self.bound = bound
        self.error = error
        self.ip = ip
    }
}

/// Decoded output of `bromure-k8s-probe.py`. Field names match the JSON the
/// probe emits (see the script) — keep them in sync.
public struct KubeProbe: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var ready: Bool
        public var roles: [String]
        public var ip: String
        public var version: String
        public var cpuCapacityM: Int
        public var memCapacityBytes: Int64
        public var cpuUsedM: Int
        public var memUsedBytes: Int64
        public var pods: Int
        public var unschedulable: Bool
        public var pressure: [String]

        public var isControlPlane: Bool {
            roles.contains("control-plane") || roles.contains("master")
        }
        public var cpuPercent: Double? {
            guard cpuCapacityM > 0, cpuUsedM > 0 else { return nil }
            return min(100, Double(cpuUsedM) / Double(cpuCapacityM) * 100)
        }
        public var memPercent: Double? {
            guard memCapacityBytes > 0, memUsedBytes > 0 else { return nil }
            return min(100, Double(memUsedBytes) / Double(memCapacityBytes) * 100)
        }
    }

    public struct PodSummary: Codable, Equatable, Sendable {
        public var total: Int = 0
        public var running: Int = 0
        public var pending: Int = 0
        public var failed: Int = 0
        public var succeeded: Int = 0
        public var unknown: Int = 0
        public init() {}
    }

    public struct Pod: Codable, Equatable, Identifiable, Sendable {
        public var id: String { "\(namespace)/\(name)" }
        public var namespace: String
        public var name: String
        public var phase: String
        public var reason: String
        public var ready: Int
        public var containers: Int
        public var restarts: Int
        public var node: String
        public var createdAt: String
        public var isHealthy: Bool { phase == "Running" && ready == containers && reason.isEmpty }
    }

    public struct ServicePort: Codable, Equatable, Sendable {
        public var name: String
        public var port: Int
        public var nodePort: Int
        public var protocolName: String
        public var targetPort: String
        private enum CodingKeys: String, CodingKey {
            case name, port, nodePort, protocolName = "protocol", targetPort
        }
    }

    public struct Service: Codable, Equatable, Identifiable, Sendable {
        public var id: String { "\(namespace)/\(name)" }
        public var namespace: String
        public var name: String
        public var type: String
        public var clusterIP: String
        public var ports: [ServicePort]
        public var ingress: [String]
        public var lbClass: String
        /// Requested address (spec.loadBalancerIP / annotation), "" if none.
        public var lbIP: String?
        public var isLoadBalancer: Bool { type == "LoadBalancer" }
    }

    public struct PVC: Codable, Equatable, Identifiable, Sendable {
        public var id: String { "\(namespace)/\(name)" }
        public var namespace: String
        public var name: String
        public var phase: String
        public var storageClass: String
        public var capacityBytes: Int64
        public var requestBytes: Int64
        public var modes: [String]
        public var volume: String
    }

    public struct Deployments: Codable, Equatable, Sendable {
        public var total: Int = 0
        public var available: Int = 0
        public init() {}
    }

    public struct Longhorn: Codable, Equatable, Sendable {
        public struct Volume: Codable, Equatable, Identifiable, Sendable {
            public var id: String { name }
            public var name: String
            public var state: String
            public var robustness: String
            public var sizeBytes: Int64
            public var actualSizeBytes: Int64
            public var replicas: Int
            public var node: String
            public var pvc: String
            public var namespace: String
        }
        public struct Node: Codable, Equatable, Identifiable, Sendable {
            public var id: String { name }
            public var name: String
            public var ready: Bool
            public var schedulable: Bool
            public var storageMaximumBytes: Int64
            public var storageAvailableBytes: Int64
        }
        public var installed: Bool
        public var ready: Bool
        public var volumes: [Volume]
        public var nodes: [Node]

        public var storageMaximumBytes: Int64 { nodes.reduce(0) { $0 + $1.storageMaximumBytes } }
        public var storageAvailableBytes: Int64 { nodes.reduce(0) { $0 + $1.storageAvailableBytes } }
    }

    public struct Warning: Codable, Equatable, Identifiable, Sendable {
        public var id: String { "\(at)|\(object)|\(reason)" }
        public var at: String
        public var reason: String
        public var message: String
        public var object: String
        public var namespace: String
        public var count: Int
    }

    public var at: String
    public var reachable: Bool
    public var version: String
    public var full: Bool
    public var nodes: [Node]
    public var podSummary: PodSummary
    public var podsByNamespace: [String: Int]
    public var services: [Service]
    public var deployments: Deployments
    public var longhorn: Longhorn?
    public var pods: [Pod]
    public var pvcs: [PVC]
    public var warnings: [Warning]
    public var probeMillis: Int

    private enum CodingKeys: String, CodingKey {
        case at, reachable, version, full, nodes, podSummary, podsByNamespace, services,
             deployments, longhorn, pods, pvcs, warnings, probeMillis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        reachable = try c.decodeIfPresent(Bool.self, forKey: .reachable) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        full = try c.decodeIfPresent(Bool.self, forKey: .full) ?? false
        nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        podSummary = try c.decodeIfPresent(PodSummary.self, forKey: .podSummary) ?? PodSummary()
        podsByNamespace = try c.decodeIfPresent([String: Int].self, forKey: .podsByNamespace) ?? [:]
        services = try c.decodeIfPresent([Service].self, forKey: .services) ?? []
        deployments = try c.decodeIfPresent(Deployments.self, forKey: .deployments) ?? Deployments()
        longhorn = try c.decodeIfPresent(Longhorn.self, forKey: .longhorn)
        pods = try c.decodeIfPresent([Pod].self, forKey: .pods) ?? []
        pvcs = try c.decodeIfPresent([PVC].self, forKey: .pvcs) ?? []
        warnings = try c.decodeIfPresent([Warning].self, forKey: .warnings) ?? []
        probeMillis = try c.decodeIfPresent(Int.self, forKey: .probeMillis) ?? 0
    }

    /// Merge a lightweight probe over a previous full one so the dashboard's
    /// heavy tables don't blink empty between full refreshes.
    public func mergingDetails(from previous: KubeProbe?) -> KubeProbe {
        guard !full, let previous, previous.full else { return self }
        var merged = self
        merged.pods = previous.pods
        merged.pvcs = previous.pvcs
        merged.warnings = previous.warnings
        if var lh = merged.longhorn, let prevLH = previous.longhorn {
            lh.volumes = prevLH.volumes
            merged.longhorn = lh
        }
        return merged
    }

    public var readyNodes: Int { nodes.filter(\.ready).count }
    public var cpuUsedM: Int { nodes.reduce(0) { $0 + $1.cpuUsedM } }
    public var cpuCapacityM: Int { nodes.reduce(0) { $0 + $1.cpuCapacityM } }
    public var memUsedBytes: Int64 { nodes.reduce(0) { $0 + $1.memUsedBytes } }
    public var memCapacityBytes: Int64 { nodes.reduce(0) { $0 + $1.memCapacityBytes } }
    public var cpuPercent: Double {
        guard cpuCapacityM > 0 else { return 0 }
        return min(100, Double(cpuUsedM) / Double(cpuCapacityM) * 100)
    }
    public var loadBalancerServices: [Service] { services.filter(\.isLoadBalancer) }

    public static func decode(_ data: Data) -> KubeProbe? {
        try? JSONDecoder().decode(KubeProbe.self, from: data)
    }
}

/// Everything about a cluster that isn't its saved record: lifecycle phase,
/// provisioning log, the last probe, and the load balancer's endpoints.
public struct KubeClusterStatus: Codable, Equatable, Sendable {
    public var phase: KubeClusterPhase = .stopped
    /// Error text (phase == .error) or a one-line progress note.
    public var message: String?
    /// Current provisioning step, e.g. "Installing k3s on k8s-dev-2".
    public var step: String?
    /// Tail of the provisioning/boot log (bounded).
    public var log: [String] = []
    public var probe: KubeProbe?
    public var lbEndpoints: [KubeLBEndpoint] = []
    /// The Mac's LAN address LoadBalancer services are published on.
    public var hostIP: String?
    /// Nodes whose VM is up (booted, shell reachable).
    public var nodesUp: Int = 0
    public var startedAt: Date?

    public init() {}

    public static let maxLogLines = 400

    public mutating func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log.append(trimmed)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }
}

// MARK: - Store

/// The clusters the app knows about + their live status. Locally the
/// engine writes `status`; on a fat client both come from `/state` via
/// `mirror` (no save — a mirror is a read model of another machine).
@MainActor
@Observable
public final class KubeClusterStore {
    public private(set) var clusters: [KubeCluster] = []
    public private(set) var status: [UUID: KubeClusterStatus] = [:]

    private let fileURL: URL?
    private let isMirror: Bool

    /// `mirror: true` → in-memory only, fed by `mirror(...)`. Otherwise
    /// persisted at `fileURL` (default: BromureAC/kube/clusters.json).
    public init(mirror: Bool = false, fileURL: URL? = nil) {
        isMirror = mirror
        if mirror {
            self.fileURL = nil
        } else if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultDirectory.appendingPathComponent("clusters.json")
        }
        load()
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("kube", isDirectory: true)
    }

    public func cluster(_ id: UUID) -> KubeCluster? { clusters.first { $0.id == id } }
    public func status(_ id: UUID) -> KubeClusterStatus { status[id] ?? KubeClusterStatus() }

    /// Clusters whose kubeconfig this workspace receives.
    public func clusters(for profileID: UUID) -> [KubeCluster] {
        clusters.filter { $0.access.allows(profileID) }
    }

    public func upsert(_ cluster: KubeCluster) {
        if let i = clusters.firstIndex(where: { $0.id == cluster.id }) {
            clusters[i] = cluster
        } else {
            clusters.append(cluster)
        }
        save()
    }

    public func remove(_ id: UUID) {
        clusters.removeAll { $0.id == id }
        status[id] = nil
        save()
    }

    /// A workspace was deleted: drop it from every allow-list.
    public func workspaceDeleted(_ profileID: UUID) {
        var changed = false
        for i in clusters.indices {
            let next = clusters[i].access.removing(profileID)
            if next != clusters[i].access { clusters[i].access = next; changed = true }
        }
        if changed { save() }
    }

    /// Engine-side status update. Skips the write when nothing changed so
    /// observers don't churn on every probe tick.
    public func setStatus(_ id: UUID, _ update: (inout KubeClusterStatus) -> Void) {
        var s = status[id] ?? KubeClusterStatus()
        update(&s)
        if status[id] != s { status[id] = s }
    }

    /// Fat-client mirror: replace clusters + status from a `/state` snapshot.
    public func mirror(clusters newClusters: [KubeCluster], status newStatus: [UUID: KubeClusterStatus]) {
        if clusters != newClusters { clusters = newClusters }
        if status != newStatus { status = newStatus }
    }

    // MARK: Persistence

    private struct FilePayload: Codable {
        var version = 1
        var clusters: [KubeCluster]
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let payload = try? dec.decode(FilePayload.self, from: data) {
            clusters = payload.clusters
        }
    }

    private func save() {
        guard !isMirror, let fileURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(FilePayload(clusters: clusters)) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Wire form (the /state snapshot)

    /// `[String: Any]` for the control server's snapshot: the records as
    /// stored plus each cluster's status.
    public func snapshot() -> [String: Any] {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        func dict<T: Encodable>(_ v: T) -> [String: Any]? {
            guard let data = try? enc.encode(v),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }
        return [
            "clusters": clusters.compactMap { dict($0) },
            "status": Dictionary(uniqueKeysWithValues: status.compactMap { k, v in
                dict(v).map { (k.uuidString, $0) }
            }),
        ]
    }

    /// Decode a snapshot produced by `snapshot()` (on the mirroring client).
    public static func decodeSnapshot(_ payload: [String: Any])
        -> (clusters: [KubeCluster], status: [UUID: KubeClusterStatus]) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        func decode<T: Decodable>(_ obj: Any, _ type: T.Type) -> T? {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            return try? dec.decode(T.self, from: data)
        }
        let clusters = ((payload["clusters"] as? [[String: Any]]) ?? [])
            .compactMap { decode($0, KubeCluster.self) }
        var status: [UUID: KubeClusterStatus] = [:]
        for (k, v) in (payload["status"] as? [String: Any]) ?? [:] {
            guard let id = UUID(uuidString: k), let s = decode(v, KubeClusterStatus.self) else { continue }
            status[id] = s
        }
        return (clusters, status)
    }
}

// MARK: - Kubeconfig helpers (pure)

/// The direct-access kubeconfig material for one bromure cluster, as handed
/// to the workspace materializer: real CA + admin client cert, server URL on
/// the VM LAN. (No proxy indirection — the workspace reaches the node
/// straight over the switch, which the MITM never intercepts on-subnet.)
public struct KubeDirectCluster: Equatable, Sendable {
    public var contextName: String
    public var serverURL: String
    /// base64 DER, exactly as a kubeconfig carries it.
    public var caData: String
    public var clientCertData: String
    public var clientKeyData: String

    public init(contextName: String, serverURL: String, caData: String,
                clientCertData: String, clientKeyData: String) {
        self.contextName = contextName
        self.serverURL = serverURL
        self.caData = caData
        self.clientCertData = clientCertData
        self.clientKeyData = clientKeyData
    }

    /// Parse k3s's `/etc/rancher/k3s/k3s.yaml` (a flat, single-context file
    /// with inline `*-data` fields) without a YAML dependency, pointing the
    /// server at `serverIP`. Returns nil if any field is missing.
    public static func fromK3sYAML(_ yaml: String, contextName: String, serverIP: String) -> KubeDirectCluster? {
        func field(_ key: String) -> String? {
            for raw in yaml.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix(key + ":") else { continue }
                let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
            return nil
        }
        guard let ca = field("certificate-authority-data"),
              let cert = field("client-certificate-data"),
              let key = field("client-key-data") else { return nil }
        return KubeDirectCluster(contextName: contextName,
                                 serverURL: "https://\(serverIP):6443",
                                 caData: ca, clientCertData: cert, clientKeyData: key)
    }

    /// A standalone kubeconfig for this cluster alone (the host-side copy the
    /// dashboard offers to copy, and what the fat client can hand a user).
    public var standaloneYAML: String {
        """
        apiVersion: v1
        kind: Config
        current-context: \(contextName)
        clusters:
        - name: \(contextName)
          cluster:
            server: \(serverURL)
            certificate-authority-data: \(caData)
        contexts:
        - name: \(contextName)
          context:
            cluster: \(contextName)
            user: \(contextName)-admin
        users:
        - name: \(contextName)-admin
          user:
            client-certificate-data: \(clientCertData)
            client-key-data: \(clientKeyData)

        """
    }
}
