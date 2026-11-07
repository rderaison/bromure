# Bromure Agentic Coding on Linux: release notes

## Upgrading

### VMs without a workspace profile aren't taken back (egress firewall, linux-port cd55e0e4)

A daemon that restarts (a crash, an upgrade, `systemctl` restarting the
unit after its main process is killed) takes back the VMs still running.
Since the egress firewall, it takes back only VMs whose workspace profile
it can read, because a VM's network is governed from that profile. A VM it
can't govern is stopped (its Firecracker killed) and logged:

    'NAME': not re-adopted (invalid VM config: its workspace profile can't be read, so its network can't be governed); killed its Firecracker (pid N)

VMs started before Linux workspaces had profiles have none, so they stop
on the first daemon restart after the upgrade. Their disks are kept: a
fresh start (`bromure-ac vm start NAME`) makes their profile from the
preferences template and boots them governed.

Before upgrading a server, list each account's running VMs (`GET /vms` on
its socket). An upgrade that restarts the daemons with SIGKILL keeps every
VM that has a profile running across the restart.
