#ifndef CACLINUXSHIMS_H
#define CACLINUXSHIMS_H
#include <stdint.h>

/// Whether a guest CID is taken on this host, asked the way QEMU's
/// vhost-vsock does it: VHOST_SET_OWNER + VHOST_VSOCK_SET_GUEST_CID on a
/// fresh /dev/vhost-vsock fd (closed again, which releases the CID).
/// Returns 0 if free, 1 if in use (EADDRINUSE), or -errno if the probe
/// itself failed (no device access, no module, not Linux).
int acl_vhost_vsock_cid_in_use(uint64_t cid);

#endif
