/* SPDX-License-Identifier: GPL-2.0 */
/*
 * bromure_sentry — event ABI shared by the BPF programs and the kernel module.
 *
 * The BPF side writes these records into a BPF ring buffer; the module's kernel
 * thread drains them, renders JSON and writes it to the host over vsock. Nothing
 * in userland is in the path, which is the whole point: an agent that is root in
 * the guest can stop a daemon, but it cannot stop a kthread it has no handle on,
 * and it cannot unload a module that refuses to go.
 *
 * Keep this file in sync with the host's decoder. Every field the host reads is
 * fixed-width and little-endian (the guest is arm64 LE; the module asserts it).
 */
#ifndef _BROMURE_SENTRY_H
#define _BROMURE_SENTRY_H

#define BROMURE_SENTRY_ABI      1
#define BROMURE_SENTRY_COMM_LEN 16
#define BROMURE_SENTRY_PATH_LEN 256
#define BROMURE_SENTRY_ARG_LEN  128

/* Event kinds. The host maps these to the string `kind` in the wire JSON;
 * the numbers are the ABI, the strings are presentation. */
enum bromure_sentry_kind {
	BSK_EXEC = 1,
	/* Superseded. `setuid`/`setgid`/`capset` entry probes fired on every call,
	 * including every privilege DROP and every failure -- one idle minute of
	 * boot produced 924 of them. They are counted in the heartbeat now and are
	 * no longer events. BSK_CRED_GAIN is what replaced them: it reports a
	 * credential GAIN, which is the thing anyone actually wants to know. */
	BSK_SETUID_UNUSED = 2,
	BSK_SETGID_UNUSED = 3,
	BSK_CAPSET_UNUSED = 4,
	BSK_PTRACE = 5,
	BSK_MODULE_LOAD = 6,
	BSK_BPF_LOAD = 7,
	BSK_KEXEC_ATTEMPT = 8,
	BSK_LOCKDOWN_CHANGE_ATTEMPT = 9,
	BSK_MOUNT = 10,
	BSK_UNSHARE = 11,
	BSK_SETNS = 12,
	/* Superseded by BSK_NET_FLOW, which reports the same connection with the
	 * protocol, the source port, the process's start time and the ancestor
	 * chain -- and folds repeats instead of emitting one event per call.
	 * Retired at the host's request once nothing there consumed it. Kept so
	 * the number is never reused. */
	BSK_CONNECT_UNUSED = 13,
	/* Superseded by BSK_SANDBOX_DENIED, which reports the same thing for
	 * every path operation rather than only `open`. Kept so the number is
	 * never reused. */
	BSK_FILE_OPEN_DENIED_UNUSED = 14,
	BSK_SECCOMP_DENIED = 15,
	BSK_LANDLOCK_DENIED = 16,	/* reserved, never emitted today */
	BSK_CRED_GAIN = 17,
	/* A `security_*` hook refused an operation for a task in the sandbox
	 * cgroup. **NOT attributed to Landlock**, and the distinction is not
	 * pedantry: this image runs `lockdown,capability,landlock,yama,apparmor`,
	 * Landlock's own hook functions are static and absent from kallsyms, and
	 * the generic hook returns the same -EACCES whoever produced it. What the
	 * probe proves is "an LSM refused this, for a sandboxed task". Landlock is
	 * the cause in every case we can construct, and the event says so no more
	 * strongly than that. `BSK_LANDLOCK_DENIED` stays reserved for the day
	 * BPF-LSM or an upstream tracepoint can name the LSM. */
	BSK_SANDBOX_DENIED = 18,
	/* One event the first time a socket talks to a destination -- never per
	 * packet. Carries the process CHAIN, so a flow can be explained back to
	 * the agent that caused it even for processes that started before this
	 * module loaded. */
	BSK_NET_FLOW = 19,
	BSK_MAX
};

/* `proto` on a BSK_NET_FLOW. The host renders the string. */
enum bromure_sentry_proto {
	BSPR_NONE = 0,
	BSPR_TCP,
	BSPR_UDP,
	BSPR_ICMP,
	BSPR_ICMPV6,
	BSPR_RAW,
	BSPR_MAX
};

#define BROMURE_SENTRY_ARGV_LEN  1024
#define BROMURE_SENTRY_CHAIN_MAX 8

/* One ancestor. `(pid, start_ns)` is a process's identity: pids are reused,
 * start times are not. */
struct bromure_sentry_ancestor {
	__u32 pid;
	__u64 start_ns;
	char  comm[BROMURE_SENTRY_COMM_LEN];
};

/* Which operation a BSK_SANDBOX_DENIED refers to. The host renders the string;
 * these numbers are the ABI. */
enum bromure_sentry_op {
	BSO_NONE = 0,
	BSO_OPEN_READ,
	BSO_OPEN_WRITE,
	BSO_OPEN_EXEC,
	BSO_CREATE,
	BSO_MKDIR,
	BSO_RMDIR,
	BSO_UNLINK,
	BSO_SYMLINK,
	BSO_LINK,
	BSO_RENAME,
	BSO_TRUNCATE,
	BSO_BIND,
	BSO_CONNECT,
	BSO_MAX
};

/* One fixed-size record. Fixed size so the ring buffer reservation never fails
 * for a variable reason and so the module can bound its JSON output buffer. */
struct bromure_sentry_event {
	__u64 timestamp_ns;	/* CLOCK_MONOTONIC, ktime_get_ns() */
	__u32 kind;
	__u32 pid;		/* tgid, in the init pid namespace */
	__u32 ppid;
	__u32 uid;
	__u32 gid;
	__u32 aux1;		/* kind-specific: target uid / ptrace request / … */
	__u32 aux2;		/* kind-specific: target gid / dst port / … */
	__u64 aux3;		/* kind-specific: capability mask / cgroup id / … */
	__u64 aux4;		/* kind-specific: the OLD capability mask */
	__s32 result;		/* kind-specific: a syscall/helper return value */
	__u32 count;		/* BSK_SANDBOX_DENIED / BSK_SECCOMP_DENIED: how many
				 * identical denials this record stands for. One
				 * event per (op, path, exe) per dedup window, so a
				 * loop that retries 100 times is one row saying
				 * 100 rather than 100 rows -- or, worse, 64 rows
				 * and a silent token-bucket drop. */
	__u8  op;		/* enum bromure_sentry_op */
	/* `start_boottime`, nanoseconds. With `pid` this is the identity the host
	 * keys its process table on -- a pid alone is ambiguous the moment one is
	 * reused, which on a busy workspace is minutes, not days. */
	__u64 start_ns;
	__u8  proto;		/* enum bromure_sentry_proto */
	__u8  ip_proto;		/* IPPROTO_*, the number */
	__u8  icmp_type;	/* 8 = echo request; 0xff when not read */
	__u8  argv_truncated;
	__u16 sport;		/* local port; for a ping socket, the echo id */
	__u8  chain_len;
	struct bromure_sentry_ancestor chain[BROMURE_SENTRY_CHAIN_MAX];
	__u8  phase;		/* 0 = boot (Bromure's own root helpers are still
				 * setting the VM up), 1 = session, 2 = shutdown.
				 * Nothing outside `session` is a security event. */
	__u8  sandboxed;	/* the task is in the sandbox's cgroup, i.e. it is
				 * the agent's confined tree rather than one of
				 * Bromure's own unconfined helpers. Under strict
				 * a credential gain from HERE is the real signal;
				 * the same event from a helper is merely visible. */
	__u8  flag1;		/* kind-specific boolean: signed / lowering / … */
	__u8  addr[16];		/* BSK_NET_FLOW: IPv6 bytes, or v4-mapped */
	__u8  addr_family;
	__u8  truncated;	/* the path or argv below was cut short */
	char  comm[BROMURE_SENTRY_COMM_LEN];
	char  path[BROMURE_SENTRY_PATH_LEN];	/* exe path, mount source, … */
	char  arg[BROMURE_SENTRY_ARG_LEN];	/* argv[0], module name, … */
	/* The command line, args joined by single spaces. Last, and the largest
	 * field by far, which is why SENTRY_FIFO_EVENTS came down when it was
	 * added: the fifo is allocated once and sized in whole events. */
	char  argv[BROMURE_SENTRY_ARGV_LEN];
};

/* Ring buffer size. 256 KiB holds ~380 events; the drain thread wakes on every
 * submit, so this only has to cover a burst, not a backlog. */
#define BROMURE_SENTRY_RINGBUF_BYTES (256 * 1024)

/* Names the module looks up in bpffs to find the maps the loader pinned. */
#define BROMURE_SENTRY_PIN_DIR   "/sys/fs/bpf/bromure_sentry"
#define BROMURE_SENTRY_RINGBUF_PIN BROMURE_SENTRY_PIN_DIR "/events"
#define BROMURE_SENTRY_STATS_PIN   BROMURE_SENTRY_PIN_DIR "/stats"

/* Things worth counting but not worth an event each. Reported in every
 * heartbeat, so the host can see the shape of the machine's activity without a
 * timeline row per syscall. */
enum bromure_sentry_tally {
	BST_SETUID = 0,		/* every set*uid call, gain or drop, ok or EPERM */
	BST_SETGID,
	BST_CAPSET,
	BST_CRED_DROP,		/* commit_creds that did not gain anything */
	BST_CRED_REASSERT,	/* a task re-taking authority it already held */
	/* Sandboxed tasks only. `allowed` is what makes `denied` readable: a
	 * hundred denials against two hundred operations is a policy that is
	 * wrong, and a hundred against two million is an agent probing its walls.
	 * The host cannot tell those apart from the denial count alone. */
	BST_FILE_ALLOWED,
	BST_FILE_DENIED,
	BST_SYSCALL_DENIED,
	/* A capability set that grew only inside a NON-init user namespace, which
	 * is not authority over anything the init namespace owns. Counted rather
	 * than reported, so the decision not to alarm is visible instead of
	 * silent -- every other suppression in this module has cost a round when
	 * it was invisible. */
	BST_CAPS_IN_USERNS,
	/* A flow whose destination is loopback, which is not egress and can
	 * never carry a switch decision. Counted rather than emitted because it
	 * is the single largest source of volume in the module: measured on an
	 * otherwise quiet VM, 93 of 97 flow probe hits in 90 seconds were
	 * datagram connects to 127.0.0.53, the systemd-resolved stub -- three
	 * per `sudo`, each from a short-lived pid the dedup cannot fold. */
	BST_FLOW_LOCAL,
	BST_MAX
};

#endif /* _BROMURE_SENTRY_H */
