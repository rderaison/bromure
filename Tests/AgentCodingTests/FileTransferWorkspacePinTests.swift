import Foundation
import Testing
@testable import bromure_ac

/// Regression (CWE-362): the Files pane keeps one FileExplorerModel across
/// selections and its file ops followed the CURRENT machine. A drop's writes —
/// and a failed copy's cleanup `remove` — could land on the machine selected
/// after the drop started (or fail once the pane closed). A transfer now
/// pins the machine it started on.
@MainActor
@Suite("Files pane transfers stay on their machine")
struct FileTransferWorkspacePinTests {
    private final class Log: @unchecked Sendable {
        var ops: [(UUID, String)] = []
    }

    @Test("A drop's ops go to the machine it was dropped on, after a switch or a close")
    func pinned() async throws {
        for next in [UUID(), nil] as [UUID?] {
            let a = UUID(), log = Log()
            let m = FileExplorerModel()
            m.execProvider = { _, _, _ in "" }
            m.fileOpProvider = { pid, op in
                log.ops.append((pid, op["op"] as? String ?? "?")); return [:]
            }
            m.setLocation(profileID: a, cwd: "/home/ubuntu", repoRoot: nil)
            let src = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString).txt")
            try Data("hello".utf8).write(to: src)
            defer { try? FileManager.default.removeItem(at: src) }
            m.receive([src])
            // The drop's task hasn't run yet: the user picks another machine
            // (or closes the pane) first.
            m.setLocation(profileID: next, cwd: next == nil ? nil : "/home/ubuntu", repoRoot: nil)
            for _ in 0..<200 where !log.ops.contains(where: { ["rename", "write"].contains($0.1) }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            let transfer = log.ops.filter { ["write", "rename", "remove", "mkdir"].contains($0.1) }
            #expect(!transfer.isEmpty)
            #expect(transfer.allSatisfy { $0.0 == a }, "\(transfer)")
        }
    }
}
