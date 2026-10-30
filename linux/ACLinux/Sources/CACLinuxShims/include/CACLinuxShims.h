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

#endif
