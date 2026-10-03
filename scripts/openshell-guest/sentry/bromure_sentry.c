// SPDX-License-Identifier: GPL-2.0
/*
 * bromure_sentry — a security event stream the guest cannot silence.
 *
 * The threat model is specific: the agent is assumed to be able to become root
 * inside the workspace VM. Anything root can stop is therefore not evidence.
 * So the capture, the buffering and the transport all live in the kernel, and
 * the module is built so that root's options are limited to "kill the whole
 * VM", which the host sees immediately as silence.
 *
 *   * Capture is kprobes, registered from kernel space.
 *     There is no bpffs pin to unpin, no BPF link to detach, no perf fd to
 *     close, and no userland daemon to kill.
 *   * Transport is an AF_VSOCK socket opened by a kthread with
 *     `sock_create_kern`. It has no file descriptor, so it does not appear in
 *     any /proc/<pid>/fd and cannot be closed from userland.
 *   * The module has no exit function. `delete_module` refuses a module with no
 *     exit routine (-EBUSY) unless MODULE_FORCE_UNLOAD is configured, which it
 *     is not on Ubuntu's kernels; `__module_get` on top makes the refcount
 *     nonzero as well, so even a forcing kernel would refuse.
 *   * After the loader raises lockdown to `integrity`, root can no longer load
 *     a module to undo any of this, write kernel memory through /dev/mem, or
 *     kexec a kernel that never had the sentry.
 *
 * What remains possible for guest root: crashing or powering off the VM. The
 * host detects that as missing heartbeats, which is the point of the sequence
 * numbers.
 *
 * Wire format (host listens on CID 2, port 5841; the guest connects):
 *   u32 big-endian length, then that many bytes of UTF-8 JSON.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kthread.h>
#include <linux/kfifo.h>
#include <linux/spinlock.h>
#include <linux/random.h>
#include <linux/net.h>
#include <linux/socket.h>
#include <linux/vm_sockets.h>
#include <linux/kprobes.h>
#include <linux/sched.h>
#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/dcache.h>
#include <linux/binfmts.h>
#include <linux/delay.h>
#include <linux/inet.h>
#include <linux/in.h>
#include <linux/in6.h>
#include <linux/crypto.h>
#include <linux/utsname.h>
#include <crypto/hash.h>
#include <linux/cgroup.h>
#include <linux/reboot.h>
#include <linux/notifier.h>
#include <net/sock.h>
#include <net/ipv6.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/netfilter_ipv6.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <net/dsfield.h>
#include <linux/netlink.h>
#include <net/netlink.h>
#include <linux/rtnetlink.h>

#include "bromure_sentry.h"

#ifndef CONFIG_ARM64
#error "bromure_sentry reads syscall arguments through arm64's pt_regs wrapper convention"
#endif

#define SENTRY_NAME    "bromure_sentry"
#define SENTRY_VERSION "1.0.0"

/* Ring capacity in events. A power of two, as kfifo requires. */
/* 256, not 1024. The event grew from ~460 bytes to ~1.7 KB when argv and the
 * ancestor chain were added, and the fifo is allocated once in whole events:
 * 1024 of them would be 1.8 MB of kernel memory held for a burst that never
 * comes. The drain thread wakes on every submit, so this has to cover a burst,
 * not a backlog. */
#define SENTRY_FIFO_EVENTS 256
/* Per-kind token bucket: this many events per refill window, refilled 1/s. */
#define SENTRY_TOKENS_PER_SEC 64
#define SENTRY_TOKENS_BURST   256
/* Heartbeat period. */
#define SENTRY_HEARTBEAT_MS 1000
/* Give up on one send after this long rather than wedging the kthread. */
#define SENTRY_SEND_TIMEOUT_S 5
/* Upper bound on one rendered frame. */
/* argv is 1024 bytes and JSON-escaping is up to 6 bytes per byte (\uXXXX for
 * anything non-ASCII), so the worst case is ~6 KB for argv alone, plus the
 * chain. A truncated frame is invalid JSON rather than a short one, so this is
 * sized for the worst case and not the common one. */
#define SENTRY_JSON_MAX 12288

static unsigned int sentry_cid = 2;	/* VMADDR_CID_HOST */
module_param_named(cid, sentry_cid, uint, 0444);
MODULE_PARM_DESC(cid, "vsock CID to stream to (2 = host)");

static unsigned int sentry_port = 5841;
module_param_named(port, sentry_port, uint, 0444);
MODULE_PARM_DESC(port, "vsock port to stream to");

/*
 * The hello secret proves to the host that the peer on 5841 is the module and
 * not a userland impostor that won the race while the module failed to load.
 * The secret itself never leaves the kernel except inside the hello frame; what
 * is exposed here is only its digest, readable by root so attestd can echo it
 * back on the *other* channel (5840). The host then checks that the two agree.
 * A userland impostor can read this digest but cannot produce a preimage for it.
 */
static char sentry_secret[32];
static char sentry_secret_hex[65];
static char sentry_secret_digest[65];
static char *sentry_secret_digest_p = sentry_secret_digest;
module_param_named(secret_digest, sentry_secret_digest_p, charp, 0400);
MODULE_PARM_DESC(secret_digest, "sha256 of the hello secret, hex (root only)");

/*
 * Facts the kernel will not hand a module: the boot UUID (`sysctl_bootid` is
 * private to drivers/char/random.c) and the Landlock ABI (probing it means a
 * syscall, which a module has no business making). The loader reads both and
 * passes them in at insmod time, and they are read-only thereafter. The host
 * treats them as loader-asserted, not module-asserted, which is why they sit
 * beside the secret in the hello rather than being conflated with it.
 */
/*
 * The boot phase.
 *
 * Bromure's own root helpers do, during boot, most of the things that would
 * otherwise look alarming: the sentry loader raises lockdown, dockerd and udev
 * load signed modules, systemd and PAM change credentials constantly. One idle
 * minute of boot produced 924 credential events and tripped the host's watchdog
 * with nobody doing anything -- and a tamper alarm in the first minute is how
 * users learn to turn the sentry off.
 *
 * So every event carries a phase. The supervisor flips this to 1 when it starts
 * the tmux server, i.e. when agent code becomes possible; everything before that
 * is the VM being assembled and is reported as informational.
 */
/*
 * MONOTONIC, and that is the whole point of the custom setter.
 *
 * The host treats `phase: "boot"` as informational, because everything Bromure's
 * own root helpers do while assembling the VM is not a security event. A plain
 * writable parameter would therefore hand a root agent — which the non-strict
 * mode still permits — a one-line way to make all of its own activity
 * informational: write 0, do whatever, and every event is downgraded.
 *
 * So the transition only ever goes boot -> session, and a write of 0 after that
 * is refused with -EPERM. There is no legitimate reason to go back: a VM assembles
 * once.
 */
static int sentry_phase;

/*
 * Who declared the phase, and when.
 *
 * Phase 2 (`shutdown`) has to be reachable from userspace, because the kernel
 * has no hook for "systemd began its stop transaction" and the reboot notifier
 * fires long after the unmounts it exists to label. That means a root agent in a
 * non-strict workspace can declare shutdown early and have everything after it
 * judged as teardown.
 *
 * The module cannot tell a Bromure helper from anything else root runs, so it
 * does not pretend to: it records WHO said so and reports it in every heartbeat.
 * The host pairs that with a shutdown budget — events still arriving well after
 * the declaration are judged as session events — and now has the pid and comm to
 * put in the warning instead of an unattributed "phase looks wrong".
 */
static int sentry_phase_setter_pid;
static char sentry_phase_setter_comm[BROMURE_SENTRY_COMM_LEN];

static int sentry_phase_set(const char *value, const struct kernel_param *param)
{
	int want;
	int rc = kstrtoint(value, 0, &want);

	if (rc)
		return rc;
	if (want < 0 || want > 2)
		return -EINVAL;
	if (want < sentry_phase) {
		pr_warn(SENTRY_NAME ": refused an attempt to move the phase "
			"backwards, %d -> %d (pid %d, comm %s)\n",
			sentry_phase, want, task_tgid_nr(current), current->comm);
		return -EPERM;
	}
	sentry_phase = want;
	sentry_phase_setter_pid = task_tgid_nr(current);
	memcpy(sentry_phase_setter_comm, current->comm,
	       sizeof(sentry_phase_setter_comm) - 1);
	sentry_phase_setter_comm[sizeof(sentry_phase_setter_comm) - 1] = '\0';
	return 0;
}

static int sentry_phase_get(char *buffer, const struct kernel_param *param)
{
	return scnprintf(buffer, PAGE_SIZE, "%d\n", sentry_phase);
}

static const struct kernel_param_ops sentry_phase_ops = {
	.set = sentry_phase_set,
	.get = sentry_phase_get,
};
module_param_cb(phase, &sentry_phase_ops, NULL, 0600);
MODULE_PARM_DESC(phase, "0 = boot, 1 = session; one-way (the supervisor sets it)");

static char *sentry_boot_id = "";
module_param_named(boot_id, sentry_boot_id, charp, 0444);
MODULE_PARM_DESC(boot_id, "the guest's /proc/sys/kernel/random/boot_id");

static int sentry_landlock_abi;
module_param_named(landlock_abi, sentry_landlock_abi, int, 0444);
MODULE_PARM_DESC(landlock_abi, "Landlock ABI the loader probed, 0 if none");

/*
 * The cgroup the supervisor puts the sandboxed tree in. Every event says whether
 * its task is inside it, because under the strict sandbox that is what separates
 * the real signal from the noise: `no_new_privs` makes a credential gain
 * impossible inside the sandbox, so one from there is an escalation, while the
 * same event from one of Bromure's own unconfined helpers is merely visible.
 *
 * One-way, like `phase`: it can be set once and never changed, so root cannot
 * point it at a cgroup the agent does not live in and have its own activity
 * reported as Bromure's.
 */
static unsigned long long sentry_sandbox_cgroup;

static int sentry_cgroup_set(const char *value, const struct kernel_param *param)
{
	unsigned long long want;
	int rc = kstrtoull(value, 0, &want);

	if (rc)
		return rc;
	if (sentry_sandbox_cgroup && want != sentry_sandbox_cgroup) {
		pr_warn(SENTRY_NAME ": refused an attempt to change the sandbox "
			"cgroup (pid %d, comm %s)\n",
			task_tgid_nr(current), current->comm);
		return -EPERM;
	}
	sentry_sandbox_cgroup = want;
	return 0;
}

static int sentry_cgroup_get(char *buffer, const struct kernel_param *param)
{
	return scnprintf(buffer, PAGE_SIZE, "%llu\n", sentry_sandbox_cgroup);
}

static const struct kernel_param_ops sentry_cgroup_ops = {
	.set = sentry_cgroup_set,
	.get = sentry_cgroup_get,
};
module_param_cb(sandbox_cgroup, &sentry_cgroup_ops, NULL, 0600);
MODULE_PARM_DESC(sandbox_cgroup, "cgroup id of the sandboxed tree; one-way");

struct sentry_state {
	struct kfifo fifo;
	spinlock_t fifo_lock;
	struct task_struct *thread;

	/* One counter shared by heartbeats and events, as the host expects. */
	atomic64_t seq;
	atomic64_t dropped;		/* fifo full */
	atomic64_t rate_limited;	/* token bucket */

	/* Counted, not reported one by one. */
	atomic64_t tallies[BST_MAX];

	/* Per-kind token bucket. */
	spinlock_t bucket_lock;
	int tokens[BSK_MAX];
	unsigned long last_refill;
};

static struct sentry_state state;

/* ------------------------------------------------------------------ */
/* Event submission                                                     */
/* ------------------------------------------------------------------ */

static bool sentry_take_token(u32 kind)
{
	unsigned long flags;
	unsigned long now = jiffies;
	bool allowed;
	int i;

	if (kind >= BSK_MAX)
		return false;

	spin_lock_irqsave(&state.bucket_lock, flags);
	if (time_after(now, state.last_refill + HZ)) {
		unsigned long elapsed = (now - state.last_refill) / HZ;

		for (i = 0; i < BSK_MAX; i++) {
			u64 refill = (u64)elapsed * SENTRY_TOKENS_PER_SEC;

			if (refill > SENTRY_TOKENS_BURST)
				refill = SENTRY_TOKENS_BURST;
			state.tokens[i] += (int)refill;
			if (state.tokens[i] > SENTRY_TOKENS_BURST)
				state.tokens[i] = SENTRY_TOKENS_BURST;
		}
		state.last_refill = now;
	}
	allowed = state.tokens[kind] > 0;
	if (allowed)
		state.tokens[kind]--;
	spin_unlock_irqrestore(&state.bucket_lock, flags);
	return allowed;
}

/*
 * Never blocks and never sleeps: this runs from kprobe context. A full fifo
 * increments `dropped`, which the next heartbeat reports. Silent loss would
 * make the whole stream untrustworthy, so there is no path that discards an
 * event without counting it.
 */
static void sentry_submit(struct bromure_sentry_event *event)
{
	unsigned long flags;

	if (!sentry_take_token(event->kind)) {
		atomic64_inc(&state.rate_limited);
		return;
	}

	event->timestamp_ns = ktime_get_ns();

	spin_lock_irqsave(&state.fifo_lock, flags);
	if (kfifo_avail(&state.fifo) < sizeof(*event)) {
		spin_unlock_irqrestore(&state.fifo_lock, flags);
		atomic64_inc(&state.dropped);
		return;
	}
	kfifo_in(&state.fifo, event, sizeof(*event));
	spin_unlock_irqrestore(&state.fifo_lock, flags);

	if (state.thread)
		wake_up_process(state.thread);
}

static void sentry_tally(enum bromure_sentry_tally which)
{
	if (which < BST_MAX)
		atomic64_inc(&state.tallies[which]);
}

/* `(pid, start_ns)` is a process's identity; see "Process lineage" below. */
static u64 sentry_start_ns(struct task_struct *task)
{
	return task ? task->start_boottime : 0;
}


/* -------- the probe handlers' staging buffer ----------------------------- */
/*
 * `struct bromure_sentry_event` is 1792 bytes since it gained `argv[1024]` and
 * `chain[8]`; before that it was 512. Sixteen probe handlers staged one on the
 * stack, and the compiler reported sixteen 1808-byte frames -- inside
 * `udp_sendmsg`, inside the LSM hooks, on a 16 KB arm64 kernel stack already
 * partly spent by the kprobe trampoline that got us there. A watchdog that can
 * overflow the stack of the thing it is watching is worse than no watchdog, so
 * the staging buffer is per-CPU and the handlers' frames go back to ~64 bytes.
 *
 * Why this needs no lock, and why it must ONLY be called from a probe handler:
 *
 *  - Preemption is off. A kprobe handler on arm64 is reached from the debug
 *    exception, and `debug_exception_enter()` disables preemption for its
 *    duration, so no other task can run on this CPU and take the buffer.
 *  - Re-entry on the same CPU is refused by the kprobe framework itself, not by
 *    us. `kprobe_breakpoint_handler()` reads the per-CPU `current_kprobe`; if a
 *    handler is already in flight it accounts the hit to `nmissed` and does not
 *    call a second `pre_handler`. That covers the interrupt case, which is the
 *    only way in once preemption is off. kretprobes come through the same path.
 *
 * So "one user per CPU" is a property of the context rather than a hope -- and
 * it stops being true the moment this is called from anywhere else, which is
 * why the two sleepable emitters have their own buffers instead.
 *
 * No memset here: every caller's first act is `sentry_fill_common()`, which
 * zeroes the whole struct. That is load-bearing for a shared buffer, not
 * incidental -- without it an event would inherit the previous one's `argv` and
 * `path` -- so it is checked for all sixteen callers rather than assumed.
 */
static DEFINE_PER_CPU(struct bromure_sentry_event, sentry_probe_scratch);

static struct bromure_sentry_event *sentry_probe_event(void)
{
	return this_cpu_ptr(&sentry_probe_scratch);
}

/* The running binary's path into `event->path`.
 *
 * `get_mm_exe_file` is not exported to modules, so the RCU pointer is read
 * directly and no reference is taken: the path is rendered and copied before
 * the lock is dropped, and `d_path` is safe in this context.
 *
 * NOT free -- it walks the dentry chain -- so callers on a per-packet path must
 * decide whether the event is going to be reported before calling it. See
 * `sentry_kp_flow`.
 */
static void sentry_fill_exe(struct bromure_sentry_event *event)
{
	struct file *exe;

	if (!current->mm)
		return;			/* a kernel thread has no exe */
	rcu_read_lock();
	exe = rcu_dereference(current->mm->exe_file);
	if (exe) {
		char *rendered = file_path(exe, event->path,
					   sizeof(event->path));

		if (IS_ERR(rendered))
			event->path[0] = '\0';
		else if (rendered != event->path)
			memmove(event->path, rendered,
				strnlen(rendered, sizeof(event->path) - 1) + 1);
	}
	rcu_read_unlock();
}

static void sentry_fill_common(struct bromure_sentry_event *event, u32 kind)
{
	const struct cred *cred = current_cred();

	memset(event, 0, sizeof(*event));
	event->kind = kind;
	event->pid = task_tgid_nr(current);
	rcu_read_lock();
	event->ppid = task_tgid_nr(rcu_dereference(current->real_parent));
	rcu_read_unlock();
	event->uid = from_kuid_munged(&init_user_ns, cred->uid);
	event->gid = from_kgid_munged(&init_user_ns, cred->gid);
	memcpy(event->comm, current->comm, sizeof(event->comm) - 1);
	event->phase = (u8)sentry_phase;
	event->start_ns = sentry_start_ns(current);
	event->icmp_type = 0xff;	/* "not read", distinct from type 0 (reply) */
	if (sentry_sandbox_cgroup) {
		struct cgroup *cgrp;

		rcu_read_lock();
		cgrp = task_dfl_cgroup(current);
		event->sandboxed = (cgrp && cgroup_id(cgrp) == sentry_sandbox_cgroup)
				   ? 1 : 0;
		rcu_read_unlock();
	}
}

/* ------------------------------------------------------------------ */
/* JSON rendering                                                       */
/* ------------------------------------------------------------------ */

/* Escape into a JSON string body. Control characters and everything non-ASCII
 * become \uXXXX so the host always receives valid UTF-8 even when a path on
 * disk is not. */
static int sentry_json_escape(char *out, size_t out_len, const char *in, size_t in_len)
{
	size_t used = 0;
	size_t i;

	for (i = 0; i < in_len && in[i]; i++) {
		unsigned char c = (unsigned char)in[i];
		char buf[8];
		int n;

		if (c == '"' || c == '\\') {
			n = scnprintf(buf, sizeof(buf), "\\%c", c);
		} else if (c == '\n') {
			n = scnprintf(buf, sizeof(buf), "\\n");
		} else if (c == '\t') {
			n = scnprintf(buf, sizeof(buf), "\\t");
		} else if (c == '\r') {
			n = scnprintf(buf, sizeof(buf), "\\r");
		} else if (c < 0x20 || c >= 0x7f) {
			n = scnprintf(buf, sizeof(buf), "\\u%04x", c);
		} else {
			buf[0] = c;
			buf[1] = '\0';
			n = 1;
		}
		if (used + n >= out_len)
			break;
		memcpy(out + used, buf, n);
		used += n;
	}
	out[used] = '\0';
	return (int)used;
}

static const char *sentry_phase_name(u8 phase)
{
	switch (phase) {
	case 0:  return "boot";
	case 1:  return "session";
	case 2:  return "shutdown";
	default: return "unknown";
	}
}

static const char *sentry_op_name(u8 op)
{
	switch (op) {
	case BSO_OPEN_READ:	return "open_read";
	case BSO_OPEN_WRITE:	return "open_write";
	case BSO_TC_QDISC:	return "qdisc";
	case BSO_TC_FILTER:	return "filter";
	case BSO_TC_ACTION:	return "action";
	case BSO_OPEN_EXEC:	return "open_exec";
	case BSO_CREATE:	return "create";
	case BSO_MKDIR:		return "mkdir";
	case BSO_RMDIR:		return "rmdir";
	case BSO_UNLINK:	return "unlink";
	case BSO_SYMLINK:	return "symlink";
	case BSO_LINK:		return "link";
	case BSO_RENAME:	return "rename";
	case BSO_TRUNCATE:	return "truncate";
	case BSO_BIND:		return "bind";
	case BSO_CONNECT:	return "connect";
	default:		return "other";
	}
}

static const char *sentry_proto_name(u8 proto)
{
	switch (proto) {
	case BSPR_TCP:		return "tcp";
	case BSPR_UDP:		return "udp";
	case BSPR_ICMP:		return "icmp";
	case BSPR_ICMPV6:	return "icmpv6";
	case BSPR_RAW:		return "raw";
	default:		return "other";
	}
}

static const char *sentry_kind_name(u32 kind)
{
	switch (kind) {
	case BSK_EXEC:				return "exec";
	/* Retired: these were reported per syscall call, which meant per privilege
	 * DROP and per failure too. Counted in the heartbeat now; `cred_gain` is
	 * what replaced them. The names stay mapped so an old host decoding a new
	 * stream never sees "unknown". */
	case BSK_SETUID_UNUSED:			return "setuid";
	case BSK_SETGID_UNUSED:			return "setgid";
	case BSK_CAPSET_UNUSED:			return "capset";
	case BSK_PTRACE:			return "ptrace";
	case BSK_MODULE_LOAD:			return "module_load";
	case BSK_BPF_LOAD:			return "bpf_load";
	case BSK_KEXEC_ATTEMPT:			return "kexec_attempt";
	case BSK_LOCKDOWN_CHANGE_ATTEMPT:	return "lockdown_change_attempt";
	case BSK_MOUNT:				return "mount";
	case BSK_UNSHARE:			return "unshare";
	case BSK_SETNS:				return "setns";
	case BSK_CRED_GAIN:			return "cred_gain";
	case BSK_SANDBOX_DENIED:		return "sandbox_denied";
	case BSK_NET_FLOW:			return "net_flow";
	case BSK_CONTAINER_MARK_FORGED:		return "container_mark_forged";
	case BSK_TC_CHANGE:			return "tc_change";
	case BSK_SECCOMP_DENIED:		return "seccomp_denied";
	case BSK_LANDLOCK_DENIED:		return "landlock_denied";
	default:				return "unknown";
	}
}

/* Escaping can sextuple a string (every byte -> \\uXXXX), so the scratch is
 * heap-allocated once by the kthread rather than sitting on its stack: a
 * 2.4 KiB frame in kernel context is well past the point of being reasonable. */
struct sentry_scratch {
	char comm[BROMURE_SENTRY_COMM_LEN * 6 + 1];
	char path[BROMURE_SENTRY_PATH_LEN * 6 + 1];
	char arg[BROMURE_SENTRY_ARG_LEN * 6 + 1];
	char argv[BROMURE_SENTRY_ARGV_LEN * 6 + 1];
	char json[SENTRY_JSON_MAX];
	/* One event on its way from the fifo to the renderer. It lives here,
	 * in the thread's own kzalloc, rather than on the thread's stack:
	 * the event is 1792 bytes since it gained `argv` and `chain`, and a
	 * buffer that size belongs on the heap. Only the sentry thread ever
	 * touches this, and there is exactly one of it, so it needs no lock. */
	struct bromure_sentry_event drained;
};

static int sentry_render_event(struct sentry_scratch *scratch, char *out,
			       size_t out_len,
			       const struct bromure_sentry_event *event, u64 seq)
{
	char *comm = scratch->comm;
	char *path = scratch->path;
	char *arg = scratch->arg;
	char *argv = scratch->argv;
	int used;

	sentry_json_escape(comm, sizeof(scratch->comm), event->comm,
			   sizeof(event->comm));
	sentry_json_escape(path, sizeof(scratch->path), event->path,
			   sizeof(event->path));
	sentry_json_escape(arg, sizeof(scratch->arg), event->arg,
			   sizeof(event->arg));
	sentry_json_escape(argv, sizeof(scratch->argv), event->argv,
			   sizeof(event->argv));

	used = scnprintf(out, out_len,
		"{\"type\":\"event\",\"seq\":%llu,\"t\":%llu,\"kind\":\"%s\","
		"\"pid\":%u,\"ppid\":%u,\"uid\":%u,\"gid\":%u,\"comm\":\"%s\"",
		seq, event->timestamp_ns, sentry_kind_name(event->kind),
		event->pid, event->ppid, event->uid, event->gid, comm);

	if (path[0])
		used += scnprintf(out + used, out_len - used, ",\"path\":\"%s\"", path);
	if (arg[0])
		used += scnprintf(out + used, out_len - used, ",\"arg\":\"%s\"", arg);
	/* On every event: `(pid, start_ns)` is what the host keys a process on,
	 * and it is useless if only some events carry it. */
	used += scnprintf(out + used, out_len - used, ",\"start_ns\":%llu",
			  event->start_ns);
	if (argv[0]) {
		used += scnprintf(out + used, out_len - used, ",\"argv\":\"%s\"",
				  argv);
		if (event->argv_truncated)
			used += scnprintf(out + used, out_len - used,
					  ",\"argv_truncated\":true");
	}
	if (event->chain_len) {
		u8 i;

		used += scnprintf(out + used, out_len - used, ",\"chain\":[");
		for (i = 0; i < event->chain_len; i++) {
			char ancestor[BROMURE_SENTRY_COMM_LEN * 6 + 1];

			sentry_json_escape(ancestor, sizeof(ancestor),
					   event->chain[i].comm,
					   sizeof(event->chain[i].comm));
			used += scnprintf(out + used, out_len - used,
					  "%s{\"pid\":%u,\"start_ns\":%llu,"
					  "\"comm\":\"%s\"}",
					  i ? "," : "", event->chain[i].pid,
					  event->chain[i].start_ns, ancestor);
		}
		used += scnprintf(out + used, out_len - used, "]");
	}

	used += scnprintf(out + used, out_len - used,
			  ",\"phase\":\"%s\",\"sandboxed\":%s",
			  sentry_phase_name(event->phase),
			  event->sandboxed ? "true" : "false");

	switch (event->kind) {
	case BSK_CRED_GAIN:
		/* The whole point: what was gained, from what, and how. A drop or a
		 * failed call never gets here. */
		used += scnprintf(out + used, out_len - used,
				  ",\"old_uid\":%u,\"new_uid\":%u,"
				  "\"old_caps\":%llu,\"new_caps\":%llu,\"via\":\"%s\"",
				  event->aux1, event->aux2,
				  event->aux4, event->aux3,
				  event->flag1 ? "exec" : "syscall");
		break;
	case BSK_MODULE_LOAD:
		used += scnprintf(out + used, out_len - used,
				  ",\"name\":\"%s\",\"signed\":%s,"
				  "\"taints\":%llu,\"result\":%d",
				  arg, event->flag1 ? "true" : "false",
				  event->aux3, event->result);
		break;
	case BSK_LOCKDOWN_CHANGE_ATTEMPT:
		used += scnprintf(out + used, out_len - used,
				  ",\"result\":%d,\"lowering\":%s",
				  event->result, event->flag1 ? "true" : "false");
		break;
	case BSK_BPF_LOAD:
		used += scnprintf(out + used, out_len - used,
				  ",\"cmd\":%u,\"prog_type\":%u",
				  event->aux1, event->aux2);
		break;
	case BSK_PTRACE:
		used += scnprintf(out + used, out_len - used,
				  ",\"request\":%u,\"target_pid\":%u",
				  event->aux1, event->aux2);
		break;
	case BSK_SANDBOX_DENIED:
		/* `hook` is what the kernel actually told us; the host renders
		 * "the sandbox denied <op> of <path>" rather than naming an LSM
		 * we cannot identify (see BSK_SANDBOX_DENIED in the header).
		 * `access` is the open flags, for the open ops only. */
		used += scnprintf(out + used, out_len - used,
				  ",\"op\":\"%s\",\"hook\":\"%s\",\"errno\":%d"
				  ",\"access\":%u,\"count\":%u",
				  sentry_op_name(event->op), arg,
				  (int)event->aux1, event->aux2, event->count);
		break;
	case BSK_NET_FLOW: {
		char addr[INET6_ADDRSTRLEN] = "";

		if (event->addr_family == AF_INET)
			snprintf(addr, sizeof(addr), "%pI4", event->addr);
		else if (event->addr_family == AF_INET6)
			snprintf(addr, sizeof(addr), "%pI6c", event->addr);
		used += scnprintf(out + used, out_len - used,
				  ",\"proto\":\"%s\",\"ip_proto\":%u,"
				  "\"family\":%u,\"dst\":\"%s\",\"dport\":%u,"
				  "\"sport\":%u,\"count\":%u",
				  sentry_proto_name(event->proto),
				  event->ip_proto, event->addr_family, addr,
				  event->aux2, event->sport, event->count);
		/* 0xff is "not read", which is not the same as type 0 (echo
		 * reply) -- so the field is omitted rather than reported wrong. */
		if (event->icmp_type != 0xff)
			used += scnprintf(out + used, out_len - used,
					  ",\"icmp_type\":%u", event->icmp_type);
		break;
	}
	case BSK_TC_CHANGE: {
		char dev[BROMURE_SENTRY_COMM_LEN * 6 + 1];

		sentry_json_escape(dev, sizeof(dev), event->dev,
				   sizeof(event->dev));
		/* `op` is rendered HERE and not once for every kind: it is only
		 * emitted inside the cases that set it, and a global `op` would
		 * put `"op":"none"` on every exec and flow in the stream. */
		used += scnprintf(out + used, out_len - used,
				  ",\"op\":\"%s\"", sentry_op_name(event->op));
		/* `dev` and `tc_kind` are omitted rather than guessed when the
		 * message did not carry them -- an action message has no
		 * ifindex at all. `tc_kind` is what tells a `pedit` apart from
		 * an ordinary `prio`. */
		if (dev[0])
			used += scnprintf(out + used, out_len - used,
					  ",\"dev\":\"%s\"", dev);
		if (arg[0])
			used += scnprintf(out + used, out_len - used,
					  ",\"tc_kind\":\"%s\"", arg);
		break;
	}
	case BSK_SECCOMP_DENIED:
		/* `syscall` is the NUMBER. The host already has the arm64 table
		 * from the differential work; a second copy in the module would
		 * eventually disagree with it. `path` is the exe. */
		used += scnprintf(out + used, out_len - used,
				  ",\"syscall\":%u,\"action\":\"%s\""
				  ",\"action_code\":%u,\"count\":%u",
				  event->aux1, arg, event->aux2, event->count);
		break;
	default:
		break;
	}

	if (event->truncated)
		used += scnprintf(out + used, out_len - used, ",\"truncated\":true");
	used += scnprintf(out + used, out_len - used, "}");
	return used;
}

/* ------------------------------------------------------------------ */
/* vsock transport                                                      */
/* ------------------------------------------------------------------ */

static int sentry_send_frame(struct socket *sock, const char *json, size_t len)
{
	__be32 length = cpu_to_be32((u32)len);
	struct kvec vec[2];
	struct msghdr msg;
	int sent;
	size_t total = len + sizeof(length);

	memset(&msg, 0, sizeof(msg));
	msg.msg_flags = MSG_NOSIGNAL;
	vec[0].iov_base = &length;
	vec[0].iov_len = sizeof(length);
	vec[1].iov_base = (void *)json;
	vec[1].iov_len = len;

	sent = kernel_sendmsg(sock, &msg, vec, 2, total);
	if (sent < 0)
		return sent;
	if ((size_t)sent != total)
		return -EIO;	/* partial write: resynchronizing is not worth it */
	return 0;
}

static struct socket *sentry_connect(void)
{
	struct sockaddr_vm addr;
	struct socket *sock = NULL;
	int rc;

	rc = sock_create_kern(&init_net, AF_VSOCK, SOCK_STREAM, 0, &sock);
	if (rc < 0) {
		pr_warn(SENTRY_NAME ": sock_create_kern: %d\n", rc);
		return NULL;
	}

	/* Bound so a wedged host stalls the stream, not the kthread. */
	sock->sk->sk_sndtimeo = SENTRY_SEND_TIMEOUT_S * HZ;
	sock->sk->sk_rcvtimeo = SENTRY_SEND_TIMEOUT_S * HZ;

	memset(&addr, 0, sizeof(addr));
	addr.svm_family = AF_VSOCK;
	addr.svm_cid = sentry_cid;
	addr.svm_port = sentry_port;

	rc = kernel_connect(sock, (struct sockaddr *)&addr, sizeof(addr), 0);
	if (rc < 0) {
		sock_release(sock);
		return NULL;
	}
	return sock;
}

/*
 * Probe health. Kprobes can be disarmed from outside the module — globally via
 * debugfs `kprobes/enabled`, or individually — which would silence events while
 * heartbeats kept flowing and the host saw nothing wrong. So every heartbeat
 * carries the live count, and the host treats `armed < total` as tampering.
 * `missed` is the kernel's own `nmissed` across all probes: a probe that fired
 * while already running is a lost event just as surely as a full fifo is.
 *
 * Defined after the probe table; declared here because the transport needs it.
 */
static void sentry_probe_health(int *armed, int *total, u64 *missed, bool *canary,
				int *ftrace);
static int sentry_probe_list(char *out, size_t out_len);
static void sentry_dedup_flush(bool force);

/*
 * Reconnect proof.
 *
 * Under `integrity`, root can still read `/proc/kcore` with `kallsyms`
 * addresses, so it can read the hello secret out of this module's memory. That
 * is bounded — the kernel owns the socket and the host pins the first hello per
 * boot — except for a RECONNECT, which does happen if a send fails. An impostor
 * holding the stolen secret could race the module there.
 *
 * So only the FIRST hello carries the secret in the clear. Every later one
 * carries `conn` and a proof:
 *
 *     proof = sha256( <secret as 64 lowercase hex ASCII>
 *                     || <boot_id as ASCII, exactly as passed in>
 *                     || <conn index as decimal ASCII, no padding> )
 *
 * concatenated with no separators and no trailing NUL, rendered as 64 lowercase
 * hex. The host knows the secret and can recompute it; someone who read memory
 * after the first hello cannot produce the next value without also knowing which
 * index the module is on. The host rejects an index at or below the last one it
 * saw, and treats a reconnect carrying the secret in the clear as tampering.
 */
static u32 sentry_connections;

static int sentry_proof(char *out, size_t out_len, u32 index)
{
	struct crypto_shash *tfm;
	struct shash_desc *desc;
	char counter[16];
	u8 digest[32];
	int rc, i;

	if (out_len < 65)
		return -EINVAL;
	scnprintf(counter, sizeof(counter), "%u", index);

	tfm = crypto_alloc_shash("sha256", 0, 0);
	if (IS_ERR(tfm))
		return PTR_ERR(tfm);
	desc = kzalloc(sizeof(*desc) + crypto_shash_descsize(tfm), GFP_KERNEL);
	if (!desc) {
		crypto_free_shash(tfm);
		return -ENOMEM;
	}
	desc->tfm = tfm;
	rc = crypto_shash_init(desc);
	if (!rc)
		rc = crypto_shash_update(desc, sentry_secret_hex,
					 strlen(sentry_secret_hex));
	if (!rc)
		rc = crypto_shash_update(desc, sentry_boot_id,
					 strlen(sentry_boot_id));
	if (!rc)
		rc = crypto_shash_update(desc, counter, strlen(counter));
	if (!rc)
		rc = crypto_shash_final(desc, digest);
	kfree(desc);
	crypto_free_shash(tfm);
	if (rc)
		return rc;

	for (i = 0; i < (int)sizeof(digest); i++)
		scnprintf(out + i * 2, 3, "%02x", digest[i]);
	return 0;
}

static int sentry_send_hello(struct socket *sock)
{
	char *json;
	char proof[65];
	u32 index = sentry_connections++;
	int len;
	int rc;

	json = kmalloc(SENTRY_JSON_MAX, GFP_KERNEL);
	if (!json)
		return -ENOMEM;

	if (index == 0) {
		len = scnprintf(json, SENTRY_JSON_MAX,
			"{\"type\":\"hello\",\"v\":%d,\"conn\":%u,"
			"\"secret\":\"%s\",\"boot_id\":\"%s\","
			"\"kernel\":\"%s\",\"module\":\"%s\",\"abi\":%d,"
			"\"landlock_abi\":%d,\"container_mark\":%d,"
			"\"probes\":[",
			1, index, sentry_secret_hex, sentry_boot_id,
			init_utsname()->release, SENTRY_VERSION,
			BROMURE_SENTRY_ABI, sentry_landlock_abi,
			BROMURE_SENTRY_CONTAINER_DSCP);
	} else {
		if (sentry_proof(proof, sizeof(proof), index) != 0) {
			kfree(json);
			return -EIO;
		}
		len = scnprintf(json, SENTRY_JSON_MAX,
			"{\"type\":\"hello\",\"v\":%d,\"conn\":%u,"
			"\"proof\":\"%s\",\"boot_id\":\"%s\","
			"\"kernel\":\"%s\",\"module\":\"%s\",\"abi\":%d,"
			"\"landlock_abi\":%d,\"container_mark\":%d,"
			"\"probes\":[",
			1, index, proof, sentry_boot_id,
			init_utsname()->release, SENTRY_VERSION,
			BROMURE_SENTRY_ABI, sentry_landlock_abi,
			BROMURE_SENTRY_CONTAINER_DSCP);
	}
	len += sentry_probe_list(json + len, SENTRY_JSON_MAX - len);
	len += scnprintf(json + len, SENTRY_JSON_MAX - len, "]}");
	rc = sentry_send_frame(sock, json, len);
	kfree(json);
	return rc;
}

static int sentry_send_heartbeat(struct socket *sock, u64 seq)
{
	char json[768];
	int len;
	int armed = 0, total = 0, ftrace = 0;
	u64 missed = 0;
	bool canary = false;

	sentry_probe_health(&armed, &total, &missed, &canary, &ftrace);
	len = scnprintf(json, sizeof(json),
		"{\"type\":\"heartbeat\",\"seq\":%llu,\"t\":%llu,"
		"\"dropped\":%llu,\"rate_limited\":%llu,"
		"\"probes\":{\"armed\":%d,\"total\":%d,\"missed\":%llu,"
		"\"canary\":%s,\"ftrace\":%d},"
		"\"phase\":\"%s\",\"phase_set_by\":{\"pid\":%d,\"comm\":\"%s\"},"
		"\"tallies\":{\"setuid\":%llu,\"setgid\":%llu,\"capset\":%llu,"
		"\"cred_drop\":%llu,\"cred_reassert\":%llu},"
		/* Sandboxed tasks only. `allowed` is what makes `denied`
		 * readable: a hundred denials out of two hundred operations is a
		 * policy that is wrong; a hundred out of two million is an agent
		 * feeling for the walls. The denial count alone cannot tell
		 * those apart. */
		"\"sandbox\":{\"allowed_file_ops\":%llu,\"denied_file_ops\":%llu,"
		"\"denied_syscalls\":%llu,\"caps_in_userns\":%llu},"
		"\"flows\":{\"local_suppressed\":%llu},"
		/* `marked` is per PACKET and says containers are really running
		 * here; `forged_cleared` above zero says a guest process tried
		 * to pass its own traffic off as a container's. */
		"\"containers\":{\"marked\":%llu,\"forged_cleared\":%llu}}",
		seq, ktime_get_ns(),
		(u64)atomic64_read(&state.dropped),
		(u64)atomic64_read(&state.rate_limited),
		armed, total, missed, canary ? "true" : "false", ftrace,
		sentry_phase_name((u8)sentry_phase),
		sentry_phase_setter_pid, sentry_phase_setter_comm,
		(u64)atomic64_read(&state.tallies[BST_SETUID]),
		(u64)atomic64_read(&state.tallies[BST_SETGID]),
		(u64)atomic64_read(&state.tallies[BST_CAPSET]),
		(u64)atomic64_read(&state.tallies[BST_CRED_DROP]),
		(u64)atomic64_read(&state.tallies[BST_CRED_REASSERT]),
		(u64)atomic64_read(&state.tallies[BST_FILE_ALLOWED]),
		(u64)atomic64_read(&state.tallies[BST_FILE_DENIED]),
		(u64)atomic64_read(&state.tallies[BST_SYSCALL_DENIED]),
		(u64)atomic64_read(&state.tallies[BST_CAPS_IN_USERNS]),
		(u64)atomic64_read(&state.tallies[BST_FLOW_LOCAL]),
		(u64)atomic64_read(&state.tallies[BST_CONTAINER_MARKED]),
		(u64)atomic64_read(&state.tallies[BST_MARK_FORGED]));
	return sentry_send_frame(sock, json, len);
}

static int sentry_thread(void *unused)
{
	struct socket *sock = NULL;
	struct sentry_scratch *scratch;
	struct bromure_sentry_event *event;
	char *json;
	unsigned long next_heartbeat = jiffies;

	scratch = kzalloc(sizeof(*scratch), GFP_KERNEL);
	if (!scratch)
		return -ENOMEM;
	json = scratch->json;
	event = &scratch->drained;

	while (!kthread_should_stop()) {
		if (!sock) {
			sock = sentry_connect();
			if (!sock) {
				/* The host may not be listening yet. Retry
				 * forever: giving up would be indistinguishable
				 * from being silenced. */
				schedule_timeout_interruptible(HZ);
				continue;
			}
			if (sentry_send_hello(sock) < 0) {
				sock_release(sock);
				sock = NULL;
				schedule_timeout_interruptible(HZ);
				continue;
			}
			pr_info(SENTRY_NAME ": streaming to cid %u port %u\n",
				sentry_cid, sentry_port);
		}

		while (kfifo_out_spinlocked(&state.fifo, event, sizeof(*event),
					    &state.fifo_lock) == sizeof(*event)) {
			u64 seq = atomic64_inc_return(&state.seq);
			int len = sentry_render_event(scratch, json,
						      SENTRY_JSON_MAX, event, seq);

			if (sentry_send_frame(sock, json, len) < 0) {
				sock_release(sock);
				sock = NULL;
				break;
			}
		}

		/* Before the heartbeat, so a denial that closed its window is in
		 * the fifo and goes out on this pass rather than waiting for the
		 * next. Cheap: 64 slots, almost always all free. */
		sentry_dedup_flush(false);

		if (sock && time_after_eq(jiffies, next_heartbeat)) {
			u64 seq = atomic64_inc_return(&state.seq);

			if (sentry_send_heartbeat(sock, seq) < 0) {
				sock_release(sock);
				sock = NULL;
			}
			next_heartbeat = jiffies + msecs_to_jiffies(SENTRY_HEARTBEAT_MS);
		}

		set_current_state(TASK_INTERRUPTIBLE);
		if (kfifo_is_empty(&state.fifo))
			schedule_timeout(msecs_to_jiffies(SENTRY_HEARTBEAT_MS / 4));
		else
			__set_current_state(TASK_RUNNING);
	}

	if (sock)
		sock_release(sock);
	kfree(scratch);
	return 0;
}

/* ------------------------------------------------------------------ */
/* Capture: one tracepoint plus kprobes                                 */
/* ------------------------------------------------------------------ */
/*
 * Why not BPF-LSM, which the contract first asked for: this kernel's active LSM
 * list is `lockdown,capability,landlock,yama,apparmor`. `bpf` is absent, so
 * BPF_PROG_TYPE_LSM cannot attach, and adding it means `lsm=` on the kernel
 * command line, which means an image rebuild for every user. Kprobes need
 * nothing beyond CONFIG_KPROBES, which is already on, and they are harder to
 * interfere with from userland than a BPF link is.
 *
 * Every probe below is registered by symbol name and is individually optional:
 * a kernel that renames one loses that event kind and keeps the rest, which the
 * loader reports. The alternative — refusing to load at all — would trade a
 * partial stream for no stream.
 */

/* arm64 syscall wrappers take `const struct pt_regs *` holding the user's
 * saved registers; the real arguments are regs->regs[0..5]. */
static unsigned long sentry_syscall_arg(struct pt_regs *regs, int index)
{
	struct pt_regs *user = (struct pt_regs *)regs->regs[0];

	if (!user || index < 0 || index > 5)
		return 0;
	return user->regs[index];
}

/* ------------------------------------------------------------------ */
/* Process lineage                                                      */
/* ------------------------------------------------------------------ */
/*
 * A flow is only meaningful if you can say what caused it: the user wants
 * `claude -> bash -> ping -> ICMP to 1.1.1.1`, not "something sent a packet".
 *
 * The host rebuilds the tree from `exec` events, and the chain carried here is
 * what covers the two cases it cannot: a process that started before this
 * module loaded, and a pid that has been reused since. `(pid, start_ns)` is the
 * identity -- pids come round again in minutes on a busy workspace, start times
 * do not.
 */

static void sentry_fill_chain(struct bromure_sentry_event *event)
{
	struct task_struct *task;
	u8 count = 0;

	event->chain_len = 0;
	rcu_read_lock();
	task = rcu_dereference(current->real_parent);
	while (task && count < BROMURE_SENTRY_CHAIN_MAX) {
		struct task_struct *next;

		event->chain[count].pid = task_tgid_nr(task);
		event->chain[count].start_ns = sentry_start_ns(task);
		memcpy(event->chain[count].comm, task->comm,
		       sizeof(event->chain[count].comm) - 1);
		event->chain[count].comm[sizeof(event->chain[count].comm) - 1] = '\0';
		count++;
		if (task_tgid_nr(task) <= 1)
			break;		/* init; nothing above it is interesting */
		next = rcu_dereference(task->real_parent);
		if (next == task)
			break;		/* defensive: never spin on a cycle */
		task = next;
	}
	rcu_read_unlock();
	event->chain_len = count;
}

/*
 * A NUL-terminated string from userspace, in a context that must never fault.
 *
 * This used `strncpy_from_user`, which **can fault and therefore sleep**, from
 * inside a kprobe handler running with preemption disabled. It has never been
 * hit -- the strings these probes read were just written by the caller, so the
 * pages are resident -- but "has not happened yet" is not the same as safe, and
 * `mount(2)` with a path in a page that has been reclaimed is all it would take.
 *
 * `strncpy_from_user_nofault` would be the obvious answer and is **not exported
 * to modules** on this kernel. `copy_from_user_nofault` is, so the string is
 * read in small chunks and stopped at the first NUL. Chunks rather than one
 * large copy because `copy_from_user_nofault` is all-or-nothing for the size
 * asked for: a short string near the end of a mapping would fail entirely if
 * the whole buffer were requested.
 *
 * Returns the length copied, or -1 when nothing could be read -- which the
 * caller must be able to tell apart from an empty string.
 */
#define SENTRY_USER_CHUNK 32

static long sentry_copy_user_nofault(char *dst, size_t dst_len,
				     const void __user *src, u8 *truncated)
{
	size_t used = 0;
	bool any = false;

	if (!dst_len)
		return -1;
	dst[0] = '\0';
	if (!src)
		return -1;
	while (used + 1 < dst_len) {
		size_t want = min(sizeof(char) * SENTRY_USER_CHUNK,
				  dst_len - 1 - used);
		size_t i;

		if (copy_from_user_nofault(dst + used,
					   (const char __user *)src + used,
					   want))
			break;
		any = true;
		for (i = 0; i < want; i++) {
			if (dst[used + i] == '\0') {
				dst[used + i] = '\0';
				return (long)(used + i);
			}
		}
		used += want;
	}
	dst[used] = '\0';
	if (!any)
		return -1;
	if (used + 1 >= dst_len && truncated)
		*truncated = 1;
	return (long)used;
}

static void sentry_copy_user_string(char *dst, size_t dst_len,
				    const void __user *src, u8 *truncated)
{
	if (sentry_copy_user_nofault(dst, dst_len, src, truncated) < 0)
		dst[0] = '\0';
}

/*
 * exec. The natural hook is the `sched_process_exec` tracepoint, but
 * `__tracepoint_sched_process_exec` is not exported on Ubuntu's kernel, so a
 * module cannot attach to it. `security_bprm_committed_creds` is exported, runs
 * once per successful exec in the *new* image's context with credentials
 * already committed, and takes the `linux_binprm` — so the path comes from
 * kernel memory rather than a re-read of a userspace pointer that the caller
 * could have changed underneath us.
 */
/*
 * The command line, read from `bprm->p` and NOT from `mm->arg_start`.
 *
 * The contract said "the new mm's arg area", and at this hook that area does not
 * exist yet: `exec_mmap()` has run, so `current->mm` IS the new mm, but
 * `mm->arg_start` is set later, in `create_elf_tables()` -- after
 * `setup_arg_pages()`, both of which happen in `load_elf_binary` *after*
 * `begin_new_exec()` calls this hook. Reading `arg_start` here would read zero.
 *
 * `bprm->p` is the top of the copied strings in that same new mm, written by
 * `copy_strings()` before the mm was installed. So it is a valid userspace
 * address in `current->mm` at this moment, and the pages are resident because
 * they were just populated.
 *
 * `_nofault` throughout: a kprobe handler runs with preemption disabled and must
 * never take a page fault. A string that cannot be read is reported as absent
 * rather than guessed at, and `argv_truncated` distinguishes "cut short" from
 * "could not be read" only in the sense that the latter leaves argv empty --
 * which the test checks, because an argv that is silently always empty would
 * look exactly like a quiet process.
 *
 * `arg_start` is still used as a FALLBACK, for a kernel or a binfmt that has
 * already populated it. Cheap, and it costs nothing when it is zero.
 */
static void sentry_read_argv(struct bromure_sentry_event *event,
			     struct linux_binprm *bprm)
{
	unsigned long addr = 0;
	int argc = 0;
	size_t used = 0;
	int i;

	event->argv[0] = '\0';
	if (bprm) {
		addr = bprm->p;
		argc = bprm->argc;
	}
	if ((!addr || argc <= 0) && current->mm) {
		/* Fallback: an already-populated arg area. */
		unsigned long start = current->mm->arg_start;
		unsigned long end = current->mm->arg_end;

		if (start && end > start) {
			size_t want = min_t(size_t, end - start,
					    sizeof(event->argv) - 1);
			long got = sentry_copy_user_nofault(
				event->argv, want + 1,
				(const void __user *)start, NULL);

			if (got > 0) {
				/* The area is NUL-separated; make it readable. */
				size_t n;

				for (n = 0; n < (size_t)got; n++) {
					if (event->argv[n] == '\0')
						event->argv[n] = ' ';
				}
				event->argv[got] = '\0';
				if ((unsigned long)got < end - start)
					event->argv_truncated = 1;
			}
		}
		return;
	}
	if (argc > 256)
		argc = 256;		/* a bound, not a judgement */
	for (i = 0; i < argc && used + 1 < sizeof(event->argv); i++) {
		long got = sentry_copy_user_nofault(
			event->argv + used, sizeof(event->argv) - used,
			(const void __user *)addr, &event->argv_truncated);

		/* `< 0`, not `<= 0`. Zero is an EMPTY argument -- `cmd '' x` --
		 * which is a perfectly ordinary thing to exec; only a negative
		 * return means the copy failed. Treating 0 as failure ended the
		 * loop at the first empty arg and flagged the result truncated,
		 * so `cmd '' x` was reported as `cmd`. The arithmetic below
		 * already handles it: `addr` advances past the NUL, `used` does
		 * not move, and the separator is appended as usual. */
		if (got < 0)
			break;
		addr += (unsigned long)got + 1;	/* past this string's NUL */
		used += (size_t)got;
		if (used + 1 >= sizeof(event->argv)) {
			event->argv_truncated = 1;
			break;
		}
		if (i + 1 < argc)
			event->argv[used++] = ' ';
	}
	event->argv[min(used, sizeof(event->argv) - 1)] = '\0';
	if (i < argc)
		event->argv_truncated = 1;
}

static int sentry_kp_exec(struct kprobe *probe, struct pt_regs *regs)
{
	struct linux_binprm *bprm = (struct linux_binprm *)regs->regs[0];
	struct bromure_sentry_event *event = sentry_probe_event();

	sentry_fill_common(event, BSK_EXEC);
	if (bprm && bprm->filename)
		strscpy(event->path, bprm->filename, sizeof(event->path));
	if (bprm && bprm->interp && bprm->interp != bprm->filename)
		strscpy(event->arg, bprm->interp, sizeof(event->arg));
	sentry_read_argv(event, bprm);
	/* The chain, so the host can place this process even if it missed the
	 * parent's own exec -- which it always does for anything that started
	 * before the module loaded. */
	sentry_fill_chain(event);
	sentry_submit(event);
	return 0;
}

/* --- credential changes --- */

/* --- credentials ---
 *
 * The set*uid / set*gid / capset ENTRY probes are counted, not reported. They
 * fire on every call a healthy machine makes -- systemd, PAM, cron and every
 * daemon dropping privileges -- and on every failure too, since an entry probe
 * runs before the kernel has decided anything. One idle minute of boot produced
 * 924 of them and tripped the host's watchdog with nobody doing anything.
 *
 * What is worth an event is a credential GAIN, and `commit_creds` is where the
 * kernel commits one. Comparing the incoming cred against the current one
 * catches sudo, a setuid binary and a kernel exploit under the same rule, and
 * is silent for every drop and every refusal.
 */
static int sentry_kp_setuid(struct kprobe *probe, struct pt_regs *regs)
{
	sentry_tally(BST_SETUID);
	return 0;
}

static int sentry_kp_setgid(struct kprobe *probe, struct pt_regs *regs)
{
	sentry_tally(BST_SETGID);
	return 0;
}

static int sentry_kp_capset(struct kprobe *probe, struct pt_regs *regs)
{
	sentry_tally(BST_CAPSET);
	return 0;
}

static int sentry_kp_commit_creds(struct kprobe *probe, struct pt_regs *regs)
{
	const struct cred *new = (const struct cred *)regs->regs[0];
	const struct cred *old = current_cred();
	struct bromure_sentry_event *event = sentry_probe_event();
	kernel_cap_t gained_permitted;
	bool entitled, uid_gain, cap_gain;

	if (!new || !old)
		return 0;

	/*
	 * The rule is "authority the task could not already assume", not "euid
	 * changed to 0". The difference is large and was measured: with the naive
	 * rule, five `sudo` invocations produced 55 events --
	 *
	 *   11  sudo  exec     1000 -> 0     <- the real gain, one per sudo
	 *   11  sudo  syscall  1000 -> 0     <- sudo making it permanent
	 *   33  sudo  syscall     1 -> 0     <- sudo's own privilege juggling
	 *
	 * -- and only the first line is an escalation. After the setuid exec, sudo
	 * holds saved-uid 0 and a full permitted set: it can return to root at
	 * will, so doing it again is not news. A root daemon that drops its
	 * effective capabilities and raises them again is the same story.
	 *
	 * `old->suid == 0` is exactly "was already entitled to be root", and it is
	 * what a setuid-root exec grants. The capability test moves to
	 * `cap_permitted`, because effective is always a subset of permitted, so
	 * only a growth in PERMITTED is new authority.
	 */
	entitled = uid_eq(old->suid, GLOBAL_ROOT_UID) ||
		   uid_eq(old->uid, GLOBAL_ROOT_UID) ||
		   uid_eq(old->euid, GLOBAL_ROOT_UID);

	uid_gain = !entitled &&
		   (uid_eq(new->euid, GLOBAL_ROOT_UID) ||
		    uid_eq(new->fsuid, GLOBAL_ROOT_UID));

	/*
	 * A capability set only means something in the namespace that granted it.
	 *
	 * `unshare(CLONE_NEWUSER)` hands the task a FULL permitted set inside its
	 * new user namespace -- measured: CapPrm 0 -> 0x1ffffffffff with the global
	 * uid unchanged -- and `commit_creds` duly reports it. Those capabilities
	 * are authority over nothing the init namespace owns. Reporting it as a
	 * gain made every rootless container, every `bwrap`, every Chrome sandbox
	 * and every test runner that creates a user namespace read as privilege
	 * escalation: weight 20 from a sandboxed task under strict, which is enough
	 * to quarantine a workspace for doing something ordinary.
	 *
	 * So a cap growth counts only in the init namespace. A **uid** gain still
	 * counts everywhere, because `uid_eq(..., GLOBAL_ROOT_UID)` compares kuids
	 * and is namespace-independent: real root is real root wherever it is seen
	 * from.
	 *
	 * Nothing is lost by not reporting it. The `unshare` and `setns` events
	 * report the namespace creation itself, which is the fact that matters.
	 */
	gained_permitted = cap_drop(new->cap_permitted, old->cap_permitted);
	cap_gain = !cap_isclear(gained_permitted) &&
		   new->user_ns == &init_user_ns;
	if (!cap_isclear(gained_permitted) && new->user_ns != &init_user_ns)
		sentry_tally(BST_CAPS_IN_USERNS);

	if (!uid_gain && !cap_gain) {
		/* Distinguish "gave something up" from "took back what it had", so
		 * neither is silent and neither is an alarm. */
		if (uid_eq(new->euid, GLOBAL_ROOT_UID) && !uid_eq(old->euid, GLOBAL_ROOT_UID))
			sentry_tally(BST_CRED_REASSERT);
		else
			sentry_tally(BST_CRED_DROP);
		return 0;
	}

	sentry_fill_common(event, BSK_CRED_GAIN);
	event->aux1 = from_kuid_munged(&init_user_ns, old->euid);
	event->aux2 = from_kuid_munged(&init_user_ns, new->euid);
	event->aux4 = old->cap_permitted.val;
	event->aux3 = new->cap_permitted.val;
	/* Mid-execve means a setuid binary or a file capability taking effect
	 * rather than a syscall. The `exec` event that follows carries the path
	 * from the binprm; here the new mm may not have its exe_file yet, so the
	 * path is best-effort and `comm` is always right. */
	event->flag1 = current->in_execve ? 1 : 0;
	if (current->mm) {
		sentry_fill_exe(event);
	}
	sentry_submit(event);
	return 0;
}

static int sentry_kp_ptrace(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event *event = sentry_probe_event();

	sentry_fill_common(event, BSK_PTRACE);
	event->aux1 = (u32)sentry_syscall_arg(regs, 0);	/* request */
	event->aux2 = (u32)sentry_syscall_arg(regs, 1);	/* target pid */
	sentry_submit(event);
	return 0;
}

/* --- kernel-surface changes --- */

/*
 * Modules. The entry probes on `init_module`/`finit_module` reported one event
 * per call with no name and no signature, so every normal load looked the same
 * as an attack: dockerd starting pulls in overlay, br_netfilter and a handful of
 * nf_* modules, udev loads vsock transports, and all of them are in-tree and
 * distro-signed.
 *
 * `do_init_module(struct module *mod)` knows the name and, with
 * CONFIG_MODULE_SIG, whether the signature checked out. A signed load is
 * routine; an UNSIGNED load, or an attempt that was refused, is the tamper
 * signal -- under lockdown=integrity an unsigned load is impossible, so an
 * attempt means someone is trying.
 */
static int sentry_kp_do_init_module(struct kprobe *probe, struct pt_regs *regs)
{
	struct module *mod = (struct module *)regs->regs[0];
	struct bromure_sentry_event *event = sentry_probe_event();

	sentry_fill_common(event, BSK_MODULE_LOAD);
	if (mod) {
		strscpy(event->arg, mod->name, sizeof(event->arg));
		event->aux3 = mod->taints;
#ifdef CONFIG_MODULE_SIG
		event->flag1 = mod->sig_ok ? 1 : 0;
#else
		event->flag1 = 0;
#endif
	}
	event->result = 0;
	sentry_submit(event);
	return 0;
}

/*
 * And the refusals. `load_module` returns a negative errno when it rejects one
 * -- `-EKEYREJECTED` is specifically "unsigned module under lockdown", which is
 * exactly what an attempt to blind the sentry looks like. There is no name to
 * report at that point, and the errno is the actionable part.
 */
static int sentry_krp_load_module(struct kretprobe_instance *instance,
				  struct pt_regs *regs)
{
	/* (int): `load_module()` returns int, and the raw register is not
	 * sign-extended -- so -ENOKEY arrived as 4294967163, `ret >= 0` was true,
	 * and this probe returned early on every refused module. It never
	 * reported one. Same bug as the denial probes; see the comment there. */
	int ret = (int)regs_return_value(regs);
	struct bromure_sentry_event *event = sentry_probe_event();

	if (ret >= 0)
		return 0;		/* success is reported by do_init_module */

	sentry_fill_common(event, BSK_MODULE_LOAD);
	strscpy(event->arg, "<refused>", sizeof(event->arg));
	event->result = (s32)ret;
	event->flag1 = 0;
	sentry_submit(event);
	return 0;
}

static struct kretprobe sentry_load_module_kretprobe = {
	.handler = sentry_krp_load_module,
	.maxactive = 16,
	.kp.symbol_name = "load_module",
};
static bool load_module_kretprobe_registered;

static int sentry_kp_delete_module(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event *event = sentry_probe_event();

	sentry_fill_common(event, BSK_MODULE_LOAD);
	strscpy(event->arg, "<delete_module>", sizeof(event->arg));
	event->result = 0;
	event->flag1 = 1;	/* not an unsigned load; the host treats it as info */
	sentry_submit(event);
	return 0;
}

/*
 * bpf(). systemd loads a handful of cgroup and device programs at boot and at
 * shutdown, all from pid 1, so the command and the program type are what make an
 * event readable rather than just "something used bpf".
 *
 * `attr` is a userspace pointer and its first u32 for BPF_PROG_LOAD is
 * `prog_type`, so one `get_user` is enough; anything else is reported as 0
 * rather than guessed at.
 */
static int sentry_kp_bpf(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event *event = sentry_probe_event();
	u32 command = (u32)sentry_syscall_arg(regs, 0);
	u32 prog_type = 0;

	sentry_fill_common(event, BSK_BPF_LOAD);
	event->aux1 = command;
	if (command == 5 /* BPF_PROG_LOAD */) {
		const u32 __user *attr =
			(const u32 __user *)sentry_syscall_arg(regs, 1);

		if (attr && get_user(prog_type, attr))
			prog_type = 0;
	}
	event->aux2 = prog_type;
	sentry_submit(event);
	return 0;
}

static int sentry_kp_kexec(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event *event = sentry_probe_event();

	sentry_fill_common(event, BSK_KEXEC_ATTEMPT);
	strscpy(event->arg, probe->symbol_name, sizeof(event->arg));
	sentry_submit(event);
	return 0;
}

/*
 * Lockdown. The entry probe fired on every write, which meant the sentry
 * loader's own raise to `integrity` -- the thing that makes the sentry
 * tamper-resistant in the first place -- was reported as a tampering attempt.
 *
 * The interface can only ever RAISE: the kernel rejects any write that would
 * lower the level. So a successful write is our own action or a further
 * tightening, and a FAILED write is the interesting case, because that is what
 * an attempt to lower looks like. A kretprobe reporting only negative returns
 * says exactly that and nothing else.
 */
static int sentry_krp_lockdown_write(struct kretprobe_instance *instance,
				     struct pt_regs *regs)
{
	/* `long` is correct HERE and nowhere else nearby: lockdown_write returns
	 * ssize_t, which is 64 bits on arm64, so the register really is the
	 * signed value. The probes above return int and must be cast. */
	long ret = regs_return_value(regs);
	struct bromure_sentry_event *event = sentry_probe_event();

	if (ret >= 0)
		return 0;

	sentry_fill_common(event, BSK_LOCKDOWN_CHANGE_ATTEMPT);
	event->result = (s32)ret;
	event->flag1 = 1;	/* a rejected write is an attempt to lower */
	sentry_submit(event);
	return 0;
}

static struct kretprobe sentry_lockdown_kretprobe = {
	.handler = sentry_krp_lockdown_write,
	.maxactive = 8,
	.kp.symbol_name = "lockdown_write",
};
static bool lockdown_kretprobe_registered;

/* --- namespace and mount --- */

static int sentry_kp_mount(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event *event = sentry_probe_event();

	sentry_fill_common(event, BSK_MOUNT);
	sentry_copy_user_string(event->path, sizeof(event->path),
				(const void __user *)sentry_syscall_arg(regs, 1),
				&event->truncated);
	sentry_copy_user_string(event->arg, sizeof(event->arg),
				(const void __user *)sentry_syscall_arg(regs, 2),
				&event->truncated);
	sentry_submit(event);
	return 0;
}

static int sentry_kp_unshare(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event *event = sentry_probe_event();

	sentry_fill_common(event, BSK_UNSHARE);
	event->aux3 = sentry_syscall_arg(regs, 0);	/* clone flags */
	sentry_submit(event);
	return 0;
}

static int sentry_kp_setns(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event *event = sentry_probe_event();

	sentry_fill_common(event, BSK_SETNS);
	event->aux1 = (u32)sentry_syscall_arg(regs, 0);	/* fd */
	event->aux3 = sentry_syscall_arg(regs, 1);	/* nstype */
	sentry_submit(event);
	return 0;
}

/* --- outbound connections, for the host to cross-check against attestd --- */

/* Loopback is not egress.
 *
 * Measured over 90 seconds on a VM doing nothing but running this session: 97
 * hits across every flow probe point, of which 93 were datagram connects to
 * 127.0.0.53 -- the systemd-resolved stub -- three of them per `sudo`. Each is a
 * different short-lived pid, so the (pid, proto, dst, dport) dedup cannot fold
 * them; an `npm ci` would turn that into thousands of rows. None of them can
 * ever be joined to a switch decision, because none of them leaves the VM. So
 * they would bury exactly the flows the feature exists to show.
 *
 * What this costs: the agent's own DNS goes through the stub, so the
 * process -> name link via 127.0.0.53 is not reported. The name is still
 * recoverable -- systemd-resolved's UPSTREAM query is a real egress flow and is
 * reported, attributed to `systemd-resolve` rather than to the agent -- and the
 * host snoops DNS anyway. Set `flow_local=1` to get them back; the count in
 * every heartbeat says how many were held back, so the trade is visible rather
 * than inferred from an absence.
 */
static bool sentry_flow_local;
module_param_named(flow_local, sentry_flow_local, bool, 0644);
MODULE_PARM_DESC(flow_local,
		 "report flows to loopback destinations too (default: count them only)");

/* Loopback destinations that are NOT plumbing, and must be reported anyway.
 *
 * Bromure's cooperative HTTP proxy listens on 127.0.0.1:<proxy_port> (65534 on
 * a fresh boot), and agentd puts it in `HTTPS_PROXY` for every non-OpenShell
 * workspace. So `curl`, `npm`, `pip` and git-over-https all connect to
 * LOOPBACK, and the blanket loopback filter swallowed every one of them --
 * measured live: `curl https://1.1.1.1/` produced no flow at all. That is the
 * opposite of the mistake the filter was added to avoid: suppressing the
 * agent's real egress while keeping the noise would be worse than keeping both.
 *
 * The destination of such a flow is the proxy rather than the site, which is
 * the host's problem and it has one: agentd writes a `BROMURE-CLIENT` preamble
 * on the vsock bridge carrying the client's source port, and the host ties that
 * `sport` to the CONNECT target and to every L7 decision on the connection.
 * This event's `sport` is the join key -- which is why it matters that
 * `tcp_connect` runs after the source port has been chosen.
 *
 * `bromure-sentryd` sets this from the same file agentd reads
 * (/mnt/bromure-meta/proxy_port), so the two cannot disagree about which port
 * the proxy is on.
 */
#define SENTRY_FLOW_PORTS_MAX 8
static unsigned short sentry_flow_local_ports[SENTRY_FLOW_PORTS_MAX];
static int sentry_flow_local_ports_count;
/*
 * 0444 -- set at insmod and NOT writable afterwards, unlike `flow_local` and
 * the dedup windows beside it. The asymmetry is deliberate: this is the only
 * flow parameter whose value can make the sentry report LESS.
 *
 * A root agent -- which the non-strict mode still permits -- could write a
 * shorter array to drop the proxy port out of the exemption, and from then on
 * every HTTP and HTTPS request it made would be suppressed as ordinary
 * loopback plumbing. That is a one-line way to hide its own egress.
 *
 * The others cannot do that. `flow_local=1` only adds events. A longer
 * `flow_dedup_ms` folds repeats of the SAME (pid, proto, dst, dport) and still
 * emits the first one with a count, so it cannot conceal a destination the
 * process had not already reached.
 */
module_param_array_named(flow_local_ports, sentry_flow_local_ports, ushort,
			 &sentry_flow_local_ports_count, 0444);
MODULE_PARM_DESC(flow_local_ports,
		 "loopback destination ports to report rather than suppress (the HTTP proxy); set at load, not writable after");

static bool sentry_flow_port_exempt(u16 dport)
{
	int i;

	for (i = 0; i < sentry_flow_local_ports_count; i++)
		if (sentry_flow_local_ports[i] == dport)
			return true;
	return false;
}

static bool sentry_flow_is_local(const struct bromure_sentry_event *event)
{
	if (event->addr_family == AF_INET) {
		__be32 v4;

		memcpy(&v4, event->addr, sizeof(v4));
		return ipv4_is_loopback(v4);
	}
#if IS_ENABLED(CONFIG_IPV6)
	if (event->addr_family == AF_INET6) {
		const struct in6_addr *v6 = (const struct in6_addr *)event->addr;

		if (ipv6_addr_loopback(v6))
			return true;
		/* ::ffff:127.0.0.0/8 -- v4 loopback reached through a v6
		 * socket, which is what a dual-stack resolver client does, and
		 * is where most of the measured volume actually came from. */
		if (ipv6_addr_v4mapped(v6))
			return ipv4_is_loopback(v6->s6_addr32[3]);
	}
#endif
	return false;
}

/* A send with no destination is not a flow.
 *
 * The guard here used to be `if (!event->addr_family)`, carried over from when
 * datagram connects were probed and `connect(AF_UNSPEC)` could reach this code.
 * With the family filtered earlier, `addr_family` is always AF_INET or
 * AF_INET6 by this point, so that test had become unreachable -- while the
 * situation it was meant to catch is real and still happens:
 *
 *   send() on an unconnected UDP socket returns -EDESTADDRREQ, and `udp_sendmsg`
 *   runs FIRST. Measured: one probe hit, errno 89. The event that would have
 *   been emitted reads `dst: 0.0.0.0, dport: 0` -- a row for a packet that was
 *   never sent, which is the same defect as reporting a source-address probe.
 *
 * Tested on the address alone, not on the port: ICMP and RAW legitimately have
 * no destination port (the handler zeroes it), so a `dport == 0` condition
 * would throw away every ping.
 */
static bool sentry_flow_no_destination(const struct bromure_sentry_event *event)
{
	if (event->addr_family == AF_INET) {
		__be32 v4;

		memcpy(&v4, event->addr, sizeof(v4));
		return v4 == 0;
	}
#if IS_ENABLED(CONFIG_IPV6)
	if (event->addr_family == AF_INET6)
		return ipv6_addr_any((const struct in6_addr *)event->addr);
#endif
	return true;		/* neither family: nothing we can report */
}

/* The one question both emitters ask. A predicate rather than a repeated
 * three-part condition, because the first version of this WAS duplicated at two
 * call sites and that is exactly how one of them ends up without the port
 * exemption. */
static bool sentry_flow_held_back(const struct bromure_sentry_event *event)
{
	if (sentry_flow_local)
		return false;
	if (!sentry_flow_is_local(event))
		return false;
	return !sentry_flow_port_exempt((u16)event->aux2);
}


/*
 * Denied opens.
 *
 * Landlock has no tracepoint and its hooks are static, so a Landlock denial can
 * only be observed indirectly: a `security_file_open` that comes back -EACCES.
 * The kernel never says WHICH LSM refused, so this is deliberately not reported
 * as a Landlock verdict — the kind is `file_open_denied` and it carries the
 * hook name, and the host presents it as "the kernel denied this open", which
 * is the true statement. In a Bromure workspace AppArmor is unconfined for
 * these paths, so in practice it is Landlock; that inference belongs to whoever
 * reads the timeline, not to the wire format. `BSK_LANDLOCK_DENIED` stays
 * reserved for a BPF-LSM or upstream-tracepoint path that really can attribute.
 *
 * The entry handler stashes the `struct file *` so the return handler has a
 * path: by then the argument register may have been reused.
 */
/* ------------------------------------------------------------------ */
/* Sandbox denials                                                      */
/* ------------------------------------------------------------------ */
/*
 * The user's question is "is the agent trying to get out of its permissions?",
 * and until now the only answer was a denied `open`. A denied create, unlink,
 * rename, mkdir, exec or truncate was invisible, and so was every syscall the
 * seccomp filter refused.
 *
 * These are kretprobes on the generic LSM hooks, not on Landlock, because
 * Landlock's own hook functions are static and absent from kallsyms. See the
 * comment on BSK_SANDBOX_DENIED for exactly what that does and does not prove.
 *
 * Every one of these hooks is on a hot path -- `security_file_open` fires on
 * every open in the machine -- so the handlers do the cheapest possible thing
 * first: a cgroup comparison, and return.
 */

enum sentry_path_src {
	SPS_FILE,		/* arg0: struct file *                          */
	SPS_PATH,		/* arg0: const struct path *                    */
	SPS_DIR_DENTRY,		/* arg0: const struct path *, arg1: dentry      */
	SPS_LINK,		/* arg1: const struct path *, arg2: dentry      */
};

struct sentry_denial_ctx {
	void *a;
	void *b;
	u8 sandboxed;
};

struct sentry_denial_probe {
	const char *symbol;
	u8 op;
	u8 src;
	struct kretprobe rp;
	bool registered;
};

/* Is the CURRENT task in the sandbox cgroup? Hot: called on every file open in
 * the machine, so it is a pointer compare under RCU and nothing else. */
static bool sentry_task_sandboxed(void)
{
	struct cgroup *cgrp;
	bool sandboxed = false;

	if (!sentry_sandbox_cgroup)
		return false;
	rcu_read_lock();
	cgrp = task_dfl_cgroup(current);
	sandboxed = cgrp && cgroup_id(cgrp) == sentry_sandbox_cgroup;
	rcu_read_unlock();
	return sandboxed;
}

/* Append "/<name>" to a path buffer, taking the dentry's name under d_lock.
 * d_lock rather than a bare read of d_name.name: a concurrent rename frees the
 * old name, and a spinlock is legal here because a kretprobe handler runs with
 * preemption disabled and never sleeps. */
static void sentry_append_dentry(char *buf, size_t buf_len, struct dentry *dentry,
				 u8 *truncated)
{
	size_t used = strnlen(buf, buf_len);
	unsigned int len;

	if (!dentry || used + 2 >= buf_len) {
		*truncated = 1;
		return;
	}
	if (used && buf[used - 1] != '/')
		buf[used++] = '/';
	spin_lock(&dentry->d_lock);
	len = dentry->d_name.len;
	if (used + len >= buf_len) {
		len = buf_len - used - 1;
		*truncated = 1;
	}
	memcpy(buf + used, dentry->d_name.name, len);
	spin_unlock(&dentry->d_lock);
	buf[used + len] = '\0';
}

static void sentry_denial_path(struct bromure_sentry_event *event, u8 src,
			       void *a, void *b)
{
	char *rendered;

	event->path[0] = '\0';
	if (!a)
		return;
	if (src == SPS_FILE)
		rendered = file_path((struct file *)a, event->path,
				     sizeof(event->path));
	else
		rendered = d_path((const struct path *)a, event->path,
				  sizeof(event->path));
	if (IS_ERR(rendered)) {
		/* A path we cannot render is reported as no path rather than as
		 * some other path. Naming the wrong file is worse than naming
		 * none. */
		event->path[0] = '\0';
		event->truncated = 1;
		return;
	}
	if (rendered != event->path)
		memmove(event->path, rendered,
			strnlen(rendered, sizeof(event->path) - 1) + 1);
	if (src == SPS_DIR_DENTRY || src == SPS_LINK)
		sentry_append_dentry(event->path, sizeof(event->path),
				     (struct dentry *)b, &event->truncated);
}

/* -------- deduplication ------------------------------------------- */
/*
 * A denial that repeats is one fact, not a hundred. Without this, a retry loop
 * produced a hundred rows -- or, worse, sixty-four rows and then silence, as the
 * token bucket dropped the rest: the burst that most deserves attention is
 * exactly the one the rate limiter erases.
 *
 * So identical (op, path, exe) denials inside a window become ONE event
 * carrying `count`. The window is short, because a denial nobody sees for ten
 * seconds is a denial nobody acts on.
 */
#define SENTRY_DEDUP_SLOTS 64

static int sentry_dedup_ms = 1000;
module_param_named(dedup_ms, sentry_dedup_ms, int, 0644);

/* The contract's window for `net_flow`: one event per (pid, proto, dst, dport)
 * per 10 s, folded with a count. Separate from `dedup_ms` because the two
 * measure different things -- see `sentry_dedup_absorb`. */
static int sentry_flow_dedup_ms = 10000;
module_param_named(flow_dedup_ms, sentry_flow_dedup_ms, int, 0644);
MODULE_PARM_DESC(flow_dedup_ms,
		 "window in which one process's repeat flows to the same destination fold into one event");
MODULE_PARM_DESC(dedup_ms,
		 "window in which identical denials collapse into one event with a count");

struct sentry_dedup_slot {
	u64 key;
	u64 deadline_ns;
	u32 count;
	bool used;
	struct bromure_sentry_event event;
};

static struct sentry_dedup_slot sentry_dedup[SENTRY_DEDUP_SLOTS];
static DEFINE_SPINLOCK(sentry_dedup_lock);

static u64 sentry_dedup_key(const struct bromure_sentry_event *event)
{
	u64 key = event->kind * 1000003ULL + event->op;

	/* aux1 is the syscall number for a seccomp denial and the errno for a
	 * path one, and leaving it out of the key merged DIFFERENT facts: a
	 * refused `unshare` and a refused `setns` by the same binary collapsed
	 * into one row reading `count: 53`, which is not deduplication, it is
	 * losing one of the two events. */
	key = key * 1000003ULL + event->aux1;

	/* `path` is in the key for every kind EXCEPT a flow.
	 *
	 * A flow resolves its exe lazily -- `file_path()` walks the dentry chain,
	 * and paying that per packet to fill a field the folded event already
	 * carries is exactly the per-packet cost this kind exists to avoid. So
	 * the key is computed once with `path` still empty (to ask whether a
	 * live slot exists), the exe is filled only if none does, and the key is
	 * computed again inside the absorb. Hashing `path` would make those two
	 * disagree, and every single flow would get a slot of its own.
	 *
	 * Nothing is lost: for a flow `pid` already determines the exe, and the
	 * destination fields below carry the identity that matters.
	 */
	if (event->kind != BSK_NET_FLOW)
		key = key * 1000003ULL + full_name_hash(NULL, event->path,
						       strnlen(event->path,
							       sizeof(event->path)));
	key = key * 1000003ULL + full_name_hash(NULL, event->arg,
					       strnlen(event->arg,
						       sizeof(event->arg)));
	key = key * 1000003ULL + event->pid;

	/* A FLOW's identity is its destination, and leaving that out made the
	 * same mistake the `aux1` comment above describes -- one feature later,
	 * in the same function.
	 *
	 * The contract's key is (pid, proto, dst, dport). This one was
	 * (kind, op, aux1, path, arg, pid), none of which distinguishes one
	 * destination from another, so EVERY flow a process made in the window
	 * folded into its first one. Caught live, and the data says it exactly:
	 * a `ping -c1` reported ONE event with `count: 2` and a `ping -c5` ONE
	 * with `count: 6` -- iputils probes its source address by connecting a
	 * real UDP socket to dst:1025 before pinging, that flow took the slot,
	 * and every ICMP send was absorbed into it. The ICMP flow, which is the
	 * one anybody wanted, never left the guest.
	 *
	 * It was never only about ping. A process connecting to ten different
	 * hosts reported one flow with `count: 10`, which is not deduplication,
	 * it is discarding nine destinations.
	 *
	 * Kind-gated so the denial key is bit-for-bit what it was: `aux2` is a
	 * file's `f_flags` on a denial and the destination port on a flow, and
	 * folding it in unconditionally would have quietly re-cut denial
	 * dedup that is already verified in the field.
	 */
	if (event->kind == BSK_NET_FLOW) {
		key = key * 1000003ULL + event->proto;
		key = key * 1000003ULL + event->addr_family;
		key = key * 1000003ULL + event->aux2;		/* dport */
		/* The whole 16 bytes, by explicit length: an address is binary
		 * and may contain NULs, so a string hash would stop at the
		 * first zero octet -- and 1.1.1.1 against 1.1.1.2 differs only
		 * in the last. */
		key = key * 1000003ULL + full_name_hash(NULL, event->addr,
							sizeof(event->addr));
	}
	return key;
}

/* Returns true when the caller should submit `event` itself. */
static bool sentry_dedup_absorb(const struct bromure_sentry_event *event)
{
	u64 key = sentry_dedup_key(event);
	u64 now = ktime_get_ns();
	/* Flows get their own, much longer window. The contract asks for 10 s
	 * per (pid, proto, dst, dport) -- a connection is a thing a process does
	 * occasionally, where a denial is a thing it does in bursts, so the two
	 * want different windows and sharing `dedup_ms` would have quietly given
	 * flows the denial's 1 s. */
	u64 window = (u64)(event->kind == BSK_NET_FLOW ? sentry_flow_dedup_ms
							: sentry_dedup_ms) *
		     NSEC_PER_MSEC;
	unsigned long flags;
	size_t i, free_slot = SENTRY_DEDUP_SLOTS;
	bool submit_now = false;

	spin_lock_irqsave(&sentry_dedup_lock, flags);
	for (i = 0; i < SENTRY_DEDUP_SLOTS; i++) {
		if (sentry_dedup[i].used && sentry_dedup[i].key == key &&
		    sentry_dedup[i].deadline_ns > now) {
			sentry_dedup[i].count++;
			spin_unlock_irqrestore(&sentry_dedup_lock, flags);
			return false;
		}
		if (!sentry_dedup[i].used && free_slot == SENTRY_DEDUP_SLOTS)
			free_slot = i;
	}
	if (free_slot < SENTRY_DEDUP_SLOTS) {
		sentry_dedup[free_slot].key = key;
		sentry_dedup[free_slot].deadline_ns = now + window;
		sentry_dedup[free_slot].count = 1;
		sentry_dedup[free_slot].used = true;
		sentry_dedup[free_slot].event = *event;
	} else {
		/* Every slot busy: send it rather than lose it. Sixty-four
		 * distinct denials in one window is itself worth seeing. */
		submit_now = true;
	}
	spin_unlock_irqrestore(&sentry_dedup_lock, flags);
	return submit_now;
}

/*
 * The flush's staging buffer, and why it is not the per-CPU one. This runs in
 * process context and is preemptible, so `kprobe_running()` is false for it and
 * the kprobe framework would happily run a probe handler on this CPU in the
 * middle of it -- which would overwrite a half-copied event. And it is not a
 * bare static either: the module's exit path flushes BEFORE `kthread_stop()`,
 * so exit and the sentry thread can be inside here at the same time. Both are
 * sleepable, so a mutex is legal, and with two possible users it never
 * contends.
 */
static struct bromure_sentry_event sentry_flush_scratch;
static DEFINE_MUTEX(sentry_flush_lock);

/* Called from the sentry thread once a second, and once from module exit. */
static void sentry_dedup_flush(bool force)
{
	struct bromure_sentry_event *event = &sentry_flush_scratch;
	u64 now = ktime_get_ns();
	unsigned long flags;
	size_t i;

	mutex_lock(&sentry_flush_lock);
	for (i = 0; i < SENTRY_DEDUP_SLOTS; i++) {
		bool ready = false;

		spin_lock_irqsave(&sentry_dedup_lock, flags);
		if (sentry_dedup[i].used &&
		    (force || sentry_dedup[i].deadline_ns <= now)) {
			*event = sentry_dedup[i].event;
			event->count = sentry_dedup[i].count;
			sentry_dedup[i].used = false;
			ready = true;
		}
		spin_unlock_irqrestore(&sentry_dedup_lock, flags);
		if (ready)
			sentry_submit(event);
	}
	mutex_unlock(&sentry_flush_lock);
}

/* Is a live dedup slot already holding this event's key?
 *
 * Read-only, and cheap: the same key the absorb will compute, one pass over 64
 * slots under the lock that already exists, no allocation and no path walk.
 *
 * It exists so a flow can decide whether it is worth RESOLVING anything. Both
 * the exe (`file_path`, a dentry walk) and the ancestor chain (up to eight
 * tasks under RCU) are only needed for an event that will actually be reported;
 * a QUIC-style workload sends thousands of packets a second to one destination
 * that is already folded into a single event, and paying for both on every
 * packet to fill fields the folded event already carries is precisely the
 * per-packet cost `net_flow` exists to avoid.
 *
 * The margin is what makes the answer still true a moment later. A slot that is
 * about to expire counts as NOT live, so between this check and the absorb it
 * cannot lapse underneath us -- which would otherwise let the absorb create a
 * new slot from an event whose exe and chain were never filled, and emit the
 * empty `path` this lazy resolution exists to fill correctly. The two calls are
 * sub-microsecond apart and the margin is a millisecond, so the window is shut
 * rather than merely unlikely. Being wrong in the other direction is free: we
 * resolve the fields and then fold into the dying slot, which already has them.
 *
 * The opposite race needs no handling: if another CPU creates the slot in
 * between, the work was wasted and the event folds, which is correct.
 */
#define SENTRY_DEDUP_LIVE_MARGIN_NS (1 * NSEC_PER_MSEC)
static bool sentry_dedup_live(const struct bromure_sentry_event *event)
{
	u64 key = sentry_dedup_key(event);
	u64 now = ktime_get_ns();
	unsigned long flags;
	size_t i;
	bool live = false;

	spin_lock_irqsave(&sentry_dedup_lock, flags);
	for (i = 0; i < SENTRY_DEDUP_SLOTS; i++) {
		if (sentry_dedup[i].used && sentry_dedup[i].key == key &&
		    sentry_dedup[i].deadline_ns > now +
						SENTRY_DEDUP_LIVE_MARGIN_NS) {
			live = true;
			break;
		}
	}
	spin_unlock_irqrestore(&sentry_dedup_lock, flags);
	return live;
}

static void sentry_emit_denial(struct bromure_sentry_event *event)
{
	event->count = 1;
	if (sentry_dedup_absorb(event))
		sentry_submit(event);
}

struct sentry_tc_probe {
	const char *symbol;
	u8 op;
	struct kprobe probe;
	bool registered;
};

/* -------- traffic control changes ---------------------------------------- */
/*
 * `tc` is the one remaining way to forge the container mark, and the sentry
 * cannot stop it: an egress qdisc action runs inside `__dev_queue_xmit`, after
 * netfilter is finished, so there is no later hook to take. Measured, with the
 * POSTROUTING hook active:
 *
 *   tc filter add ... action pedit ex munge ip dsfield set 0xac
 *   guest curl -> DSCP 43 on the wire        (DSCP 0 immediately before)
 *
 * So this reports the attempt instead. The host revokes the container
 * exemption for the rest of the boot when it sees one, which is why the signal
 * has to be free of false positives -- measured on this image: idle,
 * `docker run`, `docker network create` with a container on that network, and
 * a dockerd restart produce NONE of these. Docker attaches a veth's default
 * qdisc without going through tc's netlink path.
 *
 * All three handlers take `(struct sk_buff *skb, struct nlmsghdr *n, ...)`, so
 * the message is arg1. It is kernel memory -- netlink has already copied it in
 * -- so parsing needs no faulting copy, which is what made `kind` cheap enough
 * to include after all.
 */
static void sentry_tc_describe(struct bromure_sentry_event *event,
			       struct nlmsghdr *n, u8 op)
{
	struct tcmsg *tcm;
	struct nlattr *kind;

	event->op = op;
	if (!n)
		return;
	/* An action message is a `tcamsg` and carries no ifindex, so only
	 * qdisc and filter messages can name a device. */
	if (op == BSO_TC_ACTION)
		return;
	/* Trust nothing about the length: a short message would have us read
	 * past the end of the buffer netlink allocated. */
	if (n->nlmsg_len < NLMSG_LENGTH(sizeof(struct tcmsg)))
		return;
	tcm = nlmsg_data(n);
	if (tcm->tcm_ifindex > 0) {
		struct net_device *dev;

		rcu_read_lock();
		dev = dev_get_by_index_rcu(&init_net, tcm->tcm_ifindex);
		if (dev)
			strscpy(event->dev, dev->name, sizeof(event->dev));
		rcu_read_unlock();
	}
	kind = nla_find(nlmsg_attrdata(n, sizeof(struct tcmsg)),
			nlmsg_attrlen(n, sizeof(struct tcmsg)), TCA_KIND);
	if (kind && nla_len(kind) > 0)
		strscpy(event->arg, nla_data(kind),
			min_t(size_t, (size_t)nla_len(kind), sizeof(event->arg)));
}

static int sentry_kp_tc(struct kprobe *probe, struct pt_regs *regs)
{
	struct sentry_tc_probe *entry =
		container_of(probe, struct sentry_tc_probe, probe);
	struct bromure_sentry_event *event = sentry_probe_event();

	sentry_fill_common(event, BSK_TC_CHANGE);
	sentry_fill_exe(event);
	sentry_tc_describe(event, (struct nlmsghdr *)regs->regs[1], entry->op);
	/* Unfolded and immediate: these are rare, and the host acts on the
	 * first one. Folding would delay the very event it revokes on. */
	sentry_submit(event);
	return 0;
}

static struct sentry_tc_probe sentry_tc_probes[] = {
	{ .symbol = "tc_modify_qdisc", .op = BSO_TC_QDISC },
	{ .symbol = "tc_new_tfilter",  .op = BSO_TC_FILTER },
	/* `tc actions add` goes through its own netlink handler rather than the
	 * filter one, so it needs its own probe or standalone actions would be
	 * invisible. */
	{ .symbol = "tc_ctl_action",   .op = BSO_TC_ACTION },
};

/* -------- the container mark ---------------------------------------------- */
/*
 * A label on container traffic that guest root cannot forge, so the host can
 * decide not to intercept it.
 *
 * In a Bromure VM the guest forwards packets only for containers -- Docker
 * bridges, kind/k8s pods, anything behind a veth. Its own processes never
 * traverse FORWARD. So "was this forwarded?" IS the container test, and it
 * needs no process lookup, no cgroup walk and no per-packet attribution.
 *
 * Measured on this image before any of it was written, with a mangle rule
 * standing in for the FORWARD hook, one capture, container ping and guest curl
 * together:
 *
 *   172.28.66.5 -> 1.1.1.1   DSCP 43 (tos 0xac)  x3   container, MASQUERADEd
 *   172.28.66.5 -> 1.1.1.1   DSCP 0  (tos 0x00)  x11  the guest's own curl
 *
 * Three facts in that one capture: NAT does not touch TOS, so the mark
 * survives MASQUERADE to the wire; the guest's own traffic is unmarked even
 * with the hook active, because it never reaches FORWARD; and both flows leave
 * with the SAME source address, which is exactly why the host needs a label at
 * all -- after NAT it has nothing else to tell them apart by.
 *
 * ONE hook, on POSTROUTING, at `NF_IP_PRI_LAST`. The first design used two --
 * mark on FORWARD, clear on LOCAL_OUT -- and it had a forgery hole: LOCAL_OUT
 * runs BEFORE POSTROUTING, so root could add
 *
 *     iptables -t mangle -A POSTROUTING -j DSCP --set-dscp 43
 *
 * which runs after the clear and stamps the mark back onto its own traffic.
 * "Last in the chain we chose" is not the same as last. POSTROUTING at
 * PRI_LAST is after nat (priority 100) and after any iptables rule anyone can
 * add, so it genuinely is the final netfilter word.
 *
 * It decides from the INGRESS DEVICE, which is the part iptables cannot
 * rewrite:
 *
 *   skb_iif == 0            -> originated here. Clear.
 *   a bridge, a bridge port,
 *   or a veth               -> came from behind a veth, i.e. a container. Mark.
 *   anything else           -> clear.
 *
 * The device TYPE check is what closes a second hole: a TUN device. Root can
 * create a tun, route its own traffic into it and write packets back from
 * userspace, and those arrive with a non-zero `skb_iif` -- "forwarded" by any
 * naive test. Requiring a bridge or veth means the only way to earn the mark
 * is to actually be behind one, which is what a container is and what the
 * option permits by definition.
 *
 * Measured which device: `-i docker0` in mangle FORWARD counted a container's
 * packets, so the IP layer sees them arrive on the BRIDGE, not on the veth --
 * hence `netif_is_bridge_master` and not only `netif_is_bridge_port`. The veth
 * kind is accepted too, for CNIs that wire pods with veths and no bridge.
 */
/* Make the packet carry `dscp`. Returns true if it does when we are done,
 * whether or not a write was needed. */
static bool sentry_set_dscp(struct sk_buff *skb, u8 pf, u8 dscp)
{
	/* ECN lives in the low two bits of the same byte and belongs to the
	 * transport, not to us -- so the mask keeps it and only the DSCP field
	 * is replaced. */
	const u8 keep_ecn = 0x03;

	if (pf == NFPROTO_IPV4) {
		struct iphdr *iph;

		if (!pskb_may_pull(skb, sizeof(struct iphdr)))
			return false;
		if (ipv4_get_dsfield(ip_hdr(skb)) >> 2 == dscp)
			return true;			/* already right */
		if (skb_ensure_writable(skb, sizeof(struct iphdr)))
			return false;
		iph = ip_hdr(skb);
		/* The kernel's own helper, not a hand-rolled `csum_replace2`:
		 * it recomputes the header checksum as part of the write, and
		 * getting that arithmetic subtly wrong would produce packets
		 * the next hop silently discards. */
		ipv4_change_dsfield(iph, keep_ecn, dscp << 2);
		return true;
	}
#if IS_ENABLED(CONFIG_IPV6)
	if (pf == NFPROTO_IPV6) {
		if (!pskb_may_pull(skb, sizeof(struct ipv6hdr)))
			return false;
		if (ipv6_get_dsfield(ipv6_hdr(skb)) >> 2 == dscp)
			return true;
		if (skb_ensure_writable(skb, sizeof(struct ipv6hdr)))
			return false;
		/* No checksum in the IPv6 header; the traffic class straddles
		 * bytes 0 and 1 and the helper handles the nibbles. */
		ipv6_change_dsfield(ipv6_hdr(skb), keep_ecn, dscp << 2);
		return true;
	}
#endif
	return false;
}

/* Did this packet arrive from behind a veth, i.e. from a container?
 *
 * The ingress device is the one property of a packet that guest root cannot
 * rewrite: iptables can set marks, addresses, ports and TOS, but not where the
 * packet came in. See the block comment above for the TUN hole this closes.
 */
static bool sentry_from_container(const struct sk_buff *skb,
				  const struct nf_hook_state *st)
{
	struct net_device *dev;
	bool container = false;

	if (!skb->skb_iif)
		return false;		/* nothing arrived on a device */

	rcu_read_lock();
	dev = dev_get_by_index_rcu(st->net, skb->skb_iif);
	if (dev) {
		if (netif_is_bridge_master(dev) || netif_is_bridge_port(dev))
			container = true;
		else if (dev->rtnl_link_ops && dev->rtnl_link_ops->kind &&
			 !strcmp(dev->rtnl_link_ops->kind, "veth"))
			container = true;
	}
	rcu_read_unlock();
	return container;
}

static bool sentry_has_mark(const struct sk_buff *skb, u8 pf)
{
	if (pf == NFPROTO_IPV4) {
		if (!pskb_may_pull((struct sk_buff *)skb, sizeof(struct iphdr)))
			return false;
		return ipv4_get_dsfield(ip_hdr(skb)) >> 2 ==
		       BROMURE_SENTRY_CONTAINER_DSCP;
	}
#if IS_ENABLED(CONFIG_IPV6)
	if (pf == NFPROTO_IPV6) {
		if (!pskb_may_pull((struct sk_buff *)skb, sizeof(struct ipv6hdr)))
			return false;
		return ipv6_get_dsfield(ipv6_hdr(skb)) >> 2 ==
		       BROMURE_SENTRY_CONTAINER_DSCP;
	}
#endif
	return false;
}

/* Staging for the forgery event.
 *
 * NOT `sentry_probe_event()`. That buffer is sound only inside a kprobe
 * handler, where preemption is disabled and the kprobe framework refuses
 * same-CPU re-entry -- neither of which holds in a netfilter hook, which runs
 * in softirq or in process context and is preemptible in the latter. Using it
 * here would be the exact unsoundness its own comment warns about.
 *
 * So: a buffer of its own, borrowed with interrupts off. The hook is short and
 * a forgery is rare and rate-limited, so the window is tiny; `depth` catches
 * the nested case and counts it rather than emitting a torn event.
 */
struct sentry_nf_slot {
	struct bromure_sentry_event event;
	unsigned int depth;
};
static DEFINE_PER_CPU(struct sentry_nf_slot, sentry_nf_slot);

/* Did the SOCKET ask for our mark, or did something downstream stamp it on?
 *
 * This distinction is not a nicety. Measured on a live load: one root-added
 *
 *     iptables -t mangle -A POSTROUTING -j DSCP --set-dscp 43
 *
 * marked every locally originated packet on the box, so the hook cleared 36 of
 * them and the events named `curl` and the coding agent itself -- neither of
 * which had ever touched IP_TOS. One rule made every process look guilty.
 *
 * At POSTROUTING the packet cannot tell you who set the field. The socket can:
 * `IP_TOS`/`IPV6_TCLASS` is recorded on it, so a process that genuinely asked
 * for the mark is distinguishable from one whose packet merely passed through
 * somebody else's rule. The TALLY counts every clearing either way, so the
 * alarm is complete; only the ACCUSATION requires the socket's own word.
 */
static bool sentry_socket_asked_for_mark(const struct nf_hook_state *st)
{
	const struct sock *sk = st->sk;

	if (!sk)
		return false;
	if (st->pf == NFPROTO_IPV4 && sk->sk_family == AF_INET)
		return inet_sk(sk)->tos >> 2 == BROMURE_SENTRY_CONTAINER_DSCP;
#if IS_ENABLED(CONFIG_IPV6)
	if (st->pf == NFPROTO_IPV6 && sk->sk_family == AF_INET6) {
		const struct ipv6_pinfo *np = inet6_sk(sk);

		return np && np->tclass >> 2 == BROMURE_SENTRY_CONTAINER_DSCP;
	}
#endif
	return false;
}

static void sentry_report_forgery(void)
{
	struct sentry_nf_slot *slot;
	unsigned long flags;

	/* Task context only. On a softirq -- a retransmit, a delayed ACK --
	 * `current` is whatever thread the interrupt landed on, and naming it
	 * would accuse a process that did nothing. The tally above is already
	 * complete; this only adds a name when there is a real one to give. */
	if (!in_task())
		return;

	local_irq_save(flags);
	slot = this_cpu_ptr(&sentry_nf_slot);
	if (slot->depth) {
		local_irq_restore(flags);
		return;
	}
	slot->depth = 1;
	sentry_fill_common(&slot->event, BSK_CONTAINER_MARK_FORGED);
	slot->event.aux1 = BROMURE_SENTRY_CONTAINER_DSCP;
	sentry_fill_exe(&slot->event);
	/* Folded per (pid, exe) like a denial: a process hammering the socket
	 * option produces one row with a count, not a flood. */
	sentry_emit_denial(&slot->event);
	slot->depth = 0;
	local_irq_restore(flags);
}

static unsigned int sentry_nf_postrouting(void *priv, struct sk_buff *skb,
					  const struct nf_hook_state *st)
{
	if (sentry_from_container(skb, st)) {
		if (sentry_set_dscp(skb, st->pf, BROMURE_SENTRY_CONTAINER_DSCP))
			sentry_tally(BST_CONTAINER_MARKED);
		return NF_ACCEPT;
	}
	/* Not a container's. Only ever touch OUR value: a workspace using DSCP
	 * for real QoS -- EF is 46, the AF classes 10..38, CS0-7 multiples of
	 * 8 -- is left exactly alone. */
	if (!sentry_has_mark(skb, st->pf))
		return NF_ACCEPT;		/* the overwhelmingly common case */
	if (sentry_set_dscp(skb, st->pf, 0)) {
		sentry_tally(BST_MARK_FORGED);
		/* Named only when the socket itself asked for the mark. A
		 * packet carrying it because of a global iptables rule is
		 * still counted above -- the host sees the clearing happened --
		 * but no process is accused of something a rule did. */
		if (sentry_socket_asked_for_mark(st))
			sentry_report_forgery();
	}
	return NF_ACCEPT;
}

static struct nf_hook_ops sentry_nf_ops[] = {
	{ .hook = sentry_nf_postrouting, .pf = NFPROTO_IPV4,
	  .hooknum = NF_INET_POST_ROUTING, .priority = NF_IP_PRI_LAST },
#if IS_ENABLED(CONFIG_IPV6)
	{ .hook = sentry_nf_postrouting, .pf = NFPROTO_IPV6,
	  .hooknum = NF_INET_POST_ROUTING, .priority = NF_IP6_PRI_LAST },
#endif
};
static bool sentry_nf_registered;

/* -------- the probes ---------------------------------------------- */

/* `instance->rp` does not exist on this kernel: the instance carries a holder,
 * and `get_kretprobe()` is the accessor -- which returns NULL while the probe is
 * being unregistered, so both handlers check. */
static struct sentry_denial_probe *sentry_denial_of(struct kretprobe_instance *ri)
{
	struct kretprobe *rp = get_kretprobe(ri);

	return rp ? container_of(rp, struct sentry_denial_probe, rp) : NULL;
}

static int sentry_krp_denial_entry(struct kretprobe_instance *instance,
				   struct pt_regs *regs)
{
	struct sentry_denial_probe *probe = sentry_denial_of(instance);
	struct sentry_denial_ctx *ctx = (struct sentry_denial_ctx *)instance->data;

	if (!probe) {
		ctx->sandboxed = 0;
		return 0;
	}

	/* Decided on ENTRY: by the time the hook returns, `current` is the same
	 * task, but doing it here keeps the return path a single branch for the
	 * overwhelmingly common case of an allowed operation by an unsandboxed
	 * task. */
	ctx->sandboxed = sentry_task_sandboxed() ? 1 : 0;
	ctx->a = NULL;
	ctx->b = NULL;
	if (!ctx->sandboxed) {
		/* **1, not 0.** A non-zero return from a kretprobe entry handler
		 * skips the return handler and recycles the instance at once.
		 *
		 * It does NOT make this cheaper, and the measurement is worth
		 * recording because the intuition says otherwise: 792 ns/open
		 * with no module, 1006 ns with it, and the same 1006 ns whether
		 * or not the return handler runs. On arm64 a kretprobe is a
		 * kprobe at function entry that hijacks the return address, so
		 * the entry trampoline is the whole cost and there is nothing
		 * left to save.
		 *
		 * It is kept because it is still right: `security_file_open`
		 * fires on every open in the machine, `maxactive` is 64, and an
		 * instance recycled at entry is an instance that cannot be
		 * missed while a return handler runs. */
		return 1;
	}
	switch (probe->src) {
	case SPS_LINK:
		ctx->a = (void *)regs->regs[1];
		ctx->b = (void *)regs->regs[2];
		break;
	case SPS_DIR_DENTRY:
		ctx->a = (void *)regs->regs[0];
		ctx->b = (void *)regs->regs[1];
		break;
	default:
		ctx->a = (void *)regs->regs[0];
		break;
	}
	return 0;
}

static int sentry_krp_denial(struct kretprobe_instance *instance,
			     struct pt_regs *regs)
{
	struct sentry_denial_probe *probe = sentry_denial_of(instance);
	struct sentry_denial_ctx *ctx = (struct sentry_denial_ctx *)instance->data;
	/* (int), and it is the whole feature.
	 *
	 * Every `security_*` hook returns `int`. `regs_return_value()` hands back
	 * the raw 64-bit register, whose upper half is not sign-extended -- so
	 * -EACCES arrives as 0x00000000fffffff3, which is 4294967283, which is
	 * not equal to -13. The original `file_open_denied` probe compared the
	 * unsigned value against -EACCES and therefore **never fired once**, in
	 * any workspace, since the day it was written. Nothing caught it because
	 * no test ever asserted that a denial produced an event -- the suite
	 * checked the probe was REGISTERED, which it always was.
	 */
	int ret = (int)regs_return_value(regs);
	struct bromure_sentry_event *event;

	if (!probe || !ctx->sandboxed)
		return 0;
	if (ret == 0) {
		sentry_tally(BST_FILE_ALLOWED);
		return 0;
	}
	if (ret != -EACCES && ret != -EPERM)
		return 0;
	sentry_tally(BST_FILE_DENIED);

	/* Claimed only now, past the early returns. This hook is the hot one --
	 * every `security_file_open` in the workspace comes through it, and the
	 * overwhelming majority are allowed -- so the allowed path must not
	 * touch the staging buffer at all, let alone memset 1792 bytes of it. */
	event = sentry_probe_event();
	sentry_fill_common(event, BSK_SANDBOX_DENIED);
	event->op = probe->op;
	event->aux1 = (u32)(-ret);
	strscpy(event->arg, probe->symbol, sizeof(event->arg));
	sentry_denial_path(event, probe->src, ctx->a, ctx->b);

	/* `open` is three operations wearing one hook. Landlock's EXECUTE right
	 * is checked here too, so a binary outside the policy shows up as a
	 * denied open with FMODE_EXEC rather than as a denied exec -- which is
	 * why probing security_bprm_check would add nothing. */
	if (probe->src == SPS_FILE && ctx->a) {
		struct file *file = (struct file *)ctx->a;

		event->aux2 = file->f_flags;
		/* BOTH, and measured: an `execve` reaches `security_file_open`
		 * with `__FMODE_EXEC` in **f_flags**, which is where
		 * `do_open_execat` puts it -- `f_mode` does not necessarily
		 * carry FMODE_EXEC at this point. Checking only f_mode reported
		 * a denied binary as `open_read`, which is true but useless:
		 * "the agent tried to run something it may not run" is the row
		 * the user is looking for. */
		if ((file->f_mode & FMODE_EXEC) || (file->f_flags & __FMODE_EXEC))
			event->op = BSO_OPEN_EXEC;
		else if (file->f_mode & FMODE_WRITE)
			event->op = BSO_OPEN_WRITE;
		else
			event->op = BSO_OPEN_READ;
	}
	sentry_emit_denial(event);
	return 0;
}

#define SENTRY_DENIAL(sym, operation, source) {				\
	.symbol = (sym), .op = (operation), .src = (source),		\
	.rp = {								\
		.handler = sentry_krp_denial,				\
		.entry_handler = sentry_krp_denial_entry,		\
		.data_size = sizeof(struct sentry_denial_ctx),		\
		.maxactive = 64,					\
		.kp.symbol_name = (sym),				\
	},								\
}

static struct sentry_denial_probe sentry_denial_probes[] = {
	SENTRY_DENIAL("security_file_open",	BSO_OPEN_READ,	SPS_FILE),
	SENTRY_DENIAL("security_path_mknod",	BSO_CREATE,	SPS_DIR_DENTRY),
	SENTRY_DENIAL("security_path_mkdir",	BSO_MKDIR,	SPS_DIR_DENTRY),
	SENTRY_DENIAL("security_path_rmdir",	BSO_RMDIR,	SPS_DIR_DENTRY),
	SENTRY_DENIAL("security_path_unlink",	BSO_UNLINK,	SPS_DIR_DENTRY),
	SENTRY_DENIAL("security_path_symlink",	BSO_SYMLINK,	SPS_DIR_DENTRY),
	SENTRY_DENIAL("security_path_link",	BSO_LINK,	SPS_LINK),
	SENTRY_DENIAL("security_path_rename",	BSO_RENAME,	SPS_DIR_DENTRY),
	SENTRY_DENIAL("security_path_truncate",	BSO_TRUNCATE,	SPS_PATH),
	SENTRY_DENIAL("security_file_truncate",	BSO_TRUNCATE,	SPS_FILE),
};

/* -------- seccomp -------------------------------------------------- */
/*
 * `audit_seccomp` is the one call the kernel makes on a logged seccomp action.
 * `seccomp_log` is static and inlined on this kernel, so this is the probe
 * point; `audit_seccomp` fires on entry whether or not auditd is running, which
 * is what makes it usable here.
 *
 * It is reached only when the filter was installed with
 * SECCOMP_FILTER_FLAG_LOG **and** the action is in
 * /proc/sys/kernel/seccomp/actions_logged. Both are arranged by the userspace
 * side; see bromure_openshell.py and bromure-sandboxd.
 */
static const char *sentry_seccomp_action(u32 code)
{
	switch (code & 0xffff0000u) {
	case 0x80000000u:	return "kill_process";
	case 0x00000000u:	return "kill_thread";
	case 0x00030000u:	return "trap";
	case 0x00050000u:	return "errno";
	case 0x7fc00000u:	return "user_notif";
	case 0x7ff00000u:	return "trace";
	case 0x7ffc0000u:	return "log";
	default:		return "unknown";
	}
}

static int sentry_kp_seccomp(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event *event = sentry_probe_event();

	if (!sentry_task_sandboxed())
		return 0;
	sentry_tally(BST_SYSCALL_DENIED);
	sentry_fill_common(event, BSK_SECCOMP_DENIED);
	/* The syscall NUMBER, not a name: a name table in the module would be a
	 * second copy of something the host already has, and the two would
	 * eventually disagree. */
	event->aux1 = (u32)regs->regs[0];
	event->aux2 = (u32)regs->regs[2];
	strscpy(event->arg, sentry_seccomp_action((u32)regs->regs[2]),
		sizeof(event->arg));
	{
		struct file *exe;

		rcu_read_lock();
		exe = current->mm ? rcu_dereference(current->mm->exe_file) : NULL;
		if (exe) {
			char *rendered = file_path(exe, event->path,
						   sizeof(event->path));

			if (IS_ERR(rendered))
				event->path[0] = '\0';
			else if (rendered != event->path)
				memmove(event->path, rendered,
					strnlen(rendered,
						sizeof(event->path) - 1) + 1);
		}
		rcu_read_unlock();
	}
	sentry_emit_denial(event);
	return 0;
}

/* ------------------------------------------------------------------ */
/* Network flows                                                        */
/* ------------------------------------------------------------------ */
/*
 * One event the first time a socket talks to a destination. Never per packet:
 * a `curl` of a large file is one flow, and so is a `ping -i0.2` that runs for
 * a minute.
 *
 * The probe points were chosen by TRACING, not from the header files, and two
 * of the guesses in the original brief turned out to be wrong on this image:
 *
 *   ping -c1 1.1.1.1   ->  ip4_datagram_connect x2, raw_sendmsg x1
 *   curl https://…     ->  tcp_connect x1
 *   connected UDP      ->  ip4_datagram_connect, udp_sendmsg
 *   unconnected UDP    ->  udp_sendmsg
 *
 * So: Ubuntu's `ping` uses a RAW socket, not a ping socket, because
 * `net.ipv4.ping_group_range` is `1 0` -- an empty range -- and `/usr/bin/ping`
 * carries `cap_net_raw=ep`. `ping_v4_sendmsg` never fires here. It is probed
 * anyway: it costs one kprobe and it becomes the live path the moment that
 * sysctl is widened, which is also the only way a SANDBOXED ping can work at
 * all (nnp drops the file capability, so a confined `ping` gets neither socket).
 *
 * And `ping` *does* call `connect()`, so the existing `connect` event was never
 * blind to ICMP. The reason for `net_flow` is the fields and the chain.
 */

enum sentry_flow_src {
	SFS_SOCK,		/* arg0 is a struct sock *, destination from it  */
	SFS_SOCK_MSG,		/* arg0 sock, arg1 a struct msghdr *            */
};

struct sentry_flow_probe {
	const char *symbol;
	u8 proto;
	u8 src;
	struct kprobe probe;
	bool registered;
};

/* Destination from a connected socket. */
static void sentry_dst_from_sock(struct bromure_sentry_event *event,
				 struct sock *sk)
{
	if (!sk)
		return;
	event->addr_family = (u8)sk->sk_family;
	event->ip_proto = (u8)sk->sk_protocol;
	event->aux2 = ntohs(sk->sk_dport);
	event->sport = (u16)sk->sk_num;
	if (sk->sk_family == AF_INET) {
		__be32 v4 = sk->sk_daddr;

		memcpy(event->addr, &v4, sizeof(v4));
	} else if (sk->sk_family == AF_INET6) {
#if IS_ENABLED(CONFIG_IPV6)
		memcpy(event->addr, &sk->sk_v6_daddr, sizeof(event->addr));
#endif
	}
}

/* Destination from a kernel-side sockaddr. `__sys_connect` and `__sys_sendto`
 * copy the address in before the protocol sees it, so this is kernel memory and
 * needs no user access. */
static void sentry_dst_from_addr(struct bromure_sentry_event *event,
				 struct sockaddr *uaddr, int len)
{
	if (!uaddr)
		return;
	if (uaddr->sa_family == AF_INET && len >= (int)sizeof(struct sockaddr_in)) {
		struct sockaddr_in *in4 = (struct sockaddr_in *)uaddr;

		event->addr_family = AF_INET;
		memcpy(event->addr, &in4->sin_addr, sizeof(in4->sin_addr));
		event->aux2 = ntohs(in4->sin_port);
	} else if (uaddr->sa_family == AF_INET6 &&
		   len >= (int)sizeof(struct sockaddr_in6)) {
		struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)uaddr;

		event->addr_family = AF_INET6;
		memcpy(event->addr, &in6->sin6_addr, sizeof(event->addr));
		event->aux2 = ntohs(in6->sin6_port);
	}
}

/* The flow's protocol LABEL, from the socket rather than from the probe it was
 * caught on.
 *
 * Measured, and the reason this exists: `ip4_datagram_connect` is `udp_prot`'s
 * connect AND `ping_prot`'s, so a `ping -c1` fires it -- and a static per-probe
 * label reported that flow as `udp`. The socket always knows what it is, so ask
 * it, and keep the table's label only as the fallback for a socket that does
 * not say (an unusual `sk_protocol` on a shared entry point).
 *
 * `sk_type` is checked before `sk_protocol` because a RAW socket carries the
 * protocol it was opened with -- `socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)` has
 * `sk_protocol == IPPROTO_ICMP` and is still a raw socket, which is a different
 * capability and belongs in a different bucket.
 */
static u8 sentry_proto_from_sock(struct sock *sk)
{
	if (!sk)
		return BSPR_NONE;
	if (sk->sk_type == SOCK_RAW)
		return BSPR_RAW;
	switch (sk->sk_protocol) {
	case IPPROTO_TCP:
		return BSPR_TCP;
	case IPPROTO_UDP:
		return BSPR_UDP;
	case IPPROTO_ICMP:
		return BSPR_ICMP;
	case IPPROTO_ICMPV6:
		return BSPR_ICMPV6;
	default:
		return BSPR_NONE;
	}
}

/* The ICMP type byte, for a ping socket's send.
 *
 * The contract asks for `icmp_type` "when cheap". It was not cheap when this
 * was written -- reading the message meant a faulting copy from a kprobe
 * handler -- and the field shipped as 0xff ("not read") for two rounds. It is
 * cheap now: `sentry_copy_user_nofault` exists, and one byte is all it takes.
 *
 * A ping socket's send begins with the full ICMP header the application built:
 * type, code, checksum, id, sequence. `ping_v4_sendmsg` reads the same eight
 * bytes with `memcpy_from_msg`, so byte 0 is the type. (The kernel then
 * overrides the id with the socket's local port, which is why `sport` carries
 * the echo identifier.)
 *
 * PING SOCKETS ONLY, never raw. A raw socket with `IP_HDRINCL` supplies the IP
 * header itself, so byte 0 there is version/IHL -- 0x45 -- which would be
 * reported as `icmp_type: 69`. For a raw socket the type is not determinable
 * without parsing a header whose presence depends on a socket option, so it
 * stays "not read": a field that is honestly absent beats a field that is
 * confidently wrong.
 *
 * `iter_iov_addr` is a header macro over `iter_iov`, which handles ITER_UBUF
 * and ITER_IOVEC alike, so this adapts at compile time to whatever kernel the
 * module is built against rather than reaching into `iov_iter` by hand.
 */
static void sentry_fill_icmp_type(struct bromure_sentry_event *event,
				  struct msghdr *msg)
{
	const struct iov_iter *iter;
	u8 type;

	if (!msg)
		return;
	iter = &msg->msg_iter;
	/* User-backed only. A kvec or bvec send is the kernel's own, and
	 * `iter_iov_addr` would not be a user address. */
	if (!iter_is_ubuf(iter) && !iter_is_iovec(iter))
		return;
	if (iter_iov_len(iter) < 1)
		return;
	/* `copy_from_user_nofault` directly, not the string helper beside it:
	 * this is a FIXED one-byte binary read, and the string helper stops at
	 * the first NUL -- so an ICMP type of 0 (echo reply) would come back as
	 * "nothing copied" and the field would stay unread for exactly the value
	 * that is hardest to distinguish from absent. */
	if (copy_from_user_nofault(&type, (const void __user *)iter_iov_addr(iter),
				   sizeof(type)))
		return;
	event->icmp_type = type;
}

static int sentry_kp_flow(struct kprobe *probe, struct pt_regs *regs)
{
	struct sentry_flow_probe *entry =
		container_of(probe, struct sentry_flow_probe, probe);
	struct sock *sk = (struct sock *)regs->regs[0];
	struct bromure_sentry_event *event = sentry_probe_event();

	if (!sk)
		return 0;
	/* AF_INET and AF_INET6 only. A unix-socket send is not a network flow,
	 * and reporting one would bury the flows that are. */
	if (sk->sk_family != AF_INET && sk->sk_family != AF_INET6)
		return 0;

	sentry_fill_common(event, BSK_NET_FLOW);
	event->proto = sentry_proto_from_sock(sk);
	if (event->proto == BSPR_NONE)
		event->proto = entry->proto;
	sentry_dst_from_sock(event, sk);

	/* There used to be a guard here skipping a ping socket's CONNECT, so the
	 * echo identifier (the local port, which may be unbound at connect time)
	 * could not be lost to the dedup. It is gone because no probe watches a
	 * datagram connect any more -- see the table. Removed rather than left
	 * in: an unreachable branch in a security module is a claim nobody can
	 * check. */

	switch (entry->src) {
	case SFS_SOCK_MSG: {
		struct msghdr *msg = (struct msghdr *)regs->regs[1];

		/* An unconnected send names its destination in the message; a
		 * connected one leaves it NULL and the socket already has it. */
		if (msg && msg->msg_name)
			sentry_dst_from_addr(event,
					     (struct sockaddr *)msg->msg_name,
					     msg->msg_namelen);
		/* A ping socket's first byte is the ICMP type it is sending.
		 * Not for raw -- see the helper. */
		if (event->proto == BSPR_ICMP || event->proto == BSPR_ICMPV6)
			sentry_fill_icmp_type(event, msg);
		break;
	}
	default:
		break;
	}

	/* ICMP has no ports. For a ping socket the kernel puts the echo
	 * identifier in the local port, which is the one number that lets the
	 * host match a reply to a request -- so it travels as `sport`. For a RAW
	 * socket the identifier is in the payload, which would mean reading the
	 * iov in a kprobe; not worth a fault for a field the host treats as a
	 * hint. `icmp_type` stays 0xff ("not read") for the same reason. */
	if (event->proto == BSPR_ICMP || event->proto == BSPR_ICMPV6 ||
	    event->proto == BSPR_RAW)
		event->aux2 = 0;

	/* `send()` with nowhere to send it: the syscall is about to fail with
	 * -EDESTADDRREQ and no packet will leave. See above. */
	if (sentry_flow_no_destination(event))
		return 0;

	/* Before the chain walk, so a suppressed flow costs no ancestry. */
	if (sentry_flow_held_back(event)) {
		sentry_tally(BST_FLOW_LOCAL);
		return 0;
	}

	/* The exe and the ancestry, but only for a flow that is going to be
	 * reported. Both cost real work -- a dentry walk and up to eight task
	 * dereferences -- and a folded repeat needs neither, because the event
	 * holding the slot already carries them for this same pid. */
	if (!sentry_dedup_live(event)) {
		sentry_fill_exe(event);
		sentry_fill_chain(event);
	}
	/* Folded exactly like a denial: one event per (pid, proto, dst, dport)
	 * per window, with a count. A socket-lifetime key would need per-socket
	 * storage, and the only place to put it is `sk_user_data`, which belongs
	 * to the protocol -- so the window is the honest approximation, and for
	 * TCP it makes no difference because `tcp_connect` fires once per
	 * connection anyway. */
	sentry_emit_denial(event);
	return 0;
}

#define SENTRY_FLOW(sym, protocol, source) {				\
	.symbol = (sym), .proto = (protocol), .src = (source),		\
}

/*
 * Nine probes, one kind. Every entry here is a `struct proto` method, which is
 * what makes reading arg0/arg1 safe to assert rather than to hope: the
 * prototypes are fixed by the vtable, not by each implementation --
 *
 *   int (*sendmsg)(struct sock *sk, struct msghdr *msg, size_t len);
 *   int (*connect)(struct sock *sk, struct sockaddr *uaddr, int addr_len);
 *
 * -- so arg0 is always the sock and arg1 is always the msghdr or the sockaddr.
 * Four of the nine also appear in `include/net/` and were checked directly;
 * the other five are static to their translation units and are guaranteed by
 * the vtable they are assigned into. `tcp_connect(struct sock *sk)` is the one
 * that is not a proto method, and takes the sock alone.
 *
 * The sockaddr and `msg->msg_name` are KERNEL memory: `__sys_connect` and
 * `__sys_sendto`/`copy_msghdr_from_user` both run `move_addr_to_kernel` before
 * the protocol sees them, so nothing here touches user memory.
 */
static struct sentry_flow_probe sentry_flow_probes[] = {
	/* TCP, once the source port is chosen. Shared by v4 and v6. */
	SENTRY_FLOW("tcp_connect",		BSPR_TCP,	SFS_SOCK),
	/* NOT `ip4_datagram_connect`/`ip6_datagram_connect`. A datagram connect
	 * is not a packet: it only records where this socket will send if it
	 * ever sends. Probing it put rows on the timeline for traffic that
	 * never existed -- iputils connects a UDP socket to dst:1025 purely to
	 * ask the routing table which source address it would use, and never
	 * sends a byte, which arrived live as
	 * "bash -> ping -> UDP 1.1.1.1:1025". Any `getaddrinfo`-style route
	 * lookup does the same.
	 *
	 * So UDP -- connected or not -- is reported on its FIRST SEND, from the
	 * two probes below. A connected send leaves `msg_name` NULL and the
	 * destination comes off the socket, which `sentry_dst_from_sock`
	 * already does, so nothing is lost by not watching the connect. TCP is
	 * different and unchanged: `tcp_connect` IS a packet, the SYN.
	 */
	/* Sends: unconnected UDP names its destination per message; a connected
	 * one leaves it NULL and the socket carries it. */
	SENTRY_FLOW("udp_sendmsg",		BSPR_UDP,	SFS_SOCK_MSG),
	SENTRY_FLOW("udpv6_sendmsg",		BSPR_UDP,	SFS_SOCK_MSG),
	/* Ping sockets. Dead while `ping_group_range` is `1 0` (Ubuntu's
	 * shipped value), live once it names the workload's gid -- which
	 * `bromure-sandboxd` now does at boot, and which is the only way a
	 * sandboxed `ping` can work at all, since `no_new_privs` means the
	 * `cap_net_raw` on /usr/bin/ping is not honoured. */
	SENTRY_FLOW("ping_v4_sendmsg",		BSPR_ICMP,	SFS_SOCK_MSG),
	SENTRY_FLOW("ping_v6_sendmsg",		BSPR_ICMPV6,	SFS_SOCK_MSG),
	/* Raw sockets. This is what Ubuntu's `ping` actually uses today. */
	SENTRY_FLOW("raw_sendmsg",		BSPR_RAW,	SFS_SOCK_MSG),
	SENTRY_FLOW("rawv6_sendmsg",		BSPR_RAW,	SFS_SOCK_MSG),
};

struct sentry_kprobe {
	const char *symbol;
	kprobe_pre_handler_t handler;
	struct kprobe probe;
	bool registered;
};

static struct sentry_kprobe sentry_kprobes[] = {
	{ "audit_seccomp",		sentry_kp_seccomp },
	{ "__arm64_sys_setuid",		sentry_kp_setuid },
	{ "__arm64_sys_setreuid",	sentry_kp_setuid },
	{ "__arm64_sys_setresuid",	sentry_kp_setuid },
	{ "__arm64_sys_setgid",		sentry_kp_setgid },
	{ "__arm64_sys_setregid",	sentry_kp_setgid },
	{ "__arm64_sys_setresgid",	sentry_kp_setgid },
	{ "__arm64_sys_capset",		sentry_kp_capset },
	{ "commit_creds",		sentry_kp_commit_creds },
	{ "__arm64_sys_ptrace",		sentry_kp_ptrace },
	{ "do_init_module",		sentry_kp_do_init_module },
	{ "__arm64_sys_delete_module",	sentry_kp_delete_module },
	{ "__arm64_sys_bpf",		sentry_kp_bpf },
	{ "__arm64_sys_kexec_load",	sentry_kp_kexec },
	{ "__arm64_sys_kexec_file_load", sentry_kp_kexec },
	{ "__arm64_sys_mount",		sentry_kp_mount },
	{ "__arm64_sys_unshare",	sentry_kp_unshare },
	{ "__arm64_sys_setns",		sentry_kp_setns },
	{ "security_bprm_committed_creds", sentry_kp_exec },
};

/*
 * Blinding detection, in two layers, because one is not enough.
 *
 * `kprobe_disabled()` catches an individually disabled probe (KPROBE_FLAG_DISABLED)
 * and a probe whose symbol went away (KPROBE_FLAG_GONE). What it does NOT catch
 * is the global switch: writing 0 to debugfs `kprobes/enabled` runs
 * `disarm_all_kprobes`, which sets the file-scope `kprobes_all_disarmed` and
 * physically disarms every probe WITHOUT touching any `p->flags`. Measured in
 * this VM: with the global switch off, every probe still reported itself armed
 * and no events flowed. A host trusting that count would have seen a healthy
 * sentry go silent and believed it.
 *
 * `kprobes_all_disarmed` is file-scope in kernel/kprobes.c and not exported, so
 * the second layer does not try to read kernel state at all: the module keeps a
 * kprobe on a `noinline` function of its own and calls it once per heartbeat.
 * If the counter does not move, probes are not firing — whatever the reason,
 * whether the global switch, ftrace, or something not invented yet. The host
 * gets `canary:false` and an `armed` of 0.
 */
static noinline void sentry_canary_target(void)
{
	/* Empty, never inlined, and reachable only from the heartbeat: its only
	 * purpose is to be somewhere a kprobe can fire. */
	asm volatile("" ::: "memory");
}

static atomic_t sentry_canary_hits = ATOMIC_INIT(0);

static int sentry_kp_canary(struct kprobe *probe, struct pt_regs *regs)
{
	atomic_inc(&sentry_canary_hits);
	return 0;
}

static struct kprobe sentry_canary_probe = {
	.pre_handler = sentry_kp_canary,
};
static bool canary_probe_registered;

static bool sentry_canary_fires(void)
{
	int before;

	if (!canary_probe_registered)
		return false;
	before = atomic_read(&sentry_canary_hits);
	sentry_canary_target();
	return atomic_read(&sentry_canary_hits) != before;
}

/*
 * `ftrace` counts how many probes the kernel chose to implement through ftrace
 * rather than a breakpoint. It matters because `sysctl kernel.ftrace_enabled=0`
 * is writable by root even under lockdown=integrity, and would silently disarm
 * any ftrace-based probe.
 *
 * On this kernel the count is zero: `CONFIG_KPROBES_ON_FTRACE` is not set, no
 * probe in `kprobes/list` carries the `[FTRACE]` marker, and writing
 * `ftrace_enabled=0` left every event flowing and the canary true. But that is a
 * kernel CONFIG away from changing, and an assumption about someone else's build
 * options is not something to leave implicit — so the module reports the number
 * and the host can alarm if it is ever non-zero.
 */
static void sentry_probe_health(int *armed, int *total, u64 *missed, bool *canary,
				int *ftrace)
{
	size_t i;

	*armed = 0;
	*total = 0;
	*missed = 0;
	*ftrace = 0;
	*canary = sentry_canary_fires();

	for (i = 0; i < ARRAY_SIZE(sentry_kprobes); i++) {
		struct sentry_kprobe *entry = &sentry_kprobes[i];

		if (!entry->registered)
			continue;
		(*total)++;
		*missed += entry->probe.nmissed;
		if (kprobe_ftrace(&entry->probe))
			(*ftrace)++;
		if (!kprobe_disabled(&entry->probe))
			(*armed)++;
	}
	for (i = 0; i < ARRAY_SIZE(sentry_tc_probes); i++) {
		struct sentry_tc_probe *entry = &sentry_tc_probes[i];

		if (!entry->registered)
			continue;
		(*total)++;
		*missed += entry->probe.nmissed;
		if (kprobe_ftrace(&entry->probe))
			(*ftrace)++;
		if (!kprobe_disabled(&entry->probe))
			(*armed)++;
	}
	for (i = 0; i < ARRAY_SIZE(sentry_flow_probes); i++) {
		struct sentry_flow_probe *entry = &sentry_flow_probes[i];

		if (!entry->registered)
			continue;
		(*total)++;
		*missed += entry->probe.nmissed;
		if (kprobe_ftrace(&entry->probe))
			(*ftrace)++;
		if (!kprobe_disabled(&entry->probe))
			(*armed)++;
	}
	for (i = 0; i < ARRAY_SIZE(sentry_denial_probes); i++) {
		struct sentry_denial_probe *entry = &sentry_denial_probes[i];

		if (!entry->registered)
			continue;
		(*total)++;
		*missed += entry->rp.nmissed + entry->rp.kp.nmissed;
		if (kprobe_ftrace(&entry->rp.kp))
			(*ftrace)++;
		if (!kprobe_disabled(&entry->rp.kp))
			(*armed)++;
	}
	{
		struct kretprobe *rp[] = {
			load_module_kretprobe_registered
				? &sentry_load_module_kretprobe : NULL,
			lockdown_kretprobe_registered
				? &sentry_lockdown_kretprobe : NULL,
		};
		size_t j;

		for (j = 0; j < ARRAY_SIZE(rp); j++) {
			if (!rp[j])
				continue;
			(*total)++;
			*missed += rp[j]->nmissed + rp[j]->kp.nmissed;
			if (kprobe_ftrace(&rp[j]->kp))
				(*ftrace)++;
			if (!kprobe_disabled(&rp[j]->kp))
				(*armed)++;
		}
	}

	/* Nothing is firing: the per-probe flags are not to be believed. */
	if (!*canary)
		*armed = 0;
}

/* The per-probe detail, sent once in the hello so the host knows the baseline
 * the heartbeat counts are against. */
static int sentry_probe_list(char *out, size_t out_len)
{
	size_t i;
	int used = 0;
	bool first = true;

	for (i = 0; i < ARRAY_SIZE(sentry_kprobes); i++) {
		struct sentry_kprobe *entry = &sentry_kprobes[i];

		if (!entry->registered)
			continue;
		used += scnprintf(out + used, out_len - used, "%s\"%s\"",
				  first ? "" : ",", entry->symbol);
		first = false;
	}
	for (i = 0; i < ARRAY_SIZE(sentry_flow_probes); i++) {
		if (!sentry_flow_probes[i].registered)
			continue;
		used += scnprintf(out + used, out_len - used, "%s\"%s\"",
				  first ? "" : ",", sentry_flow_probes[i].symbol);
		first = false;
	}
	for (i = 0; i < ARRAY_SIZE(sentry_tc_probes); i++) {
		if (!sentry_tc_probes[i].registered)
			continue;
		used += scnprintf(out + used, out_len - used, "%s\"%s\"",
				  first ? "" : ",", sentry_tc_probes[i].symbol);
		first = false;
	}
	for (i = 0; i < ARRAY_SIZE(sentry_denial_probes); i++) {
		if (!sentry_denial_probes[i].registered)
			continue;
		used += scnprintf(out + used, out_len - used, "%s\"%s\"",
				  first ? "" : ",", sentry_denial_probes[i].symbol);
		first = false;
	}
	if (load_module_kretprobe_registered)
		used += scnprintf(out + used, out_len - used, ",\"%s\"",
				  sentry_load_module_kretprobe.kp.symbol_name);
	if (lockdown_kretprobe_registered)
		used += scnprintf(out + used, out_len - used, ",\"%s\"",
				  sentry_lockdown_kretprobe.kp.symbol_name);
	return used;
}

static int sentry_register_probes(int *armed, int *missing)
{
	size_t i;

	*armed = 0;
	*missing = 0;

	for (i = 0; i < ARRAY_SIZE(sentry_kprobes); i++) {
		struct sentry_kprobe *entry = &sentry_kprobes[i];
		int rc;

		entry->probe.symbol_name = entry->symbol;
		entry->probe.pre_handler = entry->handler;
		rc = register_kprobe(&entry->probe);
		if (rc < 0) {
			pr_info(SENTRY_NAME ": no probe for %s (%d)\n",
				entry->symbol, rc);
			(*missing)++;
			continue;
		}
		entry->registered = true;
		(*armed)++;
	}

	sentry_canary_probe.addr = (kprobe_opcode_t *)sentry_canary_target;
	if (register_kprobe(&sentry_canary_probe) == 0) {
		canary_probe_registered = true;
	} else {
		pr_warn(SENTRY_NAME ": canary probe unavailable; blinding via the "
			"global kprobe switch will not be detectable\n");
	}

	for (i = 0; i < ARRAY_SIZE(sentry_tc_probes); i++) {
		struct sentry_tc_probe *entry = &sentry_tc_probes[i];

		entry->probe.symbol_name = entry->symbol;
		entry->probe.pre_handler = sentry_kp_tc;
		if (register_kprobe(&entry->probe) == 0) {
			entry->registered = true;
			(*armed)++;
		} else {
			/* Losing one of these means a `tc` path the host cannot
			 * see, which it would otherwise read as "no tampering".
			 * The hello's probe list is what tells it which. */
			(*missing)++;
			pr_warn(SENTRY_NAME ": tc probe %s unavailable\n",
				entry->symbol);
		}
	}

	for (i = 0; i < ARRAY_SIZE(sentry_flow_probes); i++) {
		struct sentry_flow_probe *entry = &sentry_flow_probes[i];

		entry->probe.symbol_name = entry->symbol;
		entry->probe.pre_handler = sentry_kp_flow;
		if (register_kprobe(&entry->probe) == 0) {
			entry->registered = true;
			(*armed)++;
		} else {
			/* A protocol this kernel does not build is a gap in what
			 * the host can see, not a reason to refuse: the others
			 * still report, and the hello's probe list says which. */
			(*missing)++;
			pr_warn(SENTRY_NAME ": flow probe %s unavailable\n",
				entry->symbol);
		}
	}

	for (i = 0; i < ARRAY_SIZE(sentry_denial_probes); i++) {
		struct sentry_denial_probe *entry = &sentry_denial_probes[i];

		if (register_kretprobe(&entry->rp) == 0) {
			entry->registered = true;
			(*armed)++;
		} else {
			/* A hook this kernel does not have is a gap in what the
			 * host can see, not a reason to refuse to run: the other
			 * nine still report. The hello's probe list is what says
			 * which ones are live. */
			(*missing)++;
			pr_warn(SENTRY_NAME ": denial probe %s unavailable\n",
				entry->symbol);
		}
	}

	if (register_kretprobe(&sentry_load_module_kretprobe) == 0) {
		load_module_kretprobe_registered = true;
		(*armed)++;
	} else {
		(*missing)++;
	}

	if (register_kretprobe(&sentry_lockdown_kretprobe) == 0) {
		lockdown_kretprobe_registered = true;
		(*armed)++;
	} else {
		(*missing)++;
	}

	return *armed ? 0 : -ENODEV;
}

/* ------------------------------------------------------------------ */
/* Init. There is deliberately no exit.                                 */
/* ------------------------------------------------------------------ */

static int sentry_make_secret(void)
{
	struct crypto_shash *tfm;
	struct shash_desc *desc;
	u8 digest[32];
	int rc;
	int i;

	get_random_bytes(sentry_secret, sizeof(sentry_secret));
	for (i = 0; i < (int)sizeof(sentry_secret); i++)
		scnprintf(sentry_secret_hex + i * 2, 3, "%02x",
			  (unsigned char)sentry_secret[i]);

	tfm = crypto_alloc_shash("sha256", 0, 0);
	if (IS_ERR(tfm))
		return PTR_ERR(tfm);
	desc = kzalloc(sizeof(*desc) + crypto_shash_descsize(tfm), GFP_KERNEL);
	if (!desc) {
		crypto_free_shash(tfm);
		return -ENOMEM;
	}
	desc->tfm = tfm;
	/* Digest the hex form: that is exactly the string the host sees in the
	 * hello frame, so both sides hash the same bytes with no encoding
	 * question left to get wrong. */
	rc = crypto_shash_digest(desc, sentry_secret_hex,
				 strlen(sentry_secret_hex), digest);
	kfree(desc);
	crypto_free_shash(tfm);
	if (rc)
		return rc;

	for (i = 0; i < (int)sizeof(digest); i++)
		scnprintf(sentry_secret_digest + i * 2, 3, "%02x", digest[i]);
	return 0;
}

/*
 * Shutdown. Systemd tears the machine down by unmounting everything, which
 * arrives as a burst of `mount` events from pid 1 -- `/`, `/home/ubuntu`,
 * `/mnt/bromure-outbox` -- on a machine that is going away. Labelling them
 * `shutdown` is what stops the last thing in a workspace's timeline being an
 * alarm.
 */
static int sentry_reboot_notify(struct notifier_block *self, unsigned long code,
				void *unused)
{
	/* A backstop, not the primary signal: by the time this fires, userspace has
	 * already done its unmounting. The shutdown unit (see PATCHES.md) declares
	 * the phase while systemd is still stopping things. This catches a machine
	 * that went down without it. */
	if (sentry_phase < 2) {
		sentry_phase = 2;
		sentry_phase_setter_pid = task_tgid_nr(current);
		strscpy(sentry_phase_setter_comm, "reboot_notifier",
			sizeof(sentry_phase_setter_comm));
	}
	return NOTIFY_DONE;
}

static struct notifier_block sentry_reboot_nb = {
	.notifier_call = sentry_reboot_notify,
	/* Early, so the unmount burst it exists to label is already covered. */
	.priority = INT_MAX,
};

static int __init sentry_init(void)
{
	int rc;
	int armed = 0, missing = 0;
	int i;

	/* The fifo is allocated once and sized in whole events, so the event's
	 * size is kernel memory held for the life of the module. 512 was the
	 * right bound until argv (1024) and the ancestor chain (8 x 28) made the
	 * record genuinely larger; the budget moved with it rather than the guard
	 * being deleted, because the guard's job is to make the next person who
	 * grows this think about the fifo.
	 *
	 * 2 KiB x 256 events = 512 KiB. Grow either and do the arithmetic again. */
	BUILD_BUG_ON(sizeof(struct bromure_sentry_event) > 2048);
	/* The frame budget, as arithmetic rather than as a comment. A rendered
	 * frame that does not fit is TRUNCATED, which is invalid JSON rather
	 * than a short record -- the host drops the connection, not the field.
	 * Worst case is every escapable byte becoming \uXXXX (6 bytes), so
	 * growing any of these lengths, or CHAIN_MAX, has to grow JSON_MAX with
	 * it. Currently ~11.1 KB against 12288, which is thinner headroom than
	 * it looks and is exactly why this is checked by the compiler. */
	BUILD_BUG_ON(SENTRY_JSON_MAX <
		     (BROMURE_SENTRY_ARGV_LEN + BROMURE_SENTRY_PATH_LEN +
		      BROMURE_SENTRY_ARG_LEN + BROMURE_SENTRY_COMM_LEN) * 6 +
		     BROMURE_SENTRY_CHAIN_MAX *
		     (BROMURE_SENTRY_COMM_LEN * 6 + 64) + 512);
	BUILD_BUG_ON(sizeof(struct bromure_sentry_event) * SENTRY_FIFO_EVENTS
		     > 512 * 1024);

	spin_lock_init(&state.fifo_lock);
	spin_lock_init(&state.bucket_lock);
	atomic64_set(&state.seq, 0);
	atomic64_set(&state.dropped, 0);
	atomic64_set(&state.rate_limited, 0);
	state.last_refill = jiffies;
	for (i = 0; i < BSK_MAX; i++)
		state.tokens[i] = SENTRY_TOKENS_BURST;

	rc = kfifo_alloc(&state.fifo,
			 SENTRY_FIFO_EVENTS * sizeof(struct bromure_sentry_event),
			 GFP_KERNEL);
	if (rc)
		return rc;

	rc = sentry_make_secret();
	if (rc) {
		kfifo_free(&state.fifo);
		return rc;
	}

	rc = sentry_register_probes(&armed, &missing);
	if (rc) {
		pr_err(SENTRY_NAME ": no probes could be armed\n");
		kfifo_free(&state.fifo);
		return rc;
	}

	/* The container mark. `nf_register_net_hook` puts these OUTSIDE
	 * iptables, so `iptables -F` and Docker's own chain rewrites cannot
	 * remove them, and lockdown keeps the module loaded -- which together
	 * are what make the mark something the host can believe.
	 *
	 * A failure here is NOT fatal to the module. The sentry's job is
	 * reporting; losing the mark costs a workspace the option to skip
	 * interception for containers, and the host fails closed on that by
	 * only trusting a mark the hello announced. Taking the whole sentry
	 * down instead would turn a lost feature into a blind guest.
	 */
	rc = nf_register_net_hooks(&init_net, sentry_nf_ops,
				   ARRAY_SIZE(sentry_nf_ops));
	if (rc) {
		pr_warn(SENTRY_NAME ": container mark unavailable: "
			"nf_register_net_hooks failed (%d)\n", rc);
	} else {
		sentry_nf_registered = true;
		pr_info(SENTRY_NAME ": marking forwarded traffic DSCP %d\n",
			BROMURE_SENTRY_CONTAINER_DSCP);
	}

	register_reboot_notifier(&sentry_reboot_nb);

	state.thread = kthread_run(sentry_thread, NULL, SENTRY_NAME);
	if (IS_ERR(state.thread)) {
		rc = PTR_ERR(state.thread);
		state.thread = NULL;
		kfifo_free(&state.fifo);
		return rc;
	}

#ifndef BROMURE_SENTRY_TESTABLE
	/*
	 * Belt and braces against unload. A module with no exit function is
	 * already refused by delete_module with -EBUSY; raising the refcount
	 * means even a kernel built with MODULE_FORCE_UNLOAD has to be told
	 * twice, and `lsmod` shows the module as permanently in use.
	 */
	__module_get(THIS_MODULE);
#endif

	pr_info(SENTRY_NAME ": v%s armed %d probe(s), %d unavailable\n",
		SENTRY_VERSION, armed, missing);
	return 0;
}

module_init(sentry_init);

#ifdef BROMURE_SENTRY_TESTABLE
/*
 * Test-only handle on the refcount half of the unload refusal.
 *
 * The shipped build calls `__module_get` once at init and never lets go, so
 * `rmmod` sees a nonzero refcount on top of the missing exit path. Proving that
 * by executing it would mean pinning this VM's kernel for good, so instead the
 * testable build exposes the same `__module_get` behind a writable parameter
 * that can also `module_put` it again:
 *
 *     echo 1 | sudo tee /sys/module/bromure_sentry/parameters/pin
 *     sudo rmmod bromure_sentry     # -> EBUSY, refcount held
 *     echo 0 | sudo tee /sys/module/bromure_sentry/parameters/pin
 *     sudo rmmod bromure_sentry     # -> succeeds
 *
 * Same call, same effect on the same counter; only the release is added.
 */
static int sentry_pinned;

static int sentry_pin_set(const char *value, const struct kernel_param *param)
{
	bool want;
	int rc = kstrtobool(value, &want);

	if (rc)
		return rc;
	if (want && !sentry_pinned) {
		__module_get(THIS_MODULE);
		sentry_pinned = 1;
	} else if (!want && sentry_pinned) {
		module_put(THIS_MODULE);
		sentry_pinned = 0;
	}
	return 0;
}

static int sentry_pin_get(char *buffer, const struct kernel_param *param)
{
	return scnprintf(buffer, PAGE_SIZE, "%d\n", sentry_pinned);
}

static const struct kernel_param_ops sentry_pin_ops = {
	.set = sentry_pin_set,
	.get = sentry_pin_get,
};
module_param_cb(pin, &sentry_pin_ops, NULL, 0600);
MODULE_PARM_DESC(pin, "test only: hold/release a module reference");

/*
 * Test-only teardown. The shipped module has no exit path at all — that is the
 * whole tamper-resistance argument — but a build that can only ever be loaded
 * once is a build nobody can iterate on, and requiring a VM reboot per test run
 * means the capture path gets tested less, not more. `build.sh` never defines
 * this; `tests/test_sentry.sh` always does.
 *
 * Order matters: stop producing before stopping the consumer, and free the
 * fifo only once nothing can still reach it.
 */
static void __exit sentry_exit(void)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(sentry_kprobes); i++) {
		if (sentry_kprobes[i].registered)
			unregister_kprobe(&sentry_kprobes[i].probe);
	}
	for (i = 0; i < ARRAY_SIZE(sentry_flow_probes); i++) {
		if (sentry_flow_probes[i].registered)
			unregister_kprobe(&sentry_flow_probes[i].probe);
	}
	for (i = 0; i < ARRAY_SIZE(sentry_tc_probes); i++) {
		if (sentry_tc_probes[i].registered)
			unregister_kprobe(&sentry_tc_probes[i].probe);
	}
	for (i = 0; i < ARRAY_SIZE(sentry_denial_probes); i++) {
		if (sentry_denial_probes[i].registered)
			unregister_kretprobe(&sentry_denial_probes[i].rp);
	}
	/* Before the flush: stop generating forgery events, then let the ones
	 * already folded into a slot out. `nf_unregister_net_hooks` waits for
	 * in-flight hooks to finish, so nothing is mid-`sentry_emit_denial`
	 * when the flush runs. */
	if (sentry_nf_registered) {
		nf_unregister_net_hooks(&init_net, sentry_nf_ops,
					ARRAY_SIZE(sentry_nf_ops));
		sentry_nf_registered = false;
	}
	/* Anything still held in a dedup slot goes out now rather than being
	 * discarded: a denial that happened is a denial the host should see,
	 * even if the module is being taken down a moment later. */
	sentry_dedup_flush(true);
	if (load_module_kretprobe_registered)
		unregister_kretprobe(&sentry_load_module_kretprobe);
	if (lockdown_kretprobe_registered)
		unregister_kretprobe(&sentry_lockdown_kretprobe);
	if (canary_probe_registered)
		unregister_kprobe(&sentry_canary_probe);
	unregister_reboot_notifier(&sentry_reboot_nb);
	/* unregister_kprobe waits for in-flight handlers; this covers the
	 * window where one had already passed the probe and is inside
	 * sentry_submit. */
	synchronize_rcu();

	if (state.thread) {
		kthread_stop(state.thread);
		state.thread = NULL;
	}
	kfifo_free(&state.fifo);
	pr_info(SENTRY_NAME ": unloaded (testable build)\n");
}
module_exit(sentry_exit);
#endif
/* No module_exit in the shipped build: see the file header. Load once, for the
 * life of the VM. */

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Bromure Agentic Coding");
MODULE_DESCRIPTION("Tamper-resistant guest security event stream over vsock");
MODULE_VERSION(SENTRY_VERSION);
MODULE_INFO(bromure_sentry_abi, __stringify(BROMURE_SENTRY_ABI));
