#!/usr/bin/env bash
# What lockdown=integrity actually costs, and what it actually buys.
#
# This is the investigation @openshell asked for, run as a test so the answer is
# reproducible rather than asserted. It probes each surface BEFORE raising
# lockdown, then raises it, then probes again, and prints a before/after table.
#
# RAISING LOCKDOWN IS ONE-WAY FOR THE LIFE OF THE BOOT. This script therefore
# does NOT raise it unless you pass --raise, so it can be run repeatedly for the
# "before" column alone. With --raise, expect to reboot the VM afterwards.
#
#   tests/test_lockdown.sh                   # probe only, safe, repeatable
#   tests/test_lockdown.sh --raise           # probe, raise to integrity, re-probe
#   tests/test_lockdown.sh --confidentiality # ... to confidentiality instead
#
# `confidentiality` is the stronger level and is worth measuring because it also
# blocks /proc/kcore, /proc/kallsyms addresses, tracefs kprobes and perf — which
# is what stops root reading the sentry's hello secret out of module memory. The
# question is what it costs: run this with --confidentiality on a disposable VM
# and compare the workload rows (docker, k3s modules, iptables, virtiofs, vsock).
set -uo pipefail

RAISE=0
LEVEL=integrity
case "${1:-}" in
    --raise)           RAISE=1 ;;
    --confidentiality) RAISE=1; LEVEL=confidentiality ;;
esac

LOCKDOWN=/sys/kernel/security/lockdown
declare -A BEFORE AFTER

probe() {
    # probe <name> <command...> -> "yes" if the command succeeds
    local name="$1"; shift
    if "$@" > /dev/null 2>&1; then echo "yes"; else echo "no"; fi
}

probe_write() {
    # probe_write <name> <path> <value>
    # The existence check goes through sudo too: /sys/kernel/debug is mode 0700,
    # so a plain `[ -e ]` as the agent user reports "absent" for a file that is
    # very much there and very much writable by root.
    local path="$2" value="$3"
    if ! sudo test -e "$path"; then echo "absent"; return; fi
    if echo "$value" | sudo tee "$path" > /dev/null 2>&1; then echo "yes"; else echo "no"; fi
}

run_probes() {
    local -n out=$1

    # --- the blinding vectors ---
    sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null
    out[kprobes_enabled_write]=$(probe_write x /sys/kernel/debug/kprobes/enabled 1)
    out[tracefs_kprobe_events]=$(probe_write x /sys/kernel/tracing/kprobe_events "")
    out[tracefs_kprobe_dir]=$(probe x sudo test -d /sys/kernel/tracing/events/kprobes)
    out[ftrace_enabled_sysctl]=$(probe x sudo sysctl -q -w kernel.ftrace_enabled=1)
    out[kptr_restrict_sysctl]=$(probe x sudo sysctl -q -w kernel.kptr_restrict=1)
    out[perf_event_paranoid]=$(probe x sudo sysctl -q -w kernel.perf_event_paranoid=4)
    out[perf_event_open]=$(probe x sudo perf stat -e cycles true)

    # --- loading code into the kernel ---
    out[modprobe_signed]=$(probe x sudo modprobe -q dummy)
    out[insmod_unsigned]=$(probe x sudo insmod /tmp/lockdown-probe.ko)
    out[bpf_prog_load]=$(probe x sudo python3 -c "
import ctypes, struct
# BPF_PROG_LOAD of a minimal 'return 0' socket filter. Lockdown=confidentiality
# blocks bpf(); integrity does not, which is exactly the kind of thing worth
# measuring rather than assuming.
libc = ctypes.CDLL('libc.so.6', use_errno=True)
insns = struct.pack('<QQ', 0xb7, 0x95)  # mov r0,0 ; exit
buf = ctypes.create_string_buffer(insns)
log = ctypes.create_string_buffer(4096)
attr = struct.pack('<IIQQIIi16sIII', 1, 2, ctypes.addressof(buf), 0, 0, 0, 0,
                   b'GPL\\0'.ljust(16, b'\\0'), 0, 0, 0)
a = ctypes.create_string_buffer(attr, 120)
rc = libc.syscall(280, 5, a, 120)
raise SystemExit(0 if rc >= 0 else 1)
")

    # --- reading/writing kernel memory ---
    out[dev_mem_read]=$(probe x sudo dd if=/dev/mem of=/dev/null bs=1 count=1)
    out[kcore_read]=$(probe x sudo dd if=/proc/kcore of=/dev/null bs=1 count=1)
    out[kallsyms_addrs]=$(sudo awk '$1 !~ /^0+$/ {found=1; exit} END {print (found ? "yes" : "no")}' /proc/kallsyms)

    # --- things Bromure needs to keep working ---
    out[virtiofs_mounted]=$(probe x mountpoint -q /mnt/bromure-meta)
    # "Can a vsock socket still be created and driven": the answer we care
    # about is about the stack, not about whether anything is listening.
    out[vsock_socket]=$(probe x python3 -c '
import socket
socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM).close()
')
    out[vsock_connect_kernel]=$(probe x python3 -c '
import socket, errno
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect((1, 1))          # VMADDR_CID_LOCAL, nothing listening
except OSError as exc:
    # Anything but "the stack refused to work at all" counts as working.
    if exc.errno in (errno.EPERM, errno.EACCES, errno.EAFNOSUPPORT):
        raise SystemExit(1)
')
    out[docker_run]=$(probe x timeout 60 docker run --rm hello-world)
    out[docker_module_autoload]=$(probe x sudo modprobe -q br_netfilter)
    out[k3s_modules]=$(probe x sudo modprobe -q overlay)
    out[iptables]=$(probe x sudo iptables -L -n)
    if command -v kexec > /dev/null 2>&1; then
        out[kexec_load]=$(probe x sudo kexec -l /boot/vmlinuz-"$(uname -r)" --reuse-cmdline)
    else
        out[kexec_load]="no-tool"
    fi
}

echo "kernel:    $(uname -r)"
echo "lockdown:  $(cat $LOCKDOWN 2>/dev/null)"
echo "LSMs:      $(cat /sys/kernel/security/lsm 2>/dev/null)"
echo "sig_enforce: $(cat /sys/module/module/parameters/sig_enforce 2>/dev/null)"

# A tiny unsigned module, so "can root still load unsigned code" is a real test
# and not an inference.
if [ ! -f /tmp/lockdown-probe.ko ]; then
    tmp=$(mktemp -d)
    cat > "$tmp/lockdown_probe.c" <<'EOF'
#include <linux/module.h>
static int __init p(void) { return 0; }
static void __exit q(void) { }
module_init(p); module_exit(q);
MODULE_LICENSE("GPL");
EOF
    echo 'obj-m := lockdown_probe.o' > "$tmp/Makefile"
    make -C "/lib/modules/$(uname -r)/build" M="$tmp" modules > /dev/null 2>&1 \
        && cp "$tmp/lockdown_probe.ko" /tmp/lockdown-probe.ko
    rm -rf "$tmp"
fi

echo
echo "--- probing (lockdown=$(cat $LOCKDOWN | grep -o '\[[a-z]*\]' | tr -d '[]')) ---"
run_probes BEFORE

if [ "$RAISE" = "1" ]; then
    echo
    echo "--- raising lockdown to $LEVEL (ONE-WAY) ---"
    echo "$LEVEL" | sudo tee $LOCKDOWN > /dev/null
    echo "lockdown is now: $(cat $LOCKDOWN)"
    echo
    echo "--- re-probing ---"
    run_probes AFTER
fi

echo
printf '%-28s %-10s %-10s\n' "surface" "before" "after"
printf '%-28s %-10s %-10s\n' "----------------------------" "----------" "----------"
for key in "${!BEFORE[@]}"; do
    printf '%-28s %-10s %-10s\n' "$key" "${BEFORE[$key]}" "${AFTER[$key]:--}"
done | sort

echo
if [ "$RAISE" = "1" ]; then
    echo "NOTE: this VM is now locked down for the rest of this boot. Reboot to reset."
else
    echo "NOTE: pass --raise (or --confidentiality) to measure the 'after'"
    echo "      column. It cannot be undone without a reboot."
fi
