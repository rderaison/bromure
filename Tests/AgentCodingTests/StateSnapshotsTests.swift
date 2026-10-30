import Foundation
import Testing
@testable import bromure_ac

@Suite("State snapshots: names, retention, restore")
struct StateSnapshotsTests {
    func snap(_ name: String) -> StateStore.Snapshot? {
        StateStore.parseSnapshotName(name, url: URL(fileURLWithPath: "/s/\(name)", isDirectory: true))
    }

    @Test("Snapshot directory names: a UTC stamp, an optional label")
    func names() throws {
        let s = try #require(snap("2026-10-25T08-22-12"))
        #expect(s.label == nil)
        #expect(s.isAutomatic)
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 25; c.hour = 8; c.minute = 22; c.second = 12
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(s.takenAt == cal.date(from: c))

        let l = try #require(snap("2026-10-25T08-22-12-pre-devbuild-02"))
        #expect(l.label == "pre-devbuild-02")
        #expect(!l.isAutomatic)

        #expect(snap("notes.txt") == nil)
        #expect(snap("2026-10-25T08-22-12x") == nil)
        #expect(snap(".2026-10-25T08-22-12.partial") == nil)
    }

    @Test("Retention: all <24h, hourly <7d, daily <30d; labelled ones never")
    func retention() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func s(hoursAgo h: Double, label: String? = nil) -> StateStore.Snapshot {
            let t = now.addingTimeInterval(-h * 3600)
            return StateStore.Snapshot(url: URL(fileURLWithPath: "/s/\(h)\(label ?? "")"), takenAt: t, label: label)
        }
        // Two per hour for the last 48 h, two per day for 40 days, plus a labelled old one.
        var all: [StateStore.Snapshot] = []
        for h in stride(from: 0.0, to: 48, by: 0.5) { all.append(s(hoursAgo: h)) }
        for d in 3..<40 { all.append(s(hoursAgo: Double(d) * 24)); all.append(s(hoursAgo: Double(d) * 24 + 12)) }
        all.append(s(hoursAgo: 35 * 24, label: "keep-me"))

        let drop = StateStore.snapshotsToDrop(all, policy: .init(), now: now)
        let kept = all.filter { k in !drop.contains(where: { $0.url == k.url }) }
        // Everything under 24 h is kept.
        #expect(all.filter { now.timeIntervalSince($0.takenAt) < 24 * 3600 }.allSatisfy { k in kept.contains(where: { $0.url == k.url }) })
        // Between 24 h and 7 d: one per hour slot.
        let hourly = kept.filter { let a = now.timeIntervalSince($0.takenAt); return a >= 24 * 3600 && a < 7 * 86400 && $0.isAutomatic }
        #expect(Set(hourly.map { Int($0.takenAt.timeIntervalSince1970 / 3600) }).count == hourly.count)
        // Between 7 d and 30 d: one per day.
        let daily = kept.filter { let a = now.timeIntervalSince($0.takenAt); return a >= 7 * 86400 && a < 30 * 86400 && $0.isAutomatic }
        #expect(Set(daily.map { Int($0.takenAt.timeIntervalSince1970 / 86400) }).count == daily.count)
        #expect(daily.count >= 20)
        // Older than 30 d: gone, unless labelled.
        #expect(kept.filter { now.timeIntervalSince($0.takenAt) >= 30 * 86400 }.allSatisfy { !$0.isAutomatic })
        #expect(kept.contains { $0.label == "keep-me" })
        #expect(!drop.contains { $0.label != nil })
    }

    @Test("Settings override the policy")
    func policyFromSettings() throws {
        let suite = "io.bromure.test.state.\(UUID().uuidString.prefix(8))"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(StateStore.RetentionPolicy.fromSettings(d) == .init())
        d.set(6, forKey: "snapshots.keepAllHours"); d.set(2, forKey: "snapshots.hourlyDays"); d.set(10, forKey: "snapshots.dailyDays")
        #expect(StateStore.RetentionPolicy.fromSettings(d) == .init(keepAllHours: 6, hourlyDays: 2, dailyDays: 10))
    }

    @Test("Restore swaps the tree and keeps the replaced one; --only swaps a subtree")
    func restore() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("brm-restore-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state", isDirectory: true)
        try fm.createDirectory(at: stateURL.appendingPathComponent("profiles/A"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stateURL.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: stateURL.appendingPathComponent("profiles/A/disk.img"))
        try Data("v1".utf8).write(to: stateURL.appendingPathComponent("sessions.json"))
        try Data("log".utf8).write(to: stateURL.appendingPathComponent("logs/instance.log"))
        let entry = StateStore.Entry(name: "t", url: stateURL, isDefault: false, metadata: nil,
                                     instance: (false, nil), settingsDomain: "io.bromure.test.none")

        // A snapshot by hand (the real one lives under the states root).
        let snapDir = root.appendingPathComponent("snap", isDirectory: true)
        try StateStore.cloneTree(from: stateURL, to: snapDir, relative: "") { $0 == "logs" }
        let snapshot = StateStore.Snapshot(url: snapDir, takenAt: Date(), label: nil)

        try Data("v2".utf8).write(to: stateURL.appendingPathComponent("profiles/A/disk.img"))
        try Data("v2".utf8).write(to: stateURL.appendingPathComponent("sessions.json"))

        // The pre-restore snapshot goes under the real snapshots root: point
        // the test at a scratch one by restoring into a state whose snapshots
        // dir we clean up.
        let keepRoot = StateStore.snapshotsDirectory(for: entry)
        defer { try? fm.removeItem(at: keepRoot) }

        try StateStore.restore(entry, from: snapshot, only: "profiles/A")
        #expect(try String(contentsOf: stateURL.appendingPathComponent("profiles/A/disk.img"), encoding: .utf8) == "v1")
        #expect(try String(contentsOf: stateURL.appendingPathComponent("sessions.json"), encoding: .utf8) == "v2")
        let kept1 = try #require(StateStore.snapshots(of: entry).last(where: { $0.label == "pre-restore" }))
        #expect(try String(contentsOf: kept1.url.appendingPathComponent("profiles/A/disk.img"), encoding: .utf8) == "v2")

        try StateStore.restore(entry, from: snapshot, now: Date().addingTimeInterval(2))
        #expect(try String(contentsOf: stateURL.appendingPathComponent("sessions.json"), encoding: .utf8) == "v1")
        #expect(fm.fileExists(atPath: stateURL.appendingPathComponent("logs/instance.log").path), "logs stay with the live state")
        let preRestores = StateStore.snapshots(of: entry).filter { $0.label == "pre-restore" }
        #expect(preRestores.count == 2)
        #expect(try String(contentsOf: preRestores.last!.url.appendingPathComponent("sessions.json"), encoding: .utf8) == "v2")
    }

    @Test("Restore refuses a running state")
    func restoreRunning() {
        let entry = StateStore.Entry(name: "t", url: URL(fileURLWithPath: "/nonexistent"), isDefault: false, metadata: nil,
                                     instance: (true, nil), settingsDomain: "x")
        let s = StateStore.Snapshot(url: URL(fileURLWithPath: "/nonexistent-snap"), takenAt: Date(), label: nil)
        #expect(throws: StateStore.Failure.self) { try StateStore.restore(entry, from: s) }
    }

    @Test("The hourly schedule's label and plist are per data folder and state")
    func schedule() {
        let entry = StateStore.Entry(name: "work", url: URL(fileURLWithPath: "/x"), isDefault: true, metadata: nil,
                                     instance: (false, nil), settingsDomain: "x")
        #expect(StateStore.scheduleLabel(for: entry) == "io.bromure.agentic-coding.snapshot.\(ACSupportDir.name).work")
        #expect(StateStore.schedulePlistURL(for: entry).path.hasSuffix("Library/LaunchAgents/io.bromure.agentic-coding.snapshot.\(ACSupportDir.name).work.plist"))
    }
}
