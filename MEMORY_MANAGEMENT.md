# Memory management for workspace VMs

The problem: a user on a 16 GB Mac runs many agents in one workspace, and the
guest runs out of memory. A smaller VM avoids that only by crippling other work
in it. The hoped-for answer was an 8 GB VM with a balloon that follows real use.

## What was measured

macOS 27.0.1, Apple Silicon, a 4 GB throwaway VM (Alpine 6.12 kernel, no Bromure
code) with a traditional balloon. Figures are the VM helper's resident size. The
harness is in `tools/balloon-measure/`. One run per configuration.

| Guest setting | Step | Helper RSS |
| --- | --- | --- |
| `init_on_alloc=0` | booted | 323 MB |
| | inflate to 1 GB before anything is touched | 323 MB |
| | guest touches 3 GB, then frees it | 3394 MB |
| | inflate to 1 GB, wait 60 s | 3394 MB |
| | deflate; touch 1 GB; inflate again | 3404 MB |
| `init_on_alloc=1` | booted | 324 MB |
| | inflate to 1 GB before anything is touched | 3389 MB |
| `init_on_free=1` | booted | 4179 MB |

What follows:

1. **A balloon can't give memory back to the Mac.** Once the guest has touched a
   page, it stays resident, however the balloon moves. The device doesn't offer
   free page reporting either (`VIRTIO_BALLOON_F_REPORTING`, bit 5, is clear in
   the features the guest negotiated), and that is Apple's to add.
2. **A kernel module can't change that.** The pages stay resident on the host
   side; nothing in the guest can release them. PSI, memcg and `oom_score_adj`
   already cover what a module would do inside the guest.
3. **A balloon can cap growth.** Inflated before pages are touched, it costs
   nothing, as long as the guest doesn't zero pages on allocation. Ubuntu's
   kernel does by default (`CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`), which is why
   `VMPool` once measured inflation as costing memory.
4. `init_on_free=1` is out: the whole VM is resident right after boot.

Not settled: **does suspend and resume compact a VM?** The save file was 47 MB
after 3 GB was touched and freed. The restore failed with "permission denied" in
the ad-hoc-signed harness, so the size after a restore is unknown. It's worth
trying in the signed app, since suspend already exists there.

What a live guest looks like (31 GB, three Claude agents, one survey): 456 MB per
agent; 17 MCP helpers totalling 1135 MB; agentd itself at 935 MB; all in one
cgroup, with `oom_score_adj` 0 everywhere. agentd scored highest for the OOM
killer. `zram` is not in the image, and there is no swap.

## What this change does

No image change: everything ships through the meta share or the app.

- **Pressure reporting.** agentd adds PSI `avg10` to `vmstat.txt`.
- **Admission** (`MemoryAdmission.swift`). A new agent, or a restart of an exited
  one, is refused when the workspace has other agents and either PSI is high
  (`full` ≥ 5 or `some` ≥ 30) or free memory is below 900 MB per agent being
  started plus a reserve (the larger of 512 MB and 5% of the VM). Agents still
  starting count against what's free. These thresholds are estimates from the one
  survey above, not tuned on a 16 GB machine.
- **Nothing is lost on refusal.** The session keeps the start as asked, and the
  next message or resume retries it.
- **OOM order.** agentd protects itself and the tmux server (`oom_score_adj` -500,
  through `sudo -n`) and sets what runs below them back to 0, because protection
  is inherited across fork. Nothing else is ranked: size still decides between an
  agent, a build and a database. A strict workspace has no sudo, so it gets none of
  this. A process that detaches in the seconds before a pass keeps the protection.
  Only the workspace's own tmux server counts, not one an agent starts, and only an
  inherited -500 is reset. Confirmed on a live guest with throwaway processes:
  children inherit -500, and go back to 0 without privilege.

  A process that inherited -500 can set it again, since it keeps the inherited
  floor. Resetting through sudo would close that, at a privileged event per tab,
  but where this runs sudo is passwordless, so an agent could do it regardless. It
  isn't a boundary, and shouldn't be read as one.

  An earlier version raised everything under a tab to +300 instead, which needs no
  privilege. A dry run on a live guest showed why not: a 369 MB agent became the
  first victim while a 1 GB ClickHouse survived, MCP helpers could be killed under
  a live agent, and an unprivileged agentd could never undo the score.

## What this doesn't do

Coding tasks and automations open their tabs without going through admission, so
they can still pile agents onto a workspace. Refusing unattended work needs its
own design: what should a nightly automation do when it's turned away?

It keeps a workspace alive. It doesn't reduce what the VM costs the Mac: an 8 GB VM
still ends up holding 8 GB once its page cache has filled.

## Proposed next steps

**Balloon as a growth cap** (needs a decision). Boot with the balloon holding
memory back, and release it in steps as PSI or `MemAvailable` call for it. An "8 GB
VM" would then cost only what it has needed so far. It's one-way until the VM
restarts, and page cache would stop filling the VM on its own. The device offers
`DEFLATE_ON_OOM`, so the guest should be able to take memory back in an emergency.
It needs:

- `init_on_alloc=0`, which **gives up a kernel hardening** against leaks of
  uninitialised memory, in a product whose point is isolation. That's the decision.
- An image release to set it, plus a balloon device on workspace VMs. A device
  change invalidates saved suspend states, so those machines boot fresh once.

Smaller, and independent of the above:

- **Find out why agentd is at 935 MB.** It may be a leak, and it's one of the
  largest processes in the guest.
- **Share the MCP helpers.** At 1135 MB they cost more than the agents did.
- **Per-agent cgroups**: attribution, `memory.high` to throttle rather than kill,
  and `memory.oom.group` so an agent and its helpers go together.
- **zram**: an image change; capacity inside the VM, nothing back for the Mac.
- **Host pressure**: refuse to boot another VM when the Mac itself is short.
