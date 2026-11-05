#define _GNU_SOURCE
#include "CACLinuxShims.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int acl_spawn(const char *path, char *const argv[], int in_fd, int out_fd, int err_fd, int *pid_out) {
    return acl_spawn_fds(path, argv, in_fd, out_fd, err_fd, NULL, 0, pid_out);
}

int acl_spawn_fds(const char *path, char *const argv[], int in_fd, int out_fd, int err_fd,
                  const int *extra, int nextra, int *pid_out) {
    if (nextra < 0 || nextra > 64) return EINVAL;
    // Each extra descriptor through a private copy above every target, so a
    // dup2 onto 3+i can't clobber a source still to be placed.
    int high[64];
    for (int i = 0; i < nextra; i++) {
        high[i] = fcntl(extra[i], F_DUPFD_CLOEXEC, 3 + nextra + 64);
        if (high[i] < 0) {
            int e = errno;
            while (i-- > 0) close(high[i]);
            return e;
        }
    }
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t at;
    posix_spawn_file_actions_init(&fa);
    posix_spawnattr_init(&at);
    int fds[3] = {in_fd, out_fd, err_fd};
    for (int i = 0; i < 3; i++) {
        if (fds[i] >= 0) posix_spawn_file_actions_adddup2(&fa, fds[i], i);
        else posix_spawn_file_actions_addopen(&fa, i, "/dev/null", i == 0 ? O_RDONLY : O_WRONLY, 0);
    }
    // dup2 clears close-on-exec on the copy.
    for (int i = 0; i < nextra; i++) posix_spawn_file_actions_adddup2(&fa, high[i], 3 + i);
#ifdef __linux__
    posix_spawn_file_actions_addclosefrom_np(&fa, 3 + nextra);
#endif
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&at, &none);
    posix_spawnattr_setsigdefault(&at, &all);
    posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    pid_t pid = 0;
    int r = posix_spawn(&pid, path, &fa, &at, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&at);
    for (int i = 0; i < nextra; i++) close(high[i]);
    if (r == 0) *pid_out = pid;
    return r;
}

int acl_wait_exited(int pid) {
    siginfo_t info;
    for (;;) {
        info.si_pid = 0;
        if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) == 0) break;
        if (errno != EINTR) return -1;
    }
    switch (info.si_code) {
    case CLD_EXITED: return info.si_status;
    case CLD_KILLED:
    case CLD_DUMPED: return 128 + info.si_status;
    default: return -1;
    }
}

void acl_reap(int pid) {
    int st;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
}

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static size_t acl_round_pages(size_t len) {
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) pg = 4096;
    return (len + (size_t)pg - 1) / (size_t)pg * (size_t)pg;
}

void *acl_secure_alloc(size_t len, int *locked) {
    size_t n = acl_round_pages(len ? len : 1);
    void *p = NULL;
    long pg = sysconf(_SC_PAGESIZE);
    if (posix_memalign(&p, pg > 0 ? (size_t)pg : 4096, n) != 0) return NULL;
    memset(p, 0, n);
    *locked = mlock(p, n) == 0;
#ifdef MADV_DONTDUMP
    madvise(p, n, MADV_DONTDUMP);
#endif
    return p;
}

void acl_secure_free(void *p, size_t len) {
    if (!p) return;
    size_t n = acl_round_pages(len ? len : 1);
    explicit_bzero(p, n);
    munlock(p, n);
    free(p);
}

#include <sys/socket.h>
#include <sys/un.h>

int acl_sd_notify(const char *state) {
    const char *path = getenv("NOTIFY_SOCKET");
    if (!path || !*path) return 0;
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    size_t n = strlen(path);
    if (n >= sizeof sa.sun_path) return -ENAMETOOLONG;
    memcpy(sa.sun_path, path, n);
    if (sa.sun_path[0] == '@') sa.sun_path[0] = 0;          /* abstract namespace */
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    ssize_t r = sendto(fd, state, strlen(state), MSG_NOSIGNAL, (struct sockaddr *)&sa,
                       (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n));
    int e = errno;
    close(fd);
    return r < 0 ? -e : 1;
}

int acl_sd_notify_fds(const char *state, const int *fds, int nfds) {
    const char *path = getenv("NOTIFY_SOCKET");
    if (!path || !*path) return 0;
    if (nfds < 0 || nfds > 16) return -EINVAL;
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    size_t n = strlen(path);
    if (n >= sizeof sa.sun_path) return -ENAMETOOLONG;
    memcpy(sa.sun_path, path, n);
    if (sa.sun_path[0] == '@') sa.sun_path[0] = 0;
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    struct iovec iov = { .iov_base = (void *)state, .iov_len = strlen(state) };
    union { char buf[CMSG_SPACE(sizeof(int) * 16)]; struct cmsghdr align; } u;
    memset(&u, 0, sizeof u);
    struct msghdr msg = { .msg_name = &sa, .msg_namelen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n),
                          .msg_iov = &iov, .msg_iovlen = 1 };
    if (nfds > 0) {
        msg.msg_control = u.buf;
        msg.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)nfds);
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)nfds);
        memcpy(CMSG_DATA(c), fds, sizeof(int) * (size_t)nfds);
    }
    ssize_t r = sendmsg(fd, &msg, MSG_NOSIGNAL);
    int e = errno;
    close(fd);
    return r < 0 ? -e : 1;
}

#ifdef __linux__
int acl_pipe_cloexec(int fds[2]) { return pipe2(fds, O_CLOEXEC) == 0 ? 0 : -errno; }
#else
int acl_pipe_cloexec(int fds[2]) { return pipe(fds) == 0 ? 0 : -errno; }
#endif

#include <sys/socket.h>
#ifdef __linux__
int acl_accept_cloexec(int fd) { int c = accept4(fd, NULL, NULL, SOCK_CLOEXEC); return c >= 0 ? c : -errno; }
#else
int acl_accept_cloexec(int fd) {
    int c = accept(fd, NULL, NULL);
    if (c < 0) return -errno;
    fcntl(c, F_SETFD, FD_CLOEXEC);
    return c;
}
#endif

#include <pthread.h>
int acl_unblock_term_signals(void) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGTERM);
    sigaddset(&set, SIGINT);
    int r = pthread_sigmask(SIG_UNBLOCK, &set, NULL);
    return r == 0 ? 0 : -r;
}

#ifdef __linux__
#include <sys/prctl.h>
int acl_set_nondumpable(void) { return prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == 0 ? 0 : -errno; }
int acl_get_dumpable(void) { return prctl(PR_GET_DUMPABLE, 0, 0, 0, 0); }
#else
int acl_set_nondumpable(void) { return -ENOSYS; }
int acl_get_dumpable(void) { return -ENOSYS; }
#endif

#ifdef __linux__
#include <sys/ioctl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <string.h>


int acl_tap_open(const char *name) {
    int fd = open("/dev/net/tun", O_RDWR | O_CLOEXEC);
    if (fd < 0) return -errno;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        int e = errno;
        close(fd);
        return -e;
    }
    return fd;
}
#else
int acl_tap_open(const char *name) {
    (void)name;
    return -ENOSYS;
}
#endif

int acl_pidfd_open(int pid) {
    long r = syscall(SYS_pidfd_open, (pid_t)pid, 0);
    return r < 0 ? -errno : (int)r;
}

int acl_pidfd_send_signal(int pidfd, int sig) {
    return syscall(SYS_pidfd_send_signal, pidfd, sig, NULL, 0) < 0 ? -errno : 0;
}

#ifdef __linux__
#include <poll.h>
#include <time.h>
#include <stdio.h>
#include <sys/time.h>

// Connects `fd` to `sa`, giving up after `timeout_ms`; the fd is left blocking.
static int acl_connect_timeout(int fd, const struct sockaddr *sa, socklen_t len, int timeout_ms) {
    int fl = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = connect(fd, sa, len);
    // AF_UNIX: EAGAIN when the listener's backlog is full; try again until the deadline.
    for (int waited = 0; r < 0 && errno == EAGAIN && sa->sa_family == AF_UNIX && waited < timeout_ms; waited += 10) {
        struct timespec ts = { 0, 10 * 1000 * 1000 };
        nanosleep(&ts, NULL);
        r = connect(fd, sa, len);
    }
    if (r < 0 && errno == EINPROGRESS) {
        struct pollfd p = { .fd = fd, .events = POLLOUT };
        r = poll(&p, 1, timeout_ms);
        if (r == 0) { errno = ETIMEDOUT; r = -1; }
        else if (r > 0) {
            int err = 0; socklen_t el = sizeof err;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
            if (err) { errno = err; r = -1; } else r = 0;
        }
    }
    fcntl(fd, F_SETFL, fl);
    return r;
}

#else
#endif

int acl_hybrid_vsock_connect(const char *path, unsigned int port, int timeout_ms) {
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof sa.sun_path) return -ENAMETOOLONG;
    strcpy(sa.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    if (acl_connect_timeout(fd, (struct sockaddr *)&sa, sizeof sa, timeout_ms) < 0) {
        int e = errno;
        close(fd);
        return -e;
    }
    struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char req[32];
    int n = snprintf(req, sizeof req, "CONNECT %u\n", port);
    if (write(fd, req, (size_t)n) != n) { int e = errno ? errno : EIO; close(fd); return -e; }
    // "OK <host port>\n", read a byte at a time so nothing past it is consumed.
    char line[64];
    size_t got = 0;
    for (;;) {
        char c;
        ssize_t r = read(fd, &c, 1);
        if (r != 1 || got + 1 >= sizeof line) { close(fd); return r == 0 ? -ECONNREFUSED : -(errno ? errno : EPROTO); }
        line[got++] = c;
        if (c == '\n') break;
    }
    line[got] = 0;
    if (strncmp(line, "OK ", 3) != 0) { close(fd); return -ECONNREFUSED; }
    struct timeval none = { 0, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof none);
    return fd;
}

// --- PAM, dlopen'ed (no libpam headers needed) ---
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

struct acl_pam_message { int msg_style; const char *msg; };
struct acl_pam_response { char *resp; int resp_retcode; };
struct acl_pam_conv {
    int (*conv)(int, const struct acl_pam_message **, struct acl_pam_response **, void *);
    void *appdata_ptr;
};
enum { ACL_PAM_SUCCESS = 0, ACL_PAM_BUF_ERR = 5, ACL_PAM_CONV_ERR = 19,
       ACL_PAM_PROMPT_ECHO_OFF = 1, ACL_PAM_PROMPT_ECHO_ON = 2 };

// Answers every hidden prompt with the password; anything else gets no answer.
static int acl_pam_conv_fn(int n, const struct acl_pam_message **msg, struct acl_pam_response **resp, void *data) {
    if (n <= 0 || n > 32) return ACL_PAM_CONV_ERR;
    struct acl_pam_response *r = calloc((size_t)n, sizeof *r);
    if (!r) return ACL_PAM_BUF_ERR;
    for (int i = 0; i < n; i++) {
        if (msg[i]->msg_style == ACL_PAM_PROMPT_ECHO_OFF) {
            r[i].resp = strdup((const char *)data);
            if (!r[i].resp) {
                for (int j = 0; j < i; j++) free(r[j].resp);
                free(r);
                return ACL_PAM_BUF_ERR;
            }
        }
    }
    *resp = r;
    return ACL_PAM_SUCCESS;
}

int acl_pam_check(const char *service, const char *user, const char *password) {
    void *h = dlopen("libpam.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!h) return -1;
    int (*start)(const char *, const char *, const struct acl_pam_conv *, void **) = dlsym(h, "pam_start");
    int (*authenticate)(void *, int) = dlsym(h, "pam_authenticate");
    int (*acct)(void *, int) = dlsym(h, "pam_acct_mgmt");
    int (*end)(void *, int) = dlsym(h, "pam_end");
    if (!start || !authenticate || !acct || !end) { dlclose(h); return -1; }
    struct acl_pam_conv conv = { acl_pam_conv_fn, (void *)password };
    void *pamh = NULL;
    int r = start(service, user, &conv, &pamh);
    if (r == ACL_PAM_SUCCESS) r = authenticate(pamh, 0);
    if (r == ACL_PAM_SUCCESS) r = acct(pamh, 0);
    if (pamh) end(pamh, r);
    dlclose(h);
    return r;
}
