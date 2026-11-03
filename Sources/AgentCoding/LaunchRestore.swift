#if os(macOS)
import AppKit
import SwiftUI

/// What the quit confirmation's "Restore at next start" checkbox asks to
/// bring back: the workspaces that were running and the agent sessions open
/// in them. Saved when the app quits, taken (read AND removed) at the next
/// start before anything boots — so a start that dies while restoring (out
/// of memory with a dozen VMs coming up) never restores a second time.
struct LaunchRestorePlan: Codable, Equatable {
    struct Workspace: Codable, Equatable {
        var profileID: UUID
        var name: String
        /// Agent sessions open in it, resumed in this order.
        var sessions: [UUID]
    }
    var savedAt: Date
    var workspaces: [Workspace]

    /// A session that was open at quit: in a tab, its agent not known to
    /// have exited, not put away.
    static func restorable(_ s: AgentSession) -> Bool {
        !s.isArchived && !s.isDeleted && s.windowIndex != nil && s.agentAlive != false
    }

    /// The plan for these running workspaces, in the order given.
    static func make(running: [(id: UUID, name: String)], sessions: [AgentSession],
                     now: Date = Date()) -> LaunchRestorePlan {
        LaunchRestorePlan(savedAt: now, workspaces: running.map { w in
            Workspace(profileID: w.id, name: w.name,
                      sessions: sessions.filter { $0.profileID == w.id && restorable($0) }
                          .sorted { ($0.windowIndex ?? 0) < ($1.windowIndex ?? 0) }
                          .map(\.id))
        })
    }

    /// A plan older than this is from another era (the app was quit, then
    /// not started for weeks): its workspaces aren't brought back unasked.
    static let maxAge: TimeInterval = 14 * 24 * 3600

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("restore-at-launch.json")
    }

    static func save(_ plan: LaunchRestorePlan, to url: URL = defaultURL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(plan) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func discard(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Read and remove the plan in one step. Nil when there is none, it
    /// can't be read, it's past `maxAge`, or it couldn't be removed — a plan
    /// that stays on disk would be restored again by the next start.
    static func take(from url: URL = defaultURL, now: Date = Date()) -> LaunchRestorePlan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { try FileManager.default.removeItem(at: url) } catch { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let plan = try? dec.decode(LaunchRestorePlan.self, from: data),
              now.timeIntervalSince(plan.savedAt) < maxAge,
              !plan.workspaces.isEmpty else { return nil }
        return plan
    }

    /// The checkbox's last answer, offered again at the next quit.
    static let preferenceKey = "quit.restoreAtNextStart"
}

/// The restore's progress, shown in a small panel while the workspaces come
/// up one after the other.
@MainActor @Observable
final class LaunchRestoreProgress {
    enum State: Equatable { case waiting, starting, done, failed(String), skipped }
    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let sessions: Int
        var state: State = .waiting
    }
    var rows: [Row]
    var stopped = false
    init(_ plan: LaunchRestorePlan) {
        rows = plan.workspaces.map { Row(id: $0.profileID, name: $0.name, sessions: $0.sessions.count) }
    }
    var finished: Int { rows.filter { ![.waiting, .starting].contains($0.state) }.count }
    var current: Row? { rows.first { $0.state == .starting } }
    /// Every workspace is up, failed or skipped (or the user stopped it).
    var over = false
}

extension ACAppDelegate {
    /// Bring back what the last quit asked for: one workspace at a time —
    /// each is up (or has failed) before the next boots, so a dozen VMs
    /// don't all claim their memory at once — then the sessions open in it.
    /// The plan is taken before the first boot: if this start dies on the
    /// way, the next one starts with nothing running.
    @MainActor func restoreAtLaunch(planURL: URL = LaunchRestorePlan.defaultURL) {
        // The login agent (no window) leaves the plan to the app.
        guard !headless, let plan = LaunchRestorePlan.take(from: planURL) else { return }
        AppLog.stamp("launch restore: \(plan.workspaces.count) workspace(s) from the last quit")
        let progress = LaunchRestoreProgress(plan)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = NSLocalizedString("Restoring Workspaces", comment: "launch restore panel window title")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.contentViewController = NSHostingController(rootView: LaunchRestoreView(progress: progress) { [weak panel] in
            if progress.over { panel?.close() } else { progress.stopped = true }
        })
        panel.center()
        panel.orderFront(nil)
        Task { @MainActor [weak self] in
            for (i, w) in plan.workspaces.enumerated() {
                guard let self else { return }
                guard !progress.stopped else { progress.rows[i].state = .skipped; continue }
                guard self.profile(for: w.profileID) != nil else { progress.rows[i].state = .skipped; continue }
                progress.rows[i].state = .starting
                // Quiet and unattended: the stage stays where the user is,
                // and a gate that would ask a question (a compromised disk,
                // a model still downloading) declines instead of a modal.
                guard await self.agentSessionEngine.ensureUp(w.profileID, quietly: true) else {
                    progress.rows[i].state = .failed(self.unattendedLaunchRefusal(w.profileID)
                        ?? NSLocalizedString("did not start in time", comment: "launch restore: a workspace that never came up"))
                    continue
                }
                for id in w.sessions {
                    guard let s = self.agentSessionStore.session(id), !s.isArchived, !s.isDeleted else { continue }
                    self.agentSessionEngine.resume(id, quietly: true)
                }
                progress.rows[i].state = .done
            }
            progress.over = true
            let failed = progress.rows.contains { if case .failed = $0.state { return true } else { return false } }
            AppLog.stamp("launch restore: over (\(progress.rows.filter { $0.state == .done }.count) up\(failed ? ", some failed" : ""))")
            // Nothing to read: out of the way. A failure stays up to be read.
            if !failed {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                panel.close()
            }
        }
    }
}

struct LaunchRestoreView: View {
    let progress: LaunchRestoreProgress
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Restoring your workspaces", comment: "launch restore panel title"))
                .font(.headline)
            ProgressView(value: Double(progress.finished), total: Double(max(progress.rows.count, 1)))
            Text(statusLine)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(progress.rows) { row in
                    HStack(spacing: 6) {
                        icon(row.state).frame(width: 14)
                        Text(row.name).lineLimit(1)
                        Spacer(minLength: 8)
                        if case .failed(let why) = row.state {
                            Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if row.sessions > 0 {
                            Text(row.sessions == 1
                                 ? NSLocalizedString("1 session", comment: "launch restore: one agent session resumed in a workspace")
                                 : String(format: NSLocalizedString("%d sessions", comment: "launch restore: agent sessions resumed in a workspace"),
                                          row.sessions))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
            HStack {
                Spacer()
                if progress.over {
                    Button(NSLocalizedString("Close", comment: ""), action: onStop)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(NSLocalizedString("Stop Restoring", comment: "launch restore: stop starting the remaining workspaces"),
                           action: onStop)
                        .keyboardShortcut(.cancelAction)
                        .disabled(progress.stopped)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var statusLine: String {
        if let row = progress.current {
            return String(format: NSLocalizedString("Starting “%@”…", comment: "launch restore: the workspace coming up now"), row.name)
        }
        return String(format: NSLocalizedString("%1$d of %2$d", comment: "launch restore: workspaces done of all"),
                      progress.finished, progress.rows.count)
    }

    @ViewBuilder private func icon(_ s: LaunchRestoreProgress.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .starting: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
#endif
