#!/usr/bin/python3
"""portmap-compare.py <status.json> <other-export.json>
Reduces `portmap status --json` to {id: [hash, inMacOS, inLinux]} and diffs it against
an export of the same shape from the other platform. Exit 1 on any difference."""
import json, sys
rep = json.load(open(sys.argv[1]))
mine = {}
for e in rep["entries"]:
    m = e["mac"]; mine[m["id"]] = [m["hash"], m["inMacOS"], m["inLinux"]]
theirs = json.load(open(sys.argv[2]))
only_mine = sorted(mine.keys() - theirs.keys()); only_theirs = sorted(theirs.keys() - mine.keys())
diff = sorted(k for k in mine.keys() & theirs.keys() if mine[k] != theirs[k])
print(f"entries: here {len(mine)} (records {len(rep['entries'])}), other {len(theirs)}")
print(f"only here {len(only_mine)}, only other {len(only_theirs)}, differing {len(diff)}")
for k in only_mine[:50]: print("  + ", k)
for k in only_theirs[:50]: print("  - ", k)
for k in diff[:50]: print("  ~ ", k, "here", mine[k], "other", theirs[k])
sys.exit(1 if only_mine or only_theirs or diff else 0)
