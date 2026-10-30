# Draft upstream report: a guest TCP flow stops for good when passt's tap writes hit EAGAIN

**Status: drafted for the passt maintainers, NOT filed.** Bromure's side decides whether and how to send it.

## Summary

passt runs as a QEMU backend over a stream socket (`--fd`, or `-netdev stream`). When whatever reads passt's side of that socket stops reading for a few milliseconds, so that passt's writes to the tap fd hit EAGAIN, a guest→host TCP upload can stop **for good**:

- passt has consumed and forwarded more of the guest's data than it has acknowledged to the guest.
- The ACKs for that data never reach the guest.
- passt then never answers the guest's retransmissions of that data.

The guest backs off exponentially and the flow is dead. Other flows keep working.

## Versions

- passt `0.0~git20260120.386b5f5-1` (Ubuntu 26.04 package, `passt.avx2`)
- QEMU 10.2.1 (`qemu-system-x86_64`)
- Host: Ubuntu 26.04, kernel 7.0.0-42-generic, x86_64 (Threadripper 9970X)
- Guest: Ubuntu 24.04, kernel 6.8.0-147-generic, virtio-net, MTU 1500

## Reproduction (no Bromure code on the host)

`linux/passt-repro/repro.sh` in this repository: QEMU + passt, plus virtiofsd only to hand the guest a script. The guest boots with `systemd.run=` and uploads N × 256 MiB, one connection each, to a sink on the host's LAN address. A transfer counts as stalled when `send()` makes no progress for 10 s.

passt runs as:

```
passt --foreground --fd 0 -4 -a 192.168.64.2 -n 24 -g 192.168.64.1 --mtu 1500 \
      --map-host-loopback none --map-guest-addr none -t none -u none
```

Its fd 0 is one end of a socketpair. The other end goes to QEMU (`-netdev stream,addr.type=fd`), either directly or through a byte relay:

| path between QEMU and passt | stalled runs |
|---|---|
| direct (QEMU reads passt promptly), q35 and microvm, MTU 1500 or passt at 65520 | **0 / 140** |
| relay forwarding every read unchanged (control) | **0 / 20** |
| relay forwarding guest→passt in random pieces, nothing held back | **0 / 40** |
| **relay that stops reading passt's side for 5–50 ms every 200 reads, socket buffers 32 KiB** (`RELAY=slowread`) | **5 / 20**, **2 / 20** |
| Bromure's L2 switch in place of the relay (it stops reading passt while a VM's port is full), one guest | 5 / 30 |

```bash
sudo -g kvm env MACHINE=microvm PCAP=0 RELAY=slowread \
    linux/passt-repro/repro.sh <image-dir> <out-dir> 1500 20 256
```

`<image-dir>` is any Ubuntu guest kernel, initrd and raw disk whose fstab mounts the virtiofs tag `bromure-meta` at `/mnt/bromure-meta`. `bromure-ac image bake` produces one.

## What a stalled flow looks like

Run 2 of the second `slowread` series. Both sides were read at the moment of the stall:

**Guest** (`ss -tin`, the uploading socket):

```
ESTAB 0 2869696 192.168.64.2:39688 10.163.12.85:47011
  rto:7808 backoff:5 mss:1460 pmtu:1500 cwnd:1 bytes_sent:137760504 bytes_retrans:873824
  bytes_acked:135344921 unacked:1056 lost:1056 retrans:1/599 lastsnd:2300 lastrcv:11614
  lastack:9979 snd_wnd:1591296 rwnd_limited:10622ms(91.5%)
```

**Host**: passt's own socket to the sink (`ss -tni`), and the sink's count:

```
ESTAB 0 0 10.163.12.85:47011 10.163.12.85:47828      (Recv-Q 0, Send-Q 0)
sink: 135894036 bytes received on this connection, then nothing for 5 s
```

What this shows:

- **passt has forwarded 135,894,036 bytes to the host but has acknowledged only 135,344,921 to the guest**: 549,115 bytes, about 376 segments, consumed and passed on but never ACKed where the guest can see it. The other stall gives the same picture: 115,344,872 forwarded, 114,379,813 acked, 965,059 bytes apart.
- The guest still holds 1056 unacknowledged segments. It retransmits the first one with exponential backoff (rto 7.8 s, backoff 5), and nothing from passt has arrived for 11.6 s.
- The host socket has nothing queued in either direction. Everything passt wrote was received, and the host side is idle, waiting on passt.

So the guest's data reached passt, and passt's host side is healthy. What's missing is passt's ACKs toward the guest, and any reply to the retransmissions.

## Our reading (for the maintainers to confirm or correct)

1. While the tap fd is full, passt drops frames it can't write. That's fine for data, which TCP recovers. But the ACKs for the guest data passt has already consumed are among them, and passt's state seems to treat them as sent.
2. The guest's retransmissions then carry sequence numbers passt has already consumed (below its "next expected"). passt discards them **without sending an ACK**. RFC 9293 §3.10.7.4: a segment that isn't acceptable, including old duplicate data, should be answered with an acknowledgment. That ACK is what would let the guest move on.
3. With nothing new arriving from the guest (it is window- and congestion-limited, cwnd 1) and no ACK going out, nothing ever restarts the flow.

## Things that make it hard to see

- **`--pcap` hides it:** 0/32 stalls with passt's capture on, against 5/20 off. A capture taken in the relay (headers only) hides it too. The socket states above are the evidence instead.
- An earlier capture, through Bromure's switch with `--pcap` on, did catch one. In it, passt's last ACK opened about 1 MB of window, the guest filled it, every segment appears in passt's capture, and afterwards passt sends nothing on the flow while each retransmit still appears. That matches the reading above. That pcap was not kept.
- Ubuntu's AppArmor profile for passt denies its syslog socket, and the reads `--log-file` needs, so passt's own warnings aren't visible: "Failed to send … to syslog".

## Separately, smaller

In this build, `passt --socket <path>` (with the socket under `/tmp`, which the AppArmor profile allows) logs `Failed to add fd to epoll: Bad file descriptor` as soon as a client connects. We saw it with every option set we tried and with `socat` as the client. We moved to `--fd 0` and did not check whether traffic still flows in socket mode, so this may be only a spurious message.

## Local data (lnx-ntv)

Nothing is in git:

- Socket dumps and logs: `/tmp/claude-1000/-home-renaud/5df66134-3725-4495-a1a1-913617f2f140/scratchpad/passt-repro/ss-slowread/` (`sink.log`, `serial.log`, `results.txt`).
- The `--pcap` captures from the non-stalling runs (0.9–5.6 GB each) were deleted, since none of them shows a stall.

## On Bromure's side, regardless

- ACLinux's PasstUplink stops reading passt when the switch's consumer lags. That is the trigger. Reading passt eagerly and dropping at the VM's own port (which the switch already does toward a slow VM) avoids it.
- The guest MTU default behind passt (65520) makes it rarer, not impossible: fewer, larger frames.
