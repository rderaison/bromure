// The page a boot template's /init (linux/preinit/preinit.c) shares with the
// host: the daemon finds it in the template's memory by its magic and fills
// it in, in the restored guest's memory, before that guest runs
// (acl_preinit_go). Little-endian, as both sides are; one header for both.
#ifndef BROMURE_PREINIT_PARAMS_H
#define BROMURE_PREINIT_PARAMS_H
#include <stdint.h>

#define BROMURE_PREINIT_MAGIC { 'B','R','O','M','U','R','E','-','P','R','E','I','N','I','T','\0' }
// Changes with the page's layout or with what preinit does with it.
#define BROMURE_PREINIT_VERSION 1u
#define BROMURE_PREINIT_READY 0x59444152u            // "RADY": waiting for go
#define BROMURE_PREINIT_HANDOFF 0x454e4f44u          // "DONE": about to exec the root's init
#define BROMURE_PREINIT_FAILED 0x4c494146u           // "FAIL": said why on the console, rebooting
#define BROMURE_PREINIT_READY_LINE "bromure-preinit: ready"
#define BROMURE_PREINIT_MAX_DISKS 8

#define BROMURE_PREINIT_TRACE 1u      // flags: print each step's time on the console
#define BROMURE_PREINIT_HAS_MAC 2u    // flags: `mac` is this boot's

struct bromure_preinit_disk {
    char name[16];            // "vda"
    uint64_t sectors;         // its real size, in 512-byte sectors
};

struct bromure_preinit_params {
    uint8_t magic[16];                                        //   0
    uint32_t version;                                         //  16
    uint32_t state;                                           //  20  preinit: READY, then HANDOFF or FAILED
    uint64_t counter;                                         //  24  preinit: counts while it waits
    uint32_t go;                                              //  32  host: nonzero, written last
    uint32_t flags;                                           //  36
    uint64_t realtime_ns;                                     //  40  the wall clock, since the epoch
    uint8_t mac[6];                                           //  48
    uint8_t reserved[2];                                      //  54
    uint32_t ndisks;                                          //  56
    uint32_t reserved2;                                       //  60
    uint8_t seed[64];                                         //  64  fresh random bytes
    struct bromure_preinit_disk disks[BROMURE_PREINIT_MAX_DISKS];   // 128  24 bytes each
    char root[128];                                           // 320  "LABEL=root"; "": the command line's root=
};                                                            // 448

_Static_assert(sizeof(struct bromure_preinit_disk) == 24, "disk entry layout");
_Static_assert(sizeof(struct bromure_preinit_params) == 448, "parameter page layout");
#endif
