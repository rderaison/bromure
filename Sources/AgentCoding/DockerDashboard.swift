#if os(macOS)
import AppKit
#endif
import Charts
import SwiftUI

/// Owns an arrow cursor rect over its bounds — used as a background so the
/// dashboard never inherits a stray I-beam from neighbouring text/framebuffer
/// views. Real text fields layered above keep their own I-beam.
#if os(macOS)
private struct ArrowCursor: NSViewRepresentable {
    final class View: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    }
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}
#else
private struct ArrowCursor: View { var body: some View { Color.clear } }
#endif

// MARK: - Docker dashboard

/// A clean, modern Docker dashboard shown in the stage when a workspace's Docker
/// node is selected. Driven by the pane's `TabsModel` (containers + images,
/// refreshed by the guest while this is visible) and a set of action closures
/// that the host turns into guest commands.
struct DockerDashboardView: View {
    let model: TabsModel
    let accentHex: String
    let onRun: (ACAppDelegate.DockerRunSpec) -> Void
    let onStart: (String) -> Void
    let onStop: (String) -> Void
    let onRemove: (String) -> Void
    /// (containerID, shell)
    let onAttach: (String, String) -> Void
    /// containerID — opens `docker logs -f` in a new tab.
    let onLogs: (String) -> Void
    /// volume name — `docker volume create` / `docker volume rm` in the guest.
    let onVolumeCreate: (String) -> Void
    let onVolumeRemove: (String) -> Void
    /// Install / uninstall cross-arch QEMU emulation in the workspace.
    let onInstallBinfmt: () -> Void
    let onUninstallBinfmt: () -> Void
    /// When set, open straight into this container's detail view.
    var initialContainerID: String? = nil

    private enum Pane: Hashable { case containers, images, volumes }
    @State private var pane: Pane = .containers
    /// Compact = iPhone portrait → stacked header + card rows. `.regular` on
    /// macOS, so the desktop table layout is unchanged.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }
    @State private var query = ""
    @State private var showNew = false
    @State private var showNewVolume = false
    @State private var prefillImage = ""
    @State private var detailID: String?
    @State private var deleteTarget: DockerContainer?
    @State private var deleteVolumeTarget: DockerVolume?
    /// Rolling samples of total CPU% across running containers (drives the graph).
    @State private var cpuHistory: [Double] = []

    static let dockerBlue = Color(hex: "#2496ED")

    private var running: Int { model.dockerContainers.filter(\.isRunning).count }
    private var cpuTotal: Double {
        model.dockerContainers.filter(\.isRunning).compactMap(\.cpuValue).reduce(0, +)
    }
    private var memTotal: Double {
        model.dockerContainers.filter(\.isRunning)
            .compactMap { usedMemoryBytes($0.memUsage) }.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let err = model.dockerError {
                ErrorBanner(message: err) { model.dockerError = nil }
            }
            if let run = model.dockerRunStatus {
                RunProgressBanner(status: run)
            }
            Group {
                switch pane {
                case .containers: containersPane
                case .images: imagesPane
                case .volumes: volumesPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.platformWindowBackground)
        // Force the arrow cursor over the whole dashboard. Plain SwiftUI Text
        // doesn't claim a cursor, but the framebuffer/text views around it can
        // leave a stale I-beam; this background owns an arrow cursor rect, while
        // real TextFields layered on top keep their own I-beam.
        .background(ArrowCursor())
        // Sample CPU on a steady cadence so the graph keeps moving even when
        // load is flat. Cancelled automatically when the dashboard goes away.
        .task(id: pane) {
            while !Task.isCancelled {
                cpuHistory.append(cpuTotal)
                if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .sheet(isPresented: $showNew) {
            NewContainerSheet(
                images: model.dockerImages,
                prefillImage: prefillImage,
                onRun: { spec in onRun(spec); showNew = false },
                onCancel: { showNew = false })
        }
        .sheet(isPresented: $showNewVolume) {
            NewVolumeSheet(
                onCreate: { name in onVolumeCreate(name); showNewVolume = false },
                onCancel: { showNewVolume = false })
        }
        .onAppear { if let initialContainerID { detailID = initialContainerID } }
        .confirmationDialog(
            "Delete container?",
            isPresented: Binding(get: { deleteTarget != nil },
                                 set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { c in
            Button("Delete \(displayName(c))", role: .destructive) { onRemove(c.id); deleteTarget = nil }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("This force-removes the container (docker rm -f). This can't be undone.")
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if compact {
            // Phone: identity + primary action on one row, the pane picker and
            // search on their own full-width rows. (Emulation install is an
            // advanced binfmt control — reachable from the desktop app.)
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    headerBadge
                    headerTitle
                    Spacer()
                    primaryButton
                }
                panemPicker.pickerStyle(.segmented).frame(maxWidth: .infinity)
                SearchField(text: $query, prompt: searchPrompt).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            HStack(spacing: 12) {
                headerBadge
                headerTitle
                Spacer()
                EmulationControl(probed: model.binfmtProbed, arches: model.binfmtArches,
                                 onInstall: onInstallBinfmt, onUninstall: onUninstallBinfmt)
                SearchField(text: $query, prompt: searchPrompt)
                    .frame(width: 200)
                panemPicker.pickerStyle(.segmented).fixedSize()
                primaryButton
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private var headerBadge: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Self.dockerBlue.opacity(0.15))
            .frame(width: 38, height: 38)
            .overlay(Image(systemName: "shippingbox.fill")
                .font(.system(size: 18)).foregroundStyle(Self.dockerBlue))
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Docker").font(.system(size: 18, weight: .semibold))
            Text("\(running) running · \(model.dockerContainers.count) total")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var panemPicker: some View {
        Picker("", selection: $pane) {
            Text("Containers").tag(Pane.containers)
            Text("Images").tag(Pane.images)
            Text("Volumes").tag(Pane.volumes)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if pane == .volumes {
            Button { showNewVolume = true } label: { Label("New Volume", systemImage: "plus") }
                .buttonStyle(.borderedProminent).help("Create a named volume")
        } else {
            Button { prefillImage = ""; showNew = true } label: { Label("Run", systemImage: "plus") }
                .buttonStyle(.borderedProminent).help("Run a new container")
        }
    }

    private var searchPrompt: LocalizedStringKey {
        switch pane {
        case .containers: return "Search containers"
        case .images: return "Search images"
        case .volumes: return "Search volumes"
        }
    }

    // MARK: Containers

    private var containersPane: some View {
        Group {
            if let id = detailID, let c = model.dockerContainers.first(where: { $0.id == id }) {
                ContainerDetailView(
                    container: c,
                    onBack: { detailID = nil },
                    onStart: { onStart(c.id) },
                    onStop: { onStop(c.id) },
                    onDelete: { deleteTarget = c },
                    onAttach: { shell in onAttach(c.id, shell) },
                    onLogs: { onLogs(c.id) })
            } else if model.dockerContainers.isEmpty {
                EmptyStateView(
                    icon: "shippingbox",
                    title: "No containers yet",
                    subtitle: "Run one to get started — it lives only inside this disposable workspace.",
                    actionTitle: "Run a container",
                    action: { prefillImage = ""; showNew = true })
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        statStrip
                        containerList
                    }
                    .padding(18)
                }
            }
        }
    }

    @ViewBuilder private var statStrip: some View {
        if compact {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                statCards
            }
        } else {
            HStack(spacing: 12) { statCards }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statCards: some View {
        StatCard(title: "Running", value: "\(running)", caption: "of \(model.dockerContainers.count)",
                 systemImage: "play.circle.fill", tint: .green)
        CPUStatCard(value: cpuTotal, history: cpuHistory, tint: Self.dockerBlue)
        StatCard(title: "Memory", value: formatBytes(memTotal), caption: "in use",
                 systemImage: "memorychip.fill", tint: .purple)
        StatCard(title: "Images", value: "\(model.dockerImages.count)", caption: "local",
                 systemImage: "square.stack.3d.up.fill", tint: .orange)
    }

    private var filteredContainers: [DockerContainer] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.dockerContainers }
        return model.dockerContainers.filter {
            displayName($0).lowercased().contains(q) || $0.image.lowercased().contains(q)
                || $0.shortID.lowercased().contains(q)
        }
    }

    private var containerList: some View {
        VStack(spacing: 0) {
            if !compact { ContainerHeaderRow() }   // no columns in card mode
            ForEach(filteredContainers) { c in
                ContainerRow(
                    container: c,
                    onOpen: { detailID = c.id },
                    onStart: { onStart(c.id) }, onStop: { onStop(c.id) },
                    onDelete: { deleteTarget = c },
                    onLogs: { onLogs(c.id) })
                if c.id != filteredContainers.last?.id {
                    Divider().opacity(0.35).padding(.leading, 14)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06)))
    }

    // MARK: Images

    private var filteredImages: [DockerImage] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.dockerImages }
        return model.dockerImages.filter {
            $0.repository.lowercased().contains(q) || $0.tag.lowercased().contains(q)
        }
    }

    private var inUseRefs: Set<String> { Set(model.dockerContainers.map(\.image)) }

    private var imagesPane: some View {
        Group {
            if model.dockerImages.isEmpty {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "No local images",
                    subtitle: "Images appear here after you run one. Any reference is pulled on first use.",
                    actionTitle: nil, action: nil)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ImageHeaderRow()
                        ForEach(filteredImages) { im in
                            ImageRow(image: im, inUse: inUseRefs.contains(im.ref),
                                     onRun: { prefillImage = im.ref; showNew = true })
                            if im.id != filteredImages.last?.id {
                                Divider().opacity(0.35).padding(.leading, 14)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06)))
                    .horizontalScrollIfCompact(compact)
                    .padding(18)
                }
            }
        }
    }

    // MARK: Volumes

    private var filteredVolumes: [DockerVolume] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.dockerVolumes }
        return model.dockerVolumes.filter {
            $0.name.lowercased().contains(q) || $0.driver.lowercased().contains(q)
        }
    }

    /// volume name → display names of the containers mounting it (docker ps's
    /// Mounts column, so stopped containers count too — matching `volume rm`,
    /// which they'd also block).
    private var volumeUsers: [String: [String]] {
        var map: [String: [String]] = [:]
        for c in model.dockerContainers {
            for m in c.mountList { map[m, default: []].append(displayName(c)) }
        }
        return map
    }

    private var volumesPane: some View {
        Group {
            if model.dockerVolumes.isEmpty {
                EmptyStateView(
                    icon: "externaldrive",
                    title: "No volumes yet",
                    subtitle: "Named volumes hold data that outlives any single container — databases, caches, build artifacts.",
                    actionTitle: "New volume",
                    action: { showNewVolume = true })
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        VolumeHeaderRow()
                        ForEach(filteredVolumes) { v in
                            VolumeRow(volume: v, usedBy: volumeUsers[v.name] ?? [],
                                      onDelete: { deleteVolumeTarget = v })
                            if v.id != filteredVolumes.last?.id {
                                Divider().opacity(0.35).padding(.leading, 14)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06)))
                    .horizontalScrollIfCompact(compact)
                    .padding(18)
                }
            }
        }
        .confirmationDialog(
            "Delete volume?",
            isPresented: Binding(get: { deleteVolumeTarget != nil },
                                 set: { if !$0 { deleteVolumeTarget = nil } }),
            presenting: deleteVolumeTarget
        ) { v in
            Button("Delete \(v.name)", role: .destructive) {
                onVolumeRemove(v.name); deleteVolumeTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteVolumeTarget = nil }
        } message: { v in
            if let users = volumeUsers[v.name], !users.isEmpty {
                Text("This volume is mounted by \(users.joined(separator: ", ")) — docker will refuse to delete it until those containers are removed.")
            } else {
                Text("This permanently deletes the volume and its data (docker volume rm). This can't be undone.")
            }
        }
    }
}

private func displayName(_ c: DockerContainer) -> String {
    c.name.isEmpty ? c.shortID : c.name
}

// MARK: - Column metrics (shared by header + rows)

private enum Col {
    static let dot: CGFloat = 16
    static let status: CGFloat = 96
    static let ports: CGFloat = 130
    static let started: CGFloat = 96
    static let cpu: CGFloat = 96
    static let actions: CGFloat = 104
}

// MARK: - Container rows

private struct ContainerHeaderRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Col.dot)
            label("Name").frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            label("Image").frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            label("Status").frame(width: Col.status, alignment: .leading)
            label("Ports").frame(width: Col.ports, alignment: .leading)
            label("Started").frame(width: Col.started, alignment: .leading)
            label("CPU").frame(width: Col.cpu, alignment: .leading)
            label("").frame(width: Col.actions)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
    private func label(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            .textCase(.uppercase).tracking(0.6)
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    let onOpen: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void
    let onLogs: () -> Void
    @State private var hovering = false
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        if compact { compactRow } else { wideRow }
    }

    /// Phone card: name + image + status, tap to open the detail (which holds
    /// the start/stop/logs/delete actions), so the row stays legible.
    private var compactRow: some View {
        HStack(spacing: 10) {
            StatusDot(running: container.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(container)).font(.system(size: 14, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(container.image).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            StatusPill(container: container)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var wideRow: some View {
        HStack(spacing: 10) {
            StatusDot(running: container.isRunning).frame(width: Col.dot)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(container)).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(container.shortID).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if !container.arch.isEmpty { ArchBadge(arch: container.arch) }
                }
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            Text(container.image).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            StatusPill(container: container).frame(width: Col.status, alignment: .leading)
            PortsCell(ports: container.ports).frame(width: Col.ports, alignment: .leading)
            Text(container.isRunning ? humanStarted(container.runningFor) : "—")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: Col.started, alignment: .leading)
            CPUCell(container: container).frame(width: Col.cpu, alignment: .leading)
            ContainerActions(container: container, hovering: hovering,
                             onStart: onStart, onStop: onStop, onDelete: onDelete,
                             onLogs: onLogs)
                .frame(width: Col.actions, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
    }
}

// MARK: - Image rows

private struct ImageHeaderRow: View {
    var body: some View {
        HStack(spacing: 10) {
            label("Repository").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            label("Tag").frame(width: 120, alignment: .leading)
            label("Image ID").frame(width: 110, alignment: .leading)
            label("Created").frame(width: 120, alignment: .leading)
            label("Size").frame(width: 80, alignment: .trailing)
            label("").frame(width: 44)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
    private func label(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            .textCase(.uppercase).tracking(0.6)
    }
}

private struct ImageRow: View {
    let image: DockerImage
    let inUse: Bool
    let onRun: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(image.repository).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                if inUse {
                    Text("in use").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.16)))
                        .foregroundStyle(.green)
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            Text(image.tag).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(String(image.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(image.created).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(image.size).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Button(action: onRun) { Image(systemName: "play.fill").font(.system(size: 12)) }
                .buttonStyle(.borderless).foregroundStyle(hovering ? DockerDashboardView.dockerBlue : .secondary)
                .help("Run a container from this image")
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Volume rows

private enum VCol {
    static let driver: CGFloat = 70
    static let created: CGFloat = 110
    static let size: CGFloat = 80
    static let actions: CGFloat = 44
}

private struct VolumeHeaderRow: View {
    var body: some View {
        HStack(spacing: 10) {
            label("Name").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            label("Driver").frame(width: VCol.driver, alignment: .leading)
            label("Created").frame(width: VCol.created, alignment: .leading)
            label("Size").frame(width: VCol.size, alignment: .trailing)
            label("").frame(width: VCol.actions)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
    private func label(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            .textCase(.uppercase).tracking(0.6)
    }
}

private struct VolumeRow: View {
    let volume: DockerVolume
    let usedBy: [String]
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(volume.name).font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if !usedBy.isEmpty {
                        Text("in use").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.16)))
                            .foregroundStyle(.green)
                            .help("Mounted by \(usedBy.joined(separator: ", "))")
                    }
                }
                Text(volume.mountpoint).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .help(volume.mountpoint)
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            Text(volume.driver.isEmpty ? "—" : volume.driver)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: VCol.driver, alignment: .leading)
            Text(humanVolumeCreated(volume.createdAt))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: VCol.created, alignment: .leading)
            Text(volume.size.isEmpty || volume.size == "N/A" ? "—" : volume.size)
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: VCol.size, alignment: .trailing)
            Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 12)) }
                .buttonStyle(.borderless)
                .foregroundStyle(hovering ? Color.red : Color.secondary)
                .help("Delete volume")
                .frame(width: VCol.actions, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// docker's inspect CreatedAt (RFC3339) → "2 days ago"; the raw string when it
/// doesn't parse (old docker), "—" when absent.
private func humanVolumeCreated(_ iso: String) -> String {
    guard !iso.isEmpty else { return "—" }
    let f = ISO8601DateFormatter()
    guard let date = f.date(from: iso) else { return iso }
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .full
    return rel.localizedString(for: date, relativeTo: Date())
}

// MARK: - Stat cards + graph

struct StatCard: View {
    let title: LocalizedStringKey
    let value: String
    let caption: LocalizedStringKey
    let systemImage: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }
}

/// CPU stat card with a live area-chart sparkline of recent total CPU.
struct CPUStatCard: View {
    let value: Double
    let history: [Double]
    let tint: Color

    private var peak: Double { max(100, (history.max() ?? 0) * 1.1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cpu.fill").font(.system(size: 11)).foregroundStyle(tint)
                Text("CPU").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(String(format: "%.1f%%", value)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Chart(Array(history.enumerated()), id: \.offset) { idx, v in
                AreaMark(x: .value("t", idx), y: .value("cpu", v))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", idx), y: .value("cpu", v))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartYScale(domain: 0...peak)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 26)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }
}

private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.primary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06)))
}

// MARK: - Small cells

private struct StatusDot: View {
    let running: Bool
    var body: some View {
        Circle()
            .fill(running ? Color.green : Color.platformTertiaryLabel)
            .frame(width: 8, height: 8)
    }
}

private struct StatusPill: View {
    let container: DockerContainer
    private var color: Color {
        switch container.state {
        case "running": return .green
        case "paused":  return .orange
        case "created": return .blue
        default:        return Color.platformTertiaryLabel
        }
    }
    private var label: String {
        container.state.isEmpty ? "—" : container.state.prefix(1).uppercased() + container.state.dropFirst()
    }
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .help(container.status)
    }
}

private struct PortsCell: View {
    let ports: String
    var body: some View {
        let mapped = publishedPorts(ports)
        if mapped.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 4) {
                ForEach(mapped.prefix(2), id: \.self) { p in
                    Text(p).font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                        .foregroundStyle(.secondary)
                }
                if mapped.count > 2 {
                    Text("+\(mapped.count - 2)").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .help(mapped.joined(separator: ", "))
        }
    }
}

private struct CPUCell: View {
    let container: DockerContainer
    var body: some View {
        if !container.isRunning {
            Text("—").foregroundStyle(.tertiary)
        } else if let v = container.cpuValue {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.cpuPerc).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                ProgressView(value: min(max(v / 100, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(v > 80 ? .red : (v > 40 ? .orange : .green))
                    .frame(width: 64)
            }
        } else {
            Text("…").foregroundStyle(.tertiary)
        }
    }
}

private struct ContainerActions: View {
    let container: DockerContainer
    let hovering: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void
    let onLogs: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if container.isRunning {
                actionButton("stop.fill", "Stop", .orange, action: onStop)
            } else {
                actionButton("play.fill", "Start", .green, action: onStart)
            }
            actionButton("doc.plaintext", "View logs", .secondary, action: onLogs)
            actionButton("trash", "Delete", .secondary, action: onDelete)
        }
        .opacity(hovering ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func actionButton(_ symbol: String, _ help: LocalizedStringKey, _ tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)) }
            .buttonStyle(.borderless).foregroundStyle(tint).help(help)
    }
}

// MARK: - Shared bits

private struct SearchField: View {
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

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.system(size: 12))
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button { onDismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.red.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Header control for cross-arch emulation: an install button when no QEMU
/// handlers are registered, a green "Emulation" chip (with the arch list) once
/// they are. Hidden until the first probe so it doesn't flash.
private struct EmulationControl: View {
    let probed: Bool
    let arches: [String]    // qemu suffixes, e.g. "x86_64"
    let onInstall: () -> Void
    let onUninstall: () -> Void
    @State private var busy = false

    var body: some View {
        Group {
            if !probed {
                Color.clear.frame(width: 0, height: 0)
            } else if arches.isEmpty {
                Button { busy = true; onInstall() } label: {
                    Label(busy ? "Enabling…" : "Enable emulation", systemImage: "cpu")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                .help("Install QEMU binfmt handlers so this workspace can run other-arch images (amd64, etc.)")
            } else {
                Menu {
                    Button("Disable emulation", role: .destructive) { busy = true; onUninstall() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu").font(.system(size: 11))
                        Text(busy ? "Disabling…" : "Emulation").font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.16)))
                    .foregroundStyle(.green)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Cross-arch emulation enabled: \(arches.map(friendlyArch).sorted().joined(separator: ", "))")
            }
        }
        .onChange(of: arches.isEmpty) { _, _ in busy = false }   // settled either way
    }
}

/// Banner shown while a detached `docker run` is pulling/starting an image.
private struct RunProgressBanner: View {
    let status: DockerRunStatus
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.state == "pulling"
                     ? "Pulling \(status.image)…"
                     : "Starting \(status.image)…")
                    .font(.system(size: 12, weight: .medium))
                if status.state == "pulling" {
                    if let f = status.fraction {
                        ProgressView(value: f).frame(maxWidth: 260)
                        Text("\(status.done)/\(status.total) layers")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: 260)   // indeterminate until layers known
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(DockerDashboardView.dockerBlue.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Small architecture chip; tinted when the arch is emulated (non-native).
private struct ArchBadge: View {
    let arch: String
    var body: some View {
        let emulated = archIsEmulated(arch)
        Text(arch)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .background(RoundedRectangle(cornerRadius: 3)
                .fill((emulated ? Color.purple : Color.secondary).opacity(0.16)))
            .foregroundStyle(emulated ? Color.purple : Color.secondary)
            .help(emulated ? "Running under emulation" : "Native architecture")
    }
}

/// Map a qemu interpreter suffix to docker's GOARCH name.
private func friendlyArch(_ qemu: String) -> String {
    switch qemu {
    case "x86_64": return "amd64"
    case "i386":   return "386"
    case "aarch64": return "arm64"
    default:        return qemu
    }
}

/// Apple Silicon hosts run arm64 natively; anything else is emulated.
private func archIsEmulated(_ arch: String) -> Bool {
    let base = arch.split(separator: "/").first.map(String.init) ?? arch
    return !base.isEmpty && base != "arm64" && base != "aarch64"
}

private struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let actionTitle: LocalizedStringKey?
    let action: (() -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 42, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(action: action) { Label(actionTitle, systemImage: "plus") }
                    .buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Parsing helpers

/// Reduce docker's verbose `Ports` string to compact "host→container" mappings,
/// deduped. e.g. "0.0.0.0:8080->80/tcp, :::8080->80/tcp" → ["8080→80"].
private func publishedPorts(_ raw: String) -> [String] {
    var seen = Set<String>(); var out: [String] = []
    for seg in raw.split(separator: ",") {
        let s = seg.trimmingCharacters(in: .whitespaces)
        guard let arrow = s.range(of: "->") else { continue }
        let host = s[..<arrow.lowerBound].split(separator: ":").last.map(String.init)
            ?? String(s[..<arrow.lowerBound])
        var cont = String(s[arrow.upperBound...])
        if let slash = cont.firstIndex(of: "/") { cont = String(cont[..<slash]) }
        let label = "\(host)→\(cont)"
        if seen.insert(label).inserted { out.append(label) }
    }
    return out
}

/// "5 minutes ago" → "5 minutes".
private func humanStarted(_ s: String) -> String { s.replacingOccurrences(of: " ago", with: "") }

/// Parse the "used" side of docker's "12.3MiB / 7.6GiB" into bytes.
private func usedMemoryBytes(_ s: String) -> Double? {
    let used = s.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? s
    let units: [(String, Double)] = [
        ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1_024),
        ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1),
    ]
    for (suffix, mult) in units where used.hasSuffix(suffix) {
        let num = used.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
        if let v = Double(num) { return v * mult }
    }
    return nil
}

private func formatBytes(_ b: Double) -> String {
    guard b > 0 else { return "0 MB" }
    if b >= 1e9 { return String(format: "%.1f GB", b / 1e9) }
    if b >= 1e6 { return String(format: "%.0f MB", b / 1e6) }
    return String(format: "%.0f KB", b / 1e3)
}

// MARK: - Container detail

/// Clean, focused detail screen for one container: a hero header, a centered
/// primary action (Attach a shell when running, Start when stopped), the full
/// stats, and lifecycle controls. Reflects live data (the parent re-resolves the
/// container by id every refresh).
private struct ContainerDetailView: View {
    let container: DockerContainer
    let onBack: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void
    let onAttach: (String) -> Void
    let onLogs: () -> Void
    @State private var shell = "sh"

    private var color: Color {
        switch container.state {
        case "running": return .green
        case "paused":  return .orange
        case "created": return .blue
        default:        return Color.platformTertiaryLabel
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) { Label("Containers", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                if container.isRunning {
                    Button { onStop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.orange)
                } else {
                    Button { onStart() } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.green)
                }
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // Hero
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(color.opacity(0.14))
                            .frame(width: 64, height: 64)
                            .overlay(Image(systemName: "shippingbox.fill")
                                .font(.system(size: 30)).foregroundStyle(color))
                        Text(displayName(container)).font(.system(size: 22, weight: .semibold))
                        Text(container.image).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(container.status).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(color.opacity(0.16)))
                            .foregroundStyle(color)
                    }
                    .padding(.top, 8)

                    // Centered primary action
                    VStack(spacing: 10) {
                        if container.isRunning {
                            HStack(spacing: 8) {
                                Text("Shell").font(.system(size: 12)).foregroundStyle(.secondary)
                                TextField("sh", text: $shell)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 160)
                                    .onSubmit { onAttach(shell) }
                            }
                            Button { onAttach(shell) } label: {
                                Label("Attach", systemImage: "terminal")
                                    .frame(minWidth: 150)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        } else {
                            Button { onStart() } label: {
                                Label("Start container", systemImage: "play.fill")
                                    .frame(minWidth: 150)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        // Logs work whether the container is running or stopped.
                        Button { onLogs() } label: {
                            Label("Logs", systemImage: "doc.plaintext")
                                .frame(minWidth: 150)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                    }

                    // Details
                    VStack(spacing: 0) {
                        DetailRow("Container ID", container.id, mono: true)
                        Divider().opacity(0.35)
                        DetailRow("Image", container.image, mono: true)
                        if !container.arch.isEmpty {
                            Divider().opacity(0.35)
                            DetailRow("Architecture",
                                      container.arch + (archIsEmulated(container.arch) ? "  " + String(localized: "(emulated)") : ""),
                                      mono: true)
                        }
                        Divider().opacity(0.35)
                        DetailRow("State", container.state.capitalized)
                        Divider().opacity(0.35)
                        DetailRow("Status", container.status)
                        Divider().opacity(0.35)
                        DetailRow("Ports", publishedPorts(container.ports).isEmpty
                                  ? "—" : publishedPorts(container.ports).joined(separator: ", "), mono: true)
                        Divider().opacity(0.35)
                        DetailRow("Mounts", container.mountList.isEmpty
                                  ? "—" : container.mountList.joined(separator: "\n"), mono: true)
                        if container.isRunning {
                            Divider().opacity(0.35)
                            DetailRow("Started", humanStarted(container.runningFor))
                            Divider().opacity(0.35)
                            DetailRow("CPU", container.cpuPerc.isEmpty ? "…" : container.cpuPerc, mono: true)
                            Divider().opacity(0.35)
                            DetailRow("Memory", container.memUsage.isEmpty ? "…" : container.memUsage, mono: true)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06)))
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct DetailRow: View {
    let label: LocalizedStringKey
    let value: String
    var mono = false
    init(_ label: LocalizedStringKey, _ value: String, mono: Bool = false) {
        self.label = label; self.value = value; self.mono = mono
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - New container sheet

private struct KV: Identifiable { let id = UUID(); var a = ""; var b = "" }

/// Modern "run a container" form: a prominent image field with one-tap local
/// images, an optional name, and collapsed advanced options (ports / env /
/// volumes) as add-as-you-go rows — nothing intrusive shown by default.
private struct NewContainerSheet: View {
    let images: [DockerImage]
    let prefillImage: String
    let onRun: (ACAppDelegate.DockerRunSpec) -> Void
    let onCancel: () -> Void

    @State private var image = ""
    @State private var name = ""
    @State private var ports: [KV] = []
    @State private var envs: [KV] = []
    @State private var vols: [KV] = []
    @State private var inheritEnv = true
    @State private var inheritProxy = true
    @State private var interactive = false
    @State private var showAdvanced = false

    private var imageRefs: [String] { Array(Set(images.map(\.ref))).sorted() }
    private var canRun: Bool { !image.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").foregroundStyle(DockerDashboardView.dockerBlue)
                Text("Run a new container").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Image")
                        TextField("Search or paste an image reference", text: $image)
                            .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        if !imageRefs.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(imageRefs, id: \.self) { ref in
                                        Button { image = ref } label: {
                                            Text(ref).font(.system(size: 11, design: .monospaced))
                                                .padding(.horizontal, 8).padding(.vertical, 4)
                                                .background(Capsule().fill(image == ref
                                                    ? DockerDashboardView.dockerBlue.opacity(0.18)
                                                    : Color.primary.opacity(0.06)))
                                                .foregroundStyle(image == ref
                                                    ? DockerDashboardView.dockerBlue : .secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Name")
                        TextField("Leave blank to auto-generate", text: $name)
                            .textFieldStyle(.roundedBorder).font(.system(size: 13))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Environment")
                        Toggle(isOn: $inheritEnv) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Inherit workspace environment")
                                Text("Pass the workspace's variables (API tokens, etc.) into the container.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Toggle(isOn: $inheritProxy) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Inherit HTTP proxy settings")
                                Text("http_proxy / https_proxy / no_proxy.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Toggle(isOn: $interactive) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Run interactively")
                                Text("Allocate a TTY (-it) and open it in a new tab — for images that drop into a shell/REPL (e.g. gdb).")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .platformCheckboxToggle()

                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 16) {
                            kvEditor("Port mappings", $ports, "host", "container", "→", add: "Add port")
                            kvEditor("Environment variables", $envs, "KEY", "value", "=", add: "Add variable")
                            kvEditor("Volumes", $vols, "volume or host path", "container path", "→", add: "Add volume")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    } label: {
                        Text("Advanced options").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Run") { run() }.keyboardShortcut(.defaultAction).disabled(!canRun)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 480, height: 460)
        .onAppear { if image.isEmpty { image = prefillImage } }
    }

    private func fieldLabel(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase).tracking(0.5)
    }

    private func kvEditor(_ title: LocalizedStringKey, _ rows: Binding<[KV]>,
                          _ aPrompt: LocalizedStringKey, _ bPrompt: LocalizedStringKey, _ sep: String,
                          add: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            ForEach(rows) { $row in
                HStack(spacing: 6) {
                    TextField(aPrompt, text: $row.a).textFieldStyle(.roundedBorder)
                    Text(sep).foregroundStyle(.tertiary)
                    TextField(bPrompt, text: $row.b).textFieldStyle(.roundedBorder)
                    Button { rows.wrappedValue.removeAll { $0.id == row.id } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
                }
                .font(.system(size: 12, design: .monospaced))
            }
            Button { rows.wrappedValue.append(KV()) } label: {
                Label(add, systemImage: "plus.circle").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
    }

    private func run() {
        func joinPairs(_ rows: [KV], _ sep: String) -> [String] {
            rows.compactMap { r in
                let a = r.a.trimmingCharacters(in: .whitespaces)
                let b = r.b.trimmingCharacters(in: .whitespaces)
                guard !a.isEmpty else { return nil }
                return b.isEmpty ? a : "\(a)\(sep)\(b)"
            }
        }
        onRun(ACAppDelegate.DockerRunSpec(
            image: image.trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces),
            ports: joinPairs(ports, ":"),
            env: joinPairs(envs, "="),
            volumes: joinPairs(vols, ":"),
            inheritEnv: inheritEnv,
            inheritProxy: inheritProxy,
            interactive: interactive))
    }
}

// MARK: - New volume sheet

/// Minimal "create a named volume" form: just the name, validated against
/// docker's volume-name rule so the guest command can't fail on syntax.
private struct NewVolumeSheet: View {
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var canCreate: Bool { Self.isValidName(trimmed) }

    /// [a-zA-Z0-9][a-zA-Z0-9_.-]* — mirrors the host-side sanitizer.
    static func isValidName(_ s: String) -> Bool {
        let first = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let rest = first.union(CharacterSet(charactersIn: "_.-"))
        guard let f = s.unicodeScalars.first, first.contains(f) else { return false }
        return s.unicodeScalars.allSatisfy(rest.contains)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill.badge.plus")
                    .foregroundStyle(DockerDashboardView.dockerBlue)
                Text("New volume").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.5)
                TextField("e.g. pgdata", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { if canCreate { onCreate(trimmed) } }
                Text("Letters and digits, then _ . - too. Mount it in a container as name → path.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create") { onCreate(trimmed) }
                    .keyboardShortcut(.defaultAction).disabled(!canCreate)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 380)
    }
}
