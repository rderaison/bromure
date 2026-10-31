# ACLinux

The Linux implementations behind Bromure AC's platform protocols: QEMU/KVM VMs (`QEMUMachine`), host AF_VSOCK, guest CIDs, the network ports and uplinks, the secrets vault, and the `bromure-ac` daemon and CLI. Every declaration carries `@port` or `@port-skip` (see `tools/portmap`).

## Network ports and backpressure (`FramePort`)

`StreamPort` (a VM, through QEMU's `-netdev stream`), `PasstUplink` and `TapUplink` are all `FramePort`s. They mirror VMNetSwitch's frame loop on macOS, plus backpressure:

| VMNetSwitch (macOS) | FramePort (Linux) |
|---|---|
| `readVMLoop`: a blocking `read` per VM socketpair | `inbound`: an `NIOAsyncSequenceProducer` (high/low watermark, lossless). The port stops reading QEMU's socket, passt's socketpair or the tap while the consumer lags. |
| `drainVmnetToVMs`: vmnet's packets-available callback | the uplink's `inbound` |
| `write(fd)` to a VM, dropped by the kernel when its buffer is full | `send(_:)`: never blocks; a bounded per-port queue (1024 frames, 8 MiB) that drops, counted in `stats.dropped`, only when that port's queue is full |
| `writeToVmnet` | `sendWaiting(_:)`: waits for room (one source, one destination) |

- **Writer:** a per-port task drains the queue in batches: one buffer and one write per batch, waiting while the socket isn't writable.
- **InterimSwitch** (a stand-in for VMNetSwitch until ACCore):
  - each VM's reader `sendWaiting`s to the uplink, so pressure goes back to that VM;
  - the shared uplink reader only `send`s, so a VM that stops draining (paused, slow) drops at its own limit and the other VMs don't slow down (`StallTests`).

## Known issue: passt stops ACKing a flow when its tap writes hit EAGAIN

**Symptom:** occasionally, under sustained guest→host TCP, passt (0.0~git20260120) stops answering one flow for good. It shows up mostly at MTU 1500.

**Cause** (reproduced without Bromure; see `linux/PASST_STALL_REPORT.md`, a draft for upstream, not filed):
- The trigger is backpressure on passt's output. PasstUplink stops reading passt while the switch's consumer lags, so passt's writes to its tap fd hit EAGAIN.
- At the stall, passt has forwarded hundreds of KB of guest data to the host that it never acknowledged to the guest. It then never answers the guest's retransmissions of that data.
- The plain QEMU + passt reproduction (`linux/passt-repro/repro.sh`) stalls 0/140 runs with QEMU reading promptly, and 5/20 with a relay that pauses reading passt for 5–50 ms.
- passt's `--pcap` hides it (0/32).

**Fix (ours):**
- A thread of its own reads passt's socket and splits frames, as QEMU's net backend does (`PasstUplink.readLoop`, on a dup of the fd; NIO only writes).
- A second thread routes those frames: the switch is the uplink's receiver (`Uplink.setReceiver`).
- Between the two is an inbox that **never drops**. A frame lost from passt is worse than a late one: a lost ACK is never re-sent, and an earlier version that dropped there turned one flow's losses into 117M frames of retransmission in 60 s. Its backlog is bounded by the guests' TCP windows, and at 256Ki frames the reader waits (`routeWaits`, expected 0).
- A VM that stops draining still drops at its own port.

Measured, one guest uploading at MTU 1500 through the switch:
- the stall went from 5–6/30 to 0/30 and 0/30;
- passt's failed tap writes (EAGAIN) went from 28,000–44,000 per run to 3;
- the routing backlog peaked at 203 frames.

Routing is now the throughput limit: about 560k frames/s on one thread. A guest downloading flat out can build a large backlog (it peaked at the 256Ki limit in one run).
