import SwiftUI

// MARK: - Docker dashboard

/// A Docker-Desktop-style dashboard shown in the stage when a workspace's Docker
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

    private enum Pane: Hashable { case containers, images }
    @State private var pane: Pane = .containers
    @State private var query = ""
    @State private var showNew = false
    @State private var prefillImage = ""
    @State private var attachTarget: DockerContainer?
    @State private var deleteTarget: DockerContainer?

    static let dockerBlue = Color(hex: "#2496ED")

    private var running: Int { model.dockerContainers.filter(\.isRunning).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch pane {
                case .containers: ContainersPane(
                    containers: filteredContainers,
                    total: model.dockerContainers.count,
                    onStart: onStart, onStop: onStop,
                    onAttach: { attachTarget = $0 }, onDelete: { deleteTarget = $0 },
                    onNew: { prefillImage = ""; showNew = true })
                case .images: ImagesPane(
                    images: filteredImages,
                    total: model.dockerImages.count,
                    inUse: inUseRefs,
                    onRun: { prefillImage = $0; showNew = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showNew) {
            NewContainerSheet(
                images: model.dockerImages,
                prefillImage: prefillImage,
                onRun: { spec in onRun(spec); showNew = false },
                onCancel: { showNew = false })
        }
        .sheet(item: $attachTarget) { c in
            AttachSheet(
                container: c,
                onAttach: { shell in onAttach(c.id, shell); attachTarget = nil },
                onCancel: { attachTarget = nil })
        }
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

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Self.dockerBlue.opacity(0.15))
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: "shippingbox.fill")
                    .font(.system(size: 18)).foregroundStyle(Self.dockerBlue))
            VStack(alignment: .leading, spacing: 1) {
                Text("Docker").font(.system(size: 18, weight: .semibold))
                Text("\(running) running · \(model.dockerContainers.count) total")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            SearchField(text: $query, prompt: pane == .containers ? "Search containers" : "Search images")
                .frame(width: 200)
            Picker("", selection: $pane) {
                Text("Containers").tag(Pane.containers)
                Text("Images").tag(Pane.images)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Button { prefillImage = ""; showNew = true } label: {
                Label("Run", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Run a new container")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Filtering

    private var filteredContainers: [DockerContainer] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.dockerContainers }
        return model.dockerContainers.filter {
            displayName($0).lowercased().contains(q) || $0.image.lowercased().contains(q)
                || $0.shortID.lowercased().contains(q)
        }
    }

    private var filteredImages: [DockerImage] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.dockerImages }
        return model.dockerImages.filter {
            $0.repository.lowercased().contains(q) || $0.tag.lowercased().contains(q)
        }
    }

    /// Image refs currently used by a container — drives the "in use" badge.
    private var inUseRefs: Set<String> {
        Set(model.dockerContainers.map { $0.image })
    }
}

private func displayName(_ c: DockerContainer) -> String {
    c.name.isEmpty ? c.shortID : c.name
}

// MARK: - Containers pane

private struct ContainersPane: View {
    let containers: [DockerContainer]
    let total: Int
    let onStart: (String) -> Void
    let onStop: (String) -> Void
    let onAttach: (DockerContainer) -> Void
    let onDelete: (DockerContainer) -> Void
    let onNew: () -> Void

    var body: some View {
        if total == 0 {
            EmptyStateView(
                icon: "shippingbox",
                title: "No containers yet",
                subtitle: "Run one to get started — it lives only inside this disposable workspace.",
                actionTitle: "Run a container",
                action: onNew)
        } else {
            Table(containers) {
                TableColumn("") { c in StatusDot(running: c.isRunning) }.width(16)
                TableColumn("Name") { c in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName(c)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Text(c.shortID).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .width(min: 130, ideal: 180)
                TableColumn("Image") { c in
                    Text(c.image).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .width(min: 120, ideal: 200)
                TableColumn("Status") { c in StatusPill(container: c) }.width(110)
                TableColumn("Ports") { c in PortsCell(ports: c.ports) }.width(min: 80, ideal: 130)
                TableColumn("Started") { c in
                    Text(c.isRunning ? humanStarted(c.runningFor) : "—")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .width(110)
                TableColumn("CPU") { c in CPUCell(container: c) }.width(84)
                TableColumn("") { c in
                    ContainerActions(container: c, onStart: onStart, onStop: onStop,
                                     onAttach: onAttach, onDelete: onDelete)
                }
                .width(108)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

// MARK: - Images pane

private struct ImagesPane: View {
    let images: [DockerImage]
    let total: Int
    let inUse: Set<String>
    let onRun: (String) -> Void

    var body: some View {
        if total == 0 {
            EmptyStateView(
                icon: "square.stack.3d.up",
                title: "No local images",
                subtitle: "Images appear here after you run one. Any reference is pulled on first use.",
                actionTitle: nil, action: nil)
        } else {
            Table(images) {
                TableColumn("Repository") { (im: DockerImage) in
                    HStack(spacing: 6) {
                        Text(im.repository).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        if inUse.contains(im.ref) {
                            Text("in use").font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.16)))
                                .foregroundStyle(.green)
                        }
                    }
                }
                .width(min: 140, ideal: 220)
                TableColumn("Tag") { im in
                    Text(im.tag).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 80, ideal: 120)
                TableColumn("Image ID") { im in
                    Text(String(im.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
                .width(110)
                TableColumn("Created") { im in
                    Text(im.created).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(120)
                TableColumn("Size") { im in
                    Text(im.size).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(80)
                TableColumn("") { (im: DockerImage) in
                    Button { onRun(im.ref) } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Run a container from this image")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(50)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

// MARK: - Row components

private struct StatusDot: View {
    let running: Bool
    var body: some View {
        Circle()
            .fill(running ? Color.green : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(running ? Color.green.opacity(0.35) : .clear, lineWidth: 3))
    }
}

private struct StatusPill: View {
    let container: DockerContainer
    private var color: Color {
        switch container.state {
        case "running": return .green
        case "paused":  return .orange
        case "created": return .blue
        default:        return Color(nsColor: .tertiaryLabelColor)
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
                ForEach(mapped.prefix(3), id: \.self) { p in
                    Text(p)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                        .foregroundStyle(.secondary)
                }
                if mapped.count > 3 {
                    Text("+\(mapped.count - 3)").font(.system(size: 10)).foregroundStyle(.tertiary)
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
    let onStart: (String) -> Void
    let onStop: (String) -> Void
    let onAttach: (DockerContainer) -> Void
    let onDelete: (DockerContainer) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if container.isRunning {
                actionButton("stop.fill", "Stop", .orange) { onStop(container.id) }
                actionButton("terminal", "Attach a shell", .primary) { onAttach(container) }
            } else {
                actionButton("play.fill", "Start", .green) { onStart(container.id) }
            }
            actionButton("trash", "Delete", .secondary) { onDelete(container) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func actionButton(_ symbol: String, _ help: String, _ tint: Color,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)) }
            .buttonStyle(.borderless).foregroundStyle(tint).help(help)
    }
}

// MARK: - Shared bits

private struct SearchField: View {
    @Binding var text: String
    let prompt: String
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

private struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    let actionTitle: String?
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

// MARK: - Port parsing

/// Reduce docker's verbose `Ports` string to compact "host→container" mappings,
/// deduped. e.g. "0.0.0.0:8080->80/tcp, :::8080->80/tcp" → ["8080→80"].
private func publishedPorts(_ raw: String) -> [String] {
    var seen = Set<String>(); var out: [String] = []
    for seg in raw.split(separator: ",") {
        let s = seg.trimmingCharacters(in: .whitespaces)
        guard let arrow = s.range(of: "->") else { continue }   // only published ports
        let host = s[..<arrow.lowerBound].split(separator: ":").last.map(String.init)
            ?? String(s[..<arrow.lowerBound])
        var cont = String(s[arrow.upperBound...])
        if let slash = cont.firstIndex(of: "/") { cont = String(cont[..<slash]) }
        let label = "\(host)→\(cont)"
        if seen.insert(label).inserted { out.append(label) }
    }
    return out
}

/// "5 minutes ago" → "5 minutes"; leave other shapes alone.
private func humanStarted(_ s: String) -> String {
    s.replacingOccurrences(of: " ago", with: "")
}

// MARK: - Attach sheet

private struct AttachSheet: View {
    let container: DockerContainer
    let onAttach: (String) -> Void
    let onCancel: () -> Void
    @State private var shell = "bash"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Attach a shell").font(.system(size: 15, weight: .semibold))
                Text(displayName(container)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Shell").foregroundStyle(.secondary)
                TextField("bash", text: $shell)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 180)
                    .onSubmit { onAttach(shell) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Attach") { onAttach(shell) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
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
                    // Image
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Image")
                        TextField("Search or paste an image reference", text: $image)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
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

                    // Name
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Name")
                        TextField("Leave blank to auto-generate", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }

                    // Advanced
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 16) {
                            kvEditor("Port mappings", $ports, "host", "container", "→",
                                     add: "Add port")
                            kvEditor("Environment variables", $envs, "KEY", "value", "=",
                                     add: "Add variable")
                            kvEditor("Volumes", $vols, "host path", "container path", "→",
                                     add: "Add volume")
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Advanced options").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
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

    private func fieldLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase).tracking(0.5)
    }

    private func kvEditor(_ title: String, _ rows: Binding<[KV]>,
                          _ aPrompt: String, _ bPrompt: String, _ sep: String,
                          add: String) -> some View {
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
            volumes: joinPairs(vols, ":")))
    }
}
