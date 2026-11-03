"""Names read in a finally/except that the function never binds.

The shape of a real bug: `_run_interactive` branched on `proc` in its `finally`
while the spawn path bound only `pid`, so every interactive session raised
NameError. Counts as "bound": assignments, parameters, `except ... as NAME`,
with-items, comprehension targets, imports, nested def/class names, and
anything bound by an ENCLOSING function (closures).
"""
import ast, builtins, io, sys

def bound_names(fn):
    names = set()
    for n in ast.walk(fn):
        if isinstance(n, ast.Name) and isinstance(n.ctx, (ast.Store, ast.Del)):
            names.add(n.id)
        elif isinstance(n, ast.ExceptHandler) and n.name:
            names.add(n.name)
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(n.name)
        elif isinstance(n, (ast.Import, ast.ImportFrom)):
            names |= {a.asname or a.name.split(".")[0] for a in n.names}
        elif isinstance(n, ast.Global) or isinstance(n, ast.Nonlocal):
            names |= set(n.names)
    a = fn.args
    names |= {x.arg for x in a.args + a.kwonlyargs + getattr(a, "posonlyargs", [])}
    if a.vararg: names.add(a.vararg.arg)
    if a.kwarg: names.add(a.kwarg.arg)
    return names

def check(path):
    tree = ast.parse(io.open(path, encoding="utf-8").read(), path)
    parents = {}
    for node in ast.walk(tree):
        for child in ast.iter_child_nodes(node):
            parents[child] = node
    module = bound_names(ast.parse("def _m():\n pass").body[0])  # empty base
    for n in ast.walk(tree):
        if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
            module.add(n.id)
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            module.add(n.name)
        elif isinstance(n, (ast.Import, ast.ImportFrom)):
            module |= {a.asname or a.name.split(".")[0] for a in n.names}

    def enclosing(fn):
        names = set()
        node = parents.get(fn)
        while node is not None:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                names |= bound_names(node)
            node = parents.get(node)
        return names

    hits = []
    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        ok = bound_names(fn) | enclosing(fn) | module
        for t in ast.walk(fn):
            if not isinstance(t, ast.Try):
                continue
            for block in list(t.finalbody) + [b for h in t.handlers for b in h.body]:
                for nm in ast.walk(block):
                    if (isinstance(nm, ast.Name) and isinstance(nm.ctx, ast.Load)
                            and nm.id not in ok and not hasattr(builtins, nm.id)):
                        hits.append((nm.lineno, fn.name, nm.id))
    return sorted(set(hits))

bad = 0
for path in sys.argv[1:]:
    hits = check(path)
    if hits:
        bad += len(hits)
        for line, fn, ident in hits:
            print("  %s:%d  %s() reads %r in a finally/except but never binds it"
                  % (path, line, fn, ident))
    else:
        print("  %-36s clean" % path)
sys.exit(1 if bad else 0)
