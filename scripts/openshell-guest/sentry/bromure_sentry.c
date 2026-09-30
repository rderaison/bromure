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

#include "bromure_sentry.h"

#ifndef CONFIG_ARM64
#error "bromure_sentry reads syscall arguments through arm64's pt_regs wrapper convention"
#endif

#define SENTRY_NAME    "bromure_sentry"
#define SENTRY_VERSION "1.0.0"

/* Ring capacity in events. A power of two, as kfifo requires. */
#define SENTRY_FIFO_EVENTS 1024
/* Per-kind token bucket: this many events per refill window, refilled 1/s. */
#define SENTRY_TOKENS_PER_SEC 64
#define SENTRY_TOKENS_BURST   256
/* Heartbeat period. */
#define SENTRY_HEARTBEAT_MS 1000
/* Give up on one send after this long rather than wedging the kthread. */
#define SENTRY_SEND_TIMEOUT_S 5
/* Upper bound on one rendered frame. */
#define SENTRY_JSON_MAX 2048

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
	case BSK_CONNECT:			return "connect";
	case BSK_CRED_GAIN:			return "cred_gain";
	case BSK_SANDBOX_DENIED:		return "sandbox_denied";
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
	char json[SENTRY_JSON_MAX];
};

static int sentry_render_event(struct sentry_scratch *scratch, char *out,
			       size_t out_len,
			       const struct bromure_sentry_event *event, u64 seq)
{
	char *comm = scratch->comm;
	char *path = scratch->path;
	char *arg = scratch->arg;
	int used;

	sentry_json_escape(comm, sizeof(scratch->comm), event->comm,
			   sizeof(event->comm));
	sentry_json_escape(path, sizeof(scratch->path), event->path,
			   sizeof(event->path));
	sentry_json_escape(arg, sizeof(scratch->arg), event->arg,
			   sizeof(event->arg));

	used = scnprintf(out, out_len,
		"{\"type\":\"event\",\"seq\":%llu,\"t\":%llu,\"kind\":\"%s\","
		"\"pid\":%u,\"ppid\":%u,\"uid\":%u,\"gid\":%u,\"comm\":\"%s\"",
		seq, event->timestamp_ns, sentry_kind_name(event->kind),
		event->pid, event->ppid, event->uid, event->gid, comm);

	if (path[0])
		used += scnprintf(out + used, out_len - used, ",\"path\":\"%s\"", path);
	if (arg[0])
		used += scnprintf(out + used, out_len - used, ",\"arg\":\"%s\"", arg);

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
	case BSK_CONNECT: {
		char addr[INET6_ADDRSTRLEN + 1] = { 0 };

		if (event->addr_family == AF_INET)
			snprintf(addr, sizeof(addr), "%pI4", event->addr);
		else if (event->addr_family == AF_INET6)
			snprintf(addr, sizeof(addr), "%pI6c", event->addr);
		used += scnprintf(out + used, out_len - used,
				  ",\"family\":%u,\"dst\":\"%s\",\"dport\":%u",
				  event->addr_family, addr, event->aux2);
		break;
	}
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
			"\"landlock_abi\":%d,\"probes\":[",
			1, index, sentry_secret_hex, sentry_boot_id,
			init_utsname()->release, SENTRY_VERSION,
			BROMURE_SENTRY_ABI, sentry_landlock_abi);
	} else {
		if (sentry_proof(proof, sizeof(proof), index) != 0) {
			kfree(json);
			return -EIO;
		}
		len = scnprintf(json, SENTRY_JSON_MAX,
			"{\"type\":\"hello\",\"v\":%d,\"conn\":%u,"
			"\"proof\":\"%s\",\"boot_id\":\"%s\","
			"\"kernel\":\"%s\",\"module\":\"%s\",\"abi\":%d,"
			"\"landlock_abi\":%d,\"probes\":[",
			1, index, proof, sentry_boot_id,
			init_utsname()->release, SENTRY_VERSION,
			BROMURE_SENTRY_ABI, sentry_landlock_abi);
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
		"\"denied_syscalls\":%llu,\"caps_in_userns\":%llu}}",
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
		(u64)atomic64_read(&state.tallies[BST_CAPS_IN_USERNS]));
	return sentry_send_frame(sock, json, len);
}

static int sentry_thread(void *unused)
{
	struct socket *sock = NULL;
	struct sentry_scratch *scratch;
	char *json;
	struct bromure_sentry_event event;
	unsigned long next_heartbeat = jiffies;

	scratch = kzalloc(sizeof(*scratch), GFP_KERNEL);
	if (!scratch)
		return -ENOMEM;
	json = scratch->json;

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

		while (kfifo_out_spinlocked(&state.fifo, &event, sizeof(event),
					    &state.fifo_lock) == sizeof(event)) {
			u64 seq = atomic64_inc_return(&state.seq);
			int len = sentry_render_event(scratch, json,
						      SENTRY_JSON_MAX, &event, seq);

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

static void sentry_copy_user_string(char *dst, size_t dst_len,
				    const void __user *src, u8 *truncated)
{
	long copied;

	dst[0] = '\0';
	if (!src)
		return;
	copied = strncpy_from_user(dst, src, dst_len);
	if (copied < 0) {
		dst[0] = '\0';
		return;
	}
	if ((size_t)copied >= dst_len - 1)
		*truncated = 1;
	dst[dst_len - 1] = '\0';
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
static int sentry_kp_exec(struct kprobe *probe, struct pt_regs *regs)
{
	struct linux_binprm *bprm = (struct linux_binprm *)regs->regs[0];
	struct bromure_sentry_event event;

	sentry_fill_common(&event, BSK_EXEC);
	if (bprm && bprm->filename)
		strscpy(event.path, bprm->filename, sizeof(event.path));
	if (bprm && bprm->interp && bprm->interp != bprm->filename)
		strscpy(event.arg, bprm->interp, sizeof(event.arg));
	sentry_submit(&event);
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
	struct bromure_sentry_event event;
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

	sentry_fill_common(&event, BSK_CRED_GAIN);
	event.aux1 = from_kuid_munged(&init_user_ns, old->euid);
	event.aux2 = from_kuid_munged(&init_user_ns, new->euid);
	event.aux4 = old->cap_permitted.val;
	event.aux3 = new->cap_permitted.val;
	/* Mid-execve means a setuid binary or a file capability taking effect
	 * rather than a syscall. The `exec` event that follows carries the path
	 * from the binprm; here the new mm may not have its exe_file yet, so the
	 * path is best-effort and `comm` is always right. */
	event.flag1 = current->in_execve ? 1 : 0;
	if (current->mm) {
		struct file *exe;

		/* `get_mm_exe_file` is not exported to modules, so read the RCU
		 * pointer directly under rcu_read_lock and take no reference: the
		 * path is rendered and copied before the lock is dropped, and
		 * `d_path` is safe in this context. */
		rcu_read_lock();
		exe = rcu_dereference(current->mm->exe_file);
		if (exe) {
			char *rendered = file_path(exe, event.path,
						   sizeof(event.path));

			if (IS_ERR(rendered))
				event.path[0] = '\0';
			else if (rendered != event.path)
				memmove(event.path, rendered,
					strnlen(rendered, sizeof(event.path) - 1) + 1);
		}
		rcu_read_unlock();
	}
	sentry_submit(&event);
	return 0;
}

static int sentry_kp_ptrace(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event event;

	sentry_fill_common(&event, BSK_PTRACE);
	event.aux1 = (u32)sentry_syscall_arg(regs, 0);	/* request */
	event.aux2 = (u32)sentry_syscall_arg(regs, 1);	/* target pid */
	sentry_submit(&event);
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
	struct bromure_sentry_event event;

	sentry_fill_common(&event, BSK_MODULE_LOAD);
	if (mod) {
		strscpy(event.arg, mod->name, sizeof(event.arg));
		event.aux3 = mod->taints;
#ifdef CONFIG_MODULE_SIG
		event.flag1 = mod->sig_ok ? 1 : 0;
#else
		event.flag1 = 0;
#endif
	}
	event.result = 0;
	sentry_submit(&event);
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
	struct bromure_sentry_event event;

	if (ret >= 0)
		return 0;		/* success is reported by do_init_module */

	sentry_fill_common(&event, BSK_MODULE_LOAD);
	strscpy(event.arg, "<refused>", sizeof(event.arg));
	event.result = (s32)ret;
	event.flag1 = 0;
	sentry_submit(&event);
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
	struct bromure_sentry_event event;

	sentry_fill_common(&event, BSK_MODULE_LOAD);
	strscpy(event.arg, "<delete_module>", sizeof(event.arg));
	event.result = 0;
	event.flag1 = 1;	/* not an unsigned load; the host treats it as info */
	sentry_submit(&event);
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
	struct bromure_sentry_event event;
	u32 command = (u32)sentry_syscall_arg(regs, 0);
	u32 prog_type = 0;

	sentry_fill_common(&event, BSK_BPF_LOAD);
	event.aux1 = command;
	if (command == 5 /* BPF_PROG_LOAD */) {
		const u32 __user *attr =
			(const u32 __user *)sentry_syscall_arg(regs, 1);

		if (attr && get_user(prog_type, attr))
			prog_type = 0;
	}
	event.aux2 = prog_type;
	sentry_submit(&event);
	return 0;
}

static int sentry_kp_kexec(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event event;

	sentry_fill_common(&event, BSK_KEXEC_ATTEMPT);
	strscpy(event.arg, probe->symbol_name, sizeof(event.arg));
	sentry_submit(&event);
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
	struct bromure_sentry_event event;

	if (ret >= 0)
		return 0;

	sentry_fill_common(&event, BSK_LOCKDOWN_CHANGE_ATTEMPT);
	event.result = (s32)ret;
	event.flag1 = 1;	/* a rejected write is an attempt to lower */
	sentry_submit(&event);
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
	struct bromure_sentry_event event;

	sentry_fill_common(&event, BSK_MOUNT);
	sentry_copy_user_string(event.path, sizeof(event.path),
				(const void __user *)sentry_syscall_arg(regs, 1),
				&event.truncated);
	sentry_copy_user_string(event.arg, sizeof(event.arg),
				(const void __user *)sentry_syscall_arg(regs, 2),
				&event.truncated);
	sentry_submit(&event);
	return 0;
}

static int sentry_kp_unshare(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event event;

	sentry_fill_common(&event, BSK_UNSHARE);
	event.aux3 = sentry_syscall_arg(regs, 0);	/* clone flags */
	sentry_submit(&event);
	return 0;
}

static int sentry_kp_setns(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event event;

	sentry_fill_common(&event, BSK_SETNS);
	event.aux1 = (u32)sentry_syscall_arg(regs, 0);	/* fd */
	event.aux3 = sentry_syscall_arg(regs, 1);	/* nstype */
	sentry_submit(&event);
	return 0;
}

/* --- outbound connections, for the host to cross-check against attestd --- */

static int sentry_kp_connect(struct kprobe *probe, struct pt_regs *regs)
{
	struct bromure_sentry_event event;
	struct sockaddr *addr = (struct sockaddr *)regs->regs[1];

	if (!addr)
		return 0;
	if (addr->sa_family != AF_INET && addr->sa_family != AF_INET6)
		return 0;

	sentry_fill_common(&event, BSK_CONNECT);
	event.addr_family = addr->sa_family;
	if (addr->sa_family == AF_INET) {
		struct sockaddr_in *v4 = (struct sockaddr_in *)addr;

		memcpy(event.addr, &v4->sin_addr, 4);
		event.aux2 = ntohs(v4->sin_port);
	} else {
		struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)addr;

		memcpy(event.addr, &v6->sin6_addr, 16);
		event.aux2 = ntohs(v6->sin6_port);
	}
	sentry_submit(&event);
	return 0;
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

	key = key * 1000003ULL + full_name_hash(NULL, event->path,
					       strnlen(event->path,
						       sizeof(event->path)));
	key = key * 1000003ULL + full_name_hash(NULL, event->arg,
					       strnlen(event->arg,
						       sizeof(event->arg)));
	key = key * 1000003ULL + event->pid;
	return key;
}

/* Returns true when the caller should submit `event` itself. */
static bool sentry_dedup_absorb(const struct bromure_sentry_event *event)
{
	u64 key = sentry_dedup_key(event);
	u64 now = ktime_get_ns();
	u64 window = (u64)sentry_dedup_ms * NSEC_PER_MSEC;
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

/* Called from the sentry thread once a second. */
static void sentry_dedup_flush(bool force)
{
	u64 now = ktime_get_ns();
	unsigned long flags;
	size_t i;

	for (i = 0; i < SENTRY_DEDUP_SLOTS; i++) {
		struct bromure_sentry_event event;
		bool ready = false;

		spin_lock_irqsave(&sentry_dedup_lock, flags);
		if (sentry_dedup[i].used &&
		    (force || sentry_dedup[i].deadline_ns <= now)) {
			event = sentry_dedup[i].event;
			event.count = sentry_dedup[i].count;
			sentry_dedup[i].used = false;
			ready = true;
		}
		spin_unlock_irqrestore(&sentry_dedup_lock, flags);
		if (ready)
			sentry_submit(&event);
	}
}

static void sentry_emit_denial(struct bromure_sentry_event *event)
{
	event->count = 1;
	if (sentry_dedup_absorb(event))
		sentry_submit(event);
}

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
	struct bromure_sentry_event event;

	if (!probe || !ctx->sandboxed)
		return 0;
	if (ret == 0) {
		sentry_tally(BST_FILE_ALLOWED);
		return 0;
	}
	if (ret != -EACCES && ret != -EPERM)
		return 0;
	sentry_tally(BST_FILE_DENIED);

	sentry_fill_common(&event, BSK_SANDBOX_DENIED);
	event.op = probe->op;
	event.aux1 = (u32)(-ret);
	strscpy(event.arg, probe->symbol, sizeof(event.arg));
	sentry_denial_path(&event, probe->src, ctx->a, ctx->b);

	/* `open` is three operations wearing one hook. Landlock's EXECUTE right
	 * is checked here too, so a binary outside the policy shows up as a
	 * denied open with FMODE_EXEC rather than as a denied exec -- which is
	 * why probing security_bprm_check would add nothing. */
	if (probe->src == SPS_FILE && ctx->a) {
		struct file *file = (struct file *)ctx->a;

		event.aux2 = file->f_flags;
		/* BOTH, and measured: an `execve` reaches `security_file_open`
		 * with `__FMODE_EXEC` in **f_flags**, which is where
		 * `do_open_execat` puts it -- `f_mode` does not necessarily
		 * carry FMODE_EXEC at this point. Checking only f_mode reported
		 * a denied binary as `open_read`, which is true but useless:
		 * "the agent tried to run something it may not run" is the row
		 * the user is looking for. */
		if ((file->f_mode & FMODE_EXEC) || (file->f_flags & __FMODE_EXEC))
			event.op = BSO_OPEN_EXEC;
		else if (file->f_mode & FMODE_WRITE)
			event.op = BSO_OPEN_WRITE;
		else
			event.op = BSO_OPEN_READ;
	}
	sentry_emit_denial(&event);
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
	struct bromure_sentry_event event;

	if (!sentry_task_sandboxed())
		return 0;
	sentry_tally(BST_SYSCALL_DENIED);
	sentry_fill_common(&event, BSK_SECCOMP_DENIED);
	/* The syscall NUMBER, not a name: a name table in the module would be a
	 * second copy of something the host already has, and the two would
	 * eventually disagree. */
	event.aux1 = (u32)regs->regs[0];
	event.aux2 = (u32)regs->regs[2];
	strscpy(event.arg, sentry_seccomp_action((u32)regs->regs[2]),
		sizeof(event.arg));
	{
		struct file *exe;

		rcu_read_lock();
		exe = current->mm ? rcu_dereference(current->mm->exe_file) : NULL;
		if (exe) {
			char *rendered = file_path(exe, event.path,
						   sizeof(event.path));

			if (IS_ERR(rendered))
				event.path[0] = '\0';
			else if (rendered != event.path)
				memmove(event.path, rendered,
					strnlen(rendered,
						sizeof(event.path) - 1) + 1);
		}
		rcu_read_unlock();
	}
	sentry_emit_denial(&event);
	return 0;
}

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
	{ "security_socket_connect",	sentry_kp_connect },
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

	BUILD_BUG_ON(sizeof(struct bromure_sentry_event) > 512);

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
	for (i = 0; i < ARRAY_SIZE(sentry_denial_probes); i++) {
		if (sentry_denial_probes[i].registered)
			unregister_kretprobe(&sentry_denial_probes[i].rp);
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
