#!/usr/bin/env bash
# Exercise the sentry end to end inside the guest.
#
# Loads the TESTABLE build (which has an exit path, so the run is reversible),
# points it at VMADDR_CID_LOCAL instead of the host, drives some activity, and
# checks what came out of the vsock. The shipped build differs only in having no
# exit path; everything under test here is identical code.
#
# Run: tests/test_sentry.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SENTRY="$ROOT/sentry"
PORT=${PORT:-5841}
SECONDS_TO_WATCH=${SECONDS_TO_WATCH:-12}
FRAMES=$(mktemp /tmp/sentry-frames-XXXXXX.json)
WORK_KO=$(mktemp /tmp/sentry-corrupt-XXXXXX.ko)
SINK_LOG=$(mktemp /tmp/sentry-sink-XXXXXX.log)
fails=0

say() { printf '\n=== %s ===\n' "$1"; }
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi
}

cleanup() {
    sudo rmmod bromure_sentry 2>/dev/null
    rm -f "$FRAMES" "$SINK_LOG"
}
trap cleanup EXIT

say "build (testable)"
make -C "$SENTRY" clean >/dev/null 2>&1
make -C "$SENTRY" EXTRA_CFLAGS=-DBROMURE_SENTRY_TESTABLE >/dev/null 2>&1 \
    || { echo "  FAIL build"; exit 1; }
echo "  ok   built $(basename "$SENTRY")/bromure_sentry.ko"

# Lockdown refuses unsigned modules at `integrity` and above, and it is one-way
# for the life of the boot -- so on a VM where anything has raised it, this suite
# cannot load its own build. SKIPPING LOUDLY rather than failing obscurely, and
# never silently: a suite that quietly reports success when it ran nothing is the
# exact failure this project keeps paying for.
LOCKDOWN_NOW=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/security/lockdown 2>/dev/null)
if [ -n "$LOCKDOWN_NOW" ] && [ "$LOCKDOWN_NOW" != "none" ]; then
    printf '\n'
    printf '  SKIPPED: this VM is at lockdown=%s, which refuses unsigned\n' "$LOCKDOWN_NOW"
    printf '           modules. Lockdown is one-way until reboot, so the sentry\n'
    printf '           suite cannot load its build here. Run it on a fresh VM.\n'
    printf '\n  THE SENTRY SUITE DID NOT RUN.\n\n'
    exit 77
fi

say "loopback transport"
sudo modprobe vsock_loopback 2>/dev/null
sudo rmmod bromure_sentry 2>/dev/null

python3 "$HERE/vsock_sink.py" --port "$PORT" --seconds "$SECONDS_TO_WATCH" \
    --json-out "$FRAMES" > "$SINK_LOG" 2>&1 &
SINK=$!
sleep 1

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
LL_ABI=$(python3 -c "import sys;sys.path.insert(0,'$ROOT');import bromure_openshell as b;a=b.probe_availability();print(a.abi or 0)")
# VMADDR_CID_LOCAL = 1: the same code path as CID 2, without needing the host.
sudo insmod "$SENTRY/bromure_sentry.ko" cid=1 port="$PORT" \
    boot_id="$BOOT_ID" landlock_abi="$LL_ABI" || { echo "  FAIL insmod"; exit 1; }
echo "  ok   loaded (cid=1 port=$PORT landlock_abi=$LL_ABI)"

say "phase"
# Everything Bromure's own root helpers do while the VM is being assembled must
# be informational, not an event. The supervisor flips this when it starts the
# tmux server, i.e. when agent code becomes possible.
check "starts in the boot phase" \
    "$(sudo cat /sys/module/bromure_sentry/parameters/phase)" "0"

# The phase must be ONE-WAY. The host treats `phase: boot` as informational, so a
# writable-back parameter would hand a root agent -- which the non-strict mode
# still permits -- a one-line way to downgrade all of its own activity: write 0,
# act, and every event is counted-only.
echo 1 | sudo tee /sys/module/bromure_sentry/parameters/phase > /dev/null
check "advances to session" \
    "$(sudo cat /sys/module/bromure_sentry/parameters/phase)" "1"
if echo 0 | sudo tee /sys/module/bromure_sentry/parameters/phase > /dev/null 2>&1; then
    echo "  FAIL root put the phase back to boot"; fails=$((fails + 1))
else
    echo "  ok   returning to the boot phase is refused, even for root"
fi
check "still session after the refused write" \
    "$(sudo cat /sys/module/bromure_sentry/parameters/phase)" "1"
check "an invalid phase is rejected" \
    "$(echo 7 | sudo tee /sys/module/bromure_sentry/parameters/phase > /dev/null 2>&1 \
        && echo accepted || echo rejected)" "rejected"

# The sandbox cgroup is one-way too: root must not be able to point it at a
# cgroup the agent does not live in and have its own activity reported as
# Bromure's.
#
# A REAL cgroup, not a made-up number: the denial section below puts a landlocked
# process into it, and every `sandboxed` field and every tally depends on the id
# here being one a task can actually join. The first version used 4242, which
# made the one-way assertions pass and every denial assertion silently
# unreachable -- the probes fired for nobody.
DENY_CG=/sys/fs/cgroup/sentrytest-denials
sudo rmdir "$DENY_CG" 2>/dev/null; sudo mkdir -p "$DENY_CG"
DENY_CGID=$(stat -c %i "$DENY_CG")
echo "$DENY_CGID" | sudo tee /sys/module/bromure_sentry/parameters/sandbox_cgroup > /dev/null
check "the sandbox cgroup can be set once" \
    "$(sudo cat /sys/module/bromure_sentry/parameters/sandbox_cgroup)" "$DENY_CGID"
if echo 9999 | sudo tee /sys/module/bromure_sentry/parameters/sandbox_cgroup > /dev/null 2>&1; then
    echo "  FAIL root changed the sandbox cgroup after it was set"; fails=$((fails + 1))
else
    echo "  ok   changing the sandbox cgroup is refused, even for root"
fi
check "it is unchanged after the refusal" \
    "$(sudo cat /sys/module/bromure_sentry/parameters/sandbox_cgroup)" "$DENY_CGID"

say "drive activity"
/bin/true
/bin/echo hi > /dev/null
(exec 3<>/dev/tcp/127.0.0.1/9 ) 2>/dev/null
id -u > /dev/null
sudo -n true 2>/dev/null                 # setuid/setresuid + exec
cat /etc/hostname > /dev/null
# The loopback connect stays as activity, but it no longer names a kind: the
# `connect` kind is retired, and a loopback flow is counted rather than emitted.
echo "  ok   drove exec / a loopback TCP connect / setuid"

say "drive the remaining alarm-class syscalls"
# Seven alarm-class kinds were registered and unproven. Two probes in this module
# turned out to be incapable of firing, so "registered" earns no benefit of the
# doubt: each of these is now driven for real.
#
# Every one of them is an ENTRY kprobe on `__arm64_sys_*`, so the ATTEMPT is what
# fires it -- EINVAL from setns and EPERM from mount are expected and fine.
# Verified with tracefs first: 1 unshare, 1 setns, 1 mount and 2 ptrace calls
# reach those entry points from this script.
python3 - <<'PY'
import ctypes, ctypes.util, os, signal, time

libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
libc.syscall.restype = ctypes.c_long
SYS_mount, SYS_ptrace, SYS_setns = 40, 117, 268
CLONE_NEWUSER = 0x10000000
PTRACE_ATTACH, PTRACE_DETACH = 16, 17

# unshare: an unprivileged user namespace, which succeeds.
pid = os.fork()
if pid == 0:
    try:
        os.unshare(CLONE_NEWUSER)
    except OSError:
        pass
    os._exit(0)
os.waitpid(pid, 0)

# setns: to our own user namespace. EINVAL; the entry is what fires.
fd = os.open("/proc/self/ns/user", os.O_RDONLY)
libc.syscall(ctypes.c_long(SYS_setns), ctypes.c_long(fd),
             ctypes.c_long(CLONE_NEWUSER))
os.close(fd)

# mount: the SYSCALL, not /usr/bin/mount -- that is setuid root, so it would
# both succeed and add a cred_gain of its own, testing the wrong thing.
os.makedirs("/tmp/bromure-mount-probe", exist_ok=True)
libc.syscall(ctypes.c_long(SYS_mount), b"none", b"/tmp/bromure-mount-probe",
             b"tmpfs", ctypes.c_long(0), None)

# ptrace: PTRACE_ATTACH to our own child, which Yama's ptrace_scope permits.
child = os.fork()
if child == 0:
    time.sleep(3)
    os._exit(0)
time.sleep(0.2)
libc.syscall(ctypes.c_long(SYS_ptrace), ctypes.c_long(PTRACE_ATTACH),
             ctypes.c_long(child), 0, 0)
try:
    os.waitpid(child, 0)
    libc.syscall(ctypes.c_long(SYS_ptrace), ctypes.c_long(PTRACE_DETACH),
                 ctypes.c_long(child), 0, 0)
except OSError:
    pass
try:
    os.kill(child, signal.SIGKILL)
    os.waitpid(child, 0)
except OSError:
    pass
os.rmdir("/tmp/bromure-mount-probe")
PY
echo "  ok   drove unshare, setns, mount and ptrace"

say "sandbox denials: drive them"
# The user's question is "is the agent trying to get out of its permissions?".
# Until round 19 the only answer was a denied open -- and that probe had never
# fired once, because `regs_return_value()` returns the raw 64-bit register and
# every `security_*` hook returns `int`, so -EACCES arrived as 4294967283 and the
# comparison against -13 never matched. Nothing caught it because no test ever
# asserted that a denial produced an EVENT; the suite checked the probe was
# REGISTERED, which it always was. Hence this section.
DENY_W=$(mktemp -d /tmp/sentry-deny-XXXXXX); chmod 0755 "$DENY_W"
mkdir -p "$DENY_W/ro" "$DENY_W/rw" "$DENY_W/offpolicy"
echo hello > "$DENY_W/ro/file"
cp /bin/true "$DENY_W/offpolicy/prog"; chmod +x "$DENY_W/offpolicy/prog"
sudo python3 - "$DENY_W" "$DENY_CG" "$ROOT" > "$DENY_W/child.log" 2>&1 <<'PY'
import importlib.util, os, sys
work, cg, root = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("osh", root + "/bromure_openshell.py")
osh = importlib.util.module_from_spec(spec); spec.loader.exec_module(osh)
pid = os.fork()
if pid == 0:
    open(os.path.join(cg, "cgroup.procs"), "w").write(str(os.getpid()))
    pol = osh.SandboxPolicy.from_json({
        "filesystem_policy": {
            "read_only": ["/usr", "/lib", "/etc", "/proc", work + "/ro"],
            "read_write": [work + "/rw", "/dev/null"],
            "include_workdir": False},
        "landlock": {"compatibility": "best_effort"}})
    prepared, outcome = osh.prepare(pol, workdir=None,
                                    path_open_mode=osh.PRIVILEGED)
    osh.enforce_landlock_privileged(prepared, outcome)
    def attempt(fn):
        try:
            fn()
        except Exception:
            pass
    attempt(lambda: open("/etc/sentry-denial-probe", "w"))     # create
    attempt(lambda: os.mkdir("/opt/sentry-denial-probe"))      # mkdir
    attempt(lambda: os.unlink(work + "/ro/file"))              # unlink
    attempt(lambda: os.rename(work + "/ro/file", work + "/ro/x"))
    attempt(lambda: os.symlink("/tmp", work + "/ro/link"))     # symlink
    attempt(lambda: os.truncate(work + "/ro/file", 0))         # truncate
    attempt(lambda: os.execv(work + "/offpolicy/prog", ["prog"]))  # exec
    # A hundred identical attempts, for the dedup count.
    for _ in range(100):
        attempt(lambda: open("/etc/sentry-denial-burst", "w"))
    # Allowed work, so `allowed_file_ops` has something to compare against.
    for _ in range(25):
        open(work + "/rw/ok", "w").close()
    os._exit(0)
os.waitpid(pid, 0)
PY

# And a seccomp denial, which is a different probe (audit_seccomp) and a
# different filter flag (SECCOMP_FILTER_FLAG_LOG).
sudo python3 - "$DENY_CG" "$ROOT" >> "$DENY_W/child.log" 2>&1 <<'PY'
import importlib.util, os, sys
cg, root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("osh", root + "/bromure_openshell.py")
osh = importlib.util.module_from_spec(spec); spec.loader.exec_module(osh)
pid = os.fork()
if pid == 0:
    open(os.path.join(cg, "cgroup.procs"), "w").write(str(os.getpid()))
    osh.harden_child_process()
    osh.apply_seccomp(supervisor_tgid=os.getppid(), allow_inet=True)
    for _ in range(30):
        try:
            os.unshare(0x00020000)
        except OSError:
            pass
    try:
        os.setns(0, 0)
    except OSError:
        pass
    os._exit(0)
os.waitpid(pid, 0)
PY
sudo rm -f /etc/sentry-denial-probe /etc/sentry-denial-burst 2>/dev/null
sudo rmdir /opt/sentry-denial-probe 2>/dev/null
echo "  ok   drove 7 denied file operations, 100 identical ones and 31 blocked syscalls"

say "noise: one idle-ish minute must not look like an attack"
# The shipping blocker from the first end-to-end run: entry probes on
# set*uid/set*gid/capset fired on every call a healthy machine makes -- every
# privilege DROP by systemd, PAM and cron, and every FAILED call too, since an
# entry probe runs before the kernel decides. One idle minute produced 924
# events and tripped the host's watchdog with nobody doing anything.
#
# So: do the noisy things on purpose, and assert the stream stays quiet.
SUDOS=20
for _ in $(seq 1 $SUDOS); do sudo -n true 2>/dev/null; done
# Signed in-tree modules, the way dockerd pulls them in.
sudo modprobe -q overlay 2>/dev/null
sudo modprobe -q br_netfilter 2>/dev/null
# A privilege DROP, which must produce nothing.
sudo -n setpriv --reuid=1000 --regid=1000 --clear-groups true 2>/dev/null
# A REFUSED module load. The `load_module` kretprobe had the same 64-bit return
# bug as the denial probes: `load_module()` returns int, the raw register is not
# sign-extended, so -ENOEXEC arrived as 4294967158, `ret >= 0` was true, and the
# probe returned early on every refused module. It had never reported one.
printf 'not a module at all' > "$WORK_KO"
sudo insmod "$WORK_KO" 2>/dev/null
echo "  ok   drove 20 sudos, two signed module loads, a privilege drop and one refused module"

say "tamper attempts"
# As the unprivileged agent user.
out=$(rmmod bromure_sentry 2>&1); check "rmmod as non-root refused" "$?" "1"
# The kthread has no fd, so there is nothing in /proc to close.
count=$(sudo ls -l /proc/$(pgrep -f '^\[?bromure_sentry' | head -1)/fd 2>/dev/null | wc -l)
printf '  info kthread visible fds: %s\n' "${count:-0}"
# The secret digest must be root-only.
mode=$(stat -c %a /sys/module/bromure_sentry/parameters/secret_digest 2>/dev/null)
check "secret_digest mode" "$mode" "400"
if cat /sys/module/bromure_sentry/parameters/secret_digest >/dev/null 2>&1; then
    echo "  FAIL secret_digest readable by non-root"; fails=$((fails + 1))
else
    echo "  ok   secret_digest not readable by non-root"
fi
digest=$(sudo cat /sys/module/bromure_sentry/parameters/secret_digest)
check "secret_digest length" "${#digest}" "64"

# The shipped build holds a module reference for good. Exercise the same
# __module_get here, where it can be released again, and confirm rmmod refuses
# while it is held. The other half of the refusal -- "a module with no exit
# function is rejected with -EBUSY" -- is a kernel invariant in
# kernel/module/main.c, and this kernel has CONFIG_MODULE_FORCE_UNLOAD unset so
# there is no `rmmod -f` to fall back on. Both configs are asserted below.
echo 1 | sudo tee /sys/module/bromure_sentry/parameters/pin > /dev/null
if sudo rmmod bromure_sentry 2>/dev/null; then
    echo "  FAIL rmmod succeeded while a module reference was held"
    fails=$((fails + 1))
else
    echo "  ok   rmmod refused while a module reference is held"
fi
check "refcnt while pinned" "$(cat /sys/module/bromure_sentry/refcnt)" "1"
echo 0 | sudo tee /sys/module/bromure_sentry/parameters/pin > /dev/null
check "refcnt after unpin" "$(cat /sys/module/bromure_sentry/refcnt)" "0"
check "CONFIG_MODULE_FORCE_UNLOAD unset" \
    "$(grep -c '^CONFIG_MODULE_FORCE_UNLOAD=y' /boot/config-$(uname -r))" "0"

# Blinding: disarming kprobes globally must show up in the heartbeat.
say_armed_before=$(sudo cat /sys/kernel/debug/kprobes/enabled 2>/dev/null || echo "?")
printf '  info /sys/kernel/debug/kprobes/enabled = %s\n' "$say_armed_before"
if echo 0 | sudo tee /sys/kernel/debug/kprobes/enabled > /dev/null 2>&1; then
    echo "  info global kprobe switch is writable (pre-lockdown) -- blinding attempted"
    sleep 2
    echo 1 | sudo tee /sys/kernel/debug/kprobes/enabled > /dev/null 2>&1
    BLINDED=1
else
    echo "  info global kprobe switch not writable here"
    BLINDED=0
fi

say "collect"
wait "$SINK"
sink_status=$?
cat "$SINK_LOG"
check "sink verdict" "$sink_status" "0"

if [ -s "$FRAMES" ]; then
    BLINDED="$BLINDED" python3 - "$FRAMES" "$digest" <<'PY'
import hashlib, json, sys
frames = json.load(open(sys.argv[1]))
expected_digest = sys.argv[2]
hello = frames[0]
secret = hello["secret"]
actual = hashlib.sha256(secret.encode()).hexdigest()
print("  %s hello secret hashes to the exposed digest"
      % ("ok  " if actual == expected_digest else "FAIL"))
if actual != expected_digest:
    print("       digest=%s sha256(secret)=%s" % (expected_digest, actual))
    sys.exit(1)
kinds = {}
for frame in frames:
    if frame.get("type") == "event":
        kinds[frame["kind"]] = kinds.get(frame["kind"], 0) + 1
print("  ok   event kinds seen: %s" % json.dumps(kinds, sort_keys=True))
for required in ("exec",):
    if required not in kinds:
        print("  FAIL no %s events captured" % required)
        sys.exit(1)

# --- event semantics ---------------------------------------------------
events = [f for f in frames if f.get("type") == "event"]

# The retired kinds must not appear at all.
# `connect` is retired too: `net_flow` reports the same connection with the
# protocol, the source port, the start time and the ancestor chain, and folds
# repeats instead of emitting one event per call. The probe on
# `security_socket_connect` is gone; the ABI number stays reserved.
retired = {k: kinds.get(k, 0)
           for k in ("setuid", "setgid", "capset", "connect")}
if any(retired.values()):
    print("  FAIL retired per-syscall kinds are still emitted: %s" % retired)
    sys.exit(1)
print("  ok   setuid/setgid/capset are counted and `connect` is retired, "
      "so none of them is emitted")

beats = [f for f in frames if f.get("type") == "heartbeat"]
tallies = [b.get("tallies") for b in beats if b.get("tallies")]
if not tallies:
    print("  FAIL heartbeats carry no tallies")
    sys.exit(1)
last = tallies[-1]
if last.get("setuid", 0) + last.get("cred_drop", 0) == 0:
    print("  FAIL the tallies never moved, so the calls are not being counted "
          "either: %s" % last)
    sys.exit(1)
print("  ok   the calls ARE counted: %s" % json.dumps(last, sort_keys=True))

# `sudo` is setuid root, so each one is a real credential gain, reported once.
# `sudo` is setuid root, so each invocation is ONE real gain -- and only one.
# The naive rule gave about five per sudo: the setuid exec, sudo making it
# permanent with setresuid, and sudo's own juggling through uid 1. Only the first
# is an escalation; after the setuid exec sudo holds saved-uid 0 and a full
# permitted set, so re-taking root is not news. Measured: 55 events for five
# sudos became 10 for ten sudos, all via exec.
gains = [e for e in events if e["kind"] == "cred_gain"]
by_exec = [g for g in gains if g.get("via") == "exec"]
to_root = [g for g in gains if g.get("new_uid") == 0]
print("  ok   %d cred_gain, %d via exec, %d gaining uid 0"
      % (len(gains), len(by_exec), len(to_root)))
if not to_root:
    print("  FAIL no cred_gain reported reaching uid 0")
    sys.exit(1)
if len(gains) != len(by_exec):
    print("  FAIL %d cred_gain did NOT come from a setuid exec; a task "
          "re-taking authority it already held is not an escalation"
          % (len(gains) - len(by_exec)))
    for g in gains:
        if g.get("via") != "exec":
            print("       %s" % json.dumps(g, sort_keys=True))
            break
    sys.exit(1)
print("  ok   every cred_gain came from a setuid exec, none from re-assertion")
# The suppressed ones must still be counted, or the quiet is indistinguishable
# from the probe being broken.
if last.get("cred_reassert", 0) == 0 and last.get("cred_drop", 0) == 0:
    print("  FAIL nothing was counted as drop/re-assert, so the suppression "
          "cannot be distinguished from a dead probe")
    sys.exit(1)
print("  ok   the suppressed transitions are counted (reassert=%d drop=%d)"
      % (last.get("cred_reassert", 0), last.get("cred_drop", 0)))
for field in ("old_uid", "new_uid", "old_caps", "new_caps", "via", "phase"):
    if field not in gains[0]:
        print("  FAIL cred_gain is missing %r: %s" % (field, gains[0]))
        sys.exit(1)
print("  ok   cred_gain carries old/new uid, old/new caps, via and phase")

# Module loads must name themselves and say whether they were signed.
mods = [e for e in events if e["kind"] == "module_load"]
signed = [m for m in mods if m.get("signed")]
print("  ok   %d module_load, %d reporting signed=true, names: %s"
      % (len(mods), len(signed),
         ", ".join(sorted({m.get("name", "?") for m in mods}))[:90]))
for m in mods:
    for field in ("name", "signed", "result", "phase"):
        if field not in m:
            print("  FAIL module_load is missing %r: %s" % (field, m))
            sys.exit(1)

# The loader's own raise to integrity must never look like tampering.
lock = [e for e in events if e["kind"] == "lockdown_change_attempt"]
bad_lock = [e for e in lock if not e.get("lowering") and e.get("result", -1) >= 0]
if bad_lock:
    print("  FAIL a successful lockdown raise was reported as an attempt: %s"
          % bad_lock[0])
    sys.exit(1)
print("  ok   %d lockdown_change_attempt (only rejected writes qualify)" % len(lock))

# And every event says which phase it belongs to.
missing_phase = [e for e in events if "phase" not in e]
if missing_phase:
    print("  FAIL %d events carry no phase" % len(missing_phase))
    sys.exit(1)
print("  ok   every event carries a phase")

# Every event says whether its task was inside the sandbox's cgroup. Under strict
# that is what separates an escalation -- impossible there, because of
# no_new_privs -- from one of Bromure's own helpers doing something ordinary.
missing_sandboxed = [e for e in events if "sandboxed" not in e]
if missing_sandboxed:
    print("  FAIL %d events carry no `sandboxed` flag" % len(missing_sandboxed))
    sys.exit(1)
print("  ok   every event carries `sandboxed` (all %s here, since this test "
      "sets no sandbox cgroup)"
      % sorted({e["sandboxed"] for e in events}))

# bpf_load must say which command and program type, so systemd's cgroup and
# device programs at boot are distinguishable from anything else.
bpf = [e for e in events if e["kind"] == "bpf_load"]
for e in bpf:
    if "cmd" not in e or "prog_type" not in e:
        print("  FAIL bpf_load is missing cmd/prog_type: %s" % e)
        sys.exit(1)
print("  ok   %d bpf_load, each with cmd and prog_type" % len(bpf))

# The reconnect proof. Only the first hello may carry the secret in the clear;
# root can read it out of module memory through /proc/kcore under `integrity`,
# so a reconnect that repeated it would be replayable by an impostor.
if hello.get("conn") != 0:
    print("  FAIL the first hello is conn %r, expected 0" % hello.get("conn"))
    sys.exit(1)
print("  ok   the first hello is conn 0 and carries the secret")
later = [f for f in frames if f.get("type") == "hello"][1:]
for h in later:
    if "secret" in h:
        print("  FAIL a reconnect repeated the secret in the clear: conn %s"
              % h.get("conn"))
        sys.exit(1)
    expect = hashlib.sha256(
        (secret + h["boot_id"] + str(h["conn"])).encode()).hexdigest()
    if h.get("proof") != expect:
        print("  FAIL reconnect conn %s proof mismatch" % h.get("conn"))
        sys.exit(1)
print("  ok   %d reconnect(s), each proving the secret without repeating it"
      % len(later))

# Whoever declared the phase is named, so the host can attribute a suspicious
# declaration instead of reporting an unattributed "the phase looks wrong".
for beat in beats:
    setter = beat.get("phase_set_by")
    if not isinstance(setter, dict) or "pid" not in setter or "comm" not in setter:
        print("  FAIL heartbeat carries no phase_set_by: %s" % beat.get("seq"))
        sys.exit(1)
print("  ok   heartbeats name who declared the phase (%s)"
      % sorted({(b["phase_set_by"]["comm"] or "-") for b in beats}))

# Probe health must be present on every heartbeat and consistent with the hello.
declared = hello.get("probes")
if not isinstance(declared, list) or not declared:
    print("  FAIL hello carries no probe list")
    sys.exit(1)
print("  ok   hello declares %d probes" % len(declared))
beats = [f for f in frames if f.get("type") == "heartbeat"]
for beat in beats:
    health = beat.get("probes")
    if not isinstance(health, dict) or not {"armed", "total", "missed"} <= set(health):
        print("  FAIL heartbeat seq=%s has no probes{armed,total,missed}" % beat.get("seq"))
        sys.exit(1)
    if health["total"] != len(declared):
        print("  FAIL heartbeat total=%d but hello declared %d"
              % (health["total"], len(declared)))
        sys.exit(1)
armed_values = sorted({b["probes"]["armed"] for b in beats})
canaries = sorted({b["probes"].get("canary") for b in beats})
print("  ok   %d heartbeats carry probe health; armed seen: %s canary seen: %s"
      % (len(beats), armed_values, canaries))
# ftrace-based probes would be silently disarmed by `sysctl
# kernel.ftrace_enabled=0`, which root can write even under lockdown=integrity.
# On this kernel none of them are, and the count proves it rather than assuming.
ftrace_counts = sorted({b["probes"].get("ftrace") for b in beats})
print("  ok   ftrace-based probes: %s (0 means ftrace_enabled is irrelevant)"
      % ftrace_counts)
if any(c is None for c in ftrace_counts):
    print("  FAIL heartbeats do not report the ftrace probe count")
    sys.exit(1)
import os
if os.environ.get("BLINDED") == "1":
    # The test disarmed all kprobes globally for ~2s. That path leaves every
    # p->flags untouched, so this is the check that the canary -- not the flags
    # -- is what actually catches it.
    if False in canaries and 0 in armed_values:
        print("  ok   global kprobe disarm was reported to the host "
              "(canary=false, armed=0)")
    else:
        print("  FAIL global kprobe disarm went UNDETECTED: armed=%s canary=%s"
              % (armed_values, canaries))
        sys.exit(1)
PY
    [ $? -eq 0 ] || fails=$((fails + 1))
else
    echo "  FAIL no frames captured"; fails=$((fails + 1))
fi


# The shutdown phase has to be reachable from userspace -- the kernel has no hook
# for "systemd began stopping things" and the reboot notifier fires after the
# unmounts it exists to label. So the module records WHO declared it, and the
# host pairs that with a budget.
check "shutdown can be declared" \
    "$(echo 2 | sudo tee /sys/module/bromure_sentry/parameters/phase > /dev/null 2>&1 \
        && sudo cat /sys/module/bromure_sentry/parameters/phase)" "2"
if echo 1 | sudo tee /sys/module/bromure_sentry/parameters/phase > /dev/null 2>&1; then
    echo "  FAIL the phase moved backwards from shutdown to session"
    fails=$((fails + 1))
else
    echo "  ok   the phase cannot move back from shutdown"
fi

say "sandbox denials: what arrived"
if [ -s "$FRAMES" ]; then
    python3 - "$FRAMES" <<'PY'
import json, sys, collections
frames = json.load(open(sys.argv[1]))
den = [f for f in frames if f.get("kind") == "sandbox_denied"]
sec = [f for f in frames if f.get("kind") == "seccomp_denied"]
fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

by_op = collections.defaultdict(list)
for f in den:
    by_op[f.get("op")].append(f)

# One event for each operation, with the right op AND the right path. The path
# is the half that proves the probe read the arguments rather than merely fired.
EXPECT = {
    "create":   "/etc/sentry-denial-probe",
    "mkdir":    "/opt/sentry-denial-probe",
    "unlink":   "/ro/file",
    "rename":   "/ro/file",
    "symlink":  "/ro/link",
    "truncate": "/ro/file",
}
for op, needle in EXPECT.items():
    hit = [f for f in by_op.get(op, []) if needle in (f.get("path") or "")]
    if hit:
        ok("%-9s denial reported, path %s" % (op, hit[0]["path"]))
    else:
        bad("no %s denial naming %s (saw %s)"
            % (op, needle, [f.get("path") for f in by_op.get(op, [])]))

# A binary outside the policy. Landlock checks EXECUTE in file_open, so this
# arrives as an open, not as a bprm event -- which is why probing
# security_bprm_check would add nothing.
execs = [f for f in den if f.get("op") == "open_exec"]
if execs and "offpolicy/prog" in (execs[0].get("path") or ""):
    ok("a binary outside the policy is reported as open_exec (%s)" % execs[0]["path"])
else:
    bad("no open_exec denial for the off-policy binary (saw %s)"
        % [(f.get("op"), f.get("path")) for f in den][:8])

# Deduplication: one row for a hundred attempts, carrying the count. The
# alternative is not a hundred rows -- it is sixty-four rows and then silence, as
# the token bucket eats the rest.
burst = [f for f in den if "sentry-denial-burst" in (f.get("path") or "")]
if len(burst) == 1 and burst[0].get("count") == 100:
    ok("a hundred identical attempts are ONE event with count=100")
elif burst:
    bad("the burst produced %d event(s), counts %s"
        % (len(burst), [f.get("count") for f in burst]))
else:
    bad("the burst produced no event at all")

# Every denial must carry the fields the host renders.
for f in den[:1] or [{}]:
    missing = [k for k in ("op", "hook", "errno", "count", "comm", "pid", "uid",
                           "sandboxed") if k not in f]
    if not missing:
        ok("denials carry op/hook/errno/count/comm/pid/uid/sandboxed")
    else:
        bad("a denial is missing %s" % missing)
if den and all(f.get("sandboxed") is True for f in den):
    ok("and every one is marked sandboxed (they are attributed by cgroup)")
elif den:
    bad("a denial was reported for an unsandboxed task")

# seccomp: the syscalls are distinguished, not merged.
nrs = {f.get("syscall") for f in sec}
if len(nrs) >= 2:
    ok("seccomp denials are reported per syscall (%s)" % sorted(nrs))
else:
    bad("seccomp denials collapsed into %s -- the dedup key must include the "
        "syscall number" % sorted(nrs))
if sec and all(f.get("action") == "errno" for f in sec):
    ok("with the action the filter actually took (errno)")
elif sec:
    bad("unexpected seccomp actions: %s" % {f.get("action") for f in sec})
unshare = [f for f in sec if f.get("count", 0) > 1]
if unshare:
    ok("and the repeated one is deduplicated (count=%d)" % unshare[0]["count"])
else:
    bad("no seccomp denial carried a count > 1")

# Tallies. `allowed` is what makes `denied` mean anything.
beats = [f for f in frames if f.get("type") == "heartbeat" and f.get("sandbox")]
if beats:
    last = beats[-1]["sandbox"]
    if last.get("denied_file_ops", 0) >= 100 and last.get("allowed_file_ops", 0) > 0:
        ok("heartbeat tallies moved: %s" % json.dumps(last))
    else:
        bad("tallies did not move as expected: %s" % json.dumps(last))
else:
    bad("no heartbeat carried the sandbox tallies")

# And the thing the rate limiter must never do to a burst.
drops = [f for f in frames if f.get("type") == "heartbeat"]
if drops and drops[-1].get("dropped", 0) == 0:
    ok("nothing was dropped (the dedup window is what absorbs a burst)")
elif drops:
    bad("events were dropped: %s" % drops[-1].get("dropped"))
sys.exit(1 if fails else 0)
PY
    [ $? -eq 0 ] || fails=$((fails + 1))
else
    echo "  FAIL no frames to check denials against"; fails=$((fails + 1))
fi
sudo rmdir "$DENY_CG" 2>/dev/null; sudo rm -rf "$DENY_W"

say "every alarm-class probe FIRES, not merely registers"
# The lesson from two probes that registered perfectly and could never fire:
# `file_open_denied` and the `load_module` refusal both compared a non
# sign-extended 64-bit register against a negative errno, so neither had ever
# produced an event since the day it was written. The suite was green throughout,
# because it asserted that probes were REGISTERED.
#
# So: for every kind this test actually triggers, assert an event arrived. The
# kinds it does NOT trigger are named too -- an honest gap beats an implied
# guarantee.
if [ -s "$FRAMES" ]; then
    python3 - "$FRAMES" <<'PY'
import json, sys, collections
frames = json.load(open(sys.argv[1]))
seen = collections.Counter(f.get("kind") for f in frames if f.get("type") == "event")
fails = 0

# Driven by this test, and therefore required to appear.
DRIVEN = {
    "exec":            "/bin/true and friends",
    # NOT `connect`. The kind was retired in favour of `net_flow`, so requiring
    # it to fire asserted the opposite of what the retired-kinds check below
    # asserts -- the suite contradicted itself, and only a run on a VM that can
    # load the module could notice. `net_flow` is not here either: it needs an
    # AF_INET destination and its own drivers, which `test_net_flow.sh` has.
    "cred_gain":       "sudo -n true",
    "module_load":     "modprobe overlay / br_netfilter, plus one refused",
    "sandbox_denied":  "seven denied file operations",
    "seccomp_denied":  "unshare and setns under the filter",
    # Promoted from "opportunistic" once they were actually driven. Two probes in
    # this module registered and could never fire, so an unproven probe is a
    # probe that does not work until shown otherwise.
    "unshare":         "an unprivileged user namespace",
    "setns":           "setns to our own userns (EINVAL is fine; entry fires)",
    "mount":           "a mount(2) that EPERMs",
    "ptrace":          "PTRACE_ATTACH to our own child",
}
for kind, how in DRIVEN.items():
    if seen.get(kind):
        print("  ok   %-16s fires (%d, from %s)" % (kind, seen[kind], how))
    else:
        print("  FAIL %-16s NEVER FIRED, though this test triggered it (%s)"
              % (kind, how)); fails += 1

# Triggered but not guaranteed: these depend on the machine's state, so their
# absence is not a failure -- but their presence is worth printing, because a
# kind that never appears in any run is a probe nobody has ever seen work.
# Left to a dedicated run on a throwaway VM: loading a BPF program, kexec and
# a lockdown write all change the machine in ways a test suite should not.
OPPORTUNISTIC = ("bpf_load", "kexec_attempt", "lockdown_change_attempt")
present = [k for k in OPPORTUNISTIC if seen.get(k)]
absent = [k for k in OPPORTUNISTIC if not seen.get(k)]
# A user namespace must NOT read as a privilege gain.
#
# `unshare(CLONE_NEWUSER)` hands the task a full capability set inside its new
# namespace -- CapPrm 0 -> 0x1ffffffffff, global uid unchanged -- and the module
# reported that as a `cred_gain`. It is authority over nothing the init namespace
# owns, and it made every rootless container, bwrap, Chrome sandbox and test
# runner look like an escalation: weight 20 from a sandboxed task under strict,
# enough to quarantine a workspace for doing something ordinary.
#
# Found by the unshare driver added one round earlier, which is the whole point
# of driving these.
userns_gain = [f for f in frames
               if f.get("kind") == "cred_gain"
               and f.get("via") == "syscall"
               and f.get("new_uid") == f.get("old_uid")
               and (f.get("new_caps") or 0) > (f.get("old_caps") or 0)]
if userns_gain:
    print("  FAIL a user namespace was reported as a credential gain: %s"
          % json.dumps(userns_gain[0])); fails += 1
else:
    print("  ok   creating a user namespace is not reported as a cred_gain")
beats = [f for f in frames if f.get("type") == "heartbeat" and f.get("sandbox")]
if beats and beats[-1]["sandbox"].get("caps_in_userns", 0) >= 1:
    print("  ok   and it is COUNTED (caps_in_userns=%d), not silently dropped"
          % beats[-1]["sandbox"]["caps_in_userns"])
else:
    print("  FAIL the suppressed cap gain was not counted: %s"
          % json.dumps(beats[-1].get("sandbox") if beats else None)); fails += 1

# The refusal specifically, which is the half that never worked: a module_load
# event carrying a negative result.
refused = [f for f in frames
           if f.get("kind") == "module_load" and (f.get("result") or 0) < 0]
if refused:
    print("  ok   a REFUSED module load is reported (result=%s)"
          % refused[0].get("result"))
else:
    print("  FAIL no module_load event carried a failure result; the refusal "
          "probe still never fires"); fails += 1

print("  info opportunistic kinds seen: %s" % (", ".join(present) or "none"))
print("  info not exercised by this run: %s" % (", ".join(absent) or "none"))
sys.exit(1 if fails else 0)
PY
    [ $? -eq 0 ] || fails=$((fails + 1))
else
    echo "  FAIL no frames"; fails=$((fails + 1))
fi
rm -f "$WORK_KO"

say "unload (testable build only)"
sudo rmmod bromure_sentry && echo "  ok   testable build unloads cleanly" \
    || { echo "  FAIL testable build would not unload"; fails=$((fails + 1)); }

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo "ALL SENTRY TESTS PASSED" || echo "$fails CHECK(S) FAILED")"
exit $((fails > 0))
