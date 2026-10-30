#ifndef CACLINUXSHIMS_H
#define CACLINUXSHIMS_H
#include <stdint.h>

/// Whether a guest CID is taken on this host, asked the way QEMU's
/// vhost-vsock does it: VHOST_SET_OWNER + VHOST_VSOCK_SET_GUEST_CID on a
/// fresh /dev/vhost-vsock fd (closed again, which releases the CID).
/// Returns 0 if free, 1 if in use (EADDRINUSE), or -errno if the probe
/// itself failed (no device access, no module, not Linux).
int acl_vhost_vsock_cid_in_use(uint64_t cid);

/// Attaches to the tap `name` (IFF_TAP | IFF_NO_PI): one Ethernet frame per
/// read()/write(). A persistent tap owned by the caller needs no privilege.
/// Returns the fd (O_CLOEXEC), or -errno.
int acl_tap_open(const char *name);

/// posix_spawn `path` with `argv` (NULL-terminated) and the current
/// environment; the child's stdin/stdout/stderr are `in_fd`/`out_fd`/`err_fd`
/// (-1: /dev/null), every other descriptor is closed, the signal mask and
/// dispositions are reset. Returns 0 and the pid, or an errno.
int acl_spawn(const char *path, char *const argv[], int in_fd, int out_fd, int err_fd, int *pid_out);

/// Blocks until `pid` has exited, WITHOUT reaping it (waitid WNOWAIT): the
/// zombie keeps the pid reserved, so it can't be recycled until acl_reap.
/// Returns the exit status, or 128 + signal, or -1.
int acl_wait_exited(int pid);

/// Reaps an exited child (after acl_wait_exited).
void acl_reap(int pid);

#include <stddef.h>

/// Page-aligned, zeroed memory for key material: mlock'ed (best effort; see
/// *locked) and excluded from core dumps (MADV_DONTDUMP). NULL on failure.
void *acl_secure_alloc(size_t len, int *locked);

/// Zeroes (explicit_bzero), unlocks and frees acl_secure_alloc memory.
void acl_secure_free(void *p, size_t len);

/// prctl(PR_SET_DUMPABLE, 0): no core dumps, no same-user ptrace or
/// /proc/<pid>/mem. Returns 0, or -errno.
int acl_set_nondumpable(void);

/// pipe2(fds, O_CLOEXEC). Returns 0, or -errno.
int acl_pipe_cloexec(int fds[2]);

/// prctl(PR_GET_DUMPABLE).
int acl_get_dumpable(void);

#endif
