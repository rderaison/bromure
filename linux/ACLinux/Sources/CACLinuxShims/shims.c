#include "CACLinuxShims.h"
#include <errno.h>

#ifdef __linux__
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
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
