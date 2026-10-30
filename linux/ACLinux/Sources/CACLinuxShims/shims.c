#define _GNU_SOURCE
#include "CACLinuxShims.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
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

int acl_wait(int pid) {
    int st = 0;
    while (waitpid(pid, &st, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    if (WIFSIGNALED(st)) return 128 + WTERMSIG(st);
    return -1;
}

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
