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
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t at;
    posix_spawn_file_actions_init(&fa);
    posix_spawnattr_init(&at);
    int fds[3] = {in_fd, out_fd, err_fd};
    for (int i = 0; i < 3; i++) {
        if (fds[i] >= 0) posix_spawn_file_actions_adddup2(&fa, fds[i], i);
        else posix_spawn_file_actions_addopen(&fa, i, "/dev/null", i == 0 ? O_RDONLY : O_WRONLY, 0);
    }
#ifdef __linux__
    posix_spawn_file_actions_addclosefrom_np(&fa, 3);
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
#include <linux/vhost.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <string.h>

int acl_vhost_vsock_cid_in_use(uint64_t cid) {
    int fd = open("/dev/vhost-vsock", O_RDWR | O_CLOEXEC);
    if (fd < 0) return -errno;
    if (ioctl(fd, VHOST_SET_OWNER, 0) < 0) {
        int e = errno;
        close(fd);
        return -e;
    }
    int r = ioctl(fd, VHOST_VSOCK_SET_GUEST_CID, &cid);
    int e = errno;
    close(fd);
    if (r == 0) return 0;
    return e == EADDRINUSE ? 1 : -e;
}

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

int acl_vhost_vsock_cid_in_use(uint64_t cid) {
    (void)cid;
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
#include <linux/vm_sockets.h>
int acl_vsock_listen(unsigned int port, int backlog) {
    int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_vm sa;
    memset(&sa, 0, sizeof sa);
    sa.svm_family = AF_VSOCK;
    sa.svm_cid = VMADDR_CID_ANY;
    sa.svm_port = port;
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(fd, backlog) < 0) {
        int e = errno;
        close(fd);
        return -e;
    }
    return fd;
}
#else
int acl_vsock_listen(unsigned int port, int backlog) { (void)port; (void)backlog; return -ENOSYS; }
#endif
