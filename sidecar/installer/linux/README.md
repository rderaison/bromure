# Bromure Sidecar on Linux

Command line only: no GUI, no tray. The daemon runs as a **systemd user
service** and every action the macOS/Windows tray offers is a subcommand.

Works on a headless server reached over SSH, with no desktop session and no
root. x86_64 and arm64.

## Install

From a release tarball:

```sh
tar xzf bromure-sidecar-linux-amd64.tar.gz
cd bromure-sidecar-linux-amd64
./install.sh ./bromure-sidecar
```

From a checkout (needs Go 1.26+):

```sh
sidecar/installer/linux/install.sh
```

Per user, with no root: the Sidecar runs *your* coding agents with *your*
credentials and git identity, and every path it touches (`~/.claude`,
`~/.codex`, the worktrees under `~/.bromure`) belongs to a person. A system
service would run them as somebody else.

### Headless servers: enable lingering

systemd only keeps a user manager running while that user has a session.
Without lingering the Sidecar stops when you log out and never starts at
boot:

```sh
sudo loginctl enable-linger "$(id -un)"
loginctl show-user "$(id -un)" -p Linger    # want Linger=yes
```

This is the one step that needs root, and it is a one-off.

If `systemctl --user` says *Failed to connect to bus*, the shell has no
`XDG_RUNTIME_DIR`. `install.sh` sets it; for your own shells:

```sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)
```

## Enrolling a headless machine

There is no browser and no URL-scheme handler, so enrollment is split in
two. `enroll` prints a URL instead of opening one:

```sh
bromure-sidecar enroll
# → open this on a machine with a browser:
#   https://bromure.io/app/enroll?capability=agent-host&state=…
```

Open it there, sign in, and the page hands back a
`bromure-agent-host://enroll?code=…&state=…` link. Paste it back:

```sh
bromure-sidecar enroll 'bromure-agent-host://enroll?code=…&state=…'
```

Then admit the machine in Bromure AC's fleet dialog, and attach it to an
account server:

```sh
bromure-sidecar servers            # what this account offers
bromure-sidecar link <server-id>
bromure-sidecar status
```

## Commands

| command | what it does |
|---|---|
| `status` | sign-in, serving, attach, agents, windows |
| `enroll [link]` | print the enroll URL, or complete it with the link |
| `signout` | forget the account and detach |
| `servers` | the account's Bromure AC servers |
| `link <server-id>`, `unlink` | attach this machine to one, or detach |
| `sessions` | the agent sessions on this machine |
| `start <tool> [dir]` | start an agent session |
| `stop <window>` | close one window |
| `agents`, `agents install <tool>` | what is installed, and install one |
| `settings`, `settings <key> [value]` | read and write settings |
| `logs [-f] [-n N]` | the daemon log |
| `update [--install]` | check the release feed, and update the binary |
| `attach <window>` | a terminal on a window (`C-b d` detaches) |
| `claude [args…]` | start Claude here and attach in one step |
| `shutdown` | stop the pane host *and* the daemon |
| `ctl <verb> [json]` | the raw control request, for scripts |

`systemctl --user {start,stop,restart,status} bromure-sidecar` manages the
daemon. Note that `stop` leaves the pane host and the agents running, by
design — see below. `bromure-sidecar shutdown` stops everything.

## Why the Go pane host, and not tmux

Linux has real tmux, and the macOS Sidecar drives real tmux. This port keeps
the **Go pane host** (`internal/panes`) that the Windows Sidecar introduced,
and puts `tmux`/`ps` shims first on the PATH so Bromure AC's shell contract
is served from it. Reasons, in order of weight:

1. **The module has no tmux backend.** `internal/panes` is the only pane
   implementation; the tmux driver is Swift (`AgentHost/Tmux.swift`). Choosing
   tmux means writing a second backend and then maintaining two pane models
   against one client contract.
2. **AC's whole tmux surface is already covered, and it is tested against the
   real client.** `internal/shims`' contract test walks the Swift sources and
   asserts every invocation parses: measured on this checkout, **365 Swift
   files, 97 `tmux` invocations, 9 `ps` invocations and 20 format variables**.
   That test fails loudly when AC grows a new tmux use.
3. **No dependency on tmux being installed**, which matters on the minimal
   server images this port targets.
4. **One behaviour across platforms**, so a pane bug fixed once is fixed
   everywhere.

The honest cost: real tmux is more battle-tested for exotic VT cases, and a
human cannot `tmux attach` to a pane from another shell. `bromure-sidecar
attach <n>` covers the second (verified: it renders a live Claude session and
`C-b d` detaches). If the VT model ever proves too thin, a tmux backend can be
added behind the same `panes.Client` interface without touching the daemon.

## The pane host outlives the daemon

The agents run in the pane host, which `serve` starts **detached** so a daemon
update or crash does not take the agents with it. Verified on Linux: SIGTERM
the daemon, start it again, and the same pane host pid is still serving the
same live session.

`setsid` does not leave a systemd **cgroup**, though, and systemd kills by
cgroup — so the unit sets `KillMode=process`. Without it, `systemctl --user
restart` would kill every running agent. The trade is that `systemctl --user
stop` leaves them running, which is what the tray does on the other platforms
too.

## Data

`$XDG_DATA_HOME/BromureSidecar`, i.e. `~/.local/share/BromureSidecar`:
`control.sock`, `panes.sock`, `delegation.sock`, `remote/` (the SSH host key
and authorized_keys), `client_ed25519`, `device-record.json`,
`sessions.json`, `settings.json`, `logs/` and `bin/` (the shims).
`BROMURE_SIDECAR_DATA` overrides it, which is how a second instance and the
tests stay out of the way.

## Uninstall

```sh
sidecar/installer/linux/uninstall.sh            # keep the keys and sessions
sidecar/installer/linux/uninstall.sh --purge    # remove the data directory
```
