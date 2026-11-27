import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

/// Claude Code's `/ship` and `/steward` (2.1.330+): commit, push and open a
/// pull request, review it, then *watch* it -- Claude fixes failing checks,
/// conflicts and review comments and pushes again, on wake-ups it schedules
/// itself (`/steward --tend <pr>`), until the pull request is merged or the
/// user stops it (`/ship stop`).
///
/// What Bromure adds around it:
/// - which tab is watching what, read off the agent's transcript in the
///   guest (`scannerScript`, run by agent-status.sh when a turn ends) and
///   reported on the tab's status line (`watch(inStatus:)`);
/// - the Mac kept awake while a watch runs (`ShipWatchAwake`): Claude Code
///   asks for "this session open, this computer awake";
/// - a per-workspace switch (`Profile.claudeShipDisabled`) that hides both
///   skills through Claude Code's `skillOverrides`.
enum ClaudeShip {
    /// The skills behind `/ship` and `/steward`, as `skillOverrides` names them.
    static let skills = ["ship-local", "steward"]

    /// The first Claude Code that has `/ship`.
    static let minimumVersion = [2, 1, 330]

    /// A watch Claude Code wakes for at least hourly (its wake-ups are capped
    /// at an hour); one not heard from for longer than this is gone -- the
    /// agent exited, the tab was closed -- and no longer holds the Mac awake.
    static let staleAfter: TimeInterval = 75 * 60

    /// Whether `claude --version` output ("2.1.331 (Claude Code)") is a
    /// Claude Code that has `/ship`.
    static func supports(versionOutput: String) -> Bool {
        guard let m = versionOutput.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return false }
        let v = versionOutput[m].split(separator: ".").compactMap { Int($0) }
        return v.lexicographicallyPrecedes(minimumVersion) == false
    }

    /// A session's machine and folder, as far as `/ship` cares.
    struct Facts: Equatable {
        /// `claude --version`, "" when there is none.
        var claudeVersion: String
        /// The origin remote's URL, "" when there is none.
        var origin: String
        /// The origin's default branch ("main"), "" when unknown.
        var defaultBranch: String

        /// From `claude <version>` / `origin <url>` / `head origin/<branch>`
        /// lines (SessionBranches' `shipFacts`).
        static func parse(_ out: String) -> Facts {
            var f = Facts(claudeVersion: "", origin: "", defaultBranch: "")
            for line in out.split(separator: "\n") {
                let (key, rest) = (line.prefix { $0 != " " }, line.drop { $0 != " " }.trimmingCharacters(in: .whitespaces))
                switch key {
                case "claude": f.claudeVersion = rest
                case "origin": f.origin = rest
                case "head":
                    f.defaultBranch = rest.hasPrefix("origin/") ? String(rest.dropFirst("origin/".count)) : rest
                default: break
                }
            }
            return f
        }
    }

    /// Whether `/ship` can open the pull request asked for: a Claude Code
    /// that has it, a repository on github.com (no Enterprise, which /ship
    /// doesn't do), and the pull request going into the default branch (the
    /// only base /ship opens against).
    static func canShip(_ f: Facts, into: String) -> Bool {
        guard supports(versionOutput: f.claudeVersion) else { return false }
        let host = githubHost(f.origin)
        return host == "github.com" && !f.defaultBranch.isEmpty && f.defaultBranch == into
    }

    /// The host of a git remote URL: https://host/…, ssh://git@host/…,
    /// git@host:owner/repo.
    static func githubHost(_ url: String) -> String? {
        let u = url.trimmingCharacters(in: .whitespaces)
        if let c = URLComponents(string: u), let h = c.host, c.scheme != nil { return h.lowercased() }
        // scp-like: [user@]host:path
        guard let colon = u.firstIndex(of: ":"), !u[..<colon].contains("/") else { return nil }
        let hostPart = u[..<colon]
        let host = hostPart.split(separator: "@").last.map(String.init) ?? String(hostPart)
        return host.isEmpty ? nil : host.lowercased()
    }

    /// The watch a tab's status report carries on its third line:
    /// `ship <ref>` (watching), `ship` (not watching). nil: the report says
    /// nothing about it (not a turn end, not Claude, an older script).
    static func watch(inStatus signal: String) -> String?? {
        let lines = signal.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2 else { return nil }
        let line = lines[2].trimmingCharacters(in: .whitespaces)
        guard line == "ship" || line.hasPrefix("ship ") else { return nil }
        let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return .some(nil) }
        // A pull request (#41) or a branch name, as git allows one; anything
        // else is not ours to show.
        guard ref.count <= 200, ref.range(of: #"^(#[1-9][0-9]{0,9}|[A-Za-z0-9._/@+-]+)$"#,
                                          options: .regularExpression) != nil else { return .some("") }
        return .some(ref)
    }

    /// "PR #41", or the branch a watch without a pull request follows.
    static func label(_ ref: String) -> String {
        if ref.hasPrefix("#") {
            return String(format: NSLocalizedString("PR %@", comment: "a pull request /ship watches, e.g. PR #41"), ref)
        }
        return ref
    }

    /// Where Bromure records the `skillOverrides` entries it wrote itself,
    /// next to `settings.json` in `~/.claude` (bromure-agentd's twin uses the
    /// same file): skill name → the user's value it replaced (`NSNull` when
    /// there was none), plus `ownedVersionKey` and, once applied, the
    /// user's re-enable (`reclaimedKey`, see `Profile.claudeShipReclaimToken`).
    static let ownedOverridesFile = "bromure-skill-overrides.json"
    static let ownedVersionKey = "_version"
    static let reclaimedKey = "_reclaimed"

    /// `skillOverrides` for the workspace switch, and the entries Bromure
    /// owns afterwards. Off (`allowed` false): both skills "off", each value
    /// it replaces remembered. On: only the "off" entries Bromure wrote go,
    /// the user's earlier value put back. A user's own entry, "off" included,
    /// is never taken back (CWE-693): turning the switch on must not re-enable
    /// a skill the user turned off. An entry the user changed since Bromure
    /// wrote it is theirs again. Overrides nil when nothing is left.
    ///
    /// `reclaim`: the user asked, with the switch on, to turn both skills
    /// back on in a workspace an earlier build switched off without keeping
    /// a record (`Profile.claudeShipLegacyOff`). Its "off" entries can't be
    /// told from the user's own, so only that explicit answer removes them --
    /// never an inference (CWE-693).
    static func skillOverrides(_ existing: Any?, allowed: Bool, owned: [String: Any],
                               reclaim: Bool = false) -> (overrides: [String: Any]?, owned: [String: Any]) {
        var o = existing as? [String: Any] ?? [:]
        var owned = owned
        if reclaim && allowed {
            for s in skills where owned[s] == nil && o[s] as? String == "off" { owned[s] = NSNull() }
        }
        var mine: [String: Any] = [:]
        for s in skills {
            let ours = owned[s] != nil && o[s] as? String == "off"
            if allowed {
                guard ours else { continue }
                if let prior = owned[s], !(prior is NSNull) { o[s] = prior } else { o.removeValue(forKey: s) }
            } else if ours {
                mine[s] = owned[s]
            } else if o[s] as? String != "off" {
                mine[s] = o[s] ?? NSNull()
                o[s] = "off"
            }
        }
        return (o.isEmpty ? nil : o, mine)
    }

    private static func readRecord(in dir: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(ownedOverridesFile)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    /// The entries Bromure owns, read from `ownedOverridesFile` in `dir`.
    static func readOwnedOverrides(in dir: URL) -> [String: Any] {
        readRecord(in: dir).filter { skills.contains($0.key) }
    }

    /// The user's re-enable already applied in `dir`, if any.
    static func reclaimed(in dir: URL) -> String? {
        readRecord(in: dir)[reclaimedKey] as? String
    }

    /// Record the entries Bromure owns in `dir`, and the re-enable applied.
    static func writeOwnedOverrides(_ owned: [String: Any], reclaimed: String?, in dir: URL) {
        let url = dir.appendingPathComponent(ownedOverridesFile)
        var record = owned
        record[ownedVersionKey] = 1
        if let reclaimed { record[reclaimedKey] = reclaimed }
        guard let d = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    /// Reads a Claude Code transcript (argv[1]) and prints the watch it shows
    /// as running: `#41` (a pull request), a branch name (a watch with git
    /// alone), `?` (a watch whose target the transcript no longer names), or
    /// nothing. The markers are Claude Code's own -- the ones it
    /// reads back when it resumes a session: the skill's heading
    /// (`# /ship-local: watch pull request #41`), the wake-up
    /// (`/steward --tend 41`), `/ship stop`, "Stopped watching …", "the watch
    /// of … has ended". Only the transcript's last few MB are read.
    static let scannerScript = #"""
    #!/usr/bin/env python3
    # Bromure (managed): which /ship watch this Claude Code transcript shows
    # running. Prints the pull request (#41), the branch, or nothing.
    import json, os, re, sys

    HEAD_PR = re.compile(r'^# /(?:steward|ship-local): (watch |review |a pass over )?pull request #([1-9]\d{0,9})\b')
    HEAD_GIT = re.compile(r"^# /(?:steward|ship-local): (?:(watch |review )(\S+?)(?:, then watch it)?, with git alone|a pass over (\S+)|(\S+) couldn't be read)$", re.M)
    HEAD_OTHER = re.compile(r'^# /[\w-]+: (?:the watch of |review only(?:\n|$))')
    STOPPED = re.compile(r'^Stopped (?:watching (?:pull request #)?|scheduled task: /steward --tend )([^\s,]+)')
    ENDED = re.compile(r'/steward: the watch of \S+ has ended')
    CMD = re.compile(r'<command-name>(/[\w:-]+)</command-name>')
    ARGS = re.compile(r'<command-args>(.*?)</command-args>', re.S)
    STOP_ARGS = re.compile(r'(?:stop|cancel|abort)(?:\s+#?\d+)?', re.I)
    TEND = re.compile(r'--tend\s+(\S+)')
    COMMANDS = ('/ship', '/steward', '/ship-local')
    TAIL = 4 << 20

    def text(o):
        m = o.get('message')
        c = m.get('content') if isinstance(m, dict) else o.get('content')
        if isinstance(c, str):
            return c
        if isinstance(c, list):
            return '\n'.join(p.get('text', '') for p in c
                             if isinstance(p, dict) and p.get('type') == 'text')
        return ''

    def ref_of_tend(key):
        # A pull request's number; a watch with git alone wakes with a
        # ten-digit key starting with 9, which names no branch: still a
        # watch, its target unknown ("?", which the host shows as such).
        return '?' if re.fullmatch(r'9\d{9}', key) else '#' + key

    def scan(records):
        # Newest first. A wake-up proves a watch runs; its heading (older)
        # names it.
        tend = None
        for o in records:
            t = o.get('type')
            if t == 'system':
                if o.get('subtype') == 'informational' and STOPPED.match(str(o.get('content', ''))):
                    break
                continue
            if t != 'user':
                continue
            s = text(o).lstrip()
            if not s:
                continue
            if ENDED.search(s):
                break
            if o.get('isMeta'):
                if HEAD_OTHER.match(s):
                    break
                m = HEAD_PR.match(s)
                if m:
                    return None if m.group(1) == 'a pass over ' else '#' + m.group(2)
                m = HEAD_GIT.search(s)
                if m:
                    return m.group(2) if m.group(1) else None
                continue
            c = CMD.search(s)
            if c:
                name = c.group(1)
                a = ARGS.search(s)
                args = a.group(1) if a else ''
            elif s.startswith('/'):
                name, _, args = s.partition(' ')
            else:
                continue
            if name not in COMMANDS:
                continue
            args = re.sub(r'^\s*local\b', '', args.strip(), flags=re.I).strip()
            if STOP_ARGS.fullmatch(args):
                break
            m = TEND.match(args)
            if m and tend is None:
                tend = ref_of_tend(m.group(1))
        return tend

    def records(path):
        try:
            with open(path, 'rb') as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - TAIL))
                data = f.read()
        except OSError:
            return
        lines = data.split(b'\n')
        if size > TAIL:
            lines = lines[1:]   # cut mid-record
        for raw in reversed(lines):
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            if isinstance(o, dict):
                yield o

    if __name__ == '__main__' and len(sys.argv) > 1:
        r = scan(records(sys.argv[1]))
        if r:
            print(r)
    """#
}

/// Holds off idle sleep while a `/ship` watch runs: the Mac asleep is the VM
/// frozen, and the watch's wake-ups with it. Released when the last watch
/// ends or goes stale.
@MainActor
final class ShipWatchAwake {
    static let shared = ShipWatchAwake()

    /// Live watches, asked on every change and every few minutes (a watch
    /// goes stale on the clock).
    var provider: (() -> Int)?
    private var timer: Timer?
    #if canImport(IOKit)
    private var assertion: IOPMAssertionID?
    #endif

    /// Re-read the watches: take or release the assertion.
    func refresh() {
        let n = provider?() ?? 0
        hold(n > 0)
        if n > 0, timer == nil {
            let t = Timer(timeInterval: 300, repeats: true) { _ in
                Task { @MainActor in ShipWatchAwake.shared.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if n == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    var isHolding: Bool {
        #if canImport(IOKit)
        return assertion != nil
        #else
        return false
        #endif
    }

    private func hold(_ on: Bool) {
        #if canImport(IOKit)
        if on, assertion == nil {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Bromure: Claude is watching a pull request (/ship)" as CFString,
                                           &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !on, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
        #endif
    }
}
