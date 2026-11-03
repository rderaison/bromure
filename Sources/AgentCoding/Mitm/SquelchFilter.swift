import Foundation

/// Squelch: cuts the noise out of command output before the agent's model
/// reads it — passing tests, download and compile progress, git's transfer
/// counters, repeated log lines — and keeps what the agent acts on: errors,
/// failures, warnings, summaries. It runs in the proxy, on the tool results
/// each request carries, so every agent gets it with nothing installed in the
/// guest (`SquelchRewriter`).
///
/// Deterministic: the same command and output always give the same text, so a
/// conversation resent turn after turn keeps its prompt-cache prefix.
/// Output a command was asked to show verbatim — a file read (`cat`, `sed -n`,
/// `head`), a diff — is never touched: the agent copies from it to edit.
enum Squelch {
    /// A command carrying this is passed through whole: the escape hatch the
    /// note on a trimmed output names.
    static let fullOutputMarker = "BROMURE_FULL_OUTPUT=1"

    enum Family: String, Codable, CaseIterable, Sendable {
        case tests, install, build, git, logs, search, other
        /// Output the agent reads as the thing itself: never trimmed.
        case verbatim
    }

    struct Result: Equatable {
        var text: String
        var family: Family
        /// What was left out, by reason ("passing tests" → 212).
        var dropped: [String: Int]
        var rawBytes: Int
        var keptBytes: Int { text.utf8.count }
    }

    /// Smallest saving worth changing what the model reads for.
    static let minSavedBytes = 300
    static let minSavedFraction = 0.10

    /// The output as the model should read it, or nil to leave it alone.
    static func trim(command: String?, output: String) -> Result? {
        if let command, command.contains(fullOutputMarker) { return nil }
        guard output.utf8.count >= minSavedBytes else { return nil }
        let family = command.map(Self.family(of:)) ?? sniff(output)
        guard family != .verbatim else { return nil }
        var t = Trimmer(cleaned(output), family: family)
        t.run()
        let raw = output.utf8.count
        var text = t.lines.joined(separator: "\n")
        if output.hasSuffix("\n") && !text.isEmpty { text += "\n" }
        if !t.dropped.isEmpty { text += note(t.dropped) }
        let saved = raw - text.utf8.count
        guard saved >= minSavedBytes, Double(saved) >= Double(raw) * minSavedFraction else { return nil }
        return Result(text: text, family: family, dropped: t.dropped, rawBytes: raw)
    }

    /// The line a trimmed output ends with: what went, and how to get it all.
    static func note(_ dropped: [String: Int]) -> String {
        let total = dropped.values.reduce(0, +)
        let parts = dropped.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "[Bromure Squelch left out \(total) noise line\(total == 1 ? "" : "s") (\(parts)). "
            + "Run the command again prefixed with \(fullOutputMarker) to see all of it.]"
    }

    // MARK: Cleaning (every family but verbatim)

    private static let ansi = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]")

    /// Terminal escapes out, and a line redrawn with carriage returns (a
    /// progress counter) as it last stood.
    static func cleaned(_ s: String) -> String {
        var s = s
        if s.contains("\u{1B}") {
            s = ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        guard s.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let r = line.lastIndex(of: "\r") else { return line }
                let after = line[line.index(after: r)...]
                return after.isEmpty ? line[..<r].split(separator: "\r").last ?? "" : after
            }.joined(separator: "\n")
    }

    // MARK: Classification

    /// Commands whose output is the content itself.
    private static let verbatimCommands: Set<String> = [
        "cat", "head", "tail", "sed", "nl", "less", "more", "bat", "batcat", "xxd", "od", "hexdump",
        "jq", "yq", "awk", "gawk", "diff", "cmp", "wc", "stat", "file", "echo", "printf", "base64",
        "sha256sum", "shasum", "md5sum", "md5", "readlink", "realpath", "pwd", "which", "type", "env",
        "printenv", "column", "tr", "cut", "sort", "uniq", "tee", "strings", "plutil", "defaults",
        "sqlite3", "psql", "mysql", "curl", "wget", "http", "openssl", "date", "cal", "man", "tree",
        "python-c", "node-e",
    ]
    /// A pipeline ending in one of these already shaped its output.
    private static let shapingCommands: Set<String> = [
        "head", "tail", "grep", "egrep", "fgrep", "rg", "wc", "sort", "uniq", "cut", "awk", "sed",
        "jq", "less", "more", "tr", "column", "xargs", "tee", "cat", "nl", "fold", "fmt",
    ]
    private static let wrappers: Set<String> = [
        "sudo", "time", "env", "nice", "nohup", "command", "exec", "stdbuf", "caffeinate", "unbuffer",
    ]

    static func family(of command: String) -> Family {
        let segments = split(command, on: ["&&", "||", ";", "\n"])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // The segment doing the work: the last one that isn't bookkeeping.
        let bookkeeping: Set<String> = ["cd", "echo", "printf", "true", "false", "exit", "set", "export",
                                        "source", ".", "pushd", "popd", "sleep", "unset", "trap"]
        let work = segments.last { seg in
            !bookkeeping.contains(words(of: split(seg, on: ["|"]).first ?? seg).first ?? "")
        } ?? segments.last ?? command
        let stages = split(work, on: ["|"]).map { $0.trimmingCharacters(in: .whitespaces) }
        let first = words(of: stages.first ?? work)
        if let w = first.first, verbatimCommands.contains(w) { return .verbatim }
        if stages.count > 1, let last = words(of: stages.last!).first, shapingCommands.contains(last) {
            // `cmd | grep x`, `cmd | tail -20`: what's left was chosen — and
            // may be what the model copies from (`git diff | head`).
            return .verbatim
        }
        return family(words: first)
    }

    static func family(words w: [String]) -> Family {
        guard let cmd = w.first else { return .other }
        let a1 = w.count > 1 ? w[1] : ""
        let a2 = w.count > 2 ? w[2] : ""
        let rest = Set(w.dropFirst())
        func isTestScript(_ s: String) -> Bool { s == "test" || s.hasPrefix("test:") || s.hasPrefix("test-") }
        // An uninstall's output is its result — what went — not install
        // chatter (pip's "Uninstalling x" / "Successfully uninstalled x").
        let removals: Set<String> = ["uninstall", "remove", "rm", "purge", "autoremove", "erase", "un", "del"]
        /// The first word after index `i` that isn't a flag (`apt-get -y
        /// remove`, `python -m pip -q uninstall`).
        func verb(after i: Int) -> String { w.dropFirst(i + 1).first { !$0.hasPrefix("-") } ?? "" }
        switch cmd {
        case "pytest", "py.test", "jest", "vitest", "mocha", "rspec", "phpunit", "tox", "nox",
             "ctest", "karma", "ava", "tap", "nextest", "bats", "behave", "playwright", "cypress":
            if cmd == "playwright" || cmd == "cypress" { return a1 == "test" || a1 == "run" ? .tests : .other }
            return .tests
        case "go":
            switch a1 {
            case "test": return .tests
            case "build", "vet", "install", "generate": return .build
            case "get", "mod": return a1 == "mod" && !["download", "tidy"].contains(a2) ? .other : .install
            default: return .other
            }
        case "cargo":
            switch a1 {
            case "test", "nextest": return .tests
            case "build", "check", "clippy", "run", "doc", "bench": return .build
            case "fetch", "install", "update", "add": return .install
            default: return .other
            }
        case "swift":
            switch a1 {
            case "test": return .tests
            case "build", "run": return .build
            case "package": return ["resolve", "update"].contains(a2) ? .install : .other
            default: return .other
            }
        case "xcodebuild":
            return rest.contains("test") || rest.contains("test-without-building") ? .tests : .build
        case "npm", "pnpm", "yarn", "bun", "deno":
            if cmd == "yarn" && a1.isEmpty { return .install }
            switch a1 {
            case "test", "t": return .tests
            case "install", "i", "ci", "add", "update", "upgrade", "up": return .install
            case _ where removals.contains(a1): return .other
            case "run", "run-script":
                if isTestScript(a2) { return .tests }
                return a2 == "build" || a2.hasPrefix("build:") ? .build : .other
            case "build": return .build
            default: return isTestScript(a1) ? .tests : (a1 == "exec" || a1 == "x" ? family(words: Array(w.dropFirst(2))) : .other)
            }
        case "npx", "bunx", "pnpx":
            return family(words: Array(w.dropFirst()))
        case "pip", "pip3", "pipx":
            return a1 == "install" || a1 == "download" ? .install : .other
        case "uv":
            if a1 == "run" { return family(words: Array(w.dropFirst(2))) }
            if (a1 == "pip" || a1 == "tool") && removals.contains(verb(after: 1)) { return .other }
            return a1 == "pip" || ["sync", "add", "lock", "install", "venv", "tool"].contains(a1) ? .install : .other
        case "poetry", "pdm", "hatch", "rye", "pipenv":
            if a1 == "run" { return family(words: Array(w.dropFirst(2))) }
            return ["install", "add", "update", "lock", "sync"].contains(a1) ? .install : .other
        case "python", "python3":
            if a1 == "-m" {
                if a2 == "pytest" || a2 == "unittest" || a2 == "nose2" || a2 == "tox" { return .tests }
                if a2 == "pip" { return removals.contains(verb(after: 2)) ? .other : .install }
                if a2 == "build" { return .build }
            }
            return .other
        case "apt", "apt-get", "aptitude", "dnf", "yum", "apk", "pacman", "zypper", "brew", "port",
             "gem", "conda", "mamba", "micromamba", "composer", "pod", "dotnet-restore":
            if removals.contains(verb(after: 0)) || cmd == "pacman" && a1.hasPrefix("-R") { return .other }
            if cmd == "brew" && ["list", "info", "search", "doctor", "config", "leaves", "deps"].contains(a1) { return .other }
            if cmd == "gem" && a1 != "install" && a1 != "update" { return .other }
            if cmd == "apt" || cmd == "apt-get" {
                return ["install", "update", "upgrade", "dist-upgrade", "full-upgrade"]
                    .contains(a1) || a1.hasPrefix("-") ? .install : .other
            }
            return .install
        case "bundle":
            if a1 == "exec" { return family(words: Array(w.dropFirst(2))) }
            return a1 == "install" || a1.isEmpty || a1 == "update" ? .install : .other
        case "rails", "mix", "rake":
            return a1 == "test" || a1 == "spec" ? .tests : .other
        case "dotnet":
            return a1 == "test" ? .tests : (a1 == "build" || a1 == "publish" ? .build : (a1 == "restore" ? .install : .other))
        case "mvn", "mvnw", "./mvnw", "gradle", "gradlew", "./gradlew":
            if rest.contains("test") || rest.contains("verify") || rest.contains("check") { return .tests }
            return .build
        case "make", "gmake":
            return ["test", "check", "tests", "unittest", "test-unit"].contains(a1) ? .tests : .build
        case "cmake", "ninja", "meson", "bazel", "bazelisk", "buck2", "tsc", "webpack", "vite", "esbuild",
             "rollup", "parcel", "turbo", "nx", "next", "nuxt", "zig", "rustc", "clang", "gcc", "g++", "cc",
             "swiftc", "javac", "kotlinc", "scons", "./build.sh", "build.sh", "msbuild":
            if cmd == "bazel" || cmd == "bazelisk" { return a1 == "test" ? .tests : .build }
            if cmd == "zig" { return a1 == "test" ? .tests : .build }
            if cmd == "turbo" || cmd == "nx" { return rest.contains("test") ? .tests : .build }
            if cmd == "next" || cmd == "nuxt" || cmd == "vite" { return a1 == "build" || cmd == "vite" && a1.isEmpty ? .build : .other }
            return .build
        case "docker", "podman", "nerdctl":
            switch a1 {
            case "build", "buildx": return .build
            case "pull", "push": return .install
            case "logs": return .logs
            case "compose", "compose-v2":
                if rest.contains("logs") { return .logs }
                if rest.contains("build") { return .build }
                return rest.contains("pull") || rest.contains("up") ? .install : .other
            default: return .other
            }
        case "docker-compose":
            return rest.contains("logs") ? .logs : (rest.contains("build") ? .build : .other)
        case "kubectl", "oc", "k3s":
            return a1 == "logs" ? .logs : .other
        case "journalctl", "dmesg", "log":
            return cmd == "log" && a1 != "show" && a1 != "stream" ? .other : .logs
        case "git":
            switch gitSubcommand(w) {
            case "diff", "show", "blame", "cat-file", "format-patch", "apply", "log", "reflog", "ls-files", "ls-tree",
                 "rev-parse", "range-diff", "annotate", "whatchanged", "shortlog", "stash", "notes":
                return .verbatim
            case "grep": return .search
            default: return .git
            }
        case "hg", "svn", "jj", "fossil":
            // Other VCSs: diffs and file contents, as git's.
            let sub = positionals(w, valued: ["-R", "--repository", "--cwd", "--config", "--at-op", "--at-operation",
                                              "--color", "--pager", "--encoding", "--encodingmode", "--username", "--password",
                                              "--config-dir", "--config-option"]).first
            return ["diff", "log", "show", "cat", "annotate", "blame", "export", "file"].contains(sub ?? "") ? .verbatim : .other
        case "gh", "glab":
            // `gh pr diff`, `gh api …`: the content itself.
            let p = positionals(w, valued: ["-R", "--repo", "--hostname"])
            let p0 = p.first ?? "", p1 = p.count > 1 ? p[1] : ""
            return p0 == "api" || p1 == "diff" || (p0 == "gist" && p1 == "view") ? .verbatim : .other
        case "grep", "egrep", "fgrep", "rg", "ag", "ack", "ugrep", "find", "fd":
            return cmd == "find" || cmd == "fd" ? .other : .search
        case "terraform", "tofu", "pulumi", "helm", "ansible-playbook":
            return .build
        default:
            return .other
        }
    }

    /// git's subcommand, past its global options (`git --no-pager diff`,
    /// `git -C repo log`, `git -c color.ui=never show`).
    static func gitSubcommand(_ w: [String]) -> String {
        positionals(w, valued: ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env",
                                "--super-prefix", "--attr-source"]).first ?? ""
    }

    /// A command's words after its name that aren't options: `valued`
    /// options take the next word (`-R repo`); `--opt=value` and the rest
    /// are flags.
    static func positionals(_ w: [String], valued: Set<String>) -> [String] {
        var out: [String] = []
        var i = 1
        while i < w.count {
            let a = w[i]
            if valued.contains(a) { i += 2; continue }
            if !a.hasPrefix("-") { out.append(a) }
            i += 1
        }
        return out
    }

    /// The family an output reads as when the command isn't known — for the
    /// hidden `__squelch` CLI only: the proxy never trims an output whose
    /// command it doesn't know (`SquelchRewriter`).
    static func sniff(_ s: String) -> Family {
        let head = String(s.prefix(4000))
        if head.contains("test session starts") || head.contains("=== RUN ") || head.contains("Test Suite '")
            || head.contains("Test run with") || head.range(of: #"(?m)^running \d+ tests?$"#, options: .regularExpression) != nil
            || head.range(of: #"(?m)^\s*(PASS|FAIL) \S+\.(test|spec)\.[jt]sx?"#, options: .regularExpression) != nil {
            return .tests
        }
        if head.range(of: #"(?m)^(Collecting |Requirement already satisfied|Reading package lists|Get:\d+ |npm (WARN|warn) |added \d+ packages|==> Downloading|go: downloading )"#,
                      options: .regularExpression) != nil { return .install }
        if head.range(of: #"(?m)^(\s+Compiling \S+ v\d|\[\d+/\d+\] (Compiling|Building)|CompileSwift |Building for (debugging|production))"#,
                      options: .regularExpression) != nil { return .build }
        if head.range(of: #"(?m)^(Enumerating objects:|remote: (Enumerating|Counting) objects)"#,
                      options: .regularExpression) != nil { return .git }
        return .other
    }

    /// `s` cut at each separator outside quotes (and outside `$(…)`).
    static func split(_ s: String, on seps: [String]) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character? = nil
        var depth = 0
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                cur.append(c)
                if c == "\\" && q == "\"" && i + 1 < chars.count { cur.append(chars[i + 1]); i += 2; continue }
                if c == q { quote = nil }
                i += 1; continue
            }
            if c == "\\" && i + 1 < chars.count { cur.append(c); cur.append(chars[i + 1]); i += 2; continue }
            if c == "'" || c == "\"" { quote = c; cur.append(c); i += 1; continue }
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            if depth == 0, let sep = seps.first(where: { matches(chars, at: i, $0) }) {
                // `|` alone, not the first half of `||`; `&&`, not a lone `&`.
                if sep == "|", i + 1 < chars.count, chars[i + 1] == "|" { cur.append("||"); i += 2; continue }
                if sep == "|", i > 0, chars[i - 1] == "|" { cur.append(c); i += 1; continue }
                out.append(cur); cur = ""; i += sep.count; continue
            }
            cur.append(c); i += 1
        }
        out.append(cur)
        return out
    }

    private static func matches(_ chars: [Character], at i: Int, _ sep: String) -> Bool {
        var j = i
        for ch in sep {
            guard j < chars.count, chars[j] == ch else { return false }
            j += 1
        }
        return true
    }

    /// The words of a simple command, with leading `VAR=value` assignments,
    /// wrappers (`sudo`, `time`, `timeout 60`…) and paths to the program
    /// left out: `CI=1 sudo /usr/bin/pytest -q` → ["pytest", "-q"].
    static func words(of segment: String) -> [String] {
        var w = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()"))
        }.filter { !$0.isEmpty }
        while let f = w.first {
            if f.contains("="), !f.hasPrefix("-"), f.first?.isLetter == true || f.first == "_" { w.removeFirst(); continue }
            if wrappers.contains(f) {
                w.removeFirst()
                while let o = w.first, o.hasPrefix("-") { w.removeFirst() }   // sudo -E, env -i
                continue
            }
            if f == "timeout" || f == "gtimeout" {
                w.removeFirst()
                while let o = w.first, o.hasPrefix("-") { w.removeFirst() }
                if !w.isEmpty { w.removeFirst() }                                // the duration
                continue
            }
            break
        }
        if let f = w.first, f.contains("/"), !f.hasPrefix("./gradlew"), !f.hasPrefix("./mvnw"), f != "./build.sh" {
            w[0] = (f as NSString).lastPathComponent
            if w[0] == "build.sh" { w[0] = "./build.sh" }
        }
        if w.first == "python" || w.first == "python3" || w.first == "node", w.count > 1, w[1] == "-c" || w[1] == "-e" {
            w = [w[0] == "node" ? "node-e" : "python-c"]
        }
        return w
    }
}

// MARK: - The filters

extension Squelch {
    /// Line filters for one family. A line that names an error, a failure or
    /// a warning is never left out (`protected`), whatever pattern it matches.
    struct Trimmer {
        var lines: [String]
        let family: Family
        var dropped: [String: Int] = [:]

        init(_ text: String, family: Family) {
            var l = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if l.last == "" { l.removeLast() }
            self.lines = l
            self.family = family
        }

        mutating func run() {
            switch family {
            case .tests:
                // A pass line names its test, and a test about errors is
                // still a pass: only a failure marker keeps it.
                drop("passing tests", Patterns.passingTest, protectedBy: Patterns.failureMarker)
                drop("build progress", Patterns.buildProgress)
                drop("download progress", Patterns.installNoise)
            case .install:
                drop("download progress", Patterns.installNoise)
                drop("deprecation notices", Patterns.deprecation, protect: false)
            case .build:
                dropXcodeSteps()
                drop("build progress", Patterns.buildProgress)
                drop("download progress", Patterns.installNoise)
                dedupeWarnings()
            case .git:
                drop("git hints", Patterns.gitHint, protect: false)
                drop("transfer progress", Patterns.gitTransfer)
                collapseCreateMode()
            case .logs:
                collapseSimilarRuns(minRun: 3)
            case .search:
                clipLongLines(max: 300)
            case .other, .verbatim:
                break
            }
            if family != .verbatim {
                drop("progress bars", Patterns.progressBar)
                collapseRepeats(minRun: 6)
                // An unknown command's output may be data the agent parses:
                // its blank lines stay as printed.
                if family != .other { collapseBlankRuns() }
            }
        }

        /// Error/failure/warning lines stay, whatever else they match.
        static func protected(_ line: String) -> Bool {
            Patterns.protectedWords.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }

        mutating func drop(_ reason: String, _ re: NSRegularExpression, protect: Bool = true,
                           protectedBy guardRE: NSRegularExpression = Patterns.protectedWords) {
            var kept: [String] = []
            kept.reserveCapacity(lines.count)
            var n = 0
            for line in lines {
                let r = NSRange(line.startIndex..., in: line)
                if re.firstMatch(in: line, range: r) != nil,
                   !(protect && guardRE.firstMatch(in: line, range: r) != nil) {
                    n += 1
                } else {
                    kept.append(line)
                }
            }
            if n > 0 { dropped[reason, default: 0] += n; lines = kept }
        }

        /// xcodebuild prints each build step as a header line and its
        /// indented command lines (`    cd …`, `    /Applications/Xcode.app/…`):
        /// both go, unless the step names an error.
        mutating func dropXcodeSteps() {
            var kept: [String] = []
            var n = 0
            var inStep = false
            for line in lines {
                if Patterns.xcodeStep.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                   !Self.protected(line) {
                    inStep = true; n += 1; continue
                }
                if inStep, line.hasPrefix("    ") || line.isEmpty, !Self.protected(line) { n += 1; continue }
                inStep = false
                kept.append(line)
            }
            if n > 0 { dropped["build steps", default: 0] += n; lines = kept }
        }

        /// The same warning printed again (one per target, per architecture).
        mutating func dedupeWarnings() {
            var seen = Set<String>()
            var kept: [String] = []
            var n = 0
            for line in lines {
                if line.range(of: "warning:", options: .caseInsensitive) != nil {
                    if !seen.insert(line).inserted { n += 1; continue }
                }
                kept.append(line)
            }
            if n > 0 { dropped["repeated warnings", default: 0] += n; lines = kept }
        }

        /// `create mode 100644 …` for every file a commit adds.
        mutating func collapseCreateMode() {
            let idx = lines.indices.filter {
                lines[$0].range(of: #"^ (create|delete) mode \d+ "#, options: .regularExpression) != nil
            }
            guard idx.count > 8 else { return }
            let keep = Set(idx.prefix(5))
            var kept: [String] = []
            for (i, line) in lines.enumerated() where !idx.contains(i) || keep.contains(i) { kept.append(line) }
            kept.insert(" … \(idx.count - 5) more file modes", at: (kept.lastIndex { $0.hasPrefix(" create mode") || $0.hasPrefix(" delete mode") } ?? kept.count - 1) + 1)
            dropped["file modes", default: 0] += idx.count - 5
            lines = kept
        }

        /// Runs of lines that differ only in their numbers (timestamps, ids,
        /// counters): the first, and a count.
        mutating func collapseSimilarRuns(minRun: Int) {
            var kept: [String] = []
            var n = 0
            var i = 0
            while i < lines.count {
                let shape = Self.shape(lines[i])
                var j = i + 1
                while j < lines.count, Self.shape(lines[j]) == shape { j += 1 }
                let run = j - i
                if run >= minRun, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    kept.append(lines[i])
                    kept.append("  … \(run - 1) more like the line above")
                    n += run - 1
                } else {
                    kept.append(contentsOf: lines[i..<j])
                }
                i = j
            }
            if n > 0 { dropped["repeated log lines", default: 0] += n; lines = kept }
        }

        static func shape(_ s: String) -> String {
            Patterns.numbers.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "#")
        }

        /// The same line many times in a row.
        mutating func collapseRepeats(minRun: Int) {
            var kept: [String] = []
            var n = 0
            var i = 0
            while i < lines.count {
                var j = i + 1
                while j < lines.count, lines[j] == lines[i] { j += 1 }
                let run = j - i
                if run >= minRun, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    kept.append(lines[i])
                    kept.append("  … the line above \(run - 1) more times")
                    n += run - 1
                } else {
                    kept.append(contentsOf: lines[i..<j])
                }
                i = j
            }
            if n > 0 { dropped["repeated lines", default: 0] += n; lines = kept }
        }

        /// No more than one blank line in a row.
        mutating func collapseBlankRuns() {
            var kept: [String] = []
            var n = 0
            for line in lines {
                let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
                if blank, let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { n += 1; continue }
                kept.append(line)
            }
            if n > 2 { dropped["blank lines", default: 0] += n; lines = kept }
        }

        /// A match in minified code is one enormous line: its start is enough
        /// to know where it is.
        mutating func clipLongLines(max: Int) {
            var n = 0
            lines = lines.map { line in
                guard line.count > max + 100 else { return line }
                n += 1
                return String(line.prefix(max)) + " … [\(line.count - max) more characters]"
            }
            if n > 0 { dropped["long lines clipped", default: 0] += n }
        }
    }

    enum Patterns {
        static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: o)
        }

        static let protectedWords = re(#"(?i)\b(error|errors|fail|failed|failure|failures|failing|panic|panicked|exception|traceback|fatal|warning|warnings|denied|abort|aborted|segfault|timeout|timed out|unresolved|undefined)\b|✗|✘|×|􀢄"#)

        static let failureMarker = re(#"\b(FAILED|FAIL|FAILURE|ERROR|PANIC)\b|✘|✗|􀢄"#)

        static let passingTest = re(#"""
        (?x)
          ^\S+::\S+.*\sPASSED(\s|$)                                  # pytest -v
        | ^[\w./\\-]+\.py\s[.sx]+\s*(\[\s*\d+%\])?$                 # pytest progress dots
        | ^\s*[✓✔√]\s                                              # jest/vitest/mocha ✓
        | ^\s*PASS\s+\S                                             # jest file PASS
        | ^===\s(RUN|PAUSE|CONT|NAME)\s                             # go test -v
        | ^\s*---\sPASS:\s                                          # go test -v
        | ^ok\s+\S+\s+(\(cached\)|[\d.]+s)                          # go test package ok
        | ^PASS$
        | ^test\s.+\s\.\.\.\s(ok|ignored)$                          # cargo test
        | ^Test\sCase\s'.*'\s(started|passed)                       # XCTest
        | ^Test\sSuite\s'.*'\s(started|passed)
        | ^\s*\t?Executed\s\d+\stests?,\swith\s0\sfailures
        | ^(◇|􀟈)\s(Test|Suite)\s.*\sstarted\.?$                     # Swift Testing
        | ^(✔|􁁛)\s(Test|Suite)\s.*\spassed
        | ^\s*Passed\s+\S+.*\[\s*[\d.]+\s*m?s\]                      # dotnet test
        | ^[.*]{8,}$                                                # rspec dots
        | ^[.SIR]+\s+\d+\s/\s\d+\s\(\s*\d+%\)$                      # phpunit
        | ^\s*\[\s*OK\s*\]\s                                        # gtest
        | ^\s*\[\s*RUN\s*\]\s
        """#)

        static let buildProgress = re(#"""
        (?x)
          ^\s*(Compiling|Checking|Documenting|Fresh|Building|Locking|Blocking)\s\S+\sv?\d    # cargo
        | ^\[\d+/\d+\]\s                                           # swift build, ninja
        | ^\[\s*\d+%\]\s(Building|Linking|Built\starget|Scanning|Generating)  # cmake
        | ^make(\[\d+\])?:\s(Entering|Leaving)\sdirectory
        | ^>\sTask\s:                                              # gradle
        | ^\[INFO\]\s(Download|Downloading|Downloaded|Building\s|---|\s*$)  # maven
        | ^\x23\d+\s(sha256:|extracting|DONE|CACHED|transferring|resolve|\[internal\])  # docker buildkit
        | ^(Fetching|Fetched|Cloning|Computing\sversion|Resolving|Working\scopy|Creating\sworking\scopy)\s.*\s(from|of|for|at)\s   # swiftpm
        | ^Building\sfor\s(debugging|production)\.\.\.$
        | ^\s*(CC|CXX|LD|AR|AS|CCLD|CXXLD)\s+\S+$                   # kbuild/automake quiet lines
        """#)

        static let installNoise = re(#"""
        (?x)
          ^\s*(Collecting|Downloading|Using\scached|Obtaining|Requirement\salready\ssatisfied|Processing|Building\swheels?|Created\swheel|Stored\sin\sdirectory|Preparing\smetadata|Installing\sbuild\sdependencies|Getting\srequirements|Attempting\suninstall|Found\sexisting\sinstallation|Uninstalling|Downloaded|Resolved|Prepared|Audited|Using\sPython|Installing\scollected\spackages)\b
        | ^\s*[━─]+\s                                              # pip progress
        | ^(Get|Hit|Ign):\d+\s                                      # apt
        | ^(Reading\spackage\slists|Building\sdependency\stree|Reading\sstate\sinformation|Calculating\supgrade)
        | ^(Selecting\spreviously\sunselected|Preparing\sto\sunpack|Unpacking|Setting\sup|Processing\striggers\sfor|Fetched\s[\d.]+\s[kMG]?B)
        | ^\(Reading\sdatabase
        | ^==>\s(Downloading|Fetching|Pouring|Verifying|Installing\sdependencies)
        | ^Already\sdownloaded:
        | ^\s*(Downloading|Downloaded|Fetching|Updating|Adding|Unpacking)\s\S+\sv?\d    # cargo, bun
        | ^go:\s(downloading|finding|extracting)\s
        | ^npm\s(http|timing|sill|verb)\s
        | ^Progress:\sresolved\s                                    # pnpm
        | ^\++$
        | ^\[\d/\d\]\s                                             # yarn
        | ^[0-9a-f]{12}:\s(Pulling\sfs\slayer|Waiting|Downloading|Verifying\sChecksum|Download\scomplete|Extracting|Pull\scomplete|Already\sexists|Preparing|Pushing|Pushed|Layer\salready\sexists|Mounted\sfrom)
        | ^\s*(Fetching|Installing|Using)\s\S+\s\d[\w.]*(\s\(was|\s*$)          # bundler, gem
        | ^\s*-\s(Installing|Downloading|Upgrading|Locking)\s\S+\s\(        # composer, poetry
        """#)

        static let deprecation = re(#"(?i)^npm\s(WARN|warn)\sdeprecated\s|^warning\s\S+\s>\s.*deprecated|^\s*DEPRECATION:\s"#)

        static let gitHint = re(#"^\s*\((use|commit or discard|create/copy files and use|fix conflicts and run|all conflicts fixed: run)\b.*\)$|^hint:\s"#)
        static let gitTransfer = re(#"^(remote:\s+)?(Enumerating|Counting|Compressing|Writing|Receiving|Resolving|Delta\scompression|Unpacking|Finding\ssources|Total)\b.*(\d+%|\bdone\b|objects|deltas)|^remote:\s*$"#)

        static let xcodeStep = re(#"^(CompileSwift|CompileSwiftSources|CompileC|SwiftCompile|SwiftDriver|SwiftDriverJobDiscovery|SwiftEmitModule|SwiftMergeGeneratedHeaders|EmitSwiftModule|Ld|Libtool|CodeSign|ProcessInfoPlistFile|CopySwiftLibs|MkDir|CreateBuildDirectory|WriteAuxiliaryFile|ProcessProductPackaging|ProcessProductPackagingDER|Touch|RegisterExecutionPolicyException|Validate|ValidateEmbeddedBinary|GenerateDSYMFile|CpResource|CpHeader|Copy|PhaseScriptExecution|ScanDependencies|CompileAssetCatalog|CompileAssetCatalogVariant|LinkStoryboards|CompileStoryboard|CompileXIB|ExtractAppIntentsMetadata|AppIntentsSSUTraining|GenerateAssetSymbols|ComputePackagePrebuildTargetDependencyGraph|CreateUniversalBinary|PrecompileModule|SymLink|Strip|SetOwnerAndGroup|SetMode|ProcessXCFramework|CopyPlistFile|ConstructStubExecutorLinkFileList|ComputeTargetDependencyGraph|GatherProvisioningInputs|CreateBuildRequest|SendProjectDescription|CreateBuildOperation|ClangStatCache|WriteAuxiliaryFile|Prepare\s+packages|Resolve\s+Package\s+Graph|Build\s+description\s+signature|Build\s+description\s+path|note:\s+(Building\s+targets|Target\s+dependency\s+graph|Using\s+codesigning|Run\s+script\s+build\s+phase|Metadata\s+extraction\s+skipped|Removed\s+stale))\b"#)

        static let progressBar = re(#"""
        (?x)
          ^\s*[\[(|]?(?=[^\x23=█━▉▊▋▌▍▎▏░▒▓>]*[\x23=█━▉▊▋▌▍▎▏░▒▓>])[\x23=>\-.\s▏▎▍▌▋▊▉█━─░▒▓]{10,}[\])|]?\s*\d{1,3}(\.\d+)?\s?%   # [=====>    ] 45%
        | ^\s*\d{1,3}(\.\d+)?\s?%\s*[\[(|]\s*[\x23=█━▉▊▋▌▍▎▏░▒▓>][\x23=>\-.\s▏▎▍▌▋▊▉█━─░▒▓]{9,}[\])|]   # 45% [=====>   ]
        | ^\s*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⣾⣽⣻⢿⡿⣟⣯⣷]\s+\S                                             # spinner lines
        """#)

        static let numbers = re(#"0x[0-9a-fA-F]+|[0-9a-fA-F]{8,}|\d+"#)
    }
}
