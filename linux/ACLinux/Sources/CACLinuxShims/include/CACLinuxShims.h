#ifndef CACLINUXSHIMS_H
#define CACLINUXSHIMS_H
#include <stdint.h>


/// Attaches to the tap `name` (IFF_TAP | IFF_NO_PI): one Ethernet frame per
/// read()/write(). A persistent tap owned by the caller needs no privilege.
/// Returns the fd (O_CLOEXEC), or -errno.
int acl_tap_open(const char *name);

/// posix_spawn `path` with `argv` (NULL-terminated) and the current
/// environment; the child's stdin/stdout/stderr are `in_fd`/`out_fd`/`err_fd`
/// (-1: /dev/null), every other descriptor is closed, the signal mask and
/// dispositions are reset. Returns 0 and the pid, or an errno.
int acl_spawn(const char *path, char *const argv[], int in_fd, int out_fd, int err_fd, int *pid_out);

/// acl_spawn, and `extra[i]` (up to 64) become the child's descriptor 3 + i;
/// everything above them is closed.
int acl_spawn_fds(const char *path, char *const argv[], int in_fd, int out_fd, int err_fd,
                  const int *extra, int nextra, int *pid_out);

/// Blocks until `pid` has exited, WITHOUT reaping it (waitid WNOWAIT): the
/// zombie keeps the pid reserved, so it can't be recycled until acl_reap.
/// Returns the exit status, or 128 + signal, or -1.
int acl_wait_exited(int pid);

/// Reaps an exited child (after acl_wait_exited).
void acl_reap(int pid);

#include <stddef.h>

/// struct ucred's layout (SO_PEERCRED), without needing _GNU_SOURCE in Swift.
typedef struct { int32_t pid; uint32_t uid; uint32_t gid; } acl_ucred;

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

/// accept4(fd, NULL, NULL, SOCK_CLOEXEC): no spawned child inherits the
/// connection. Returns the descriptor, or -errno.
int acl_accept_cloexec(int fd);

/// sd_notify(3) without libsystemd: sends `state` (e.g. "READY=1") as one
/// datagram to $NOTIFY_SOCKET (path or @abstract). 1 if sent, 0 if there's
/// no NOTIFY_SOCKET (not under systemd), or -errno.
int acl_sd_notify(const char *state);

/// sd_notify with descriptors attached (SCM_RIGHTS): `FDSTORE=1\nFDNAME=…`
/// puts them in the service manager's fd store. 0 without NOTIFY_SOCKET,
/// 1 when sent, -errno on failure.
int acl_sd_notify_fds(const char *state, const int *fds, int nfds);



/// Firecracker's hybrid vsock, host -> guest: connects to the VM's vsock Unix
/// socket `path`, sends `CONNECT <port>\n` and consumes the `OK <n>\n` reply.
/// Returns the stream (to the guest's `port`), or -errno.
int acl_hybrid_vsock_connect(const char *path, unsigned int port, int timeout_ms);

/// Unblocks SIGTERM and SIGINT in the calling thread's (and so the
/// process's future threads') mask: a parent that spawned us with them blocked
/// (Foundation's Process does) mustn't take away the graceful-stop path.
/// Returns 0, or -errno.
int acl_unblock_term_signals(void);

/// prctl(PR_GET_DUMPABLE).
int acl_get_dumpable(void);

/// pidfd_open(2): a descriptor that becomes readable when `pid` exits (-errno on failure).
int acl_pidfd_open(int pid);

/// pidfd_send_signal(2): signals the process the pidfd refers to, never a recycled pid.
int acl_pidfd_send_signal(int pidfd, int sig);

#endif

/// PAM authentication of `user` with `password` under `service` (an unknown
/// service falls back to PAM's "other"): pam_authenticate then pam_acct_mgmt.
/// libpam is dlopen'ed (libpam.so.0), so nothing links it. Returns 0 when
/// authenticated, a PAM error code (> 0) when not, -1 when PAM can't be loaded.
int acl_pam_check(const char *service, const char *user, const char *password);

// Content-coding decoders (decode.c): 0 and a malloc'd buffer the caller
// frees; -1 corrupt or truncated; -2 past `cap`.
int acl_inflate(const uint8_t *in, size_t n, int window_bits, size_t cap, uint8_t **out, size_t *out_len);
/* One raw-deflate stream (a permessage-deflate message), as macOS's decoder
   sees it: 0 once its final block is decoded (what follows isn't read);
   -3 truncated; -1 corrupt; -2 past `cap`. */
int acl_inflate_raw_message(const uint8_t *in, size_t n, size_t cap, uint8_t **out, size_t *out_len);
int acl_brotli_decode(const uint8_t *in, size_t n, size_t cap, uint8_t **out, size_t *out_len);
/* Raw deflate (no zlib or gzip wrapper) of all of `in`, malloc'ed into *out. */
int acl_deflate_raw(const uint8_t *in, size_t n, uint8_t **out, size_t *out_len);
