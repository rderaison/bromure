#if os(macOS)
import AppKit
#endif
import Charts
import SwiftUI

// MARK: - Kubernetes dashboard
//
// The stage surface for a cluster (sidebar › Machines › Kubernetes › row):
// status + key metrics, then nodes / workloads / services / storage / access
// / setup log. Pure SwiftUI over the store's `KubeCluster` + `KubeClusterStatus`
// so the fat client (and the iOS client) render the same view from the
// mirrored snapshot; every action is a closure the host turns into an engine
// call (local) or a `POST /k8s/{id}/…` (remote).

struct KubeDashboardActions {
    var start: () -> Void = {}
    var stop: () -> Void = {}
    var restart: () -> Void = {}
    var delete: () -> Void = {}
    var setAccess: (KubeWorkspaceAccess) -> Void = { _ in }
    var setAutoStart: (Bool) -> Void = { _ in }
    /// Copy the cluster's kubeconfig to the pasteboard (host-side text).
    var copyKubeconfig: () -> Void = {}
}

struct KubeDashboardView: View {
    let store: KubeClusterStore
    let clusterID: UUID
    /// Every workspace (id, name) — for the access editor.
    let workspaces: [KubeWorkspaceRef]
    let actions: KubeDashboardActions

    enum Pane: String, CaseIterable, Hashable {
        case overview, workloads, services, storage, access, log
        var title: LocalizedStringKey {
            switch self {
            case .overview:  return "Overview"
            case .workloads: return "Workloads"
            case .services:  return "Services"
            case .storage:   return "Storage"
            case .access:    return "Access"
            case .log:       return "Log"
            }
        }
    }

    @State private var pane: Pane = .overview
    @State private var query = ""
    @State private var cpuHistory: [Double] = []
    @State private var confirmDelete = false
    @State private var showAccess = false
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    static let kubeBlue = Color(hex: "#326CE5")

    private var cluster: KubeCluster? { store.cluster(clusterID) }
    private var status: KubeClusterStatus { store.status(clusterID) }
    private var probe: KubeProbe? { status.probe }

    var body: some View {
        if let cluster {
            content(cluster)
        } else {
            ContentUnavailableView("Cluster removed", systemImage: "helm")
        }
    }

    private func content(_ cluster: KubeCluster) -> some View {
        VStack(spacing: 0) {
            header(cluster)
            Divider()
            if status.phase == .error, let msg = status.message {
                KubeBanner(kind: .error, text: msg)
            } else if status.phase.isBusy {
                KubeBanner(kind: .progress, text: status.step ?? status.phase.displayName)
            }
            Group {
                switch pane {
                case .overview:  overview(cluster)
                case .workloads: workloads
                case .services:  services(cluster)
                case .storage:   storage(cluster)
                case .access:    KubeAccessEditor(cluster: cluster, workspaces: workspaces,
                                                  onChange: actions.setAccess)
                case .log:       logPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.platformWindowBackground)
        .task(id: clusterID) {
            cpuHistory = []
            while !Task.isCancelled {
                cpuHistory.append(probe?.cpuPercent ?? 0)
                if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // The setup log is what to watch while a cluster comes up.
        .onChange(of: status.phase, initial: true) { _, phase in
            if phase == .creating { pane = .log }
            if phase == .running, pane == .log, status.log.isEmpty { pane = .overview }
        }
        .confirmationDialog("Delete cluster?", isPresented: $confirmDelete) {
            Button("Delete \(cluster.name)", role: .destructive) { actions.delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops every node and deletes their disks, including all Longhorn volumes. Workspaces lose the cluster from their kubeconfig. This can't be undone.")
        }
    }

    // MARK: Header

    private func header(_ cluster: KubeCluster) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Self.kubeBlue.opacity(0.15))
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: "helm").font(.system(size: 18)).foregroundStyle(Self.kubeBlue))
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        KubePhasePill(phase: status.phase)
                        Text(subtitle(cluster)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if !compact { primaryActions(cluster).fixedSize() }
                menu(cluster)
            }
            if compact { primaryActions(cluster) }
            HStack(spacing: 10) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !compact {
                    Spacer()
                    KubeSearchField(text: $query, prompt: searchPrompt).frame(width: 200)
                }
            }
        }
        .padding(.horizontal, compact ? 16 : 18)
        .padding(.vertical, compact ? 12 : 14)
    }

    private var searchPrompt: LocalizedStringKey {
        switch pane {
        case .workloads: return "Filter pods"
        case .services:  return "Filter services"
        case .storage:   return "Filter volumes"
        case .log:       return "Filter log"
        default:         return "Filter"
        }
    }

    private func subtitle(_ cluster: KubeCluster) -> String {
        var parts: [String] = []
        parts.append(String(format: NSLocalizedString("%d node(s)", comment: "k8s"), cluster.spec.nodeCount))
        parts.append("\(cluster.spec.cpusPerNode) vCPU · \(cluster.spec.memoryGBPerNode) GB each")
        if let v = probe?.version, !v.isEmpty { parts.append(v) }
        if let up = status.startedAt, status.phase == .running {
            parts.append(String(format: NSLocalizedString("up %@", comment: "k8s uptime"), kubeUptime(since: up)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func primaryActions(_ cluster: KubeCluster) -> some View {
        HStack(spacing: 8) {
            switch status.phase {
            case .stopped, .error:
                Button { actions.start() } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(Self.kubeBlue)
            case .running:
                Button { actions.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                Button { actions.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.bordered)
            default:
                ProgressView().controlSize(.small)
                Text(status.phase.displayName).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func menu(_ cluster: KubeCluster) -> some View {
        Menu {
            Button { actions.copyKubeconfig() } label: { Label("Copy kubeconfig", systemImage: "doc.on.doc") }
                .disabled(!cluster.provisioned)
            Button { pane = .access } label: { Label("Workspace access…", systemImage: "person.2") }
            Toggle(isOn: Binding(get: { cluster.autoStart }, set: { actions.setAutoStart($0) })) {
                Label("Start with Bromure", systemImage: "power")
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete cluster…", systemImage: "trash") }
                .disabled(status.phase.isBusy)
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 16))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("Cluster actions", comment: "k8s"))
    }

    // MARK: Overview

    private func overview(_ cluster: KubeCluster) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statStrip(cluster)
                nodesCard(cluster)
                if cluster.spec.loadBalancer == .bromure { loadBalancerCard }
                if let warnings = probe?.warnings, !warnings.isEmpty { warningsCard(warnings) }
                if status.phase == .stopped && probe == nil { stoppedHint(cluster) }
            }
            .padding(18)
        }
    }

    private func statStrip(_ cluster: KubeCluster) -> some View {
        let p = probe
        let ready = p?.readyNodes ?? 0
        let total = max(cluster.spec.nodeCount, p?.nodes.count ?? 0)
        let pods = p?.podSummary ?? KubeProbe.PodSummary()
        let cpuVal = p?.cpuPercent ?? 0
        let memUsed = p?.memUsedBytes ?? 0
        let memCap = p?.memCapacityBytes ?? 0
        let lbCount = p?.loadBalancerServices.count ?? 0
        let storageLine: (String, String)
        if let lh = p?.longhorn {
            storageLine = (kubeFormatBytes(lh.storageAvailableBytes),
                           String(format: NSLocalizedString("free of %@ (Longhorn)", comment: "k8s"),
                                  kubeFormatBytes(lh.storageMaximumBytes)))
        } else if cluster.spec.storageEnabled {
            storageLine = ("—", NSLocalizedString("Longhorn not ready", comment: "k8s"))
        } else {
            storageLine = ("\(p?.pvcs.count ?? 0)", NSLocalizedString("volume claims (local-path)", comment: "k8s"))
        }
        let cards: [AnyView] = [
            AnyView(StatCard(title: "Nodes", value: "\(ready)/\(total)",
                             caption: ready == total && total > 0 ? "all Ready" : "Ready / total",
                             systemImage: "server.rack", tint: Self.kubeBlue)),
            AnyView(StatCard(title: "Pods", value: "\(pods.running)",
                             caption: LocalizedStringKey(pods.pending > 0 ? "\(pods.pending) pending · \(pods.total) total" : "running · \(pods.total) total"),
                             systemImage: "cube.fill", tint: .green)),
            AnyView(CPUStatCard(value: cpuVal, history: cpuHistory, tint: .orange)),
            AnyView(StatCard(title: "Memory", value: memCap > 0 ? kubeFormatBytes(memUsed) : "—",
                             caption: LocalizedStringKey(memCap > 0 ? "of \(kubeFormatBytes(memCap)) allocatable" : "waiting for metrics"),
                             systemImage: "memorychip.fill", tint: .purple)),
            AnyView(StatCard(title: "Storage", value: storageLine.0, caption: LocalizedStringKey(storageLine.1),
                             systemImage: "externaldrive.fill", tint: .teal)),
            AnyView(StatCard(title: "Load balancers", value: "\(lbCount)",
                             caption: LocalizedStringKey(cluster.spec.loadBalancer == .bromure
                                 ? (status.hostIP.map { "on \($0)" } ?? "no LAN address")
                                 : cluster.spec.loadBalancer == .metallb ? "MetalLB L2" : "NodePort only"),
                             systemImage: "point.3.connected.trianglepath.dotted", tint: .pink)),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: compact ? 2 : 6),
                         spacing: 12) {
            ForEach(Array(cards.enumerated()), id: \.offset) { $0.element }
        }
    }

    private func nodesCard(_ cluster: KubeCluster) -> some View {
        KubeCard(title: "Nodes", systemImage: "server.rack") {
            if let nodes = probe?.nodes, !nodes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(nodes) { n in
                        HStack(spacing: 10) {
                            Circle().fill(n.ready ? Color.green : Color.orange).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.name).font(.system(size: 12, weight: .medium))
                                Text([n.isControlPlane ? "control plane" : "worker", n.ip, n.version]
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !compact {
                                KubeMiniGauge(label: "CPU", fraction: n.cpuPercent.map { $0 / 100 },
                                              text: n.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                                KubeMiniGauge(label: "Mem", fraction: n.memPercent.map { $0 / 100 },
                                              text: n.memCapacityBytes > 0 && n.memUsedBytes > 0
                                                  ? kubeFormatBytes(n.memUsedBytes) : "—")
                            }
                            Text("\(String(n.pods)) pods").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                            if !n.pressure.isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help(n.pressure.joined(separator: ", "))
                            }
                        }
                        .padding(.vertical, 6)
                        if n.id != nodes.last?.id { Divider() }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(cluster.nodes) { n in
                        HStack(spacing: 10) {
                            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                            Text(n.name).font(.system(size: 12, weight: .medium))
                            Text(n.role == .server ? "control plane" : "worker").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Spacer()
                            Text(n.lastIP ?? "").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        if n.id != cluster.nodes.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var loadBalancerCard: some View {
        KubeCard(title: "LAN load balancer", systemImage: "point.3.connected.trianglepath.dotted") {
            if let pool = cluster?.spec.lanPool, !pool.isEmpty {
                Text("Services of type LoadBalancer get their own LAN address from \(pool), answered by ARP; the host relays each port into the cluster.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let ip = status.hostIP {
                Text("Services of type LoadBalancer are published on this Mac's address \(ip); the host relays each port into the cluster.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if status.lbEndpoints.isEmpty {
                Text(status.phase == .running ? "No LoadBalancer services yet." : "Starts with the cluster.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(status.lbEndpoints) { e in
                        HStack(spacing: 10) {
                            Circle().fill(e.bound ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text("\(e.namespace)/\(e.service)").font(.system(size: 12, weight: .medium))
                            Spacer()
                            if let ip = e.ip ?? status.hostIP, e.bound {
                                Text("\(ip):\(String(e.port))").font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(e.error ?? "pending").font(.system(size: 11)).foregroundStyle(.red)
                            }
                            Text("→ :\(String(e.nodePort))\(e.protocolName.uppercased() == "UDP" ? "/udp" : "")")
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        if e.id != status.lbEndpoints.last?.id { Divider() }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func warningsCard(_ warnings: [KubeProbe.Warning]) -> some View {
        KubeCard(title: "Recent warnings", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings.prefix(8)) { w in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(w.reason).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                            Text(w.namespace.isEmpty ? w.object : "\(w.namespace)/\(w.object)")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            if w.count > 1 { Text("×\(String(w.count))").font(.system(size: 10)).foregroundStyle(.tertiary) }
                        }
                        Text(w.message).font(.system(size: 11)).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func stoppedHint(_ cluster: KubeCluster) -> some View {
        KubeCard(title: "Cluster is stopped", systemImage: "moon.zzz") {
            Text(cluster.provisioned
                 ? "Start the cluster to boot its \(cluster.spec.nodeCount) node VM(s). Workspaces already carry its kubeconfig; kubectl works as soon as the API server is back."
                 : "Provisioning never completed. Start the cluster to run the setup again.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    // MARK: Workloads

    private var workloads: some View {
        let pods = (probe?.pods ?? []).filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
        let grouped = Dictionary(grouping: pods, by: \.namespace).sorted { $0.key < $1.key }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let d = probe?.deployments, d.total > 0 {
                    Text("\(String(d.available))/\(String(d.total)) deployments available")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if pods.isEmpty {
                    KubeEmpty(text: probe?.full == true ? "No pods." : "Collecting workloads…")
                } else {
                    ForEach(grouped, id: \.key) { ns, list in
                        KubeCard(title: LocalizedStringKey(ns), systemImage: "folder", trailing: "\(list.count)") {
                            VStack(spacing: 0) {
                                ForEach(list.sorted { $0.name < $1.name }) { p in
                                    HStack(spacing: 10) {
                                        Circle().fill(p.isHealthy ? Color.green : (p.phase == "Succeeded" ? Color.secondary : Color.orange))
                                            .frame(width: 8, height: 8)
                                        Text(p.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        if !p.reason.isEmpty {
                                            Text(p.reason).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange)
                                        } else {
                                            Text(p.phase).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                        }
                                        Text("\(String(p.ready))/\(String(p.containers))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                        if p.restarts > 0 {
                                            Text("↻\(String(p.restarts))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.orange)
                                        }
                                        if !compact {
                                            Text(p.node).font(.system(size: 10.5)).foregroundStyle(.tertiary).frame(width: 110, alignment: .trailing)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    if p.id != list.last?.id { Divider() }
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    // MARK: Services

    private func services(_ cluster: KubeCluster) -> some View {
        let list = (probe?.services ?? [])
            .filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.isLoadBalancer ? 0 : 1, $0.namespace, $0.name) < ($1.isLoadBalancer ? 0 : 1, $1.namespace, $1.name) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if list.isEmpty {
                    KubeEmpty(text: "No services.")
                } else {
                    ForEach(list) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.isLoadBalancer ? "point.3.connected.trianglepath.dotted"
                                  : s.type == "NodePort" ? "arrow.up.right.square" : "circle.grid.cross")
                                .font(.system(size: 12)).foregroundStyle(s.isLoadBalancer ? Color.pink : .secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("\(s.namespace)/\(s.name)").font(.system(size: 12, weight: .medium))
                                    Text(s.type).font(.system(size: 10)).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                                }
                                Text(servicePorts(s)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                                if s.isLoadBalancer {
                                    if s.ingress.isEmpty {
                                        Text("External IP: pending").font(.system(size: 10.5)).foregroundStyle(.orange)
                                    } else {
                                        Text("External IP: \(s.ingress.joined(separator: ", "))")
                                            .font(.system(size: 10.5)).foregroundStyle(.green).textSelection(.enabled)
                                    }
                                }
                            }
                            Spacer()
                            Text(s.clusterIP).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
            .padding(18)
        }
    }

    private func servicePorts(_ s: KubeProbe.Service) -> String {
        s.ports.map { p in
            var t = "\(p.port)"
            if !p.targetPort.isEmpty, p.targetPort != "\(p.port)" { t += "→\(p.targetPort)" }
            if p.nodePort > 0 { t += " (node \(p.nodePort))" }
            if p.protocolName != "TCP" { t += "/\(p.protocolName)" }
            return t
        }.joined(separator: "  ")
    }

    // MARK: Storage

    private func storage(_ cluster: KubeCluster) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let lh = probe?.longhorn {
                    KubeCard(title: "Longhorn", systemImage: "externaldrive.badge.icloud") {
                        HStack(spacing: 6) {
                            Circle().fill(lh.ready ? Color.green : Color.orange).frame(width: 8, height: 8)
                            Text(lh.ready ? "Ready" : "Starting up").font(.system(size: 12))
                            Text("· \(kubeFormatBytes(lh.storageAvailableBytes)) free of \(kubeFormatBytes(lh.storageMaximumBytes)) · \(cluster.spec.storageReplicas) replica(s) · iSCSI")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if !lh.nodes.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(lh.nodes) { n in
                                    HStack {
                                        Circle().fill(n.ready && n.schedulable ? Color.green : Color.orange).frame(width: 7, height: 7)
                                        Text(n.name).font(.system(size: 11.5))
                                        Spacer()
                                        KubeMiniGauge(label: "Used",
                                                      fraction: n.storageMaximumBytes > 0
                                                          ? Double(n.storageMaximumBytes - n.storageAvailableBytes) / Double(n.storageMaximumBytes) : nil,
                                                      text: kubeFormatBytes(n.storageAvailableBytes) + " free")
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(.top, 6)
                        }
                        let volumes = lh.volumes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.pvc.localizedCaseInsensitiveContains(query) }
                        if !volumes.isEmpty {
                            Divider().padding(.vertical, 4)
                            VStack(spacing: 0) {
                                ForEach(volumes) { v in
                                    HStack(spacing: 10) {
                                        Circle().fill(v.robustness == "healthy" ? Color.green : v.robustness == "degraded" ? Color.orange : Color.secondary)
                                            .frame(width: 8, height: 8)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(v.pvc.isEmpty ? v.name : "\(v.namespace)/\(v.pvc)").font(.system(size: 12, weight: .medium))
                                            Text("\(v.state) · \(v.robustness) · \(v.replicas) replica(s)" + (v.node.isEmpty ? "" : " · on \(v.node)"))
                                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("\(kubeFormatBytes(v.actualSizeBytes)) / \(kubeFormatBytes(v.sizeBytes))")
                                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 5)
                                    if v.id != volumes.last?.id { Divider() }
                                }
                            }
                        }
                    }
                } else if cluster.spec.storageEnabled {
                    KubeEmpty(text: status.phase == .running ? "Longhorn is coming up…" : "Longhorn storage starts with the cluster.")
                }
                let pvcs = (probe?.pvcs ?? []).filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
                KubeCard(title: "Volume claims", systemImage: "internaldrive", trailing: "\(pvcs.count)") {
                    if pvcs.isEmpty {
                        Text("No PersistentVolumeClaims.").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(pvcs) { c in
                                HStack(spacing: 10) {
                                    Circle().fill(c.phase == "Bound" ? Color.green : Color.orange).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(c.namespace)/\(c.name)").font(.system(size: 12, weight: .medium))
                                        Text("\(c.phase) · \(c.storageClass) · \(c.modes.joined(separator: ","))")
                                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(kubeFormatBytes(c.capacityBytes > 0 ? c.capacityBytes : c.requestBytes))
                                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 5)
                                if c.id != pvcs.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    // MARK: Log

    private var logPane: some View {
        let lines = status.log.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty {
                        KubeEmpty(text: "Nothing logged yet.")
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("✗") ? Color.red : line.hasPrefix("▸") || line.hasPrefix("✓") ? Color.primary : Color.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(14)
            }
            .onChange(of: lines.count) { _, n in
                if n > 0 { withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            .onAppear { if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
        }
    }
}

// MARK: - Access editor

struct KubeWorkspaceRef: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// "Which workspaces may touch this cluster" — all (incl. future ones) or an
/// explicit list that is never allowed to be empty.
struct KubeAccessEditor: View {
    let cluster: KubeCluster
    let workspaces: [KubeWorkspaceRef]
    let onChange: (KubeWorkspaceAccess) -> Void

    private var isAll: Bool { if case .all = cluster.access { return true } else { return false } }
    private var selected: Set<UUID> {
        if case .only(let ids) = cluster.access { return ids }
        return Set(workspaces.map(\.id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                KubeCard(title: "Workspace access", systemImage: "person.2") {
                    Text("Allowed workspaces get this cluster in their ~/.kube/config (context “\(cluster.contextName)”) and kubectl talks to it directly over the VM network. Others never see it.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    KubeAccessPicker(isAll: isAll, selected: selected, workspaces: workspaces) { access in
                        onChange(access)
                    }
                }
            }
            .padding(18)
        }
    }
}

/// The access control shared by the creation sheet and the editor.
struct KubeAccessPicker: View {
    let isAll: Bool
    let selected: Set<UUID>
    let workspaces: [KubeWorkspaceRef]
    let onChange: (KubeWorkspaceAccess) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { isAll ? 0 : 1 },
                set: { v in
                    if v == 0 { onChange(.all) }
                    else {
                        let ids = selected.isEmpty ? Set(workspaces.prefix(1).map(\.id)) : selected
                        onChange(ids.isEmpty ? .all : .only(ids))
                    }
                })) {
                Text("All workspaces, including new ones").tag(0)
                Text("Only these workspaces").tag(1)
            }
            .kubeRadioStyle()
            .labelsHidden()
            .disabled(workspaces.isEmpty)
            if !isAll {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(workspaces) { w in
                        Toggle(isOn: Binding(
                            get: { selected.contains(w.id) },
                            set: { on in
                                var ids = selected
                                if on { ids.insert(w.id) } else { ids.remove(w.id) }
                                // Never empty: the last one stays checked.
                                if ids.isEmpty { return }
                                onChange(.only(ids))
                            })) {
                            Text(w.name).font(.system(size: 12))
                        }
                        .kubeCheckboxStyle()
                    }
                    if selected.count <= 1 {
                        Text("At least one workspace must keep access.")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 18)
            }
            if workspaces.isEmpty {
                Text("No workspaces yet — every workspace you create will get access.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - New cluster sheet

struct NewKubeClusterSheet: View {
    let workspaces: [KubeWorkspaceRef]
    /// Names already taken (the sheet suggests a free one).
    let existingNames: [String]
    let hostMemoryGB: Int
    let onCreate: (_ name: String, _ spec: KubeClusterSpec, _ access: KubeWorkspaceAccess, _ autoStart: Bool) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var spec = KubeClusterSpec()
    @State private var access: KubeWorkspaceAccess = .all
    @State private var autoStart = true

    private var totalMemoryGB: Int { spec.nodeCount * spec.memoryGBPerNode }
    private var totalDiskGB: Int { spec.storageEnabled ? spec.nodeCount * spec.storageDiskGB : 0 }
    private var memoryWarning: String? {
        guard hostMemoryGB > 0 else { return nil }
        if totalMemoryGB > hostMemoryGB - 4 {
            return String(format: NSLocalizedString("That's %d GB of this Mac's %d GB — workspaces need room too.", comment: "k8s"),
                          totalMemoryGB, hostMemoryGB)
        }
        return nil
    }
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(KubeDashboardView.kubeBlue.opacity(0.15))
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: "helm").font(.system(size: 18)).foregroundStyle(KubeDashboardView.kubeBlue))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Kubernetes cluster").font(.system(size: 16, weight: .semibold))
                    Text("A k3s cluster in its own VMs, shared by your workspaces.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Cluster") {
                        HStack {
                            Text("Name").frame(width: 120, alignment: .trailing)
                            TextField("dev", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        }
                        Text("Nodes will be named k8s-\(KubeCluster.slug(for: name.isEmpty ? "dev" : name))-1, -2, …")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.leading, 128)
                    }
                    section("Nodes") {
                        stepperRow("Nodes", value: $spec.nodeCount, range: KubeClusterSpec.nodeRange,
                                   caption: spec.nodeCount == 1 ? "one node: control plane + workloads" : "node 1 is the control plane; the rest join as workers")
                        stepperRow("vCPUs per node", value: $spec.cpusPerNode, range: KubeClusterSpec.cpuRange, caption: nil)
                        stepperRow("Memory per node (GB)", value: $spec.memoryGBPerNode, range: KubeClusterSpec.memoryRange,
                                   caption: "\(totalMemoryGB) GB in total")
                        if let w = memoryWarning {
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5)).foregroundStyle(.orange).padding(.leading, 128)
                        }
                    }
                    section("Storage") {
                        Toggle(isOn: $spec.storageEnabled) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Longhorn distributed storage")
                                Text("Replicated block volumes served over iSCSI (open-iscsi on every node, a dedicated data disk each). Becomes the default storage class.")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        .kubeCheckboxStyle()
                        .padding(.leading, 128)
                        if spec.storageEnabled {
                            stepperRow("Data disk per node (GB)", value: $spec.storageDiskGB, range: KubeClusterSpec.storageRange,
                                       step: 10, caption: "\(totalDiskGB) GB reserved (sparse — only written blocks use space) · \(spec.storageReplicas) replica(s)")
                        }
                    }
                    section("Networking") {
                        HStack(alignment: .top) {
                            Text("Load balancer").frame(width: 120, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 6) {
                                Picker("", selection: $spec.loadBalancer) {
                                    ForEach(KubeLoadBalancerKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                                }
                                .kubeRadioStyle().labelsHidden()
                                Text(lbHelp).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                if spec.loadBalancer == .bromure {
                                    TextField("LAN address pool, e.g. 10.0.0.20-10.0.0.29 (optional)",
                                              text: Binding(get: { spec.lanPool ?? "" },
                                                            set: { spec.lanPool = $0.isEmpty ? nil : $0 }))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 360)
                                    Text("Spare addresses on your LAN: each LoadBalancer Service gets its own, answered by ARP like MetalLB — nothing on this Mac is exposed. Leave empty to share the Mac's address by port.")
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Toggle(isOn: $spec.ingress) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Traefik ingress controller")
                                Text("k3s's bundled ingress. With the LAN load balancer it publishes ports 80/443 on this Mac.")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        .kubeCheckboxStyle()
                        .padding(.leading, 128)
                    }
                    section("Workspace access") {
                        HStack(alignment: .top) {
                            Text("Kubeconfig").frame(width: 120, alignment: .trailing)
                            KubeAccessPicker(isAll: { if case .all = access { return true } else { return false } }(),
                                             selected: { if case .only(let ids) = access { return ids } else { return Set(workspaces.map(\.id)) } }(),
                                             workspaces: workspaces) { access = $0 }
                        }
                        Toggle(isOn: $autoStart) { Text("Start with Bromure") }
                            .kubeCheckboxStyle().padding(.leading, 128)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Setup takes a few minutes: the nodes boot, download k3s and pull the add-on images.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Create Cluster") {
                    onCreate(name.trimmingCharacters(in: .whitespaces), spec.clamped, access, autoStart)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 620, height: 640)
        .onAppear {
            if name.isEmpty {
                var candidate = "dev"
                var n = 2
                while existingNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    candidate = "dev \(n)"; n += 1
                }
                name = candidate
            }
        }
    }

    private var lbHelp: String {
        switch spec.loadBalancer {
        case .bromure:
            return NSLocalizedString("The cluster stays on the VM network; each LoadBalancer port is published on this Mac's LAN address and relayed in. Reachable from your LAN, this Mac and every workspace.", comment: "k8s")
        case .metallb:
            return NSLocalizedString("MetalLB hands out addresses from the VM network (reserved from DHCP). Reachable from the workspaces and this Mac only.", comment: "k8s")
        case .none:
            return NSLocalizedString("Services of type LoadBalancer stay pending; use NodePort or ClusterIP.", comment: "k8s")
        }
    }

    @ViewBuilder private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.6)
            content()
        }
    }

    private func stepperRow(_ label: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>,
                            step: Int = 1, caption: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 120, alignment: .trailing)
            Stepper(value: value, in: range, step: step) {
                Text(String(value.wrappedValue)).font(.system(size: 12).monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            .fixedSize()
            if let caption { Text(caption).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Small pieces

struct KubePhasePill: View {
    let phase: KubeClusterPhase
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(phase.displayName).font(.system(size: 10.5, weight: .medium))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundStyle(color)
    }
    private var color: Color {
        switch phase {
        case .running: return .green
        case .error: return .red
        case .stopped: return .secondary
        default: return .orange
        }
    }
}

private struct KubeCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var trailing: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary) }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06))))
    }
}

private struct KubeMiniGauge: View {
    let label: String
    let fraction: Double?
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let f = fraction {
                    Capsule().fill(f > 0.9 ? Color.red : f > 0.7 ? Color.orange : Color.green)
                        .frame(width: max(2, 46 * min(1, max(0, f))))
                }
            }
            .frame(width: 46, height: 5)
            Text(text).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
        }
    }
}

private struct KubeEmpty: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 30)
    }
}

private struct KubeSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
}

private struct KubeBanner: View {
    enum Kind { case error, progress }
    let kind: Kind
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            if kind == .progress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 12))
            }
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(3).textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(kind == .error ? Color.red.opacity(0.10) : KubeDashboardView.kubeBlue.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

func kubeFormatBytes(_ b: Int64) -> String {
    let v = Double(b)
    let tb = Double(1 << 40), gb = Double(1 << 30), mb = Double(1 << 20), kb = Double(1 << 10)
    if v >= tb { return String(format: "%.1f TB", v / tb) }
    if v >= gb { return String(format: "%.1f GB", v / gb) }
    if v >= mb { return String(format: "%.0f MB", v / mb) }
    if v >= kb { return String(format: "%.0f KB", v / kb) }
    return "\(b) B"
}

func kubeUptime(since: Date) -> String {
    let s = Int(Date().timeIntervalSince(since))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86400)d \((s % 86400) / 3600)h"
}

// macOS-only control styles, no-ops elsewhere so the same sheet builds for
// the iOS/visionOS client.
extension View {
    @ViewBuilder func kubeRadioStyle() -> some View {
        #if os(macOS)
        self.pickerStyle(.radioGroup)
        #else
        self.pickerStyle(.inline)
        #endif
    }
    @ViewBuilder func kubeCheckboxStyle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}
