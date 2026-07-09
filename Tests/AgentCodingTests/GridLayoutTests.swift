import Foundation
import Testing
@testable import bromure_ac

@Suite("GridLayout")
struct GridLayoutTests {

    @MainActor
    private func freshStore() -> GridLayoutStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grid-test-\(UUID().uuidString).json")
        return GridLayoutStore(saveURL: url)
    }

    @Test("Dimension ladder grows squarish and caps at 5x5")
    func ladder() {
        #expect(GridLayoutStore.dimensions(for: 1) == (1, 1))
        #expect(GridLayoutStore.dimensions(for: 2) == (1, 2))
        #expect(GridLayoutStore.dimensions(for: 4) == (2, 2))
        #expect(GridLayoutStore.dimensions(for: 5) == (2, 3))
        #expect(GridLayoutStore.dimensions(for: 9) == (3, 3))
        #expect(GridLayoutStore.dimensions(for: 12) == (3, 4))
        #expect(GridLayoutStore.dimensions(for: 16) == (4, 4))
        #expect(GridLayoutStore.dimensions(for: 20) == (4, 5))
        #expect(GridLayoutStore.dimensions(for: 25) == (5, 5))
        #expect(GridLayoutStore.dimensions(for: 99) == (5, 5))
    }

    @Test("Add dedupes and enforces the 25-cell cap")
    @MainActor
    func addRules() {
        let store = freshStore()
        let pid = UUID()
        #expect(store.add(profileID: pid, windowIndex: 0, label: "a"))
        #expect(!store.add(profileID: pid, windowIndex: 0, label: "a"))   // dupe
        for i in 1..<25 {
            #expect(store.add(profileID: pid, windowIndex: i, label: "w\(i)"))
        }
        #expect(!store.add(profileID: pid, windowIndex: 99, label: "over"))  // cap
        #expect(store.cells.count == 25)
    }

    @Test("Reconcile prunes dead windows and refreshes labels, off VMs untouched")
    @MainActor
    func reconcile() {
        let store = freshStore()
        let running = UUID(), off = UUID()
        store.add(profileID: running, windowIndex: 1, label: "old")
        store.add(profileID: running, windowIndex: 7, label: "gone")
        store.add(profileID: off, windowIndex: 3, label: "sleeping")

        // Roster for the running VM: window 1 renamed, window 7 vanished.
        store.reconcile(profileID: running, tabs: [(1, "renamed")])

        #expect(store.cells.count == 2)
        #expect(store.cells.first { $0.profileID == running }?.label == "renamed")
        // The off workspace's cell survives (placeholder policy).
        #expect(store.cells.contains { $0.profileID == off })
    }

    @Test("Focused/zoomed state clears when the cell is removed")
    @MainActor
    func focusClears() {
        let store = freshStore()
        let pid = UUID()
        store.add(profileID: pid, windowIndex: 2, label: "x")
        let id = GridCell.id(profileID: pid, windowIndex: 2)
        store.focusedCellID = id
        store.zoomedCellID = id
        store.remove(id: id)
        #expect(store.focusedCellID == nil)
        #expect(store.zoomedCellID == nil)
    }

    @Test("Persistence round-trips membership")
    @MainActor
    func persistence() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grid-persist-\(UUID().uuidString).json")
        let pid = UUID()
        do {
            let store = GridLayoutStore(saveURL: url)
            store.add(profileID: pid, windowIndex: 4, label: "worktree (claude)")
        }
        let reloaded = GridLayoutStore(saveURL: url)
        #expect(reloaded.cells.count == 1)
        #expect(reloaded.cells[0].profileID == pid)
        #expect(reloaded.cells[0].windowIndex == 4)
        #expect(reloaded.cells[0].label == "worktree (claude)")
    }

    @Test("Drag payload round-trips, including labels containing pipes")
    func payload() throws {
        let pid = UUID()
        let encoded = GridDragPayload.encode(profileID: pid, windowIndex: 3,
                                             label: "fix | urgent (claude)")
        let decoded = try #require(GridDragPayload.decode(encoded))
        #expect(decoded.profileID == pid)
        #expect(decoded.windowIndex == 3)
        #expect(decoded.label == "fix | urgent (claude)")
        #expect(GridDragPayload.decode("random junk") == nil)
        #expect(GridDragPayload.decode("bromure-grid-cell|nope|x|y") == nil)
    }
}
