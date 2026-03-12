#ifndef CVMNET_H
#define CVMNET_H

#include <vmnet/vmnet.h>

// Re-export vmnet enum values as plain constants so Swift can see them.
// (OBJC_ENUM values are not automatically importable as Swift globals.)
static const uint32_t kVmnetSharedMode              = VMNET_SHARED_MODE;
static const uint32_t kVmnetBridgedMode             = VMNET_BRIDGED_MODE;
static const uint32_t kVmnetSuccess                 = VMNET_SUCCESS;
static const uint32_t kVmnetInterfacePacketsAvail   = VMNET_INTERFACE_PACKETS_AVAILABLE;

#endif
