# macOS ↔ Windows feature parity

Bromure AC is developed primarily on macOS (Swift / VZ / AppKit / SwiftUI).
The Windows port (`windows/`) is a follow-on. This doc + the scripted check
keep the two trees from drifting apart silently.

## How it works

Every Windows file that ports a macOS file carries a one-line **anchor**
comment at the top:

```csharp
// macos-source: Sources/AgentCoding/Mitm/HTTPProxy.swift @ 875b644e56b1
```

The hash is the **blob SHA** (`git rev-parse HEAD:<path>`, 12-char prefix)
of the macOS file at the time the Windows port was last synced.

`windows/scripts/check-parity.ps1` walks the `windows/` tree and:

- For every anchor, asks `git rev-parse HEAD:<swift-path>` for the macOS
  file's CURRENT blob SHA. If it differs → **DRIFT**: the macOS source
  has evolved since the Windows port was last synced. Review the diff
  and refresh the anchor's SHA after porting any new behaviour.
- For every `Sources/AgentCoding/**/*.swift` that has no anchor anywhere
  in the Windows tree → **UNPORTED**, unless explicitly listed in
  `windows/PARITY_IGNORE` (macOS-only files: VZ-specific, AppKit-specific,
  SwiftUI views, AppleScript glue, etc.).

Run from the repo root:

```
pwsh windows/scripts/check-parity.ps1
```

Add `-Verbose` to inline-print the macOS diff for each drifted file.
Exit code: `0` on full parity, `1` on any drift / unported file.

## Workflows

### Adding a new Windows port of a macOS file

1. Port the code.
2. At the top of the new Windows file, add:
   ```csharp
   // macos-source: Sources/AgentCoding/Foo.swift @ <12-hex blob sha>
   ```
   Get the SHA via:
   ```
   git rev-parse HEAD:Sources/AgentCoding/Foo.swift
   ```
3. Run `pwsh windows/scripts/check-parity.ps1` to confirm there is no drift.

A single Windows file may carry **multiple** anchors (e.g.,
`AwsCredentials.cs` ports parts of both `AWSCredentialServer.swift` and
`Profile.swift`). Add one comment line per macOS source.

### Refreshing after a macOS change has landed

1. Run `pwsh windows/scripts/check-parity.ps1 -Verbose`.
2. For each DRIFT entry, read the upstream diff. Either:
   - Port the change to the Windows file, then update the SHA in the
     anchor.
   - Or, if the change doesn't apply to Windows (host-only, AppKit-only),
     just update the SHA — the anchor records "we've reviewed this delta
     and decided no port is needed."

### Declaring a macOS file as not-going-to-port

Add a one-line entry to `windows/PARITY_IGNORE`:

```
Sources/AgentCoding/SessionWindow.swift   # AppKit / NSWindow — Windows uses WPF
```

Comments after `#` are ignored.

## CI gate

The check is meant to run in CI on every PR that touches either tree.
Failure is informational, not blocking — the goal is awareness, not to
make every macOS PR mandatory-port-or-explain. A reviewer eyeballs the
report and decides.

## Limits

- The anchor records a single SHA per port. If the macOS file is
  rewritten incrementally, the diff at refresh time grows large. Refresh
  often.
- The script currently scans `Sources/AgentCoding/`. If we ever add
  `Sources/SandboxEngine/` (the browser sandbox) ports to the Windows
  tree, extend the glob.
- Tests on the Windows side aren't anchored — there's no 1:1 with the
  macOS Swift Testing suites. Test parity is tracked separately (in
  practice, by feature equivalence in the test names).
