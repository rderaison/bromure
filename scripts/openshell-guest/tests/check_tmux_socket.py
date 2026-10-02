"""String literals that build a shell command starting with a bare `tmux`.

The bug: `_view_attach_command` hard-coded `tmux`, so under a spec the command
looked for /tmp/tmux-<uid>/default instead of the supervisor's socket,
`has-session` failed, and the command exited before printing -- a blank window.
`_tmux_argv()`'s docstring already claimed every invocation went through it.

Precise by construction: docstrings and `log(...)` arguments are excluded via
the AST, so a log line reading "tmux %s timed out" is not mistaken for a
command. Only literals naming a real tmux SUBCOMMAND count.
"""
import ast, io, re, sys

SUBCOMMANDS = ("has-session", "new-session", "attach-session", "attach",
               "kill-server", "send-keys", "set-option", "new-window",
               "list-panes", "list-windows", "select-window")
PAT = re.compile(r"(?<![-\w/.])tmux\s+(" + "|".join(SUBCOMMANDS) + r")")

def check(path):
    tree = ast.parse(io.open(path, encoding="utf-8").read(), path)
    docstrings, logged = set(), set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                             ast.ClassDef)):
            body = getattr(node, "body", None)
            if body and isinstance(body[0], ast.Expr) and \
                    isinstance(body[0].value, ast.Constant) and \
                    isinstance(body[0].value.value, str):
                docstrings.add(id(body[0].value))
        if isinstance(node, ast.Call):
            fn = node.func
            name = getattr(fn, "id", None) or getattr(fn, "attr", None)
            if name in ("log", "_bridge_log", "print", "warn"):
                for arg in ast.walk(node):
                    if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                        logged.add(id(arg))
    hits = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Constant) and isinstance(node.value, str)):
            continue
        if id(node) in docstrings or id(node) in logged:
            continue
        if " -S" in node.value:
            continue
        m = PAT.search(node.value)
        if m:
            hits.append((node.lineno, node.value[max(0, m.start() - 10):][:60]))
    return sorted(set(hits))

bad = 0
for path in sys.argv[1:]:
    hits = check(path)
    for line, text in hits:
        print("  %s:%d builds a bare tmux command: %r" % (path, line, text))
    bad += len(hits)
    if not hits:
        print("  %-40s clean" % path)
sys.exit(1 if bad else 0)
