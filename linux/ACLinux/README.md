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

## Known issue: passt stops ACKing a flow at MTU 1500

**Symptom:** occasionally, under sustained guest→host TCP at MTU 1500, passt (0.0~git20260120) stops answering one flow for good.

**From a `--pcap` capture:**
- passt's last ACK opens a window of about 1 MB, and the guest fills it;
- every segment shows up in passt's capture;
- after that, passt never ACKs or sends anything on the flow again. The guest retransmits the first unacknowledged segment with exponential backoff, and passt receives each retransmit;
- other flows keep working.

**What rules out our side:**
- Our ports show no drops, no queued frames and no inbound pauses during the stall.
- The host side of the connection has everything acknowledged and nothing queued.
- The kernel tap path and passt at MTU 65520 have never shown it.

passt's own warnings can't be seen here: Ubuntu's AppArmor profile for passt denies its syslog socket and the read `--log-file` needs.

**Mitigation:** the default guest MTU behind passt is 65520 (see `PasstUplink.Config.mtu`). The tests retry or median over it and print `PASST-STALL` with the port counters. This should be reported upstream with the pcap; `PasstUplink.Config.pcapPath` turns the capture on.
