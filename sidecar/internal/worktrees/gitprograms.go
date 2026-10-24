package worktrees

// RepoGitPrograms.swift, word for word: the git Bromure runs ITSELF in a
// session's repository runs none of the programs that repository's own
// config names (hooks, fsmonitor, local filters, merge drivers, gpg).

// ProgramKeys are the config keys whose value is a program git runs.
const ProgramKeys = `^(filter\..*\.(clean|smudge|process)|merge\..*\.driver|gpg\.([^.]*\.)?program)$`

// Off is shell that switches off what `dir` (already shell-quoted, or a
// "$var") configures locally, for every git after it.
func Off(dir string) string {
	read := "git -C " + dir + " config --show-scope --name-only --get-regexp '" + ProgramKeys + "'"
	userValue := "_bg() { git -C " + dir + " config -z --show-scope --get-all \"$1\" 2>/dev/null " +
		`| LC_ALL=C tr '\n\000' '\001\n' | LC_ALL=C awk 'NR % 2 == 1 { s = $0; next } s == "global" || s == "system" { v = $0; f = 1 } END { if (f) { gsub(/\001/, "\n", v); print v }; exit !f }'; }; `
	return userValue + "_bk=$( { " + read + "; } 2>/dev/null " +
		`| awk '{ s = $0; sub(/\t.*/, "", s); if (s == "local" || s == "worktree") { sub(/^[^\t]*\t/, ""); print } }'); ` +
		"export GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null " +
		"GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false; _bn=2; " +
		"set -f; _bo=$IFS; IFS=$(printf '\\n_'); IFS=${IFS%_}; " +
		"for _bx in $_bk; do " +
		`_bv=$(_bg "$_bx") ` +
		"|| case \"$_bx\" in (filter.*.clean|filter.*.smudge) _bv=cat ;; " +
		"(filter.*.process) _bv=; _bd=${_bx%.process}; _br=false; " +
		`if [ -n "$( { _bg "$_bd.clean" || :; _bg "$_bd.smudge" || :; } )" ]; then _br=true; fi; ` +
		"export \"GIT_CONFIG_KEY_$_bn=$_bd.required\" \"GIT_CONFIG_VALUE_$_bn=$_br\"; _bn=$((_bn + 1)) ;; " +
		"(*) _bv= ;; esac; " +
		"export \"GIT_CONFIG_KEY_$_bn=$_bx\" \"GIT_CONFIG_VALUE_$_bn=$_bv\"; _bn=$((_bn + 1)); done; " +
		"IFS=$_bo; set +f; export GIT_CONFIG_COUNT=$_bn; "
}

// StatusFailedLine is printed when a `git status --porcelain` fails, so a
// failure is never the empty output of a clean tree.
const StatusFailedLine = "!! (git status failed)"

// StatusFailed is appended to such a status.
const StatusFailed = " || echo '" + StatusFailedLine + "'"

// FailedStatus is shell: true when value holds the failure line.
func FailedStatus(value string) string {
	return "printf '%s\\n' " + value + " | grep -qxF '" + StatusFailedLine + "'"
}

// DirtySubmodules prints ` M <path>` for every checked-out submodule
// under dir with uncommitted work, nested ones included.
func DirtySubmodules(dir string, nul bool) string {
	end := "\\n"
	pathVar := "$_s"
	if nul {
		end = "\\0"
		pathVar = "$_q"
	}
	return "_bsl() { git -c core.quotePath=false -C \"$1\" ls-files --stage 2>/dev/null " +
		"| awk -F'\\t' '$1 ~ /^160000 /{print $2}'; }; " +
		"_bsp() { case \"$1\" in (\\\"*) _p=$(printf '%s\\n' \"$1\" | LC_ALL=C awk '" + unquote + "'; printf x); _p=${_p%x} ;; (*) _p=$1 ;; esac; }; " +
		"_bsd() { [ -n \"$( ( cd \"$1\" || { echo '!!'; exit; }; " + Off(".") + "git status --porcelain --ignore-submodules=dirty" + StatusFailed + " ) 2>/dev/null | head -c1)\" ] " +
		"&& return 0; _bsl \"$1\" | { while IFS= read -r _s; do _bsp \"$_s\"; [ -e \"$1/$_p/.git\" ] && _bsd \"$1/$_p\" && exit 0; done; exit 1; }; }; " +
		"_bsl " + dir + " | while IFS= read -r _s; do _bsp \"$_s\"; _q=$_p; [ -e " + dir + "/\"$_q/.git\" ] && _bsd " + dir + "/\"$_q\" " +
		"&& printf ' M %s" + end + "' \"" + pathVar + "\"; done; "
}

const unquote = `{ s = substr($0, 2, length($0) - 2); o = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c != "\\") { o = o c; continue }; c = substr(s, ++i, 1); if (c ~ /[0-7]/) { o = o sprintf("%c", c * 64 + substr(s, i + 1, 1) * 8 + substr(s, i + 2, 1)); i += 2 } else if (c == "n") o = o "\n"; else if (c == "t") o = o "\t"; else if (c == "r") o = o "\r"; else if (c == "a") o = o "\007"; else if (c == "b") o = o "\b"; else if (c == "f") o = o "\f"; else if (c == "v") o = o "\v"; else o = o c }; printf "%s", o }`

// DiffFlags: no external diff, no textconv program, no submodule recursion.
const DiffFlags = "--no-ext-diff --no-textconv --ignore-submodules=dirty"
