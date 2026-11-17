#if os(macOS)
import AppKit
import SwiftUI

/// After a base-image install (new packages, or a whole new image): which
/// workspaces move to the new base — their system disk reset onto it — and
/// which keep the disk they have. Every workspace is listed and every answer
/// is recorded, so none of them asks again on its next boot, weeks later.
struct BaseImageUpdateChoice: Identifiable, Equatable {
    enum State: Equatable {
        /// Running now: "Update" restarts it onto the new base.
        case running
        /// Coming back with the launch restore.
        case restoring
        /// Stopped or suspended, with a disk from an older base.
        case idle
        /// Nothing to decide: no disk yet, or already on the new base.
        case current
    }
    let id: UUID
    let name: String
    let state: State
    /// Keep (false) unless the user picks Update: updating wipes what was
    /// installed inside the machine.
    var update = false

    var decides: Bool { state != .current }

    struct Workspace {
        let id: UUID
        let name: String
        /// The base its disk was cloned from; nil = no record.
        let baseAtClone: String?
        let hasDisk: Bool
    }

    /// One row per workspace: running ones first, then those the restore is
    /// about to bring back, then the rest, then the ones with nothing to
    /// decide — each group by name.
    static func rows(_ workspaces: [Workspace], newBase: String,
                     running: Set<UUID>, restoring: Set<UUID>) -> [BaseImageUpdateChoice] {
        workspaces.map { w in
            let state: State
            if !w.hasDisk || w.baseAtClone == newBase { state = .current }
            else if running.contains(w.id) { state = .running }
            else if restoring.contains(w.id) { state = .restoring }
            else { state = .idle }
            return BaseImageUpdateChoice(id: w.id, name: w.name, state: state)
        }
        .sorted { a, b in
            let rank: (State) -> Int = { [.running: 0, .restoring: 1, .idle: 2, .current: 3][$0] ?? 3 }
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

@MainActor @Observable
final class BaseImageUpdateChooserModel {
    var rows: [BaseImageUpdateChoice]
    let newBase: String
    init(rows: [BaseImageUpdateChoice], newBase: String) {
        self.rows = rows
        self.newBase = newBase
    }
    func setAll(_ update: Bool) {
        for i in rows.indices where rows[i].decides { rows[i].update = update }
    }
}

struct BaseImageUpdateChooserView: View {
    @Bindable var model: BaseImageUpdateChooserModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Move workspaces to the new base image?", comment: "base image chooser title"))
                .font(.headline)
            Text(NSLocalizedString(
                "Update resets a workspace's system disk onto the new base: anything installed inside the machine is wiped; its home and project folders stay. Keep leaves it as it is, and it won't ask again for this base.",
                comment: "base image chooser explanation"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach($model.rows) { $row in
                        HStack(spacing: 8) {
                            Text(row.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(stateLabel(row.state))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if row.decides {
                                Picker("", selection: $row.update) {
                                    Text(NSLocalizedString("Keep", comment: "base image chooser: keep the workspace's disk")).tag(false)
                                    Text(NSLocalizedString("Update", comment: "base image chooser: reset the workspace onto the new base")).tag(true)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 140)
                            } else {
                                Color.clear.frame(width: 140, height: 1)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Button(NSLocalizedString("Keep All", comment: "base image chooser")) { model.setAll(false) }
                Button(NSLocalizedString("Update All", comment: "base image chooser")) { model.setAll(true) }
                Spacer()
                Button(NSLocalizedString("Continue", comment: "base image chooser"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func stateLabel(_ s: BaseImageUpdateChoice.State) -> String {
        switch s {
        case .running:   return NSLocalizedString("Running — restarts to update", comment: "base image chooser row")
        case .restoring: return NSLocalizedString("Being restored", comment: "base image chooser row")
        case .idle:      return NSLocalizedString("Updates at its next start", comment: "base image chooser row")
        case .current:   return NSLocalizedString("Starts on the new base", comment: "base image chooser row")
        }
    }
}

extension ACAppDelegate {
    /// Ask, for every workspace, whether it moves to the base just installed
    /// (`newBase`), and record each answer: "Update" resets its disk at its
    /// next boot (a running one restarts now), "Keep" is the drift prompt's
    /// "No" for this base. Returns once answered — the launch restore waits
    /// for it. Headless: nobody to ask; the drift prompt stays as before.
    @MainActor func chooseWorkspacesForNewBase(_ newBase: String) async {
        guard !headless else { return }
        let restoring = Set(LaunchRestorePlan.peek()?.workspaces.map(\.profileID) ?? [])
        let rows = BaseImageUpdateChoice.rows(
            profiles.map { p in
                .init(id: p.id, name: p.name, baseAtClone: p.baseImageVersionAtClone,
                      hasDisk: FileManager.default.fileExists(atPath: store.diskURL(for: p).path))
            },
            newBase: newBase, running: Set(runningSessions.keys), restoring: restoring)
        guard rows.contains(where: \.decides) else { return }
        let model = BaseImageUpdateChooserModel(rows: rows, newBase: newBase)
        let window: NSWindow = (unifiedWindow as NSWindow?) ?? ensureUnifiedWindow()
        let sheet = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sheet.contentViewController = NSHostingController(rootView: BaseImageUpdateChooserView(model: model) {
                window.endSheet(sheet)
            })
            window.beginSheet(sheet) { _ in done.resume() }
        }
        for row in model.rows where row.decides {
            recordBaseImageUpdateChoice(profileID: row.id, current: newBase, update: row.update)
            if row.update, runningSessions[row.id] != nil {
                AppLog.stamp("base image \(newBase): restarting '\(row.name)' onto it")
                Task { @MainActor in _ = await self.rebootMachine(row.id, force: false, remoteInitiated: false) }
            }
        }
    }
}
#endif
