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

    /// One row's height; the list shows up to `visibleRows`, then scrolls.
    static let rowHeight: CGFloat = 52
    static let visibleRows = 7

    private var deciding: [BaseImageUpdateChoice] { model.rows.filter(\.decides) }
    private var updating: Int { deciding.filter(\.update).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            list
            note
            footer
        }
        .padding(24)
        .frame(width: 580)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 48, height: 48)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("A new base image is ready", comment: "base image chooser title"))
                    .font(.title3.weight(.semibold))
                Text(String(format: NSLocalizedString("Choose which workspaces move to base %@.", comment: "base image chooser subtitle; %@ = base version"), model.newBase))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: list

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array($model.rows.enumerated()), id: \.element.id) { i, $row in
                    if i > 0 { Divider().padding(.leading, 56) }
                    WorkspaceRow(row: $row).frame(height: Self.rowHeight)
                }
            }
        }
        .scrollIndicators(.automatic)
        // An explicit height: a sheet sizes to its content's ideal size, and
        // a ScrollView's ideal height is next to nothing — the rows would
        // collapse out of sight.
        .frame(height: Self.listHeight(rows: model.rows.count))
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Room for every row up to `visibleRows` (plus the hairlines between
    /// them), then the list scrolls.
    static func listHeight(rows: Int) -> CGFloat {
        let shown = CGFloat(min(max(rows, 1), visibleRows))
        return shown * rowHeight + (shown - 1)
    }

    // MARK: note

    private var note: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(NSLocalizedString(
                "Updating resets the workspace's system disk: software installed inside it is removed; home and project folders stay. Kept workspaces won't ask again for this base.",
                comment: "base image chooser explanation"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            Menu {
                Button(NSLocalizedString("Update All", comment: "base image chooser")) { model.setAll(true) }
                Button(NSLocalizedString("Keep All", comment: "base image chooser")) { model.setAll(false) }
            } label: {
                Text(String(format: NSLocalizedString("%d of %d to update", comment: "base image chooser count: updating of deciding"), updating, deciding.count))
                    .monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            Spacer()
            Button(action: onDone) {
                Text(updating == 0
                     ? NSLocalizedString("Keep All & Continue", comment: "base image chooser: continue, nothing updates")
                     : NSLocalizedString("Continue", comment: "base image chooser"))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// One workspace: a status-tinted icon, its name and what happens to it,
/// and the Update switch.
private struct WorkspaceRow: View {
    @Binding var row: BaseImageUpdateChoice

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: "shippingbox.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint))
                if row.state == .running || row.state == .restoring {
                    Circle().fill(dot)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            if row.decides {
                Toggle(NSLocalizedString("Update", comment: "base image chooser: reset the workspace onto the new base"),
                       isOn: $row.update.animation(.snappy(duration: 0.2)))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(NSLocalizedString("Update this workspace to the new base", comment: "base image chooser switch tooltip"))
            } else {
                Label(NSLocalizedString("Up to date", comment: "base image chooser row: nothing to decide"),
                      systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14)
        .opacity(row.decides ? 1 : 0.7)
        .contentShape(Rectangle())
        .onTapGesture { if row.decides { withAnimation(.snappy(duration: 0.2)) { row.update.toggle() } } }
    }

    private var tint: Color {
        guard row.decides else { return .secondary }
        return row.update ? .accentColor : .secondary
    }

    private var dot: Color { row.state == .running ? .green : .orange }

    /// What happens to it, given the switch.
    private var detail: String {
        switch (row.state, row.update) {
        case (.running, true):   return NSLocalizedString("Running · restarts now on the new base", comment: "base image chooser row")
        case (.running, false):  return NSLocalizedString("Running · keeps its current disk", comment: "base image chooser row")
        case (.restoring, true): return NSLocalizedString("Reopening · comes back on the new base", comment: "base image chooser row")
        case (.restoring, false):return NSLocalizedString("Reopening · comes back as it was", comment: "base image chooser row")
        case (.idle, true):      return NSLocalizedString("Updates at its next start", comment: "base image chooser row")
        case (.idle, false):     return NSLocalizedString("Keeps its current disk", comment: "base image chooser row")
        case (.current, _):      return NSLocalizedString("Starts on the new base", comment: "base image chooser row")
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
