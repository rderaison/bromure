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
                awsEmulatorCard(cluster)
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

    @ViewBuilder private func awsEmulatorCard(_ cluster: KubeCluster) -> some View {
        if cluster.spec.awsEmulator {
            KubeCard(title: "AWS emulator", systemImage: "cloud.fill") {
                let addon = probe?.floci
                let eps = status.awsEmulatorEndpoints(for: cluster)
                HStack(spacing: 6) {
                    Circle().fill(addon?.ready == true ? Color.green : (addon == nil ? Color.secondary.opacity(0.4) : Color.orange))
                        .frame(width: 8, height: 8)
                    Text(addon == nil ? (status.phase == .running ? "Not installed" : "Starts with the cluster")
                         : addon?.ready == true ? "floci ready" : "floci starting")
                        .font(.system(size: 12))
                    Spacer()
                    Text("floci · port \(String(KubeClusterSpec.awsEmulatorPort))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                if let lan = eps.lan {
                    HStack(spacing: 6) {
                        Text("From this Mac and the LAN").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                        Text(lan).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if let vm = eps.vmNetwork {
                    HStack(spacing: 6) {
                        Text("From the workspaces").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                        Text(vm).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if let ep = eps.vmNetwork ?? eps.lan {
                    Text("export AWS_ENDPOINT_URL=\(ep) AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                }
                Text("Any credentials work (a 12-digit access key id selects an account). State persists on the cluster's default storage class. Services that spawn containers — Lambda, RDS… — use the node's Docker and are best effort.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
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
                            if e.isVMScoped {
                                Text("VM network").font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                                    .foregroundStyle(.secondary)
                                    .help("Private: bromure.io/scope: vm — reachable from the workspaces and this Mac, not from the LAN")
                            }
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
                if let syn = cluster.spec.synology, syn.isConfigured {
                    KubeCard(title: "Synology NAS", systemImage: "externaldrive.connected.to.line.below") {
                        HStack(spacing: 6) {
                            let addon = probe?.synology
                            Circle().fill(addon?.ready == true ? Color.green : (addon == nil ? Color.secondary.opacity(0.4) : Color.orange))
                                .frame(width: 8, height: 8)
                            Text(addon == nil ? (status.phase == .running ? "Driver not installed" : "Starts with the cluster")
                                 : addon?.ready == true ? "Driver ready" : "Driver starting")
                                .font(.system(size: 12))
                            Text("· \(syn.host):\(String(syn.port)) · \(syn.volumes.isEmpty ? "volume chosen by DSM" : syn.volumes.joined(separator: ", ")) · \(syn.protocolKind.rawValue.uppercased()) · \(syn.storageClassNames.joined(separator: ", ")) (first is default)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
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
    let onCreate: (_ name: String, _ spec: KubeClusterSpec, _ access: KubeWorkspaceAccess, _ autoStart: Bool,
                   _ synologyPassword: String?) -> Void
    let onCancel: () -> Void

    /// The workspace editor's shape: a category sidebar and one pane each.
    enum Category: String, CaseIterable, Identifiable {
        case general    = "General"
        case nodes      = "Nodes"
        case storage    = "Storage"
        case networking = "Networking"
        case addOns     = "Add-ons"
        case access     = "Access"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general:    return "helm"
            case .nodes:      return "server.rack"
            case .storage:    return "internaldrive.fill"
            case .networking: return "network"
            case .addOns:     return "puzzlepiece.extension.fill"
            case .access:     return "person.2.fill"
            }
        }

        var color: Color {
            switch self {
            case .general:    return KubeDashboardView.kubeBlue
            case .nodes:      return .indigo
            case .storage:    return .orange
            case .networking: return .teal
            case .addOns:     return .purple
            case .access:     return .green
            }
        }
    }

    @State private var name: String = ""
    @State private var spec = KubeClusterSpec()
    @State private var access: KubeWorkspaceAccess = .all
    @State private var autoStart = true
    @State private var synologyOn = false
    @State private var synology = KubeSynologySpec()
    @State private var synologyPassword = ""
    @State private var category: Category = .general

    /// Optional-selection bridge for the sidebar List (the non-optional
    /// initializer is macOS-only); a tap elsewhere keeps the current pane.
    private var categoryBinding: Binding<Category?> {
        Binding(get: { category }, set: { if let c = $0 { category = c } })
    }

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
    /// Why "Create" is disabled, in a few words — nil when it isn't.
    private var blocker: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return NSLocalizedString("Give the cluster a name.", comment: "k8s") }
        if synologyOn {
            if !synology.isConfigured { return NSLocalizedString("Synology: address and user are required.", comment: "k8s") }
            if synologyPassword.isEmpty { return NSLocalizedString("Synology: password is required.", comment: "k8s") }
        }
        return nil
    }
    private var canCreate: Bool { blocker == nil }

    /// One line for the button bar: what you're about to get.
    private var summary: String {
        var parts = [String(format: NSLocalizedString("%d node(s) · %d vCPU · %d GB each", comment: "k8s"),
                            spec.nodeCount, spec.cpusPerNode, spec.memoryGBPerNode)]
        if synologyOn { parts.append("Synology") }
        if spec.storageEnabled { parts.append("Longhorn") }
        parts.append(spec.loadBalancer == .bromure ? "LAN LB" : spec.loadBalancer == .metallb ? "MetalLB" : "no LB")
        if spec.awsEmulator { parts.append("AWS") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(Category.allCases, selection: categoryBinding) { c in
                    Label {
                        Text(LocalizedStringKey(c.rawValue))
                    } icon: {
                        Image(systemName: c.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(c.color.gradient, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .tag(c)
                }
                .listStyle(.sidebar)
                #if os(macOS)
                .frame(width: 170)
                #else
                .frame(width: 230)
                #endif

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? "New Kubernetes cluster" : name)
                            .font(.title2.bold())
                        detail(for: category)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if let blocker {
                    Text(blocker).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Button("Create") {
                    var final = spec.clamped
                    final.synology = synologyOn && synology.isConfigured ? synology : nil
                    onCreate(name.trimmingCharacters(in: .whitespaces), final, access, autoStart,
                             synologyOn ? synologyPassword : nil)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(12)
        }
        #if os(macOS)
        .frame(width: 720, height: 520)
        #endif
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

    // MARK: Panes

    @ViewBuilder
    private func detail(for category: Category) -> some View {
        switch category {
        case .general:    generalPane
        case .nodes:      nodesPane
        case .storage:    storagePane
        case .networking: networkingPane
        case .addOns:     addOnsPane
        case .access:     accessPane
        }
    }

    /// macOS: the grouped Form of the workspace editor (one label column,
    /// one control column). iOS: a Form is a List and collapses inside the
    /// detail ScrollView, so the same rows stack as labeled content.
    @ViewBuilder
    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(macOS)
        Form { content() }
            .formStyle(.grouped)
        #else
        VStack(alignment: .leading, spacing: 16) { content() }
        #endif
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var generalPane: some View {
        pane {
            Section {
                TextField(NSLocalizedString("Name", comment: "k8s"), text: $name, prompt: Text("dev"))
                Toggle(NSLocalizedString("Start with Bromure", comment: "k8s"), isOn: $autoStart)
            } footer: {
                caption(String(format: NSLocalizedString("Nodes are named k8s-%@-1, -2, … The cluster is a shared machine: every workspace on its access list gets it in ~/.kube/config, and their agents learn about it through the infrastructure MCP.", comment: "k8s"),
                               KubeCluster.slug(for: name.isEmpty ? "dev" : name)))
            }
            Section(NSLocalizedString("Summary", comment: "k8s")) {
                LabeledContent(NSLocalizedString("Nodes", comment: "k8s"),
                               value: String(format: NSLocalizedString("%d × %d vCPU, %d GB", comment: "k8s"), spec.nodeCount, spec.cpusPerNode, spec.memoryGBPerNode))
                LabeledContent(NSLocalizedString("Storage", comment: "k8s"), value: storageSummary)
                LabeledContent(NSLocalizedString("Load balancer", comment: "k8s"), value: spec.loadBalancer.displayName)
                LabeledContent(NSLocalizedString("Add-ons", comment: "k8s"), value: addOnsSummary)
            }
        }
    }

    private var storageSummary: String {
        var parts: [String] = []
        if synologyOn { parts.append(NSLocalizedString("Synology NAS (default)", comment: "k8s")) }
        if spec.storageEnabled {
            parts.append(String(format: NSLocalizedString("Longhorn, %d GB per node%@", comment: "k8s"),
                                spec.storageDiskGB, synologyOn ? "" : NSLocalizedString(" (default)", comment: "k8s")))
        }
        parts.append("local-path")
        return parts.joined(separator: " · ")
    }

    private var addOnsSummary: String {
        var parts: [String] = []
        if spec.ingress { parts.append("Traefik") }
        if spec.awsEmulator { parts.append(NSLocalizedString("AWS emulator", comment: "k8s")) }
        return parts.isEmpty ? NSLocalizedString("None", comment: "k8s") : parts.joined(separator: " · ")
    }

    private var nodesPane: some View {
        pane {
            Section {
                LabeledContent(NSLocalizedString("Nodes", comment: "k8s")) {
                    Stepper(value: $spec.nodeCount, in: KubeClusterSpec.nodeRange) {
                        Text(String(spec.nodeCount)).monospacedDigit()
                    }
                }
                LabeledContent(NSLocalizedString("vCPUs per node", comment: "k8s")) {
                    Stepper(value: $spec.cpusPerNode, in: KubeClusterSpec.cpuRange) {
                        Text(String(spec.cpusPerNode)).monospacedDigit()
                    }
                }
                LabeledContent(NSLocalizedString("Memory per node", comment: "k8s")) {
                    Stepper(value: $spec.memoryGBPerNode, in: KubeClusterSpec.memoryRange) {
                        Text(String(format: NSLocalizedString("%d GB", comment: "k8s"), spec.memoryGBPerNode)).monospacedDigit()
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    caption(spec.nodeCount == 1
                            ? String(format: NSLocalizedString("One node: control plane and workloads together. %d GB of RAM in total.", comment: "k8s"), totalMemoryGB)
                            : String(format: NSLocalizedString("Node 1 is the control plane and also runs workloads; the others join as workers. %d GB of RAM in total.", comment: "k8s"), totalMemoryGB))
                    if let w = memoryWarning {
                        Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var storagePane: some View {
        pane {
            Section {
                Toggle(NSLocalizedString("Longhorn distributed storage", comment: "k8s"), isOn: $spec.storageEnabled)
                if spec.storageEnabled {
                    LabeledContent(NSLocalizedString("Data disk per node", comment: "k8s")) {
                        Stepper(value: $spec.storageDiskGB, in: KubeClusterSpec.storageRange, step: 10) {
                            Text(String(format: NSLocalizedString("%d GB", comment: "k8s"), spec.storageDiskGB)).monospacedDigit()
                        }
                    }
                }
            } footer: {
                caption(spec.storageEnabled
                        ? String(format: NSLocalizedString("Replicated block volumes served over iSCSI from a dedicated data disk on every node. %d GB reserved in total (sparse: only written blocks use space), %d replica(s). Storage class bromure-longhorn%@.", comment: "k8s"),
                                 totalDiskGB, spec.storageReplicas, synologyOn ? "" : NSLocalizedString(", the default", comment: "k8s"))
                        : NSLocalizedString("Off: only k3s's node-local local-path class, which pins a pod to its node.", comment: "k8s"))
            }
            Section {
                Toggle(NSLocalizedString("Synology NAS", comment: "k8s"), isOn: $synologyOn)
                if synologyOn {
                    TextField(NSLocalizedString("DSM address", comment: "k8s"), text: $synology.host, prompt: Text("nas.local or 192.168.1.10"))
                    TextField(NSLocalizedString("Port", comment: "k8s"), value: $synology.port, format: .number)
                    Toggle(NSLocalizedString("HTTPS", comment: "k8s"), isOn: $synology.https)
                    TextField(NSLocalizedString("DSM user", comment: "k8s"), text: $synology.username)
                    SecureField(NSLocalizedString("DSM password", comment: "k8s"), text: $synologyPassword)
                    TextField(NSLocalizedString("Volumes (optional)", comment: "k8s"), text: $synology.location, prompt: Text("/volume1, /volume3"))
                    Picker(NSLocalizedString("Protocol", comment: "k8s"), selection: $synology.protocolKind) {
                        ForEach(KubeSynologySpec.TransportKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    TextField(NSLocalizedString("Filesystem", comment: "k8s"), text: $synology.fsType)
                }
            } footer: {
                if synologyOn {
                    VStack(alignment: .leading, spacing: 4) {
                        caption(synology.volumes.isEmpty
                                ? NSLocalizedString("Leave volumes empty and DSM picks a volume with free space (storage class bromure-synology, the default). Name volumes to get one class each, the first one default.", comment: "k8s")
                                : String(format: NSLocalizedString("Storage classes: %@ — the first is the default.", comment: "k8s"), synology.storageClassNames.joined(separator: ", ")))
                        caption(NSLocalizedString("Volumes through Synology's CSI driver (iSCSI LUNs or SMB shares). The password is stored encrypted on this Mac and only lands in the cluster's own Secrets; the DSM account needs storage-manager rights. The driver's manifests are fetched from Synology's GitHub at setup.", comment: "k8s"))
                    }
                } else {
                    caption(NSLocalizedString("Persistent volumes on your NAS through Synology's CSI driver; becomes the default storage class.", comment: "k8s"))
                }
            }
        }
    }

    private var networkingPane: some View {
        pane {
            Section {
                // Every choice visible with its one-line meaning, so "VM
                // network only" is a decision, not a hidden popup entry.
                Picker(NSLocalizedString("Load balancer", comment: "k8s"), selection: $spec.loadBalancer) {
                    ForEach(KubeLoadBalancerKind.allCases, id: \.self) { kind in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.displayName)
                            Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tag(kind)
                    }
                }
                .kubeRadioStyle()
                if spec.loadBalancer == .bromure {
                    TextField(NSLocalizedString("LAN address pool", comment: "k8s"),
                              text: Binding(get: { spec.lanPool ?? "" },
                                            set: { spec.lanPool = $0.isEmpty ? nil : $0 }),
                              prompt: Text("10.0.0.20-10.0.0.29 (optional)"))
                }
            } footer: {
                if spec.loadBalancer == .bromure {
                    VStack(alignment: .leading, spacing: 4) {
                        caption(NSLocalizedString("A pool of spare addresses on your LAN gives each LoadBalancer Service its own address, answered by ARP like MetalLB — nothing on this Mac is exposed. Leave it empty to share the Mac's address by port.", comment: "k8s"))
                        caption(NSLocalizedString("Per Service: the annotation bromure.io/scope: vm keeps it private (an address on the VM network, for the workspaces and this Mac only); bromure.io/loadBalancerIP asks for a specific address. Agents get this from the infrastructure MCP.", comment: "k8s"))
                    }
                } else if spec.loadBalancer == .metallb {
                    caption(NSLocalizedString("Twenty addresses at the top of the VM subnet are reserved for MetalLB when the cluster is set up. Workspaces reach them directly; the Mac does through the VM network interface.", comment: "k8s"))
                }
            }
            Section {
                Toggle(NSLocalizedString("Traefik ingress controller", comment: "k8s"), isOn: $spec.ingress)
            } footer: {
                caption(NSLocalizedString("k3s's bundled ingress. With the LAN load balancer it publishes ports 80 and 443 on this Mac.", comment: "k8s"))
            }
        }
    }

    private var addOnsPane: some View {
        pane {
            Section {
                Toggle(NSLocalizedString("AWS emulator (floci)", comment: "k8s"), isOn: $spec.awsEmulator)
            } footer: {
                caption(NSLocalizedString("A local AWS inside the cluster: S3, DynamoDB, SQS, SNS, Lambda, API Gateway, Step Functions, EventBridge and 100+ more services, with data kept on the cluster's storage. Published as a LoadBalancer Service on port 4566; the dashboard and the agents' infrastructure MCP hand out the endpoint and the test credentials (AWS_ENDPOINT_URL, any access key). Free and open source (MIT), pulled from Docker Hub at setup. Services that spawn containers, such as Lambda and RDS, use the node's Docker and are best effort.", comment: "k8s"))
            }
        }
    }

    private var accessPane: some View {
        pane {
            Section {
                KubeAccessPicker(isAll: { if case .all = access { return true } else { return false } }(),
                                 selected: { if case .only(let ids) = access { return ids } else { return Set(workspaces.map(\.id)) } }(),
                                 workspaces: workspaces) { access = $0 }
            } header: {
                Text(NSLocalizedString("Kubeconfig", comment: "k8s"))
            } footer: {
                caption(NSLocalizedString("Workspaces on the list get the cluster in their ~/.kube/config and see it through the infrastructure MCP. You can change this later from the dashboard.", comment: "k8s"))
            }
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

// MARK: - Registry dashboard

struct KubeRegistryActions {
    var start: () -> Void = {}
    var stop: () -> Void = {}
    var restart: () -> Void = {}
    var delete: () -> Void = {}
    var setAccess: (KubeWorkspaceAccess) -> Void = { _ in }
    var setAutoStart: (Bool) -> Void = { _ in }
}

struct KubeRegistryDashboardView: View {
    let store: KubeClusterStore
    let registryID: UUID
    let workspaces: [KubeWorkspaceRef]
    let actions: KubeRegistryActions

    enum Pane: String, CaseIterable, Hashable {
        case images, access, log
        var title: LocalizedStringKey {
            switch self {
            case .images: return "Images"
            case .access: return "Access"
            case .log:    return "Log"
            }
        }
    }

    @State private var pane: Pane = .images
    @State private var query = ""
    @State private var confirmDelete = false
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    static let registryTint = Color(hex: "#F97316")

    private var registry: KubeRegistry? { store.registry(registryID) }
    private var status: KubeClusterStatus { store.status(registryID) }
    private var info: KubeRegistryInfo? { status.registry }

    var body: some View {
        if let registry {
            content(registry)
        } else {
            ContentUnavailableView("Registry removed", systemImage: "shippingbox")
        }
    }

    private func content(_ registry: KubeRegistry) -> some View {
        VStack(spacing: 0) {
            header(registry)
            Divider()
            if status.phase == .error, let msg = status.message {
                KubeBanner(kind: .error, text: msg)
            } else if status.phase.isBusy {
                KubeBanner(kind: .progress, text: status.step ?? status.phase.displayName)
            }
            Group {
                switch pane {
                case .images: images(registry)
                case .access:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            KubeCard(title: "Workspace access", systemImage: "person.2") {
                                Text("Allowed workspaces get \(status.address ?? "the registry") as an insecure registry for docker and BROMURE_REGISTRY in their shell. Every cluster can pull from it.")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                KubeAccessPicker(isAll: { if case .all = registry.access { return true } else { return false } }(),
                                                 selected: { if case .only(let ids) = registry.access { return ids } else { return Set(workspaces.map(\.id)) } }(),
                                                 workspaces: workspaces) { actions.setAccess($0) }
                            }
                        }
                        .padding(18)
                    }
                case .log: logPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.platformWindowBackground)
        .onChange(of: status.phase, initial: true) { _, phase in
            if phase == .creating { pane = .log }
            if phase == .running, pane == .log { pane = .images }
        }
        .confirmationDialog("Delete registry?", isPresented: $confirmDelete) {
            Button("Delete \(registry.name)", role: .destructive) { actions.delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops the registry VM and deletes every image it holds. Workspaces and clusters stop trusting its address. This can't be undone.")
        }
    }

    private func header(_ registry: KubeRegistry) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Self.registryTint.opacity(0.15))
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: "shippingbox.and.arrow.backward").font(.system(size: 17)).foregroundStyle(Self.registryTint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(registry.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        KubePhasePill(phase: status.phase)
                        Text(subtitle(registry)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if !compact { primaryActions.fixedSize() }
                Menu {
                    Button { if let a = status.address { platformCopyToPasteboard(a) } } label: { Label("Copy address", systemImage: "doc.on.doc") }
                        .disabled(status.address == nil)
                    Button { pane = .access } label: { Label("Workspace access…", systemImage: "person.2") }
                    Toggle(isOn: Binding(get: { registry.autoStart }, set: { actions.setAutoStart($0) })) {
                        Label("Start with Bromure", systemImage: "power")
                    }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete registry…", systemImage: "trash") }
                        .disabled(status.phase.isBusy)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 16))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if compact { primaryActions }
            HStack(spacing: 10) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !compact {
                    Spacer()
                    KubeSearchField(text: $query, prompt: "Filter images").frame(width: 200)
                }
            }
        }
        .padding(.horizontal, compact ? 16 : 18)
        .padding(.vertical, compact ? 12 : 14)
    }

    private func subtitle(_ registry: KubeRegistry) -> String {
        var parts: [String] = []
        if let a = status.address { parts.append(a) }
        parts.append("\(registry.memoryGB) GB RAM · \(registry.diskGB) GB disk")
        if let up = status.startedAt, status.phase == .running {
            parts.append(String(format: NSLocalizedString("up %@", comment: "k8s uptime"), kubeUptime(since: up)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var primaryActions: some View {
        HStack(spacing: 8) {
            switch status.phase {
            case .stopped, .error:
                Button { actions.start() } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(Self.registryTint)
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

    private func images(_ registry: KubeRegistry) -> some View {
        let repos = (info?.repositories ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: compact ? 2 : 3), spacing: 12) {
                    StatCard(title: "Repositories", value: "\(info?.repositories.count ?? 0)",
                             caption: LocalizedStringKey("\(String(info?.imageCount ?? 0)) tagged images"),
                             systemImage: "shippingbox.fill", tint: Self.registryTint)
                    StatCard(title: "Disk", value: info.map { kubeFormatBytes($0.diskUsedBytes) } ?? "—",
                             caption: LocalizedStringKey(info.map { "of \(kubeFormatBytes($0.diskTotalBytes))" } ?? "waiting for the registry"),
                             systemImage: "internaldrive.fill", tint: .teal)
                    StatCard(title: "Address", value: status.address ?? "—",
                             caption: "plain HTTP on the VM network",
                             systemImage: "network", tint: .purple)
                }
                if let a = status.address {
                    KubeCard(title: "Push from a workspace", systemImage: "terminal") {
                        Text("docker build -t \(a)/myapp:dev .\ndocker push \(a)/myapp:dev\nkubectl run myapp --image=\(a)/myapp:dev")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Text("dockerd in allowed workspaces already trusts this address, and BROMURE_REGISTRY carries it. Every cluster pulls from it without extra configuration.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                KubeCard(title: "Images", systemImage: "square.stack.3d.up", trailing: "\(repos.count)") {
                    if repos.isEmpty {
                        Text(status.phase == .running ? "Nothing pushed yet." : "Start the registry to see its images.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(repos) { r in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.name).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                                        Text(r.tags.isEmpty ? "no tags" : r.tags.joined(separator: "  "))
                                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    Text("\(String(r.tags.count))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 5)
                                if r.id != repos.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private var logPane: some View {
        let lines = status.log.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty { KubeEmpty(text: "Nothing logged yet.") }
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
            .onChange(of: lines.count) { _, n in if n > 0 { withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) } } }
            .onAppear { if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
        }
    }
}

// MARK: - New registry sheet

struct NewRegistrySheet: View {
    let workspaces: [KubeWorkspaceRef]
    let existingNames: [String]
    let onCreate: (_ name: String, _ memoryGB: Int, _ diskGB: Int, _ access: KubeWorkspaceAccess, _ autoStart: Bool) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var memoryGB = 1
    @State private var diskGB = 40
    @State private var access: KubeWorkspaceAccess = .all
    @State private var autoStart = true

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// macOS: the workspace editor's grouped Form; iOS: stacked rows.
    @ViewBuilder
    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(macOS)
        Form { content() }
            .formStyle(.grouped)
        #else
        VStack(alignment: .leading, spacing: 16) { content() }
        #endif
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "shippingbox.and.arrow.backward")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(KubeRegistryDashboardView.registryTint.gradient, in: RoundedRectangle(cornerRadius: 5))
                        Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? "New container registry" : name)
                            .font(.title2.bold())
                    }
                    pane {
                        Section {
                            TextField(NSLocalizedString("Name", comment: "registry"), text: $name, prompt: Text("registry"))
                            Toggle(NSLocalizedString("Start with Bromure", comment: "registry"), isOn: $autoStart)
                        } footer: {
                            caption(NSLocalizedString("A private Docker registry in its own VM: build in a workspace, push here, run it in a cluster. Plain HTTP on the VM network; it never leaves this Mac.", comment: "registry"))
                        }
                        Section(NSLocalizedString("Machine", comment: "registry")) {
                            LabeledContent(NSLocalizedString("Memory", comment: "registry")) {
                                Stepper(value: $memoryGB, in: KubeRegistry.memoryRange) {
                                    Text(String(format: NSLocalizedString("%d GB", comment: "registry"), memoryGB)).monospacedDigit()
                                }
                            }
                            LabeledContent(NSLocalizedString("Image storage", comment: "registry")) {
                                Stepper(value: $diskGB, in: KubeRegistry.diskRange, step: 10) {
                                    Text(String(format: NSLocalizedString("%d GB", comment: "registry"), diskGB)).monospacedDigit()
                                }
                            }
                        }
                        Section {
                            KubeAccessPicker(isAll: { if case .all = access { return true } else { return false } }(),
                                             selected: { if case .only(let ids) = access { return ids } else { return Set(workspaces.map(\.id)) } }(),
                                             workspaces: workspaces) { access = $0 }
                        } header: {
                            Text(NSLocalizedString("Push access", comment: "registry"))
                        } footer: {
                            caption(NSLocalizedString("Every cluster can pull from the registry; pushing is per workspace (docker there trusts it and $BROMURE_REGISTRY holds its address). The image disk is sparse: only pushed layers use space.", comment: "registry"))
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Text(String(format: NSLocalizedString("%d GB RAM · %d GB for images", comment: "registry"), memoryGB, diskGB))
                    .font(.caption).foregroundStyle(.tertiary)
                Button("Create") {
                    onCreate(name.trimmingCharacters(in: .whitespaces), memoryGB, diskGB, access, autoStart)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(12)
        }
        #if os(macOS)
        .frame(width: 560, height: 600)
        #endif
        .onAppear {
            if name.isEmpty {
                var candidate = "registry"
                var n = 2
                while existingNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    candidate = "registry \(n)"; n += 1
                }
                name = candidate
            }
        }
    }
}
