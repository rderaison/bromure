#include "CACLinuxShims.h"
#include <errno.h>

#ifdef __linux__
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/vhost.h>

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
#else
int acl_vhost_vsock_cid_in_use(uint64_t cid) {
    (void)cid;
    return -ENOSYS;
}
#endif
