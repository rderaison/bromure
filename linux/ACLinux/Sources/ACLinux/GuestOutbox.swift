import Foundation

/// One tmux window of the guest's workspace session, as agentd reports it in
/// the outbox's `tabs.txt` (macOS: UbuntuSandboxVM's GuestTab).
// @port-skip linux-only: the type; macOS's GuestTab is a struct with no functions to port
public struct GuestTab: Sendable, Equatable {
    public var index: Int
    public var active: Bool
    public var label: String
    public var containerID: String?
    public var cwd: String?
    public var worktreeBranch: String?
    public var parentBranch: String?
    public var rootRepo: String?
    public var display: String?
    public var repoRoot: String?
    // @port-skip linux-only: GuestTab member
    public var isWorktree: Bool { !(worktreeBranch?.isEmpty ?? true) }
    // @port-skip linux-only: GuestTab member
    public var isGitRepo: Bool { !(repoRoot?.isEmpty ?? true) }
}

/// What agentd writes into a VM's outbox share for the host: the tab roster
/// (`tabs.txt`) and its vitals (`vmstat.txt`). macOS polls the same files
/// (UbuntuSandboxVM.startOutboxPolling); here they're read when a VM entry
/// is built.
// @port-skip linux-only: namespace
public enum GuestOutbox {
    /// Parse a tabs.txt body into the tmux window list. Columns: idx, active,
    /// label, container, cwd, worktree, parent_branch, root_repo, display,
    /// repoRoot. Older guests send only the first 4: trailing fields default
    /// to nil.
    // @port UbuntuSandboxVM.static parseRoster(_: String) h=955ec5f123e1c6a5 @592b5699
    public static func parseRoster(_ raw: String) -> [GuestTab] {
        var tabs: [GuestTab] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, let idx = Int(cols[0]) else { continue }
            func col(_ i: Int) -> String? {
                guard cols.count > i else { return nil }
                let s = String(cols[i]).trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? nil : s
            }
            tabs.append(GuestTab(
                index: idx, active: cols[1] == "1",
                label: String(cols[2]).trimmingCharacters(in: .whitespaces),
                containerID: col(3),
                cwd: col(4), worktreeBranch: col(5),
                parentBranch: col(6), rootRepo: col(7),
                display: col(8), repoRoot: col(9)))
        }
        tabs.sort { $0.index < $1.index }
        return tabs
    }

    /// A tab as a VM entry's `tabs` item: macOS's automationVMList shape.
    // partial: no agentStatus (no attached pane on Linux) and no isMergeTab detection beyond the display prefix
    // @port-skip linux-only: the tab half of ACAppDelegate.automationVMList (the rest is VMRecord.json + vitals)
    public static func tabJSON(_ t: GuestTab) -> JSONValue {
        var d: [String: JSONValue] = [
            "index": .number(Double(t.index)),
            "title": .string(t.display?.isEmpty == false ? t.display! : (t.label.isEmpty ? "shell" : t.label)),
            "active": .bool(t.active),
        ]
        if let cwd = t.cwd { d["cwd"] = .string(cwd) }
        if t.isWorktree {
            d["isWorktree"] = true
            if let b = t.worktreeBranch { d["worktreeBranch"] = .string(b) }
        } else if t.isGitRepo {
            d["isGitRepo"] = true
            if let rr = t.repoRoot, !rr.isEmpty { d["repoRoot"] = .string(rr) }
        }
        if let p = t.parentBranch, !p.isEmpty { d["parentBranch"] = .string(p) }
        if let r = t.rootRepo, !r.isEmpty { d["rootRepo"] = .string(r) }
        if t.display?.hasPrefix("Merge → ") == true { d["isMergeTab"] = true }
        return .object(d)
    }

    /// vmstat.txt (`key value` per line): cpu, mem_used_kb, mem_total_kb,
    /// load, disk_used_kb, disk_total_kb, as the VM entry's keys.
    // @port-skip linux-only: the vmstat.txt branch of UbuntuSandboxVM.startOutboxPolling, as data
    public static func vitalsJSON(_ raw: String) -> [String: JSONValue] {
        var cpu = 0.0, used = 0, total = 0, load = 0.0, diskUsed = 0, diskTotal = 0
        for line in raw.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: " ")
            guard p.count == 2 else { continue }
            let v = String(p[1])
            switch p[0] {
            case "cpu": cpu = Double(v) ?? 0
            case "mem_used_kb": used = Int(v) ?? 0
            case "mem_total_kb": total = Int(v) ?? 0
            case "load": load = Double(v) ?? 0
            case "disk_used_kb": diskUsed = Int(v) ?? 0
            case "disk_total_kb": diskTotal = Int(v) ?? 0
            default: break
            }
        }
        return ["cpu": .number(cpu), "memUsedKB": .number(Double(used)), "memTotalKB": .number(Double(total)),
                "load": .number(load), "diskUsedKB": .number(Double(diskUsed)), "diskTotalKB": .number(Double(diskTotal)),
                "hasStats": .bool(total > 0)]
    }

    /// A small text file the guest wrote, nil if missing or over 256 KiB.
    // @port-skip linux-only: UbuntuSandboxVM.boundedText for a path
    public static func read(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = a[.size] as? Int, size <= 256 << 10 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
