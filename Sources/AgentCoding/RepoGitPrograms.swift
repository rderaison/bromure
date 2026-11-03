import Foundation

/// The git Bromure runs ITSELF in a task's or a session's repository — a
/// dirty check, a fast-forward, the review's diff, a branch session's merge
/// — runs none of the programs that repository's own config names. The
/// repository is the agent's work, a copied worktree, or a zip with its
/// `.git`: its config is data. (An agent's own git, in its sandbox, is its
/// business.)
///
/// Pinned: hooks (`core.hooksPath`) and `core.fsmonitor`. Switched off:
/// every clean/smudge/process filter and merge driver, and `gpg` program,
/// set in the LOCAL or WORKTREE config (includes count as local) — `git
/// status` runs a clean filter, a checkout or merge a smudge one, on
/// attributes `.git/info/attributes` or an incoming `.gitattributes` can
/// name. The user's own (global, system) drivers — git-lfs — still apply,
/// even where the local config sets the same key (`git lfs install
/// --local`): such a key is pinned to the global/system value. With none, a
/// filter's clean/smudge becomes `cat` — never blank, which fails a
/// `filter.<x>.required` filter and with it `git status` and the merge —
/// and a blank `process` (there is no no-op one) makes the filter not
/// required (`git lfs install --local` sets `required`) — unless the user
/// has a global/system clean or smudge for it, which the blank process
/// shadows: then the filter is made required, so it fails rather than pass
/// raw bytes (whatever the repository's own `required` says).
/// A diff runs its programs only with `--no-ext-diff --no-textconv` off.
enum RepoGitPrograms {
    /// The config keys whose value is a program git runs on its own.
    static let programKeys = #"^(filter\..*\.(clean|smudge|process)|merge\..*\.driver|gpg\.([^.]*\.)?program)$"#

    /// Shell that sets this shell's git environment (GIT_CONFIG_COUNT/KEY/
    /// VALUE) for every git after it: what `dir` (already shell-quoted, or
    /// a "$var") configures locally switched off. Names reach git through
    /// the environment, never the command line, so no name is read as an
    /// option or split by the shell.
    /// ONE checkout: what the user's config gives a key can differ between
    /// checkouts of one repository (includeIf onbranch:/gitdir:), so the
    /// git commands after it must run in that checkout — another one gets
    /// its own `off`, in a subshell.
    static func off(_ dir: String) -> String {
        let read = "git -C \(dir) config --show-scope --name-only --get-regexp '\(programKeys)'"
        // `_bg key`: the user's own (global or system) value of `key`, as
        // git reads it IN the repository — includes, the XDG file and
        // `includeIf gitdir:` all count, which `cd / && git config --global
        // --get` missed (an included driver read as none). Local, worktree
        // and command-line (a previous `off`) values never count. Fails
        // when there is none. Read NUL-separated (`scope\0value\0`): git
        // prints a value's newline as is, so a local value holding
        // "\nglobal\t<command>" read as one more line passed for the user's
        // own driver — and git ran the repository's command. A value's
        // newlines become \001 for awk (which pairs scope and value lines)
        // and are restored in the value printed. Bytes, not characters
        // (LC_ALL=C): a non-UTF-8 byte in a repository value doesn't stop
        // BSD tr, and the user's own value comes back byte for byte.
        let userValue = "_bg() { git -C \(dir) config -z --show-scope --get-all \"$1\" 2>/dev/null "
            + #"| LC_ALL=C tr '\n\000' '\001\n' | LC_ALL=C awk 'NR % 2 == 1 { s = $0; next } s == "global" || s == "system" { v = $0; f = 1 } END { if (f) { gsub(/\001/, "\n", v); print v }; exit !f }'; }; "#
        return userValue + "_bk=$( { \(read); } 2>/dev/null "
            + #"| awk '{ s = $0; sub(/\t.*/, "", s); if (s == "local" || s == "worktree") { sub(/^[^\t]*\t/, ""); print } }'); "#
            + "export GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null "
            + "GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false; _bn=2; "
            + "set -f; _bo=$IFS; IFS=$(printf '\\n_'); IFS=${IFS%_}; "
            + "for _bx in $_bk; do "
            + #"_bv=$(_bg "$_bx") "#
            + "|| case \"$_bx\" in (filter.*.clean|filter.*.smudge) _bv=cat ;; "
            // A blank process filter fails to start. With no user driver
            // at all for that filter: not required, the content passes
            // through unchanged, as `cat` would. With a global/system clean
            // or smudge, the blank process still shadows it (git can't unset
            // a key from the environment): required, set here — leaving it
            // to the merged config let the repository's own `required=false`
            // (or nobody's, false by default) store and write raw bytes.
            + "(filter.*.process) _bv=; _bd=${_bx%.process}; _br=false; "
            + #"if [ -n "$( { _bg "$_bd.clean" || :; _bg "$_bd.smudge" || :; } )" ]; then _br=true; fi; "#
            + "export \"GIT_CONFIG_KEY_$_bn=$_bd.required\" \"GIT_CONFIG_VALUE_$_bn=$_br\"; _bn=$((_bn + 1)) ;; "
            + "(*) _bv= ;; esac; "
            + "export \"GIT_CONFIG_KEY_$_bn=$_bx\" \"GIT_CONFIG_VALUE_$_bn=$_bv\"; _bn=$((_bn + 1)); done; "
            + "IFS=$_bo; set +f; export GIT_CONFIG_COUNT=$_bn; "
    }

    /// Appended to a `git status --porcelain` Bromure reads as "dirty or
    /// clean": a status that FAILS prints this line, so a failure is never
    /// the empty output a clean tree gives (which let a worktree holding
    /// edits be discarded as empty).
    static let statusFailed = " || echo '\(statusFailedLine)'"
    static let statusFailedLine = "!! (git status failed)"

    /// Shell: true when `value` (a "$var" holding such a status) holds the
    /// failure line. "Dirty" and "couldn't look" are told apart where it
    /// matters: a status that fails under `off` (a repository filter whose
    /// blank process is required — every stat-dirty path it covers is
    /// fatal) is no reason to hand the work to an agent's own git.
    static func failedStatus(_ value: String) -> String {
        "printf '%s\\n' \(value) | grep -qxF '\(statusFailedLine)'"
    }

    /// Shell printing ` M <path>` (NUL-ended with `nul`, else newline-ended)
    /// for every checked-out submodule under `dir` (already shell-quoted, or
    /// a "$var") with uncommitted work, nested ones included. Bromure's
    /// statuses pass `--ignore-submodules=dirty`, so git never reads a
    /// submodule under the PARENT's switched-off programs — which hid an
    /// edited submodule: the checkout read as clean ("nothing is lost") and
    /// discarding it deleted that work. Each submodule's status runs in the
    /// submodule, under its own `off`; one that fails (a truncated index, an
    /// unknown repository extension) counts as dirty, as `statusFailed` does
    /// for the parent — never the empty output of a clean submodule. Paths
    /// are relative to `dir`; a path git C-quotes is decoded before it is
    /// looked for on disk, and printed quoted (as git's own status does) —
    /// raw with `nul`.
    static func dirtySubmodules(_ dir: String, nul: Bool = false) -> String {
        let end = nul ? "\\0" : "\\n"
        return "_bsl() { git -c core.quotePath=false -C \"$1\" ls-files --stage 2>/dev/null "
            + "| awk -F'\\t' '$1 ~ /^160000 /{print $2}'; }; "
            + "_bsp() { case \"$1\" in (\\\"*) _p=$(printf '%s\\n' \"$1\" | LC_ALL=C awk '\(unquote)'; printf x); _p=${_p%x} ;; (*) _p=$1 ;; esac; }; "
            + "_bsd() { [ -n \"$( ( cd \"$1\" || { echo '!!'; exit; }; \(off("."))git status --porcelain --ignore-submodules=dirty\(statusFailed) ) 2>/dev/null | head -c1)\" ] "
            + "&& return 0; _bsl \"$1\" | { while IFS= read -r _s; do _bsp \"$_s\"; [ -e \"$1/$_p/.git\" ] && _bsd \"$1/$_p\" && exit 0; done; exit 1; }; }; "
            + "_bsl \(dir) | while IFS= read -r _s; do _bsp \"$_s\"; _q=$_p; [ -e \(dir)/\"$_q/.git\" ] && _bsd \(dir)/\"$_q\" "
            + "&& printf ' M %s\(end)' \"\(nul ? "$_q" : "$_s")\"; done; "
    }

    /// awk turning one C-quoted path git printed (`"a\"b\\c\n"`) back into
    /// its bytes: `core.quotePath=false` still quotes a path holding `"`,
    /// `\`, or a control character. (No single quote: it sits in '…'.)
    private static let unquote = #"{ s = substr($0, 2, length($0) - 2); o = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c != "\\") { o = o c; continue }; c = substr(s, ++i, 1); if (c ~ /[0-7]/) { o = o sprintf("%c", c * 64 + substr(s, i + 1, 1) * 8 + substr(s, i + 2, 1)); i += 2 } else if (c == "n") o = o "\n"; else if (c == "t") o = o "\t"; else if (c == "r") o = o "\r"; else if (c == "a") o = o "\007"; else if (c == "b") o = o "\b"; else if (c == "f") o = o "\f"; else if (c == "v") o = o "\v"; else o = o c }; printf "%s", o }"#

    /// The flags a diff Bromure runs itself carries: no external diff, no
    /// textconv program, no recursion into a submodule (its own config).
    static let diffFlags = "--no-ext-diff --no-textconv --ignore-submodules=dirty"
}
