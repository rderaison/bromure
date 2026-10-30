#!/usr/bin/python3
"""Renders linux/ACCORE_CENSUS.md from accore-census.json (census.py's output).
Usage: report.py <accore-census.json> <out.md>"""
import collections, json, sys

d = json.load(open(sys.argv[1]))
F = {f["path"]: f for f in d["files"]}
out = []
w = out.append

def short(p): return p.replace("Sources/", "")

# Transitive unlock potential: C files whose blocker chain ends at a root.
def root_of(p, seen=()):
    f = F[p]
    b = f.get("blockedBy")
    if f.get("cause") == "depends-on-C" and b and b not in seen:
        return root_of(b, seen + (p,))
    return p
unlocks = collections.Counter()
chains = collections.defaultdict(list)
for p, f in F.items():
    if f.get("cause") == "depends-on-C":
        r = root_of(p)
        unlocks[r] += 1
        chains[r].append(p)

mods = ["SandboxEngine", "BrowserBridges", "bromure_ac"]
label = {"bromure_ac": "AgentCoding (bromure_ac)"}
w("# ACCore census\n")
w("Generated from `linux/census/census.py` at %s, on %s (`%s`). The JSON is `linux/accore-census.json`.\n"
  % (d["commit"], d["generated"], d["toolchain"]))
w("It covers every file under `Sources/{SandboxEngine,BrowserBridges,AgentCoding}` that portmap doesn't skip outright. "
  "**Tiers come from actually typechecking on Linux** (`swiftc -typecheck`, Swift 5 mode), iterated to a fixed point. "
  "A file is in a tier only if it typechecks together with the other files of that tier and its dependencies' modules:\n")
w("- **A**: typechecks as-is.")
w("- **B**: typechecks with the census shims: `os`/`OSLog` to a stub `Logger`, `CryptoKit` to swift-crypto, "
  "`Darwin` to Glibc, `SQLite3` to a system module map, and an implicit `FoundationNetworking` for URLSession types. "
  "In the real carve-out these are `#if canImport` lines or a tiny shared logging/crypto shim.")
w("- **C**: doesn't. The cause is one of:")
w("  - `apple-import`: VZ, AppKit/SwiftUI, Security, Network, Combine, Compression and so on;")
w("  - `depends-on-C`: it would compile, but uses a type that lives in a C file (`blockedBy`);")
w("  - `linux-portability`: its own Linux error, such as Glibc socket constants being enums.\n")

w("## Summary\n")
w("| module | files | A | B | C: apple-import | C: depends-on-C | C: linux-portability | lines A+B |")
w("|---|---|---|---|---|---|---|---|")
for m in mods:
    fs = [f for f in d["files"] if f["module"] == m]
    c = collections.Counter(f["tier"] for f in fs)
    cc = collections.Counter(f.get("cause") for f in fs if f["tier"] == "C")
    w("| %s | %d | %d | %d | %d | %d | %d | %d |" % (label.get(m, m), len(fs), c["A"], c["B"], cc["apple-import"],
      cc["depends-on-C"], cc["linux-portability"], sum(f["lines"] for f in fs if f["tier"] in "AB")))
w("")
w("**Most of C is the cascade, not the platform:** `depends-on-C` files would compile once their blocker moves or is split. "
  "The roots with the largest unlock potential (direct plus transitive dependents) are:\n")
w("| root (C) | cause | unlocks | example dependents |")
w("|---|---|---|---|")
for r, n in unlocks.most_common(15):
    f = F[r]
    why = f.get("reason", "")[:90].replace("|", "\\|")
    w("| `%s` | %s: %s | **%d** | %s |" % (short(r), f.get("cause"), why, n, ", ".join("`%s`" % short(x).split("/")[-1] for x in chains[r][:4])))
w("")

w("## Apple-only usage by family (non-skipped files)\n")
fam_files = collections.Counter(); fam_sites = collections.Counter()
for f in d["files"]:
    for fam, sites in f["symbols"].items():
        fam_files[fam] += 1; fam_sites[fam] += len(sites)
w("| family | files | sites |")
w("|---|---|---|")
for fam, n in fam_files.most_common(): w("| %s | %d | %d |" % (fam, n, fam_sites[fam]))
w("")

def area(title, paths, note):
    w("### " + title + "\n")
    w(note + "\n")
    w("| file | tier | cause / shims | Apple-only sites (family: count) | functions with them |")
    w("|---|---|---|---|---|")
    for p in paths:
        if p not in F:
            w("| `%s` | (skipped by portmap) | | | |" % short(p)); continue
        f = F[p]
        cause = ("%s: %s" % (f.get("cause"), f.get("reason", "")[:70])) if f["tier"] == "C" else ("shims: " + ", ".join(f.get("shims", [])) if f.get("shims") else "as-is")
        fams = "; ".join("%s: %d" % (k, len(v)) for k, v in sorted(f["symbols"].items()))
        funcs = sorted({s["function"] for v in f["symbols"].values() for s in v if s["function"]})
        fn = ", ".join("`%s`" % x for x in funcs[:6]) + (" … +%d" % (len(funcs) - 6) if len(funcs) > 6 else "")
        w("| `%s` | **%s** | %s | %s | %s |" % (short(p), f["tier"], cause.replace("|", "\\|"), fams or "–", fn or "–"))
    w("")

w("## The three areas phases 3, 4 and image management wait on\n")
area("Switch (VMNetSwitch and friends)",
     ["Sources/SandboxEngine/" + n for n in ["VMNetSwitch.swift", "DNSSnoop.swift", "DHCPLeaseStore.swift", "EgressPolicy.swift",
      "NetworkFilter.swift", "LANTap.swift", "VmnetSubnet.swift", "HostNetworkInfo.swift", "HostNetworkWatcher.swift",
      "NetworkHealer.swift", "OpenShellPolicy+Destination.swift"]] + ["Sources/AgentCoding/SwitchMitmForwarder.swift"],
     "VMNetSwitch's frame logic (MAC learning, DHCP, DNS snoop, the interceptor hook) is what the Linux StreamPort/uplink plug into. "
     "Its blockers are the vmnet uplink (`CVmnet`, `vmnet_*`) and the VZ socketpair ports. The carve is: switch core in ACCore behind a "
     "`NetworkUplink`/`SwitchPort` protocol pair, with vmnet and VZ attachments staying in the macOS target.")
mitm = ["Sources/AgentCoding/Mitm/" + n for n in ["HTTPProxy.swift", "MitmEngine.swift", "TokenSwap.swift", "SessionTokenPlan.swift",
        "TLSServerStream.swift", "TLSClientHello.swift", "CertCache.swift", "BromureCA.swift", "MitmPassthrough.swift",
        "UpstreamPinning.swift", "SigV4Signer.swift", "AWSResigner.swift", "CredentialMint.swift", "GuardrailsPolicy.swift",
        "SquelchRewriter.swift", "SquelchFilter.swift", "PIIRewriter.swift", "PIIDetector.swift", "SupplyChainEnforcer.swift",
        "SupplyChainPolicy.swift", "TraceStore.swift", "TraceRecord.swift", "SecretsVault.swift", "EcosystemTransforms.swift",
        "NPMRegistryTransforms.swift", "WebSocketTrace.swift", "EgressConnectionRegistry.swift"]]
area("MITM engine (HTTPProxy and the swaps)", mitm,
     "The TLS legs (`TLSServerStream` on SecureTransport, `CertCache` on SecIdentity, `BromureCA` on Security keys) are the Security-framework "
     "core; they map to the spike's NIOSSL + swift-certificates pieces behind a `TLSStreamFactory`. The policy and rewrite files around them "
     "are mostly pure logic. Their C status is largely `depends-on-C` (on `Profile`, `HTTPProxy` types, `ConsentBroker`'s AppKit) rather than "
     "platform calls of their own.")
area("Image management", ["Sources/AgentCoding/UbuntuImageManager.swift", "Sources/SandboxEngine/ImageFetch.swift",
     "Sources/SandboxEngine/ImageCatalog.swift", "Sources/SandboxEngine/Provisioner.swift", "Sources/SandboxEngine/InitrdShim.swift",
     "Sources/SandboxEngine/LinuxImageManager.swift", "Sources/SandboxEngine/Ext4.swift"],
     "UbuntuImageManager mixes the bake *logic* (catalog, downloads, the serial dialogue, version stamps) with VZ (`VZVirtualMachine` "
     "provisioner) and CommonCrypto (SHA-256). The carve is: bake logic in ACCore against a `ProvisionerVM` protocol "
     "(linux/bake's QEMU dialogue is the Linux side), with hashing on swift-crypto.")

w("## Proposed move order (leaf-first; each step keeps macOS green)\n")
w("A and B files, ordered by the type-reference graph (SCCs together; SandboxEngine before AgentCoding). Each step moves a set whose "
  "dependencies already moved. **Moving files out of `bromure_ac`, an executable target, means making the API they expose to the app "
  "`public`**; that is the main mechanical cost per step. B files need their shim lines in the same step.\n")
steps = collections.defaultdict(list)
for f in d["files"]:
    if f["tier"] in "AB": steps[f["moveStep"]].append(f)
for i, s in enumerate(sorted(steps)):
    fs = sorted(steps[s], key=lambda f: f["path"])
    w("%d. %s" % (i + 1, ", ".join("`%s`%s" % (short(f["path"]), "ᴮ" if f["tier"] == "B" else "") for f in fs)))
w("\n(ᴮ = needs shims.) After these, the unlock table above is the next work: splitting `VMConfig`'s data from its VZ half, and "
  "`Profile`'s `toVMConfig`/UserDefaults edges, moves the largest dependent group.\n")

w("## Per file\n")
w("| file | module | lines | tier | cause / shims | blocked by | todo/skipped entries |")
w("|---|---|---|---|---|---|---|")
for f in sorted(d["files"], key=lambda f: (f["module"], f["tier"], f["path"])):
    cause = f.get("cause", "") + ((": " + f.get("reason", "")[:60]) if f["tier"] == "C" and f.get("cause") != "depends-on-C" else "")
    if f["tier"] in "AB": cause = ", ".join(f.get("shims", [])) or "as-is"
    w("| `%s` | %s | %d | %s | %s | %s | %d/%d |" % (short(f["path"]), f["module"], f["lines"], f["tier"], cause.replace("|", "\\|"),
      ("`%s`" % short(f["blockedBy"])) if f.get("blockedBy") else "", f["entries"]["todo"], f["entries"]["skipped"]))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
