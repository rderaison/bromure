# Bromure Linux Phase 0 QEMU spike (lnx-ntv, Ubuntu 26.04, QEMU 10.2.1, virtiofsd 1.13.2)
1. python3 frame_tap.py vms/<vm>/net.sock logs/frames-<vm>.log &   # userspace L2 endpoint (QEMU connects to it)
2. python3 vsock.py listen 5801 logs/host-listen.log &               # host AF_VSOCK listener (guest -> host)
3. sudo -g kvm ./run-vm.sh <vm> <cid>                                # boot; overlay auto-created on img/noble-amd64.img
4. python3 vsock.py call <cid> 5800 '<shell cmd>'                    # host -> guest
5. ./bench-boot.sh <vm> <cid> 3 ; ./suspend-resume.sh <vm> <cid> [mapped|exec]
seed/ = cloud-init (guest vsock agent vsockd.py on :5800, dials host :5801 at boot; virtiofs tag "share" -> /mnt/shared).
smoke-* = Swift 6.4.0 dependency smoke package (Package.swift, main.swift, resolved versions).
`sudo -g kvm` is only needed until the vhost udev rule exists (runs as the user with egid kvm, not root).
