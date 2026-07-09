import Foundation
import Observation

/// One grid slot: a tmux window of a workspace, plus a cached label so the
/// cell can render as a placeholder while its workspace is off.
struct GridCell: Codable, Equatable, Identifiable {
    var profileID: UUID
    var windowIndex: Int
    var label: String

    var id: String { GridCell.id(profileID: profileID, windowIndex: windowIndex) }
    static func id(profileID: UUID, windowIndex: Int) -> String {
        "\(profileID.uuidString):\(windowIndex)"
    }
}

/// The user-curated grid: which terminals to watch, in which order. This is
/// deliberately a persisted, host-owned object — it is the `StageLayout`
/// contract that phase 4 mirrors over the SSH bridge.
///
/// Membership rules (per UX review):
/// - cells of an off/suspended workspace stay (placeholder with Start) —
///   arrangements are deliberate and survive VM downtime;
/// - cells of a *running* workspace whose tmux window vanished are pruned —
///   a VM reboot loses its windows exactly like the tab bar does.
@MainActor
@Observable
final class GridLayoutStore {
    static let maxCells = 25   // 5×5

    private(set) var cells: [GridCell] = []
    var focusedCellID: String?
    /// Cell temporarily maximized inside the grid (⌘↩ / header double-click).
    var zoomedCellID: String?

    private let saveURL: URL

    init(saveURL: URL? = nil) {
        self.saveURL = saveURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/grid-layout.json")
        load()
    }

    // MARK: Membership

    /// Add a terminal; returns false when full or already present.
    @discardableResult
    func add(profileID: UUID, windowIndex: Int, label: String) -> Bool {
        guard cells.count < Self.maxCells else { return false }
        let id = GridCell.id(profileID: profileID, windowIndex: windowIndex)
        guard !cells.contains(where: { $0.id == id }) else { return false }
        cells.append(GridCell(profileID: profileID, windowIndex: windowIndex, label: label))
        save()
        return true
    }

    func remove(id: String) {
        cells.removeAll { $0.id == id }
        if focusedCellID == id { focusedCellID = nil }
        if zoomedCellID == id { zoomedCellID = nil }
        save()
    }

    func move(id: String, toIndex: Int) {
        guard let from = cells.firstIndex(where: { $0.id == id }),
              (0..<cells.count).contains(toIndex) else { return }
        cells.insert(cells.remove(at: from), at: toIndex)
        save()
    }

    /// Swap two cells' grid positions (drag-to-rearrange). No-op if either id
    /// is unknown or they're the same cell.
    func swap(_ idA: String, _ idB: String) {
        guard idA != idB,
              let a = cells.firstIndex(where: { $0.id == idA }),
              let b = cells.firstIndex(where: { $0.id == idB }) else { return }
        cells.swapAt(a, b)
        save()
    }

    /// Roster reconciliation for a *running* workspace: drop cells whose
    /// window no longer exists; refresh labels of the ones that do.
    func reconcile(profileID: UUID, tabs: [(index: Int, label: String)]) {
        let live = Dictionary(tabs.map { ($0.index, $0.label) },
                              uniquingKeysWith: { a, _ in a })
        var changed = false
        cells.removeAll { cell in
            guard cell.profileID == profileID else { return false }
            if live[cell.windowIndex] == nil {
                changed = true
                if focusedCellID == cell.id { focusedCellID = nil }
                if zoomedCellID == cell.id { zoomedCellID = nil }
                return true
            }
            return false
        }
        for i in cells.indices where cells[i].profileID == profileID {
            if let label = live[cells[i].windowIndex], cells[i].label != label {
                cells[i].label = label
                changed = true
            }
        }
        if changed { save() }
    }

    /// A deleted profile takes its cells with it.
    func removeAll(profileID: UUID) {
        let before = cells.count
        cells.removeAll { $0.profileID == profileID }
        if cells.count != before { save() }
    }

    // MARK: Geometry

    /// Rows × columns for a cell count — grows squarish, capped at 5×5.
    nonisolated static func dimensions(for count: Int) -> (rows: Int, cols: Int) {
        switch count {
        case ...1: return (1, 1)
        case 2: return (1, 2)
        case 3...4: return (2, 2)
        case 5...6: return (2, 3)
        case 7...9: return (3, 3)
        case 10...12: return (3, 4)
        case 13...16: return (4, 4)
        case 17...20: return (4, 5)
        default: return (5, 5)
        }
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var cells: [GridCell]
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        cells = Array(snap.cells.prefix(Self.maxCells))
    }

    private func save() {
        let dir = saveURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Snapshot(cells: cells)) {
            try? data.write(to: saveURL, options: .atomic)
        }
    }
}

/// Sidebar → grid drag payload ("add this terminal to the grid").
enum GridDragPayload {
    static let prefix = "bromure-grid-cell"

    static func encode(profileID: UUID, windowIndex: Int, label: String) -> String {
        // The label goes last and may contain anything but newlines.
        "\(prefix)|\(profileID.uuidString)|\(windowIndex)|\(label)"
    }

    static func decode(_ s: String) -> (profileID: UUID, windowIndex: Int, label: String)? {
        let parts = s.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == prefix,
              let uuid = UUID(uuidString: String(parts[1])),
              let index = Int(parts[2]) else { return nil }
        return (uuid, index, String(parts[3]))
    }
}
