import Foundation

/// `port/config.json`: what is scanned, what the Linux build compiles, and
/// which macOS code is deliberately not ported.
public struct PortConfig: Codable, Sendable {
    /// The macOS code base the port follows.
    public var macosRoots: [String]
    /// Files under `macosRoots` that the Linux build also compiles (the
    /// shared core). Globs: `*` within a path component, `**` across them.
    public var linuxBuild: [String]
    /// Linux-only code: scanned for `@port` annotations, never part of the
    /// macOS build.
    public var linuxRoots: [String]
    /// Whole files or ids not needed on Linux, with why ("ui", "apple-only"…).
    public var skip: [SkipRule]

    public struct SkipRule: Codable, Sendable {
        public var path: String?
        public var id: String?
        public var reason: String
    }

    public static func load(_ url: URL) throws -> PortConfig {
        try JSONDecoder().decode(PortConfig.self, from: Data(contentsOf: url))
    }
}

public enum Status: String, Codable, CaseIterable, Sendable {
    /// Compiled into both builds from the same source: can't drift.
    case shared
    /// A Linux declaration implements it at its current hash.
    case ported
    /// A Linux declaration implements it, but the macOS body changed since.
    case stale
    /// Deliberately not on Linux (UI, Apple-only), with a reason.
    case skipped
    /// Nothing on Linux yet.
    case todo
}

public struct Entry: Codable, Sendable {
    public let mac: FunctionRecord
    public let status: Status
    /// The Linux declarations that claim it (`file:line` and the hash and
    /// commit they were ported from).
    public let linux: [LinuxClaim]
    public let skipReason: String?

    public struct LinuxClaim: Codable, Sendable {
        public let id: String
        public let file: String
        public let line: Int
        public let portedHash: String
        public let portedCommit: String?
    }
}

public struct Report: Codable, Sendable {
    public let entries: [Entry]
    /// `@port` lines naming a macOS id that no longer exists (renamed or
    /// removed on macOS): the port has to be re-pointed.
    public let orphans: [Entry.LinuxClaim]
    /// Linux-only declarations with no `@port` line: new Linux code that
    /// corresponds to nothing, or a port someone forgot to stamp.
    public let unclaimedLinux: [FunctionRecord]

    public func count(_ s: Status) -> Int { entries.lazy.filter { $0.status == s }.count }
}

public enum Ledger {
    public static func sourceFiles(under roots: [String], root: URL) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for r in roots {
            let base = root.appendingPathComponent(r)
            guard let e = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                out.append(rel)
            }
        }
        return out.sorted()
    }

    public static func build(config: PortConfig, root: URL) throws -> Report {
        let macFiles = sourceFiles(under: config.macosRoots, root: root)
        let linuxOnlyFiles = sourceFiles(under: config.linuxRoots, root: root)
        let linuxGlobs = config.linuxBuild.map(Glob.init)
        let mac = try Inventory.scan(files: macFiles, root: root,
                                     linuxBuild: { f in linuxGlobs.contains { $0.matches(f) } })
        var linuxOnly: [FunctionRecord] = []
        for f in linuxOnlyFiles {
            let text = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            linuxOnly += Inventory.scan(source: text, file: f, fileInLinuxBuild: true, fileInMacOSBuild: false)
        }
        return assemble(mac: mac, linuxOnly: linuxOnly, config: config)
    }

    /// Pure: the report from scanned records (unit-tested).
    public static func assemble(mac all: [FunctionRecord], linuxOnly: [FunctionRecord],
                                config: PortConfig) -> Report {
        let macSide = all.filter { $0.inMacOS }
        // Linux implementations: Linux-only files plus `#if os(Linux)`
        // branches of shared files.
        let linuxImpls = linuxOnly + all.filter { $0.inLinux && !$0.inMacOS }
        var claims: [String: [Entry.LinuxClaim]] = [:]
        for r in linuxImpls {
            for p in r.ports {
                claims[p.macID, default: []].append(Entry.LinuxClaim(
                    id: r.id, file: r.file, line: r.line, portedHash: p.hash, portedCommit: p.commit))
            }
        }
        let pathRules = config.skip.compactMap { s in s.path.map { (Glob($0), s.reason) } }
        let idRules = Dictionary(config.skip.compactMap { s in s.id.map { ($0, s.reason) } },
                                 uniquingKeysWith: { a, _ in a })

        var entries: [Entry] = []
        var macIDs = Set<String>()
        for r in macSide {
            macIDs.insert(r.id)
            let mine = claims[r.id] ?? []
            let status: Status
            var reason: String?
            if r.inLinux {
                status = .shared
            } else if !mine.isEmpty {
                status = mine.allSatisfy { $0.portedHash == r.hash } ? .ported : .stale
            } else if let why = r.skipReason ?? idRules[r.id] ?? pathRules.first(where: { $0.0.matches(r.file) })?.1 {
                status = .skipped
                reason = why
            } else {
                status = .todo
            }
            entries.append(Entry(mac: r, status: status, linux: mine, skipReason: reason))
        }
        let orphans = claims.filter { !macIDs.contains($0.key) }.flatMap(\.value)
            .sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        let unclaimed = linuxImpls.filter { $0.ports.isEmpty && $0.skipReason == nil }
        return Report(entries: entries, orphans: orphans, unclaimedLinux: unclaimed)
    }
}

/// `*` matches within one path component, `**/` any number of them.
public struct Glob: Sendable {
    let regex: NSRegularExpression
    public init(_ pattern: String) {
        var re = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let after = pattern.index(after: next)
                    if after < pattern.endIndex, pattern[after] == "/" {
                        re += "(?:.*/)?"; i = pattern.index(after: after); continue
                    }
                    re += ".*"; i = pattern.index(after: next); continue
                }
                re += "[^/]*"
            } else if c == "?" {
                re += "[^/]"
            } else {
                re += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = pattern.index(after: i)
        }
        regex = try! NSRegularExpression(pattern: re + "$")
    }
    public func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}
