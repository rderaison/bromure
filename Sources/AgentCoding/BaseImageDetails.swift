#if os(macOS)
import AppKit
import SwiftUI
import SandboxEngine

/// One workspace as Base Image details shows it: the base its disk came
/// from, against the one on this Mac now.
struct BaseImageWorkspaceRow: Identifiable, Equatable {
    enum State: Equatable {
        /// No system disk yet: its first start clones the current base.
        case notStarted
        case current
        /// An older base, and the user chose to move it: its next start resets it.
        case updatesAtNextStart
        /// An older base the user chose to keep.
        case kept
        /// An older base, nothing decided.
        case older
    }
    let id: UUID
    let name: String
    /// The base its disk was cloned from; nil = no record.
    let base: String?
    let state: State

    struct Input {
        let id: UUID
        let name: String
        let baseAtClone: String?
        let hasDisk: Bool
        let acceptedFor: String?
        let declinedFor: String?
    }

    static func rows(_ workspaces: [Input], current: String?) -> [BaseImageWorkspaceRow] {
        workspaces.map { w in
            let state: State
            if !w.hasDisk { state = .notStarted }
            else if w.baseAtClone == nil || current == nil || w.baseAtClone == current { state = .current }
            else if w.acceptedFor == current { state = .updatesAtNextStart }
            else if w.declinedFor == current { state = .kept }
            else { state = .older }
            return BaseImageWorkspaceRow(id: w.id, name: w.name, base: w.baseAtClone, state: state)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether the workspace chooser has something to decide for it.
    var onOlderBase: Bool { [.updatesAtNextStart, .kept, .older].contains(state) }
}

@MainActor @Observable
final class BaseImageDetailsModel {
    struct Info: Equatable {
        var version: String?
        var source: String
        var installedAt: Date?
        var bytes: Int64?
    }
    var info = Info(version: nil, source: "")
    var steps: [PostinstallStepStatus] = []
    var workspaces: [BaseImageWorkspaceRow] = []
    var selected: Set<String> = []
    var busy = false

    var installable: [PostinstallStepStatus] { steps.filter { $0.state != .installed } }
    var selectedSteps: [PostinstallStep] {
        steps.filter { selected.contains($0.id) && $0.state != .installed }.map(\.step)
    }
}

struct BaseImageDetailsView: View {
    @Bindable var model: BaseImageDetailsModel
    let onInstall: ([PostinstallStep]) -> Void
    let onSkip: (String, Bool) -> Void
    let onChooseWorkspaces: () -> Void

    var body: some View {
        Form {
            Section(NSLocalizedString("Base image", comment: "base image details section")) {
                LabeledContent(NSLocalizedString("Version", comment: "base image details"),
                               value: model.info.version ?? "—")
                LabeledContent(NSLocalizedString("Source", comment: "base image details"),
                               value: model.info.source)
                if let at = model.info.installedAt {
                    LabeledContent(NSLocalizedString("Updated", comment: "base image details: last change"),
                                   value: at.formatted(date: .abbreviated, time: .shortened))
                }
                if let b = model.info.bytes {
                    LabeledContent(NSLocalizedString("Size on disk", comment: "base image details"),
                                   value: ByteCountFormatter.string(fromByteCount: b, countStyle: .file))
                }
            }
            Section {
                ForEach(model.steps) { row in stepRow(row) }
            } header: {
                Text(NSLocalizedString("Packages", comment: "base image details section: postinstall steps"))
            } footer: {
                HStack {
                    if model.busy {
                        ProgressView().controlSize(.small)
                        Text(NSLocalizedString("Installing…", comment: "base image details")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(NSLocalizedString("Install Selected", comment: "base image details")) {
                        onInstall(model.selectedSteps)
                    }
                    .disabled(model.busy || model.selectedSteps.isEmpty)
                }
            }
            Section {
                ForEach(model.workspaces) { row in
                    LabeledContent(row.name) {
                        Text(workspaceText(row)).foregroundStyle(row.onOlderBase ? .primary : .secondary)
                    }
                }
            } header: {
                Text(NSLocalizedString("Workspaces", comment: "base image details section"))
            } footer: {
                if model.workspaces.contains(where: \.onOlderBase) {
                    HStack {
                        Spacer()
                        Button(NSLocalizedString("Choose Workspaces to Update…", comment: "base image details"),
                               action: onChooseWorkspaces)
                            .disabled(model.busy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 420, maxHeight: 720)
    }

    @ViewBuilder private func stepRow(_ row: PostinstallStepStatus) -> some View {
        HStack(spacing: 8) {
            if row.state == .installed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Toggle("", isOn: Binding(
                    get: { model.selected.contains(row.id) },
                    set: { on in
                        if on { model.selected.insert(row.id) } else { model.selected.remove(row.id) }
                    }))
                    .toggleStyle(.checkbox).labelsHidden()
            }
            Text(row.step.description).lineLimit(2)
            Spacer()
            switch row.state {
            case .installed:
                Text(NSLocalizedString("Installed", comment: "postinstall step state")).foregroundStyle(.secondary)
            case .skipped:
                Text(NSLocalizedString("Skipped", comment: "postinstall step state")).foregroundStyle(.secondary)
                Button(NSLocalizedString("Don't Skip", comment: "base image details: un-skip a step")) {
                    onSkip(row.id, false)
                }
                .controlSize(.small).disabled(model.busy)
            case .notInstalled:
                Text(NSLocalizedString("Not installed", comment: "postinstall step state")).foregroundStyle(.secondary)
                Button(NSLocalizedString("Skip", comment: "base image details: skip a step for good")) {
                    onSkip(row.id, true)
                }
                .controlSize(.small).disabled(model.busy)
            }
        }
    }

    private func workspaceText(_ row: BaseImageWorkspaceRow) -> String {
        let base = row.base ?? "—"
        switch row.state {
        case .notStarted:
            return NSLocalizedString("Not started yet", comment: "base image details workspace row")
        case .current:
            return String(format: NSLocalizedString("v%@ · current", comment: "base image details workspace row; %@ = version"), base)
        case .updatesAtNextStart:
            return String(format: NSLocalizedString("v%@ · updates at its next start", comment: "base image details workspace row; %@ = version"), base)
        case .kept:
            return String(format: NSLocalizedString("v%@ · kept", comment: "base image details workspace row; %@ = version"), base)
        case .older:
            return String(format: NSLocalizedString("v%@ · older", comment: "base image details workspace row; %@ = version"), base)
        }
    }
}

extension ACAppDelegate {
    @objc func baseImageDetailsAction(_ sender: Any?) {
        showBaseImageDetails()
    }

    @MainActor func showBaseImageDetails() {
        let model = baseImageDetailsModel ?? BaseImageDetailsModel()
        baseImageDetailsModel = model
        refreshBaseImageDetails()
        if let w = baseImageDetailsWindow {
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let view = BaseImageDetailsView(
            model: model,
            onInstall: { [weak self] steps in
                guard let self else { return }
                Task { @MainActor in
                    model.busy = true
                    await self.installPostinstallStepsNow(steps)
                    model.busy = false
                    model.selected = []
                    self.refreshBaseImageDetails()
                }
            },
            onSkip: { [weak self] uuid, skip in
                if skip { PostinstallSkips().skip([uuid]) } else { PostinstallSkips().unskip([uuid]) }
                model.selected.remove(uuid)
                self?.refreshBaseImageDetails()
            },
            onChooseWorkspaces: { [weak self] in
                guard let self, let current = self.currentBaseVersion() else { return }
                Task { @MainActor in
                    await self.chooseWorkspacesForNewBase(current)
                    self.refreshBaseImageDetails()
                }
            })
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.title = NSLocalizedString("Base Image", comment: "base image details window title")
        win.styleMask = [.titled, .closable, .resizable]
        win.isReleasedWhenClosed = false
        win.center()
        baseImageDetailsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func refreshBaseImageDetails() {
        guard let model = baseImageDetailsModel else { return }
        let state = imageManager.loadImageState()
        let catalog = ImageCatalogStore.shared.effective()
        let current = currentBaseVersion()
        let source: String
        if let uuid = state?.imageUUID {
            if let image = catalog.image, image.uuid == uuid {
                source = image.description
            } else {
                source = String(format: NSLocalizedString("Published image %@", comment: "base image source; %@ = short id"),
                                String(uuid.prefix(8)))
            }
        } else {
            source = imageManager.hasBaseImage
                ? NSLocalizedString("Built on this Mac", comment: "base image source")
                : NSLocalizedString("Not installed", comment: "base image source")
        }
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: imageManager.versionStampURL.path)
        let disk = try? imageManager.baseDiskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        model.info = .init(version: current, source: source,
                           installedAt: attrs?[.modificationDate] as? Date,
                           bytes: (disk?.totalFileAllocatedSize).map(Int64.init))
        model.steps = PostinstallStepStatus.rows(catalog: catalog, applied: state?.appliedStepUUIDs ?? [],
                                                 skipped: PostinstallSkips().uuids)
        model.selected.formIntersection(model.installable.map(\.id))
        model.busy = isInstallingBaseImage
        model.workspaces = BaseImageWorkspaceRow.rows(profiles.map { p in
            .init(id: p.id, name: p.name, baseAtClone: p.baseImageVersionAtClone,
                  hasDisk: fm.fileExists(atPath: store.diskURL(for: p).path),
                  acceptedFor: p.baseImageUpgradeAcceptedFor, declinedFor: p.baseImageUpgradeDeclinedFor)
        }, current: current)
    }
}
#endif
