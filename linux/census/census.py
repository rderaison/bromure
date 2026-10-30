#!/usr/bin/python3
"""ACCore census: which macOS sources could move into a shared core, measured on Linux.

For every file under Sources/{AgentCoding,SandboxEngine,BrowserBridges} that portmap
doesn't skip entirely:
  - imports, split into Linux-available and Apple-only;
  - Apple-only symbols used (regex families), each site attributed to a portmap function id;
  - tier, by actually typechecking on Linux (swiftc -typecheck), iterated to a fixed point:
      A  typechecks as-is (with only other A files of its module, and its deps' A modules)
      B  typechecks with the census shims: os/OSLog -> a stub Logger, CryptoKit -> swift-crypto,
         Darwin -> Glibc, URLSession types -> an implicit FoundationNetworking import
      C  doesn't (reason: an Apple import that has no shim, or the first compile error)
  - a leaf-first move order for A and B files (type-reference graph, SCCs condensed).

Usage: census.py <repo-root> <out-dir>    (writes accore-census.json + work files)
Read-only on the macOS sources: they're compiled from where they are, nothing is copied or edited.
"""
import collections, json, os, re, subprocess, sys, time

ROOT = os.path.abspath(sys.argv[1])
OUT = os.path.abspath(sys.argv[2])
HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(OUT, "work")
os.makedirs(WORK, exist_ok=True)

MODULES = [  # (module name, source dir, in-repo module deps), build order
    ("SandboxEngine", "Sources/SandboxEngine", []),
    ("BrowserBridges", "Sources/BrowserBridges", ["SandboxEngine"]),
    ("bromure_ac", "Sources/AgentCoding", ["SandboxEngine", "BrowserBridges"]),
]
IN_REPO = {m for m, _, _ in MODULES} | {"BrowserBridges", "SandboxEngine"}
LINUX_OK = {"Foundation", "Dispatch", "Swift", "_Concurrency", "Glibc", "FoundationNetworking", "FoundationEssentials",
            "Crypto", "_CryptoExtras", "X509", "SwiftASN1", "Yams", "BigInt", "NIOCore", "NIOPosix", "NIOHTTP1",
            "NIOSSH", "NIOEmbedded", "NIOConcurrencyHelpers", "NIOFoundationCompat", "ArgumentParser", "Synchronization",
            "RegexBuilder", "XCTest", "Testing", "Observation"}
SHIMMED = {"os": "os", "OSLog": "os", "CryptoKit": "crypto", "Darwin": "darwin", "SQLite3": "sqlite3"}

SYMBOLS = [  # (family, regex)
    ("Keychain (SecItem)", r"\bSecItem\w+|\bkSec(Class|Attr|Value|Return|Match|Use)\w*"),
    ("Security keys/certs/trust", r"\bSec(Key|Certificate|Identity|Trust|AccessControl|Policy|Code|StaticCode|Task|Random)\w*"),
    ("SecureTransport", r"\bSSL(CreateContext|Handshake|Read|Write|Close|Set\w+|Get\w+|Context\w*)\b"),
    ("Network.framework", r"\bNW(Connection|Listener|PathMonitor|Endpoint|Parameters|Path|Browser|Protocol\w*|Error|TCPOptions|UDPOptions|TLS\w*)\b"),
    ("os logging", r"\bos_log\b|\bos_signpost\b|\bOSSignposter\b|\bLogger\(|\bOSLog\b"),
    ("Dispatch sources missing on Linux", r"makeFileSystemObjectSource|makeProcessSource|makeMemoryPressureSource|makeMachSendSource|makeMachReceiveSource"),
    ("AppKit/UI", r"\bNS(Workspace|Application|App\b|Window|View|Image|Color|Pasteboard|Alert|Screen|Event|Menu|StatusBar|Font|Cursor|Sound|OpenPanel|SavePanel|Panel|ViewController|WindowController|HostingView|Responder)\w*"),
    ("SwiftUI", r"\b(some View|@State\b|@Binding\b|@ObservedObject|@StateObject|@EnvironmentObject|ViewBuilder|NSHostingController)"),
    ("Virtualization (VZ)", r"\bVZ[A-Z]\w+"),
    ("vmnet", r"\bvmnet_\w+|\bVMNET_\w+|\binterface_ref\b"),
    ("FSEvents/kqueue/XPC/IOKit", r"\bFSEvent\w+|\bkqueue\b|\bkevent\b|\bxpc_\w+|\bNSXPC\w+|\bIOService\w+|\bIORegistry\w+|\bIOPM\w+"),
    ("ServiceManagement/notifications", r"\bSMAppService\b|\bUNUserNotification\w*|\bNSUserNotification\w*|\bNSDistributedNotificationCenter\b|\bCFNotificationCenter\w*"),
    ("AppleScript", r"\bNSAppleScript\b|\bNSAppleEventDescriptor\b|\bOSAScript\b"),
    ("ProcessInfo/Foundation gaps", r"\bthermalState\b|\bisLowPowerModeEnabled\b|\bbeginActivity\(|\bNSUserDefaults\b|\bNSFileCoordinator\b|\bURLSessionWebSocketTask\b"),
    ("URLSession (needs FoundationNetworking)", r"\bURLSession\b|\bURLRequest\b|\bHTTPURLResponse\b|\bURLResponse\b"),
    ("Combine", r"\bAnyCancellable\b|\bPassthroughSubject\b|\bCurrentValueSubject\b|@Published\b"),
]

def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

# ---- portmap: entries per file -------------------------------------------------------------
status = json.loads(run([os.path.join(ROOT, "tools/portmap/.build/release/portmap"), "status", "--root", ROOT, "--json"]).stdout)
entries_by_file = collections.defaultdict(list)
for e in status["entries"]:
    m = e["mac"]
    entries_by_file[m["file"]].append({"id": m["id"], "line": m["line"], "lines": m["lines"], "status": e["status"]})
config = json.load(open(os.path.join(ROOT, "port/config.json")))

def glob_re(p):
    r, i = "^", 0
    while i < len(p):
        if p[i:i + 3] == "**/": r += "(?:.*/)?"; i += 3
        elif p[i:i + 2] == "**": r += ".*"; i += 2
        elif p[i] == "*": r += "[^/]*"; i += 1
        elif p[i] == "?": r += "[^/]"; i += 1
        else: r += re.escape(p[i]); i += 1
    return re.compile(r + "$")
skip_globs = [glob_re(s["path"]) for s in config.get("skip", []) if s.get("path")]

def function_at(path, line):
    best = None
    for e in entries_by_file.get(path, []):
        if e["line"] <= line <= e["line"] + max(e["lines"], 1) + 1:
            if best is None or e["line"] >= best["line"]: best = e
    return best["id"] if best else None

# ---- per-file scan --------------------------------------------------------------------------
files = {}
for module, src, _ in MODULES:
    for dirpath, _, names in os.walk(os.path.join(ROOT, src)):
        for n in sorted(names):
            if not n.endswith(".swift"): continue
            full = os.path.join(dirpath, n)
            rel = os.path.relpath(full, ROOT)
            ents = entries_by_file.get(rel, [])
            if ents and all(e["status"] == "skipped" for e in ents): continue
            if not ents and any(g.match(rel) for g in skip_globs): continue
            text = open(full, encoding="utf-8", errors="replace").read()
            lines = text.split("\n")
            imports = []
            for l in lines:
                # Only the file's header: an `import` inside a multi-line string
                # (Python heredocs in guest scripts) isn't one.
                if re.match(r"\s*(?:(?:public|internal|private|fileprivate|open|final)\s+)*(?:class|struct|enum|protocol|actor|extension|func|let|var)\b", l):
                    break
                m = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:class\s+|struct\s+|enum\s+|protocol\s+|func\s+|var\s+|typealias\s+)?([\w]+)", l)
                if m and m.group(1) not in imports: imports.append(m.group(1))
            apple = [i for i in imports if i not in LINUX_OK and i not in IN_REPO]
            symbols = collections.defaultdict(list)
            for no, l in enumerate(lines, 1):
                code = l.split("//")[0]
                for fam, rx in SYMBOLS:
                    for m in re.finditer(rx, code):
                        symbols[fam].append({"line": no, "symbol": m.group(0), "function": function_at(rel, no)})
            decl = set(re.findall(r"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|open|final|nonisolated|indirect)\s+)*(?:class|struct|enum|protocol|actor|typealias)\s+(\w+)", text, re.M))
            exts = set(re.findall(r"^\s*(?:(?:public|internal|private|fileprivate)\s+)*extension\s+(\w+)", text, re.M))
            files[rel] = {"path": rel, "module": module, "lines": len(lines), "imports": imports, "appleImports": apple,
                          "symbols": symbols, "declares": sorted(decl), "extends": sorted(exts),
                          "entries": {"todo": sum(e["status"] == "todo" for e in ents),
                                      "skipped": sum(e["status"] == "skipped" for e in ents),
                                      "other": sum(e["status"] not in ("todo", "skipped") for e in ents)},
                          "text": text}

# ---- compiler plumbing ----------------------------------------------------------------------
cmdline = open(sys.argv[3]).read().replace("\\=", "=").split() if len(sys.argv) > 3 else []
flags, i = [], 0
while i < len(cmdline):
    t = cmdline[i]
    if t in ("-I", "-Xcc", "-target", "-module-cache-path", "-sdk", "-resource-dir") and i + 1 < len(cmdline):
        flags += [t, cmdline[i + 1]]; i += 2; continue
    if t.startswith("-I") and len(t) > 2: flags.append(t)
    i += 1
SWIFTC = run(["bash", "-lc", ". ~/.local/share/swiftly/env.sh; command -v swiftc"]).stdout.strip() or "swiftc"
DEPS_OUT = os.path.join(HERE, ".build/out/Products/Debug-linux-x86_64")
SHIM_OUT = os.path.join(WORK, "shims")
os.makedirs(SHIM_OUT, exist_ok=True)
for mod, src in (("os", "os.swift"), ("OSLog", "OSLog.swift"), ("CryptoKit", "CryptoKit.swift"), ("Darwin", "Darwin.swift")):
    r = run([SWIFTC, "-emit-module", "-module-name", mod, "-emit-module-path", os.path.join(SHIM_OUT, mod + ".swiftmodule"),
             "-I", SHIM_OUT, "-I", DEPS_OUT, *flags, os.path.join(HERE, "shims", src)])
    if r.returncode: sys.exit("shim %s: %s" % (mod, r.stderr[-2000:]))

SHIM_FLAGS = ["-I", SHIM_OUT, "-Xcc", "-fmodule-map-file=" + os.path.join(HERE, "shims/SQLite3/module.modulemap"),
              "-Xfrontend", "-import-module", "-Xfrontend", "FoundationNetworking"]

def bundle_stub(module):
    p = os.path.join(WORK, "BundleModule_%s.swift" % module)
    open(p, "w").write("import Foundation\nextension Foundation.Bundle { static var module: Bundle { .main } }\n")
    return p

def typecheck(module, rels, mod_dir, shims):
    """swiftc -typecheck; returns {rel: first error} for files with errors (and None if the set is clean)."""
    extra = SHIM_FLAGS if shims else []
    paths = [os.path.join(ROOT, r) for r in rels] + [bundle_stub(module)]
    cmd = [SWIFTC, "-typecheck", "-swift-version", "5", "-module-name", module, "-j", "48",
           "-I", mod_dir, "-I", DEPS_OUT, *flags, *extra, *paths]
    if not any(os.path.basename(p) == "main.swift" for p in paths): cmd.insert(2, "-parse-as-library")
    r = run(cmd)
    errors = {}
    for line in (r.stdout + r.stderr).splitlines():
        m = re.match(r"(/[^:]+\.swift):(\d+):\d+: error: (.*)", line)
        if m:
            rel = os.path.relpath(m.group(1), ROOT)
            if rel in rels and rel not in errors: errors[rel] = "%s:%s: %s" % (rel, m.group(2), m.group(3))
    if r.returncode and not errors:      # a failure we couldn't attribute (driver, module-level)
        errors["<module>"] = (r.stderr or r.stdout)[-800:]
    return errors

def fixpoint(module, start, mod_dir, shims):
    s, removed, rounds = set(start), {}, 0
    while s:
        rounds += 1
        errs = typecheck(module, sorted(s), mod_dir, shims)
        if not errs: break
        if "<module>" in errs:
            print("  %s: unattributed failure: %s" % (module, errs["<module>"][:300]), flush=True)
            removed.update({f: "module-level failure" for f in s}); s = set(); break
        for f, e in errs.items():
            removed[f] = e
            s.discard(f)
        print("  %s %s round %d: removed %d, %d left" % (module, "B" if shims else "A", rounds, len(errs), len(s)), flush=True)
    return s, removed

def emit_module(module, rels, mod_dir, shims):
    extra = SHIM_FLAGS if shims else []
    paths = [os.path.join(ROOT, r) for r in sorted(rels)] + [bundle_stub(module)]
    cmd = [SWIFTC, "-emit-module", "-parse-as-library", "-swift-version", "5", "-module-name", module, "-j", "48",
           "-emit-module-path", os.path.join(mod_dir, module + ".swiftmodule"), "-I", mod_dir, "-I", DEPS_OUT, *flags, *extra, *paths]
    r = run(cmd)
    if r.returncode: print("  emit %s failed: %s" % (module, r.stderr[-500:]), flush=True)

# ---- tiers ----------------------------------------------------------------------------------
dirA, dirB = os.path.join(WORK, "modA"), os.path.join(WORK, "modB")
os.makedirs(dirA, exist_ok=True); os.makedirs(dirB, exist_ok=True)
t0 = time.time()
for module, src, deps in MODULES:
    mine = [r for r, f in files.items() if f["module"] == module]
    candA = [r for r in mine if not files[r]["appleImports"]]
    print("%s: %d files, %d without Apple imports" % (module, len(mine), len(candA)), flush=True)
    A, removedA = fixpoint(module, candA, dirA, shims=False)
    candB = [r for r in mine if all(i in SHIMMED for i in files[r]["appleImports"])]
    AB, removedB = fixpoint(module, candB, dirB, shims=True)
    AB |= A          # an A file also typechecks with shims (the shims only add)
    for r in mine:
        f = files[r]
        if r in A: f["tier"] = "A"
        elif r in AB: f["tier"] = "B"
        else:
            f["tier"] = "C"
            unshimmed = [i for i in f["appleImports"] if i not in SHIMMED]
            f["reason"] = ("imports " + ", ".join(unshimmed)) if unshimmed else (removedB.get(r) or removedA.get(r) or "?")
        if f["tier"] in "AB":
            f["shims"] = sorted({SHIMMED[i] for i in f["appleImports"] if i in SHIMMED}
                                | ({"FoundationNetworking"} if f["symbols"].get("URLSession (needs FoundationNetworking)") else set()))
    if A: emit_module(module, A, dirA, shims=False)
    if AB: emit_module(module, AB, dirB, shims=True)
    print("  %s: A %d, B %d, C %d (%.0fs)" % (module, len(A), len(AB - A), len(mine) - len(AB), time.time() - t0), flush=True)

# ---- why C: an Apple import, a dependency that is C, or a Linux portability error ----------
owner_all = {}
for r, f in files.items():
    for d in f["declares"]: owner_all.setdefault(d, r)
for r, f in files.items():
    if f.get("tier") != "C": continue
    reason = f.get("reason", "")
    if reason.startswith("imports "):
        f["cause"] = "apple-import"
        continue
    m = re.search(r"(?:cannot find (?:type )?'(\w+)' in scope|has no member '(\w+)'|no such module '(\w+)')", reason)
    sym = m and (m.group(1) or m.group(2) or m.group(3))
    blocker = owner_all.get(sym) if sym else None
    if blocker and blocker != r and files[blocker].get("tier") == "C":
        f["cause"] = "depends-on-C"
        f["blockedBy"] = blocker
    elif m and m.group(3):
        f["cause"] = "apple-import"
    else:
        f["cause"] = "linux-portability"   # a typecheck error of its own (e.g. Glibc socket types)

# ---- move order: leaf-first over the type-reference graph of A/B files ----------------------
owner = {}
for r, f in files.items():
    for d in f["declares"]: owner.setdefault((f["module"], d), r)
graph = {}
for r, f in files.items():
    if f.get("tier") not in ("A", "B"): continue
    idents = set(re.findall(r"\b[A-Z]\w+\b", re.sub(r"//.*", "", f["text"])))
    deps = set()
    for mod in [f["module"]] + {"bromure_ac": ["SandboxEngine", "BrowserBridges"], "BrowserBridges": ["SandboxEngine"]}.get(f["module"], []):
        for name in idents:
            o = owner.get((mod, name))
            if o and o != r and files[o].get("tier") in ("A", "B"): deps.add(o)
    graph[r] = sorted(deps)
    f["dependsOn"] = graph[r]
# Tarjan SCC, then depth = longest dependency chain.
index, low, stack, on, sccs, counter = {}, {}, [], set(), [], [0]
sys.setrecursionlimit(100000)
def strong(v):
    index[v] = low[v] = counter[0]; counter[0] += 1; stack.append(v); on.add(v)
    for w in graph.get(v, []):
        if w not in index: strong(w); low[v] = min(low[v], low[w])
        elif w in on: low[v] = min(low[v], index[w])
    if low[v] == index[v]:
        comp = []
        while True:
            w = stack.pop(); on.discard(w); comp.append(w)
            if w == v: break
        sccs.append(comp)
for v in graph:
    if v not in index: strong(v)
comp_of = {v: i for i, c in enumerate(sccs) for v in c}
depth = {}
for i, c in enumerate(sccs):    # Tarjan yields SCCs in reverse topological order: deps first
    d = 0
    for v in c:
        for w in graph[v]:
            if comp_of[w] != i: d = max(d, depth[comp_of[w]] + 1)
    depth[i] = d
for v in graph:
    files[v]["moveStep"] = depth[comp_of[v]] + {"SandboxEngine": 0, "BrowserBridges": 100, "bromure_ac": 200}[files[v]["module"]]
    if len(sccs[comp_of[v]]) > 1: files[v]["cycleWith"] = sorted(x for x in sccs[comp_of[v]] if x != v)

for f in files.values():
    del f["text"]
    f["symbols"] = {k: v for k, v in f["symbols"].items()}
json.dump({"generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "commit": run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"]).stdout.strip(),
           "toolchain": run([SWIFTC, "--version"]).stdout.split("\n")[0],
           "files": sorted(files.values(), key=lambda f: f["path"])},
          open(os.path.join(OUT, "accore-census.json"), "w"), indent=1, sort_keys=True)
print("done in %.0fs" % (time.time() - t0))
