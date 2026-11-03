import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-78): the review's git status and diff — and the other
/// status/diff probes Bromure runs itself (the file pane, the session list,
/// the changes probe) — ran programs the repository's own config names:
/// `core.fsmonitor` on a status, `diff.external` / a textconv on a diff.
@Suite("Bromure's own git runs no program the repository names")
struct RepoGitProgramsTests {
    private func sh(_ c: String, home: String? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", c]
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@t"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@t"
        if let home { env["HOME"] = home }
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try? p.run()
        // Read before waiting: an output past the pipe's buffer would block
        // the command, and the wait, for good.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("the review, the session list and the changes probe run no fsmonitor, diff program or filter")
    @MainActor func noRepoPrograms() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgp-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/.bromure/worktrees/repo/x"   // where the session list looks
        let marker = home + "/PWNED", pwn = home + "/pwn.sh"
        _ = sh("set -e; mkdir -p \(root); printf '#!/bin/sh\\ntouch \(marker)\\ncat\\n' > \(pwn); chmod +x \(pwn); "
               + "cd \(root); git init -q -b main; echo a > a; git add a; git commit -qm a; echo b >> a; "
               + "echo '* diff=evil filter=evil' > .git/info/attributes; "
               + "git config core.fsmonitor \(pwn); git config diff.external \(pwn); "
               + "git config diff.evil.textconv \(pwn); git config diff.evil.command \(pwn); "
               + "git config filter.evil.clean \(pwn); git config filter.evil.smudge \(pwn)")
        // The setup is live: plain git runs it.
        _ = sh("cd \(root) && git status --porcelain >/dev/null; true")
        #expect(FileManager.default.fileExists(atPath: marker))
        try FileManager.default.removeItem(atPath: marker)

        let review = sh(TaskReviewData.sessionCommand(dir: root, base: .uncommitted))
        #expect(review.contains("===STATUS===") && review.contains("+b"))
        _ = sh(TaskReviewSummary.command(root: root, worktreeDir: root, branch: "main", target: "main"))
        _ = sh(AgentSessionEngine.changesProbeCommand([(key: "k", path: root, since: Date())]))
        let roster = sh(WorktreeEntry.guestCommand, home: home)
        #expect(roster.contains(root))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// Finding (CWE-754): a local filter key was blanked, which hid the
    /// user's global driver of the same name (`git lfs install --local`) and
    /// failed a `required` filter — `git status` exited 128 with no output,
    /// which read as a clean tree, and the worktree was discarded as empty.
    @Test("a local required filter: the global one is kept, or cat; a failing status is never clean")
    func requiredFilterKeepsStatus() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgf-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/repo", marker = home + "/PWNED", globalRan = home + "/GLOBAL"
        let pwn = home + "/pwn.sh", global = home + "/global.sh", gcfg = home + "/gitconfig"
        _ = sh("set -e; mkdir -p \(root); "
               + "printf '#!/bin/sh\\ntouch \(marker)\\ncat\\n' > \(pwn); "
               + "printf '#!/bin/sh\\ntouch \(globalRan)\\ncat\\n' > \(global); chmod +x \(pwn) \(global); "
               + "cd \(root); git init -q -b main; echo '*.bin filter=x' > .gitattributes; echo a > a.bin; "
               + "echo p > plain.txt; git add .; git commit -qm a; "
               + "git config filter.x.clean \(pwn); git config filter.x.smudge \(pwn); git config filter.x.required true; "
               // Same size: git has to read (clean) a.bin to tell.
               + "echo c > a.bin; echo q >> plain.txt")
        // No global driver: the local one is cat, the status still reads.
        let bare = sh(TaskLitter.status("'\(root)'"))
        #expect(bare.contains(" M plain.txt") && bare.contains(" M a.bin"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        // A global driver of the same name: that one runs, never the local one.
        _ = sh("printf '[filter \"x\"]\\n\\tclean = \(global)\\n\\tsmudge = \(global)\\n' > \(gcfg)")
        let withGlobal = sh("export GIT_CONFIG_GLOBAL=\(gcfg); " + TaskLitter.status("'\(root)'"))
        #expect(withGlobal.contains(" M plain.txt"))
        #expect(FileManager.default.fileExists(atPath: globalRan))
        #expect(!FileManager.default.fileExists(atPath: marker))
        // A status that fails is not a clean tree, so the worktree isn't "empty".
        _ = sh("echo garbage > \(root)/.git/index")
        #expect(!sh(TaskLitter.status("'\(root)'")).isEmpty)
        #expect(!sh(CodingTaskEngine.emptyBranchCommand(root: root, branch: "main", parent: "main",
                                                         worktreeDir: root)).contains("EMPTY"))
        // A folder that's gone still reads as clean.
        #expect(sh(TaskLitter.status("'\(home)/nope'")).isEmpty)
    }

    /// Finding (CWE-78): git prints a config value's newline as is, and the
    /// user-value read was line-based — a local value "legit\nglobal\t<cmd>"
    /// read as the user's global driver, and `off` pinned the repository's
    /// command: git add ran it.
    @Test("a repository value holding a fake global line is never taken for the user's driver")
    func newlineSpoofIgnored() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgn-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/repo", marker = home + "/PWNED", gcfg = home + "/gitconfig"
        let global = home + "/global.sh", seen = home + "/GLOBAL-RAN"
        let iso = "export GIT_CONFIG_GLOBAL=\(gcfg) GIT_CONFIG_NOSYSTEM=1; "
        _ = sh("set -e; mkdir -p \(root); : > \(gcfg); printf '#!/bin/sh\\ntouch \(seen)\\ncat\\n' > \(global); chmod +x \(global); "
               + iso + "cd \(root); git init -q -b main; echo '*.txt filter=only' > .gitattributes; "
               + "git add .gitattributes; git commit -qm a; echo x > a.txt; "
               + "git config filter.only.clean \"$(printf 'legit\\nglobal\\ttouch \(marker); cat')\"")
        // The setup is live: the stored value does hold the fake line.
        #expect(sh(iso + "git -C '\(root)' config -z --show-scope --get-all filter.only.clean | tr '\\0' '|'")
                .contains("global\ttouch"))
        func add() -> String {
            sh(iso + RepoGitPrograms.off("'\(root)'")
               + "git -C '\(root)' add a.txt >/dev/null 2>&1 && echo ADDED || echo REFUSED; git -C '\(root)' status --porcelain >/dev/null 2>&1")
        }
        // No user driver: the repository's command never runs.
        _ = add()
        #expect(!FileManager.default.fileExists(atPath: marker))
        // A real global driver: that one is pinned, not the spoofed line.
        _ = sh("git -C '\(root)' reset -q; printf '[filter \"only\"]\\n\\tclean = \(global)\\n' > \(gcfg)")
        #expect(add().contains("ADDED"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(FileManager.default.fileExists(atPath: seen))
    }

    /// Finding (CWE-754): `git lfs install --local` also sets a `process`
    /// filter; switched off it was blank, and a blank process filter that is
    /// `required` failed every status — a clean checkout read as dirty.
    @Test("a local required process filter with no global driver: a clean tree reads clean")
    func requiredProcessFilterKeepsCleanTree() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgp-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/repo", marker = home + "/PWNED", pwn = home + "/pwn.sh"
        let iso = "export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1; "
        _ = sh(iso + "set -e; mkdir -p \(root); printf '#!/bin/sh\\ntouch \(marker)\\ncat\\n' > \(pwn); chmod +x \(pwn); "
               + "cd \(root); git init -q -b main; echo '*.bin filter=lfs' > .gitattributes; echo a > a.bin; "
               + "git add .; git commit -qm a; "
               + "for k in clean smudge process; do git config filter.lfs.$k \(pwn); done; "
               + "git config filter.lfs.required true; touch a.bin")
        #expect(sh(iso + TaskLitter.status("'\(root)'")) == "")
        #expect(sh(iso + CodingTaskEngine.emptyBranchCommand(root: root, branch: "main", parent: "main",
                                                               worktreeDir: root)).contains("EMPTY"))
        // An edit still shows, and the repository's program never ran.
        _ = sh("echo b > \(root)/a.bin")
        #expect(sh(iso + TaskLitter.status("'\(root)'")).contains(" M a.bin"))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// Finding (CWE-754): with a GLOBAL clean/smudge driver for the filter,
    /// the blank local `process` shadowed it, and `required=false` hid the
    /// failure — `git add` stored raw bytes and reported success. Now the
    /// required filter fails loudly; the repository's program never runs.
    @Test("a blank process over a global clean/smudge driver fails a required filter, never passes raw bytes")
    func blankProcessOverGlobalDriverFails() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgq-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/repo", marker = home + "/PWNED", pwn = home + "/pwn.sh"
        let global = home + "/global.sh", gcfg = home + "/gitconfig"
        let iso = "export GIT_CONFIG_GLOBAL=\(gcfg) GIT_CONFIG_NOSYSTEM=1; "
        _ = sh("set -e; mkdir -p \(root); printf '#!/bin/sh\\ntouch \(marker)\\ncat\\n' > \(pwn); "
               + "printf '#!/bin/sh\\nprintf FILTERED; cat\\n' > \(global); chmod +x \(pwn) \(global); "
               + "printf '[filter \"lfs\"]\\n\\tclean = \(global)\\n\\tsmudge = \(global)\\n\\trequired = true\\n' > \(gcfg); "
               + iso + "cd \(root); git init -q -b main; echo '*.bin filter=lfs' > .gitattributes; "
               + "git add .gitattributes; git commit -qm a; "
               + "for k in clean smudge process; do git config filter.lfs.$k \(pwn); done; "
               + "git config filter.lfs.required true; echo raw > b.bin")
        let add = sh(iso + RepoGitPrograms.off("'\(root)'")
                     + "git -C '\(root)' add b.bin >/dev/null 2>&1 && echo ADDED || echo REFUSED")
        #expect(add.contains("REFUSED"))
        #expect(sh(iso + "git -C '\(root)' ls-files b.bin").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker))
        // Review: a user driver git reads through an include, or an
        // includeIf gitdir: matching this repository, counts the same.
        let inc = home + "/included"
        _ = sh("mv \(gcfg) \(inc); printf '[include]\\n\\tpath = \(inc)\\n' > \(gcfg)")
        let viaInclude = sh(iso + RepoGitPrograms.off("'\(root)'")
                            + "git -C '\(root)' add b.bin >/dev/null 2>&1 && echo ADDED || echo REFUSED")
        #expect(viaInclude.contains("REFUSED"))
        // gitdir: matches the resolved path (/var is /private/var here;
        // Foundation's resolvingSymlinksInPath turns it back into /var).
        _ = sh("git -C '\(root)' reset -q; printf '[includeIf \"gitdir:%s/\"]\\n\\tpath = \(inc)\\n' "
               + "\"$(cd '\(root)' && pwd -P)\" > \(gcfg)")
        let viaIncludeIf = sh(iso + RepoGitPrograms.off("'\(root)'")
                              + "git -C '\(root)' add b.bin >/dev/null 2>&1 && echo ADDED || echo REFUSED")
        #expect(viaIncludeIf.contains("REFUSED"))
        // Finding (CWE-754): the repository says its filter isn't required,
        // or nobody says either way (false by default): still refused —
        // the blank process shadows the user's driver whatever it says.
        _ = sh("git -C '\(root)' reset -q; mv \(inc) \(gcfg); git -C '\(root)' config filter.lfs.required false")
        let localNotRequired = sh(iso + RepoGitPrograms.off("'\(root)'")
                                  + "git -C '\(root)' add b.bin >/dev/null 2>&1 && echo ADDED || echo REFUSED")
        #expect(localNotRequired.contains("REFUSED"))
        _ = sh("git -C '\(root)' config --unset filter.lfs.required; "
               + "printf '[filter \"lfs\"]\\n\\tclean = \(global)\\n\\tsmudge = \(global)\\n' > \(gcfg)")
        let nobodyRequired = sh(iso + RepoGitPrograms.off("'\(root)'")
                                + "git -C '\(root)' add b.bin >/dev/null 2>&1 && echo ADDED || echo REFUSED")
        #expect(nobodyRequired.contains("REFUSED"))
        #expect(sh(iso + "git -C '\(root)' ls-files b.bin").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker))
        _ = sh("git -C '\(root)' config filter.lfs.required true")
        // Only a global smudge, under `set -e` (dash): still a user driver.
        _ = sh("git -C '\(root)' reset -q; printf '[filter \"lfs\"]\\n\\tsmudge = \(global)\\n\\trequired = true\\n' > \(gcfg)")
        let smudgeOnly = sh("set -e; " + iso + RepoGitPrograms.off("'\(root)'")
                            + "git -C '\(root)' add b.bin >/dev/null 2>&1 && echo ADDED || echo REFUSED")
        #expect(smudgeOnly.contains("REFUSED"))
        #expect(sh(iso + "git -C '\(root)' ls-files b.bin").isEmpty)
        // With no user driver at all, the blank process still passes through.
        _ = sh("printf '' > \(gcfg)")
        let passthrough = sh(iso + RepoGitPrograms.off("'\(root)'")
                             + "git -C '\(root)' add b.bin >/dev/null 2>&1 && echo ADDED || echo REFUSED")
        #expect(passthrough.contains("ADDED"))
        // …and under `set -e` (dash) too: no driver isn't a failure.
        _ = sh("git -C '\(root)' reset -q")
        let strict = sh("set -e; " + iso + RepoGitPrograms.off("'\(root)'")
                        + "git -C '\(root)' add b.bin >/dev/null 2>&1 && echo ADDED || echo REFUSED")
        #expect(strict.contains("ADDED"))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// Finding: `--ignore-submodules=dirty` hid an edited submodule — the
    /// session list said "no changes yet", Discard said nothing would be
    /// lost, and removing the worktree deleted that work.
    @Test("an edited submodule reads as a change, and its own programs still don't run")
    @MainActor func dirtySubmoduleCounts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgs-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/.bromure/worktrees/repo/x"
        let marker = home + "/PWNED", pwn = home + "/pwn.sh"
        _ = sh("set -e; mkdir -p \(home)/sub \(root); printf '#!/bin/sh\\ntouch \(marker)\\ncat\\n' > \(pwn); chmod +x \(pwn); "
               + "cd \(home)/sub; git init -q -b main; echo one > f; git add f; git commit -qm one; "
               + "cd \(root); git init -q -b main; echo a > a; git add a; git commit -qm a; "
               + "git -c protocol.file.allow=always submodule -q add \(home)/sub sub; git commit -qm sub")
        // Clean so far.
        func count() -> String {
            sh(WorktreeEntry.guestCommand, home: home).split(separator: "\t").dropFirst(5).first.map(String.init) ?? "?"
        }
        #expect(count() == "0")
        // Edit a tracked file in the submodule, with a clean filter there.
        _ = sh("cd \(root)/sub; echo secret-edit >> f; echo '* filter=evil' > \"$(git rev-parse --git-dir)/info/attributes\"; "
               + "git config filter.evil.clean \(pwn)")
        #expect(count() == "1")
        #expect(sh(TaskLitter.status("'\(root)'")).contains(" M sub"))
        #expect(sh(AgentSessionEngine.changesProbeCommand([(key: "k", path: root, since: Date())])).contains("k\t1"))
        #expect(sh(BranchMergeCommands.mergeScript(root: root, branch: "wt/none", into: "main", sourceDir: root,
                                                   squash: false)).contains("dirty"))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// Finding (CWE-754): a submodule whose own `git status` fails (here a
    /// truncated index, as a crash mid-write leaves it) printed nothing, so
    /// the checkout read as clean and empty — and Mark done removed it.
    @Test("a submodule whose status fails reads as a change")
    @MainActor func failedSubmoduleStatusCounts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgf-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/.bromure/worktrees/repo/x"
        _ = sh("set -e; mkdir -p \(home)/sub \(root); "
               + "cd \(home)/sub; git init -q -b main; echo one > f; git add f; git commit -qm one; "
               + "cd \(root); git init -q -b main; echo a > a; git add a; git commit -qm a; "
               + "git -c protocol.file.allow=always submodule -q add \(home)/sub sub; git commit -qm sub")
        #expect(!sh(TaskLitter.status("'\(root)'")).contains("sub"))
        // A tracked edit, then the submodule's index cut short.
        _ = sh("cd \(root)/sub; echo SECRET >> f; i=\"$(git rev-parse --git-dir)/index\"; "
               + "head -c 20 \"$i\" > \"$i.t\"; mv \"$i.t\" \"$i\"")
        #expect(sh("cd \(root)/sub && git status --porcelain >/dev/null 2>&1 || echo failed").contains("failed"))
        #expect(sh(TaskLitter.status("'\(root)'")).contains(" M sub"))
        #expect(sh(AgentSessionEngine.changesProbeCommand([(key: "k", path: root, since: Date())])).contains("k\t1"))
        #expect(sh(BranchMergeCommands.mergeScript(root: root, branch: "wt/none", into: "main", sourceDir: root,
                                                   squash: false)).contains("dirty"))
    }

    /// Finding (CWE-116): `core.quotePath=false` still C-quotes a path
    /// holding `"`, `\\`, a tab or a newline, and the quoted text was looked
    /// for on disk — an edit in such a submodule read as no change at all.
    @Test("an edited submodule whose path git quotes still reads as a change")
    @MainActor func quotedSubmodulePath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgq-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/.bromure/worktrees/repo/x"
        _ = sh("set -e; mkdir -p \(home)/sub \(root); "
               + "cd \(home)/sub; git init -q -b main; echo one > f; git add f; git commit -qm one; "
               + "cd \(root); git init -q -b main; echo a > a; git add a; git commit -qm a")
        let names = ["quote\"name", "back\\slash", "new\nline", "tab\tbed", "$(touch PWN)"]
        for (i, name) in names.enumerated() {
            let q = BranchMergeCommands.q(name)
            _ = sh("set -e; cd \(root); git clone -q \(home)/sub \(q); "
                   + "git update-index --add --cacheinfo 160000,$(git -C \(q) rev-parse HEAD),\(q); git commit -qm s\(i)")
        }
        #expect(sh(TaskLitter.status("'\(root)'")).isEmpty)
        for name in names {
            let q = BranchMergeCommands.q(name)
            _ = sh("cd \(root)/\(q) && echo SECRET-EDIT >> f")
            let out = sh(TaskLitter.status("'\(root)'"))
            #expect(out.hasPrefix(" M "), "\(name)")
            #expect(sh("cd \(root); " + RepoGitPrograms.dirtySubmodules(".", nul: true)) == " M \(name)\0", "\(name)")
            _ = sh("cd \(root)/\(q) && git checkout -q f")
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/PWN"))
    }

    /// Finding (CWE-754): a diff that failed partway (a blob git can't
    /// read) said so in the pane, but the files it wrote before stopping
    /// stayed listed — counted, markable as viewed, and copied by Copy Diff
    /// as if they were the change set, the unreadable file missing.
    @Test("a diff that fails partway keeps none of the files it wrote first")
    func failedDiffKeepsNoFiles() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("rgp-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: repo) }
        _ = sh("set -e; mkdir -p \(repo); cd \(repo); git init -q -b main; "
               + "for i in $(seq -w 1 15); do echo v1 > f$i.txt; done; git add .; git commit -qm a; "
               + "for i in $(seq -w 1 15); do echo v2 > f$i.txt; done; git add .; git commit -qm b")
        let command = TaskReviewData.sessionCommand(dir: repo, base: .lastCommit)
        #expect(TaskReviewData.parse(sh(command)).files.count == 15)
        let blob = sh("cd \(repo) && git rev-parse HEAD:f15.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = sh("rm -f \(repo)/.git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))")
        let failed = TaskReviewData.parse(sh(command))
        #expect(failed.diffFailed)
        #expect(failed.files.isEmpty)                    // nothing to list, mark viewed or copy
    }

    /// Finding (CWE-754): the review's diff is capped at 600 KB, and its
    /// failure marker came after the diff: a diff that failed past the cap
    /// (an unreadable blob, after 1.3 MB of output) lost the marker, and its
    /// first 600 KB read as the whole change set.
    @Test("a diff that fails past the 600 KB cap still says so; a big clean one doesn't")
    func failedDiffPastTheCap() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("rgd-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: repo) }
        // 30 files, ~45 KB of diff each: about 1.3 MB in all.
        _ = sh("set -e; mkdir -p \(repo); cd \(repo); git init -q -b main; "
               + "for i in $(seq -w 1 30); do seq 1 6000 | sed \"s/^/v1 $i line /\" > f$i.txt; done; "
               + "git add .; git -c user.name=t -c user.email=t@t commit -qm a; "
               + "for i in $(seq -w 1 30); do sed -i.bak 's/^v1/v2/' f$i.txt; rm f$i.txt.bak; done; "
               + "git add .; git -c user.name=t -c user.email=t@t commit -qm b")
        let command = TaskReviewData.sessionCommand(dir: repo, base: .lastCommit)
        let big = TaskReviewData.parse(sh(command))
        #expect(!big.diffFailed && !big.files.isEmpty)   // large, not failed
        // The last file's new blob is gone: git fails after writing the rest.
        let blob = sh("cd \(repo) && git rev-parse HEAD:f30.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = sh("rm -f \(repo)/.git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))")
        let failed = TaskReviewData.parse(sh(command))
        #expect(failed.diffFailed)
        #expect(failed.files.isEmpty)                    // the part before the failure isn't the change set
    }

    /// Finding (CWE-754): a failed status with a dirty submodule listed
    /// after it took the "unknown" arm and verified the landing — the
    /// submodule edit, uncommitted and not in the target, read as merged.
    @Test("a failed status that also lists work keeps the landing pending")
    func failedStatusWithDirtySubmoduleIsPending() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgs-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/repo", wt = home + "/wt", subsrc = home + "/subsrc", gcfg = home + "/gitconfig"
        let iso = "export GIT_CONFIG_GLOBAL=\(gcfg) GIT_CONFIG_NOSYSTEM=1; "
        let filter = home + "/f.sh", pwn = home + "/pwn.sh"
        _ = sh("set -e; mkdir -p \(root) \(subsrc); printf '#!/bin/sh\\ncat\\n' > \(filter); "
               + "printf '#!/bin/sh\\ncat\\n' > \(pwn); chmod +x \(filter) \(pwn); "
               + "printf '[filter \"lfs\"]\\n\\tclean = \(filter)\\n\\tsmudge = \(filter)\\n[protocol \"file\"]\\n\\tallow = always\\n' > \(gcfg); "
               + iso + "cd \(subsrc); git init -q -b main; echo s > s.txt; git add .; git commit -qm s; "
               + "cd \(root); git init -q -b main; echo '*.bin filter=lfs' > .gitattributes; "
               + "echo b > x.bin; echo a > plain.txt; git add .; git commit -qm a; "
               + "git worktree add -q -b wt/t \(wt); cd \(wt); git submodule add -q \(subsrc) sub; git commit -qm sub; "
               + "git config filter.lfs.process \(pwn); git config filter.lfs.required false")
        _ = sh(iso + "git -C '\(root)' update-ref refs/heads/main wt/t")   // the branch is in the target
        _ = sh("touch -t 202001010000 \(wt)/x.bin; echo edit >> \(wt)/sub/s.txt")
        let status = sh(iso + TaskLitter.status("'\(wt)'"))
        #expect(status.contains(RepoGitPrograms.statusFailedLine) && status.contains("sub"))
        let out = sh(iso + CodingTaskEngine.landingVerifyCommand(root: root, branch: "wt/t", target: "main", sourceDir: wt))
        #expect(LandingVerification.parse(out) == .pending)
        // The submodule clean again: in the target, the checkout unreadable.
        _ = sh("cd \(wt)/sub && git checkout -q s.txt")
        let clean = sh(iso + CodingTaskEngine.landingVerifyCommand(root: root, branch: "wt/t", target: "main", sourceDir: wt))
        #expect(LandingVerification.parse(clean) == .checkoutUnreadable)
    }

    /// Review: the look ran on every watcher poll — an old answer put a
    /// retried landing (checking, or handed to the agent) back on Needs you.
    @Test("an unreadable checkout flags only the landing it looked at, once, and never over a question")
    func unreadableFlagsOnlyItsLanding() {
        typealias E = CodingTaskEngine
        let looked = TaskLanding(mode: .merge, target: "main", phase: .agentLanding, startedAt: Date())
        #expect(E.unreadableEffects(observed: looked, now: looked) == (true, true))
        var flagged = looked
        flagged.phase = .needsYou
        flagged.detail = E.statusFailedText
        flagged.keepBranch = true
        #expect(E.unreadableEffects(observed: flagged, now: flagged) == (false, false))   // already said
        var asked = looked
        asked.phase = .needsYou
        asked.detail = "Which branch should this go into?"                               // the agent asks
        #expect(E.unreadableEffects(observed: asked, now: asked) == (true, false))        // kept, not replaced
        let retried = TaskLanding(mode: .merge, target: "main", phase: .checking,
                                  startedAt: looked.startedAt.addingTimeInterval(30))
        #expect(E.unreadableEffects(observed: flagged, now: retried) == (false, false))   // a Retry since
        #expect(E.unreadableEffects(observed: looked, now: asked) == (true, false))       // moved meanwhile
        #expect(E.unreadableEffects(observed: looked, now: nil) == (false, false))
    }

    /// Finding (CWE-754): the required blank process (above) makes `git
    /// status` fatal once a path it filters is stat-dirty. The failure line
    /// read as uncommitted work: Land handed a clean checkout to the agent's
    /// own git, its verify stayed PENDING until "Landing stalled", and the
    /// file pane and the review showed no changes at all.
    @Test("a status that fails under the required blank process is told apart from a dirty checkout")
    func failedStatusIsNotDirty() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgf-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/repo", wt = home + "/wt", marker = home + "/PWNED", pwn = home + "/pwn.sh"
        let global = home + "/global.sh", gcfg = home + "/gitconfig"
        let iso = "export GIT_CONFIG_GLOBAL=\(gcfg) GIT_CONFIG_NOSYSTEM=1; "
        _ = sh("set -e; mkdir -p \(root); printf '#!/bin/sh\\ntouch \(marker)\\ncat\\n' > \(pwn); "
               + "printf '#!/bin/sh\\ncat\\n' > \(global); chmod +x \(pwn) \(global); "
               + "printf '[filter \"lfs\"]\\n\\tclean = \(global)\\n\\tsmudge = \(global)\\n' > \(gcfg); "
               + iso + "cd \(root); git init -q -b main; echo '*.bin filter=lfs' > .gitattributes; "
               + "echo b > x.bin; echo a > plain.txt; git add .; git commit -qm a; "
               + "git worktree add -q -b wt/t \(wt); cd \(wt); echo more >> plain.txt; git commit -qam t; "
               + "git config filter.lfs.process \(pwn); git config filter.lfs.required false")
        let check = { CodingTaskEngine.parseLandingCheck(self.sh(iso + CodingTaskEngine.landingCheckCommand(
            root: root, branch: "wt/t", target: "main", sourceDir: wt, mode: .merge))) }
        let verify = { self.sh(iso + CodingTaskEngine.landingVerifyCommand(
            root: root, branch: "wt/t", target: "main", sourceDir: wt)) }
        // The filtered file is stat-dirty (untouched content): status fails.
        _ = sh("touch -t 202001010000 \(wt)/x.bin")
        #expect(sh(iso + TaskLitter.status("'\(wt)'")).contains(RepoGitPrograms.statusFailedLine))
        #expect(check() == .statusFailed)
        // Finding (CWE-754): that status no longer skips the merge check —
        // not in the target: pending (the agent's "merged" isn't taken);
        // in it: never verified — the checkout may hold work the target
        // doesn't (the user looks; the branch is kept).
        #expect(LandingVerification.parse(verify()) == .pending)
        let mainWas = sh(iso + "git -C '\(root)' rev-parse main").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = sh(iso + "git -C '\(root)' update-ref refs/heads/main wt/t")
        let landedOut = verify()
        #expect(LandingVerification.parse(landedOut) == .checkoutUnreadable)
        #expect(LandingReportOutcome.decide(status: "merged", summary: "", prURL: nil,
                                            verification: .checkoutUnreadable) == .checkoutUnreadable)
        _ = sh(iso + "git -C '\(root)' update-ref refs/heads/main \(mainWas)")
        #expect(sh(iso + "git -C '\(root)' rev-parse main") != sh(iso + "git -C '\(root)' rev-parse wt/t"))
        // The review and the file pane say so — not "no changes".
        let review = TaskReviewData.parse(sh(iso + TaskReviewData.sessionCommand(dir: wt, base: .uncommitted)))
        #expect(review.statusFailed)
        // Finding (CWE-754): with an edit and an untracked file too, the
        // failed diff still listed the untracked file alone — a normal-
        // looking review of a change set that isn't the checkout.
        _ = sh("echo edit >> \(wt)/plain.txt; echo new > \(wt)/untracked.txt")
        let partial = TaskReviewData.parse(sh(iso + TaskReviewData.sessionCommand(dir: wt, base: .uncommitted)))
        #expect(partial.diffFailed && partial.files.isEmpty)
        _ = sh("rm \(wt)/untracked.txt; cd \(wt) && git checkout -q plain.txt")
        // Review: a diff that fails for a missing revision isn't that. No
        // commits yet: the staged and untracked files show, no failure; the
        // root commit's "last commit" is its whole content.
        let fresh = home + "/fresh"
        _ = sh("mkdir -p \(fresh) && cd \(fresh) && git init -q && echo a > staged.txt && git add staged.txt && echo u > untracked.txt")
        let unborn = TaskReviewData.parse(sh(iso + TaskReviewData.sessionCommand(dir: fresh, base: .uncommitted)))
        #expect(!unborn.diffFailed && Set(unborn.files.map(\.path)) == ["staged.txt", "untracked.txt"])
        _ = sh(iso + "cd \(fresh) && git commit -qm root")
        let rootCommit = TaskReviewData.parse(sh(iso + TaskReviewData.sessionCommand(dir: fresh, base: .lastCommit)))
        #expect(!rootCommit.diffFailed && rootCommit.files.map(\.path) == ["staged.txt"])
        #expect(FileExplorerModel.statusFailed(in: [(toplevel: wt, porcelain: RepoGitPrograms.statusFailedLine + "\0")]))
        #expect(!FileExplorerModel.statusFailed(in: [(toplevel: wt, porcelain: " M a.txt\0")]))
        // A real edit, status readable again: dirty, the agent commits it.
        _ = sh(iso + "cd \(wt) && git -c filter.lfs.process= update-index -q --refresh; echo edit >> plain.txt")
        #expect(check() == .dirtySource)
        #expect(LandingVerification.parse(verify()) == .pending)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// Finding: the same hidden submodule edit passed the checks that gate
    /// `git worktree remove --force` — the landing's dirty-source check
    /// (a merged branch's worktree is removed) and Mark done's empty branch.
    @Test("a task worktree with an edited submodule is neither landed clean nor empty")
    func dirtySubmoduleBlocksRemoval() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rgw-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/repo", wt = home + "/wt"
        _ = sh("set -e; mkdir -p \(home)/sub \(root); "
               + "cd \(home)/sub; git init -q -b main; echo one > f; git add f; git commit -qm one; "
               + "cd \(root); git init -q -b main; echo a > a; git add a; git commit -qm a; "
               + "git -c protocol.file.allow=always submodule -q add \(home)/sub sub; git commit -qm sub; "
               + "git worktree add -q -b wt/t \(wt); cd \(wt); git -c protocol.file.allow=always submodule -q update --init")
        let check = { CodingTaskEngine.parseLandingCheck(self.sh(CodingTaskEngine.landingCheckCommand(
            root: root, branch: "wt/t", target: "main", sourceDir: wt, mode: .merge))) }
        let empty = { self.sh(CodingTaskEngine.emptyBranchCommand(root: root, branch: "wt/t", parent: "main",
                                                                  worktreeDir: wt)) }
        // Nothing done: already merged, and empty.
        #expect(check() == .merged)
        #expect(empty().contains("EMPTY"))
        // An uncommitted edit inside the submodule: the agent must commit it.
        _ = sh("echo secret-edit >> \(wt)/sub/f")
        #expect(check() == .dirtySource)
        #expect(!empty().contains("EMPTY"))
    }
}
