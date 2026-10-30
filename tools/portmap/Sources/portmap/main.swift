import ArgumentParser
import Foundation
import PortMapCore

/// The Linux port's function ledger. Every macOS function is `shared`
/// (compiled on both), `ported` (a Linux declaration carries its current
/// hash), `stale` (ported, then the macOS body changed), `skipped` (not
/// needed on Linux, with a reason) or `todo`.
@main
struct PortMap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "portmap",
        abstract: "Track every macOS function against the Linux port.",
        subcommands: [Status.self, Check.self, Show.self, Stamp.self, Diff.self, List.self],
        defaultSubcommand: Status.self)
}

struct Common: ParsableArguments {
    @Option(help: "Repository root.")
    var root: String = "."
    @Option(help: "Config, relative to the root.")
    var config: String = "port/config.json"

    func report() throws -> (Report, URL) {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let cfg = try PortConfig.load(rootURL.appendingPathComponent(config))
        return (try Ledger.build(config: cfg, root: rootURL), rootURL)
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Counts, overall and per file.")
    @OptionGroup var common: Common
    @Flag(help: "One row per file.") var byFile = false
    @Flag(help: "JSON instead of a table.") var json = false

    func run() throws {
        let (r, _) = try common.report()
        if json {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try enc.encode(r), as: UTF8.self)); return
        }
        let total = r.entries.count
        let lines = r.entries.reduce(0) { $0 + $1.mac.lines }
        print("macOS functions: \(total) (\(lines) body lines)")
        for s in PortMapCore.Status.allCases {
            let n = r.count(s)
            let l = r.entries.filter { $0.status == s }.reduce(0) { $0 + $1.mac.lines }
            let name = s.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            print("  " + name + String(format: " %6d  %5.1f%%  %7d lines", n,
                                       total == 0 ? 0 : Double(n) * 100 / Double(total), l))
        }
        print("orphaned @port lines: \(r.orphans.count)   unclaimed Linux functions: \(r.unclaimedLinux.count)")
        guard byFile else { return }
        print("")
        let byFileEntries = Dictionary(grouping: r.entries, by: { $0.mac.file })
        print("file\tshared\tported\tstale\tskipped\ttodo")
        for (file, es) in byFileEntries.sorted(by: { $0.key < $1.key }) {
            let c = { (s: PortMapCore.Status) in es.filter { $0.status == s }.count }
            print("\(file)\t\(c(.shared))\t\(c(.ported))\t\(c(.stale))\t\(c(.skipped))\t\(c(.todo))")
        }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List functions in one status.")
    @OptionGroup var common: Common
    @Argument(help: "shared, ported, stale, skipped or todo.") var status: String
    @Option(help: "Only files whose path contains this.") var file: String?

    func run() throws {
        let (r, _) = try common.report()
        guard let s = PortMapCore.Status(rawValue: status) else { throw ValidationError("unknown status \(status)") }
        for e in r.entries where e.status == s && (file.map { e.mac.file.contains($0) } ?? true) {
            let extra = e.skipReason.map { "  [\($0)]" } ?? ""
            print("\(e.mac.file):\(e.mac.line)\t\(e.mac.id)\t\(e.mac.lines)\(extra)")
        }
    }
}

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fail (exit 1) on stale ports, orphaned @port lines, or unclaimed Linux functions.")
    @OptionGroup var common: Common
    @Flag(help: "Unclaimed Linux functions only warn.") var allowUnclaimed = false

    func run() throws {
        let (r, _) = try common.report()
        var failed = false
        for e in r.entries where e.status == .stale {
            failed = true
            for c in e.linux where c.portedHash != e.mac.hash {
                print("STALE   \(e.mac.id)\n        macOS \(e.mac.file):\(e.mac.line) now h=\(e.mac.hash)\n        Linux \(c.file):\(c.line) ported h=\(c.portedHash)\(c.portedCommit.map { " @\($0)" } ?? "")")
            }
        }
        for o in r.orphans {
            failed = true
            print("ORPHAN  \(o.file):\(o.line) \(o.id) claims a macOS function that no longer exists")
        }
        for u in r.unclaimedLinux {
            if !allowUnclaimed { failed = true }
            print("\(allowUnclaimed ? "WARN" : "UNCLAIMED") \(u.file):\(u.line) \(u.id) has no // @port line (or // @port-skip <why> for Linux-only code)")
        }
        if failed { throw ExitCode(1) }
        print("ok: \(r.count(.shared)) shared, \(r.count(.ported)) ported, \(r.count(.skipped)) skipped, \(r.count(.todo)) todo")
    }
}

private func find(_ id: String, in r: Report) throws -> Entry {
    if let e = r.entries.first(where: { $0.mac.id == id }) { return e }
    let near = r.entries.filter { $0.mac.id.contains(id) }.prefix(10).map(\.mac.id)
    throw ValidationError("no macOS function \(id)" + (near.isEmpty ? "" : "; did you mean:\n  " + near.joined(separator: "\n  ")))
}

private func git(_ args: [String], in root: URL) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["git", "-C", root.path] + args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

struct Stamp: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the // @port line for a macOS function as it is now.")
    @OptionGroup var common: Common
    @Argument var id: String

    func run() throws {
        let (r, root) = try common.report()
        let e = try find(id, in: r)
        // The newest commit that touched its file; with a clean file that
        // commit's body is the one hashed.
        let dirty = !(git(["status", "--porcelain", "--", e.mac.file], in: root) ?? "").isEmpty
        let sha = git(["log", "-1", "--format=%h", "--", e.mac.file], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "uncommitted"
        if dirty { FileHandle.standardError.write(Data("warning: \(e.mac.file) has uncommitted changes; commit them before stamping\n".utf8)) }
        print("// @port \(e.mac.id) h=\(e.mac.hash) @\(sha)")
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "One macOS function: status, hash, Linux claims.")
    @OptionGroup var common: Common
    @Argument var id: String

    func run() throws {
        let (r, _) = try common.report()
        let e = try find(id, in: r)
        print("\(e.mac.id)\n  status \(e.status.rawValue)\(e.skipReason.map { " (\($0))" } ?? "")")
        print("  macOS  \(e.mac.file):\(e.mac.line)  h=\(e.mac.hash)  \(e.mac.lines) lines")
        for c in e.linux {
            print("  Linux  \(c.file):\(c.line)  \(c.id)  ported h=\(c.portedHash)\(c.portedCommit.map { " @\($0)" } ?? "")")
        }
    }
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What changed in a macOS function since its Linux port: the file's diff between the ported commit and HEAD.")
    @OptionGroup var common: Common
    @Argument var id: String

    func run() throws {
        let (r, root) = try common.report()
        let e = try find(id, in: r)
        guard let claim = e.linux.first(where: { $0.portedHash != e.mac.hash }) ?? e.linux.first else {
            throw ValidationError("\(id) has no Linux port")
        }
        guard let commit = claim.portedCommit else { throw ValidationError("its @port line has no @commit") }
        // The whole file's diff: `show` gives the function's line to look at.
        let out = git(["diff", "-U3", commit, "HEAD", "--", e.mac.file], in: root) ?? ""
        if out.isEmpty { print("no change in \(e.mac.file) since \(commit) (moved files: run `git log --follow`)"); return }
        print(out)
    }
}
