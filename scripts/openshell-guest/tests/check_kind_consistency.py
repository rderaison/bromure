"""The sentry suites must not require a kind to fire and to be absent.

`test_sentry.sh` listed `connect` in DRIVEN ("required to appear") while its
retired-kinds check required it never to appear. The suite contradicted itself,
and because it cannot run on a locked-down VM the contradiction survived two
rounds and was found by someone else's fresh-VM run.

This needs no module and no kernel, so it runs everywhere the suites do not.
"""
import ast, io, re, sys

def literal_set(src, name):
    """The string keys/elements of a top-level `name = {...}` or tuple."""
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if getattr(t, "id", None) != name:
                    continue
                v = node.value
                if isinstance(v, ast.Dict):
                    return {k.value for k in v.keys
                            if isinstance(k, ast.Constant)}
                if isinstance(v, (ast.Tuple, ast.List, ast.Set)):
                    return {e.value for e in v.elts
                            if isinstance(e, ast.Constant)}
    return set()

def main(path):
    shell = io.open(path, encoding="utf-8").read()
    # The suites embed python in heredocs; concatenate them and parse as one.
    blocks = re.findall(r"<<'PY'\n(.*?)\nPY\n", shell, re.S)
    driven, retired = set(), set()
    for b in blocks:
        try:
            driven |= literal_set(b, "DRIVEN")
        except SyntaxError:
            pass
        # `retired = {k: ... for k in (...)}` is a comprehension, not a literal
        for m in re.finditer(r"retired\s*=\s*\{[^}]*?for k in \(([^)]*)\)", b, re.S):
            retired |= {s.strip().strip("\"'")
                        for s in m.group(1).split(",") if s.strip()}
    both = sorted(driven & retired)
    if both:
        for kind in both:
            print("  %s requires %r to FIRE and to be ABSENT" % (path, kind))
        return 1
    print("  %-40s consistent (%d driven, %d retired, no overlap)"
          % (path, len(driven), len(retired)))
    return 0

sys.exit(max(main(p) for p in sys.argv[1:]))
