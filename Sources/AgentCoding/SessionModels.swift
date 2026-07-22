import Foundation
import Observation

// MARK: - Session models (platform-independent)
//
// The observable models behind the session UI — tab rosters, docker state,
// vitals, and the sidebar list — moved out of SessionWindow.swift /
// UnifiedSessionWindow.swift (which are AppKit window code) so the iOS client
// can compile them. Pure Foundation + Observation; the fat-client mirror
// (RemoteHostController.applyWorkspaces) reconciles /state into these on both
// platforms.

// MARK: - Docker

/// One running container reported by the guest's `docker ps` loop, mirrored into
/// `TabsModel.dockerContainers` and rendered as a sub-tree under the workspace's
/// tabs in the source-list.
public struct DockerContainer: Identifiable, Equatable {
    public let id: String       // full container id — used for `docker exec`
    public var name: String
    public var image: String
    public var status: String   // e.g. "Up 3 minutes" / "Exited (0) 2m ago"
    public var state: String    // "running", "exited", "paused", "created", …
    public var ports: String
    public var runningFor: String   // "2 hours ago" / "5 minutes ago"
    /// docker ps's Mounts column (comma-separated volume names + bind source
    /// paths, un-truncated). Matches named volumes to their using containers.
    public var mounts: String
    /// Filled from `docker stats` (gated, dashboard-only); "" when unknown.
    public var cpuPerc: String
    public var memUsage: String
    /// Image architecture, dashboard-only (e.g. "amd64", "arm64", "arm/v7").
    public var arch: String = ""
    public var shortID: String { String(id.prefix(12)) }
    public var isRunning: Bool { state == "running" }
    /// CPU as a number (docker reports "12.34%"); nil while unknown.
    public var cpuValue: Double? { Double(cpuPerc.replacingOccurrences(of: "%", with: "")) }
    /// The Mounts column as individual entries.
    public var mountList: [String] {
        mounts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public init(id: String, name: String, image: String, status: String,
                state: String, ports: String, runningFor: String = "",
                mounts: String = "", cpuPerc: String = "", memUsage: String = "") {
        self.id = id
        self.name = name
        self.image = image
        self.status = status
        self.state = state
        self.ports = ports
        self.runningFor = runningFor
        self.mounts = mounts
        self.cpuPerc = cpuPerc
        self.memUsage = memUsage
    }
}

/// Progress of an in-flight detached `docker run` (image pull → start), shown
/// as a banner in the dashboard so a pull doesn't look like a hang.
public struct DockerRunStatus: Equatable {
    public var state: String     // "pulling" | "starting"
    public var image: String
    public var done: Int
    public var total: Int
    public init(state: String, image: String, done: Int, total: Int) {
        self.state = state; self.image = image; self.done = done; self.total = total
    }
    /// 0…1 when layer counts are known, else nil (indeterminate).
    public var fraction: Double? {
        total > 0 ? min(1, Double(done) / Double(total)) : nil
    }
}

/// One local docker image, from `docker images` — feeds the dashboard's Images
/// view and the new-container picker.
public struct DockerImage: Identifiable, Equatable {
    public let id: String           // image id (sha)
    public var repository: String   // "nginx" / "<none>"
    public var tag: String          // "latest" / "<none>"
    public var size: String         // "142MB"
    public var created: String      // "2 days ago"
    /// "repo:tag" — the ref you'd `docker run`; falls back to the id when untagged.
    public var ref: String {
        repository != "<none>" && tag != "<none>" ? "\(repository):\(tag)" : String(id.prefix(12))
    }

    public init(id: String, repository: String, tag: String, size: String, created: String) {
        self.id = id
        self.repository = repository
        self.tag = tag
        self.size = size
        self.created = created
    }
}

/// One named docker volume, from `docker volume inspect` (gated, dashboard-only)
/// — feeds the dashboard's Volumes view.
public struct DockerVolume: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public var driver: String       // "local"
    public var mountpoint: String   // /var/lib/docker/volumes/<name>/_data
    public var createdAt: String    // ISO8601 from inspect; "" on old docker
    /// Human size from the slower `docker system df -v` probe; "" until known.
    public var size: String

    public init(name: String, driver: String, mountpoint: String,
                createdAt: String = "", size: String = "") {
        self.name = name
        self.driver = driver
        self.mountpoint = mountpoint
        self.createdAt = createdAt
        self.size = size
    }
}

/// One listening socket in the guest, from its ports loop (`sudo ss -tulnpH` →
/// ports.txt). Feeds the workspace dashboard's Listening Ports table, the
/// `/vms` record, and the CLI's `vm <id> -L`.
public struct ListeningPort: Equatable, Sendable {
    public let proto: String   // "tcp" / "udp"
    public let addr: String    // "0.0.0.0", "127.0.0.1", "[::]", "[::1]", …
    public let port: Int
    /// Owning process name(s) from ss's users:(…) column ("sshd", "nginx");
    /// empty when the snapshot ran without -p.
    public let process: String

    public init(proto: String, addr: String, port: Int, process: String = "") {
        self.proto = proto
        self.addr = addr
        self.port = port
        self.process = process
    }

    /// Bound to a loopback address — reachable only from inside the VM, so the
    /// dashboard hides it (the user asked for externally-visible ports).
    public var isLoopback: Bool {
        addr.hasPrefix("127.") || addr == "[::1]" || addr == "::1"
    }
}

// MARK: - Tabs model

/// Observable model backing a TabbedSessionWindow. Each tab represents a
/// Coarse coding-agent status, shown as a small dot next to the agent's icon:
/// working (orange, gently pulsing), done (green), needs the user (red).
enum AgentStatus: String, Sendable {
    case working, done, needsInput

    /// Parse a guest-hook signal ("working"/"done"/"needsInput"/"needs-input").
    init?(signal: String) {
        switch signal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "working": self = .working
        case "done": self = .done
        case "needsinput", "needs-input", "needs_input": self = .needsInput
        default: return nil
        }
    }
}

/// separate kitty process inside the SAME VM — switching tabs just
/// raises that tab's kitty window via the outbox-driven guest agent.
@MainActor
@Observable
final class TabsModel {
    @MainActor
    @Observable
    final class Tab: Identifiable {
        let id: UUID
        // @Observable makes per-property changes drive SwiftUI redraws,
        // so updating `label` from the title-poll path live-refreshes
        // the pill without us having to replace the array slot.
        var label: String
        /// The real tmux window index — used for select/close (windows can have
        /// gaps after closes, so position ≠ index).
        var index: Int
        /// Set when this tab is a `docker exec` attach window (tmux @container
        /// option); such tabs are nested under their container in the source-list
        /// instead of shown as a top-level tab.
        var containerID: String?
        /// The tab's working directory — used to gate the "New worktree" menu
        /// (only shown when the cwd is inside a git repo, resolved lazily).
        var cwd: String?
        /// This tab's worktree branch (`wt/<slug>`), if it's a worktree window.
        var worktreeBranch: String?
        /// The branch this worktree was cut from — its immediate merge parent.
        var parentBranch: String?
        /// The main worktree's path — where merges/removes run for this tree.
        var rootRepo: String?
        /// Pretty label shown instead of `label` for worktree tabs.
        var display: String?
        /// The cwd's git toplevel if it's a repo (gates "New worktree" and
        /// roots the file-explorer pane); empty for non-repo cwds. For a
        /// worktree tab this is the worktree checkout dir.
        var repoRoot: String?
        /// This tab's coding-agent status — per agent, per tab. Driven by the
        /// MITM proxy (working, non-Claude) and Claude's per-window hooks
        /// (working / done / needsInput). Drives the status dot on the icon.
        var agentStatus: AgentStatus = .done
        init(label: String, index: Int = 0, containerID: String? = nil,
             cwd: String? = nil, worktreeBranch: String? = nil,
             parentBranch: String? = nil, rootRepo: String? = nil,
             display: String? = nil, repoRoot: String? = nil, id: UUID = UUID()) {
            self.label = label
            self.index = index
            self.containerID = containerID
            self.cwd = cwd
            self.worktreeBranch = worktreeBranch
            self.parentBranch = parentBranch
            self.rootRepo = rootRepo
            self.display = display
            self.repoRoot = repoRoot
            self.id = id
        }

        var isWorktree: Bool { !(worktreeBranch?.isEmpty ?? true) }
        var isGitRepo: Bool { !(repoRoot?.isEmpty ?? true) }
        /// What the tab strip should show.
        var shownLabel: String {
            if let d = display, !d.isEmpty { return d }
            return label
        }
    }

    var tabs: [Tab] = []
    var activeIndex: Int = 0

    /// All docker containers in this VM (running + stopped), refreshed ~every 2s
    /// from the guest. Drives the source-list Docker sub-tree and the dashboard.
    var dockerContainers: [DockerContainer] = []
    /// Local docker images — only refreshed while a dashboard is open (gated).
    var dockerImages: [DockerImage] = []
    /// Named docker volumes — only refreshed while a dashboard is open (gated).
    var dockerVolumes: [DockerVolume] = []
    /// Most recent docker action failure (run/start/stop/remove), shown as a
    /// banner in the dashboard until dismissed.
    var dockerError: String?
    /// In-flight detached `docker run` progress (pull/start), nil when idle.
    var dockerRunStatus: DockerRunStatus?
    /// qemu arch suffixes currently emulated (binfmt_misc), dashboard-only.
    var binfmtArches: [String] = []
    /// True once we've received a binfmt probe (distinguishes "none" from
    /// "not yet known" so the UI doesn't flash the install button).
    var binfmtProbed = false
    var accentHex: String = "#3B82F6"
    /// Most recent VM IP reported by the guest's xinitrc loop. Surfaced
    /// in the toolbar; click to copy.
    var ipAddress: String?

    /// VM vitals for the workspace dashboard, refreshed ~every 1.5s from the
    /// guest's vmstat loop: aggregate CPU%, memory used/total (KB), 1-min load.
    var vmCPU: Double = 0
    var vmMemUsedKB: Int = 0
    var vmMemTotalKB: Int = 0
    var vmLoad: Double = 0
    /// Guest root-FS usage from df (KB) — the filesystem's own truth,
    /// preferred over the host-side CoW clone allocation (which overstates:
    /// blocks the guest freed stay materialized in the clone). 0 = not
    /// reported yet (booting, or an older guest agent).
    var vmDiskUsedKB: Int = 0
    var vmDiskTotalKB: Int = 0
    /// Listening sockets from the guest's ports loop (~every 3s). The dashboard
    /// renders the non-loopback subset.
    var vmListeningPorts: [ListeningPort] = []
    /// Drives the red toolbar indicator. True when the Mac is enrolled
    /// with bromure.io AND this session's profile is NOT in private
    /// mode — i.e. session metadata is being shipped upstream.
    /// ACAppDelegate.refreshStreamingState() pushes updates here.
    var streamingActive: Bool = false

    /// True when ≥2 providers have a usable credential — gates whether the
    /// title-bar lightning toggle can be engaged (it's always shown).
    var fusionConfigurable: Bool = false
    /// Runtime on/off for Fusion this session. Only meaningful when
    /// `fusionConfigurable`. Flipped by the lightning toggle; mirrored into
    /// the MITM engine so the proxy hot path sees the change.
    var fusionEngaged: Bool = false

    /// Local-inference engine status for this session's title-bar badge.
    /// nil = no local model (cloud session), so the badge is hidden.
    var engineStatus: EngineStatus?
    enum EngineStatus: Equatable {
        case starting(String)   // provisioning / loading the model
        case ready(String)      // serving (model label)
        case failed(String)
    }

    var activeTab: Tab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }
}

// MARK: - Sidebar list model

/// Drives the unpeel-style source-list. One `VMEntry` per running VM hosted in
/// the unified window; each entry carries the pane's live `TabsModel` so the
/// nested tab rows update in place.
@MainActor
@Observable
final class SessionListModel {
    @MainActor
    @Observable
    final class VMEntry: Identifiable {
        let id: Profile.ID
        var name: String
        var accentHex: String
        /// The pane's tab model — shared by reference, so tab labels / active
        /// index / thinking state refresh the sidebar rows live.
        let model: TabsModel
        init(id: Profile.ID, name: String, accentHex: String, model: TabsModel) {
            self.id = id
            self.name = name
            self.accentHex = accentHex
            self.model = model
        }
    }

    /// Per-profile run state shown in the source list.
    enum RunState { case off, booting, running, suspended }

    /// One row per profile — running or not. Rebuilt wholesale by the
    /// delegate's `refreshSidebar()`; a running row pairs (by id) with a
    /// `VMEntry` that carries the live tab model for its nested tab rows.
    struct ProfileRow: Identifiable, Equatable {
        let id: Profile.ID
        var name: String
        var accentHex: String
        var state: RunState
        var compromised: Bool
    }

    /// Running, attached panes — carry live tab models.
    var entries: [VMEntry] = []
    /// Every profile, in display order — the source list's top level.
    var profileRows: [ProfileRow] = []
    var selectedID: Profile.ID?
    /// Set when a VM's Docker dashboard is the active stage surface — highlights
    /// that VM's Docker node in the source list.
    var dockerSelectedID: Profile.ID?
    /// True when the Grid is the active stage surface.
    var gridSelected = false
    /// Set when an automation's editor is the active stage surface —
    /// highlights its row in the Automations section.
    var automationSelectedID: UUID?
    /// True when the automation kanban board is the active stage surface.
    var automationBoardSelected = false
    /// True when the coding-task kanban board is the active stage surface.
    var taskBoardSelected = false
    /// True when the sidebar is collapsed to the icon rail.
    var sidebarCollapsed = false
    /// True when the right-hand file-explorer pane is open. Drives the
    /// toolbar button tint and the pane's own context/polling.
    var filePaneOpen = false
    /// True when the agentic browser pane is open. Drives the toolbar tint.
    var browserPaneOpen = false
}

/// Right-click actions on a tab row. Handled by the window, which reads the
/// tab's worktree metadata and dispatches to the delegate (dialogs + guest
/// commands).
enum TabAction {
    case newWorktree        // any tab whose cwd is a git repo
    case merge              // a worktree tab → merge into an ancestor
    case attachTerminal     // a worktree tab → open a plain terminal in its checkout
    case removeWorktree     // a worktree tab → discard (remove + delete branch)
    case resolveConflicts   // a "Merge → …" tab → spawn the agent to resolve
    case createAutomation   // any tab → automation editor seeded with its cwd
}

/// Nesting depth of a tab in the worktree tree: 0 for ordinary tabs, N for a
/// worktree whose parent chain (by `parentBranch` → an ancestor's
/// `worktreeBranch`) is N deep. An attached terminal — a plain tab tagged with
/// `parentBranch` but no `worktreeBranch` — nests one step under its worktree
/// the same way. Drives the source-list indentation so worktrees-off-worktrees
/// read as nested. Capped so a deep tree can't march off the sidebar.
@MainActor
func worktreeDepth(of tab: TabsModel.Tab, in tabs: [TabsModel.Tab]) -> Int {
    guard tab.isWorktree || !(tab.parentBranch?.isEmpty ?? true) else { return 0 }
    var depth = 1
    var parentBranch = tab.parentBranch
    var guardCount = 0
    while let pb = parentBranch, !pb.isEmpty, guardCount < 8 {
        guard let parent = tabs.first(where: { $0.worktreeBranch == pb }) else { break }
        depth += 1
        parentBranch = parent.parentBranch
        guardCount += 1
    }
    return min(depth, 6)
}

extension ProfileColor {
    /// Hex form for use in the AppKit/SwiftUI mix.
    var hexInUI: String {
        switch self {
        case .blue:   "#3B82F6"
        case .red:    "#EF4444"
        case .green:  "#22C55E"
        case .orange: "#F97316"
        case .purple: "#A855F7"
        case .pink:   "#EC4899"
        case .teal:   "#14B8A6"
        case .gray:   "#6B7280"
        }
    }
}
