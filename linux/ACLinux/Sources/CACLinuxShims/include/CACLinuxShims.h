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

/// waitpid() for `pid`, blocking; returns the exit status, or 128 + signal.
int acl_wait(int pid);

#endif
