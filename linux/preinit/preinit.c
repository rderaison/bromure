// preinit: /init of a boot template's initramfs.
//
// A boot template is a guest stopped right after its kernel booted, before
// anything of a workspace was read: the daemon boots this once (kernel, this
// program as the whole initramfs, placeholder disks), snapshots it while it
// waits below, and starts every later boot of the same shape from that
// snapshot instead of booting the kernel again.
//
// Before the snapshot: the kernel's own file systems, then wait.
// After a restore, once the host says go (it wrote the parameter page below
// straight into this guest's memory, and swapped the placeholder disks for
// the workspace's): the clock, the kernel's random pool, the disks' real
// sizes and partitions, the NIC's address, then the root file system and
// its init, as the image's initramfs would have left them.
//
// Anything wrong after go: a line on the console and a reboot, which ends
// the VM (reboot=k). The daemon then boots the ordinary way.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <linux/fs.h>
#include <linux/if.h>
#include <linux/if_arp.h>
#include <linux/random.h>
#include <linux/sockios.h>

#include "bromure_preinit_params.h"

// The page the host finds in the snapshot's memory (magic, then state
// READY and the highest counter: a stale copy the kernel left behind when
// it moved the page counts lower) and fills in before a restored guest
// runs.
static struct bromure_preinit_params params __attribute__((aligned(4096))) = {
    .magic = BROMURE_PREINIT_MAGIC,
    .version = BROMURE_PREINIT_VERSION,
};

static int console = -1;
static uint64_t t_go;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void say(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof buf - 1) n = sizeof buf - 1;
    if (console >= 0) (void)!write(console, buf, (size_t)n);
}

static void trace(const char *what) {
    if (params.flags & BROMURE_PREINIT_TRACE)
        say("bromure-preinit: +%llu us %s\n", (unsigned long long)((now_ns() - t_go) / 1000), what);
}

static void die(const char *fmt, ...) __attribute__((noreturn));
static void die(const char *fmt, ...) {
    char buf[400];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    say("bromure-preinit: FAILED: %s\n", buf);
    __atomic_store_n(&params.state, BROMURE_PREINIT_FAILED, __ATOMIC_SEQ_CST);
    sync();
    reboot(RB_AUTOBOOT);
    for (;;) pause();
}

static void nap(long us) {
    struct timespec ts = { us / 1000000, (us % 1000000) * 1000 };
    nanosleep(&ts, NULL);
}

static int read_file(const char *path, char *buf, size_t size) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, size - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = 0;
    return (int)n;
}

// --- the disks ---------------------------------------------------------

static uint64_t disk_sectors(const char *name) {
    char path[96], buf[32];
    snprintf(path, sizeof path, "/sys/block/%s/size", name);
    if (read_file(path, buf, sizeof buf) <= 0) return 0;
    return strtoull(buf, NULL, 10);
}

// Each disk the host swapped in shows its real size (the host's change
// reaches the guest as a virtio config interrupt, handled on a workqueue),
// then drops what the kernel read from the placeholder and reads its
// partition table.
static void disks_changed(void) {
    uint32_t n = params.ndisks < BROMURE_PREINIT_MAX_DISKS ? params.ndisks : BROMURE_PREINIT_MAX_DISKS;
    for (uint32_t i = 0; i < n; i++) {
        const char *name = params.disks[i].name;
        uint64_t want = params.disks[i].sectors;
        uint64_t deadline = now_ns() + 3000000000ull;
        while (disk_sectors(name) != want) {
            if (now_ns() > deadline)
                die("disk %s is %llu sectors, expected %llu", name,
                    (unsigned long long)disk_sectors(name), (unsigned long long)want);
            nap(50);
        }
        char dev[64];
        snprintf(dev, sizeof dev, "/dev/%s", name);
        int fd = open(dev, O_RDONLY | O_CLOEXEC);
        if (fd < 0) die("open %s: %s", dev, strerror(errno));
        ioctl(fd, BLKFLSBUF);
        // EINVAL: a disk that can't have partitions. EBUSY can't be: nothing is open.
        if (ioctl(fd, BLKRRPART) != 0 && errno != EINVAL)
            die("re-reading %s's partition table: %s", dev, strerror(errno));
        close(fd);
    }
}

// --- the root file system ------------------------------------------------

struct ext_super {
    int ok;             // an ext2/3/4 superblock
    int clean;          // cleanly unmounted, no errors, no journal to replay
    char label[17];
    uint8_t uuid[16];
};

static struct ext_super read_super(const char *dev) {
    struct ext_super s = { 0 };
    uint8_t b[1024];
    int fd = open(dev, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return s;
    ssize_t n = pread(fd, b, sizeof b, 1024);
    close(fd);
    if (n != (ssize_t)sizeof b || b[0x38] != 0x53 || b[0x39] != 0xEF) return s;
    s.ok = 1;
    uint16_t state = (uint16_t)(b[0x3A] | b[0x3B] << 8);
    uint32_t incompat = (uint32_t)b[0x60] | (uint32_t)b[0x61] << 8 | (uint32_t)b[0x62] << 16 | (uint32_t)b[0x63] << 24;
    s.clean = (state & 1) && !(state & 2) && !(incompat & 0x4);
    memcpy(s.uuid, b + 0x68, 16);
    memcpy(s.label, b + 0x78, 16);
    return s;
}

static void format_uuid(const uint8_t *u, char *out) {
    sprintf(out, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}

// The kernel command line's `key=` value (the first), or "".
static void cmdline_value(const char *cmdline, const char *key, char *out, size_t size) {
    out[0] = 0;
    size_t klen = strlen(key);
    for (const char *p = cmdline; *p;) {
        while (*p == ' ' || *p == '\n') p++;
        const char *end = p;
        while (*end && *end != ' ' && *end != '\n') end++;
        if ((size_t)(end - p) > klen && !strncmp(p, key, klen) && p[klen] == '=') {
            size_t n = (size_t)(end - p) - klen - 1;
            if (n >= size) n = size - 1;
            memcpy(out, p + klen + 1, n);
            out[n] = 0;
            return;
        }
        p = end;
    }
}

static int cmdline_has(const char *cmdline, const char *word) {
    size_t n = strlen(word);
    for (const char *p = cmdline; (p = strstr(p, word)); p += n)
        if ((p == cmdline || p[-1] == ' ') && (p[n] == 0 || p[n] == ' ' || p[n] == '\n')) return 1;
    return 0;
}

// The block device `spec` names (root=): /dev/…, LABEL=…, UUID=….
static int find_root(const char *spec, char *dev, size_t size, struct ext_super *super) {
    if (!strncmp(spec, "/dev/", 5)) {
        snprintf(dev, size, "%s", spec);
        *super = read_super(dev);
        return super->ok;
    }
    int by_label = !strncmp(spec, "LABEL=", 6), by_uuid = !strncmp(spec, "UUID=", 5);
    if (!by_label && !by_uuid) return 0;
    const char *want = spec + (by_label ? 6 : 5);
    DIR *d = opendir("/sys/class/block");
    if (!d) return 0;
    struct dirent *e;
    int found = 0;
    while (!found && (e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char path[300];
        snprintf(path, sizeof path, "/dev/%s", e->d_name);
        struct ext_super s = read_super(path);
        if (!s.ok) continue;
        char uuid[40];
        format_uuid(s.uuid, uuid);
        if (by_label ? !strcmp(s.label, want) : !strcasecmp(uuid, want)) {
            snprintf(dev, size, "%s", path);
            *super = s;
            found = 1;
        }
    }
    closedir(d);
    return found;
}

// --- the rest of a boot's identity ---------------------------------------

static void set_clock(void) {
    if (!params.realtime_ns) return;
    struct timespec ts = { (time_t)(params.realtime_ns / 1000000000ull), (long)(params.realtime_ns % 1000000000ull) };
    if (clock_settime(CLOCK_REALTIME, &ts) != 0) die("setting the clock: %s", strerror(errno));
}

// Every guest restored from one template starts with the same kernel random
// state: the host's fresh seed goes in, credited, and the generator is
// reseeded from it before anything draws a number.
static void reseed(void) {
    struct { struct rand_pool_info info; uint8_t data[sizeof params.seed]; } e;
    e.info.entropy_count = (int)sizeof params.seed * 8;
    e.info.buf_size = (int)sizeof params.seed;
    memcpy(e.data, params.seed, sizeof params.seed);
    int fd = open("/dev/urandom", O_WRONLY | O_CLOEXEC);
    if (fd < 0) die("open /dev/urandom: %s", strerror(errno));
    if (ioctl(fd, RNDADDENTROPY, &e) != 0) die("seeding the random pool: %s", strerror(errno));
    if (ioctl(fd, RNDRESEEDCRNG) != 0) die("reseeding the random generator: %s", strerror(errno));
    close(fd);
    memset(&e, 0, sizeof e);
    memset(params.seed, 0, sizeof params.seed);
}

// The template's NIC has the template's address: this boot's, before the
// link is ever brought up.
static void set_mac(void) {
    if (!(params.flags & BROMURE_PREINIT_HAS_MAC)) return;
    DIR *d = opendir("/sys/class/net");
    if (!d) die("no /sys/class/net");
    struct dirent *e;
    char nic[IFNAMSIZ] = "";
    while ((e = readdir(d))) {
        char path[300];
        struct stat st;
        snprintf(path, sizeof path, "/sys/class/net/%s/device", e->d_name);
        if (e->d_name[0] != '.' && strlen(e->d_name) < sizeof nic && stat(path, &st) == 0
            && (!nic[0] || strcmp(e->d_name, nic) < 0))
            memcpy(nic, e->d_name, strlen(e->d_name) + 1);
    }
    closedir(d);
    if (!nic[0]) die("no network interface to give its address");
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    snprintf(ifr.ifr_name, sizeof ifr.ifr_name, "%s", nic);
    ifr.ifr_hwaddr.sa_family = ARPHRD_ETHER;
    memcpy(ifr.ifr_hwaddr.sa_data, params.mac, 6);
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s < 0 || ioctl(s, SIOCSIFHWADDR, &ifr) != 0) die("setting %s's address: %s", nic, strerror(errno));
    close(s);
}

static void mount_or_die(const char *src, const char *dst, const char *type, unsigned long flags, const char *data) {
    mkdir(dst, 0755);
    if (mount(src, dst, type, flags, data) != 0) die("mount %s on %s: %s", type, dst, strerror(errno));
}

int main(int argc, char **argv) {
    (void)argc;
    if (getpid() != 1) {
        fprintf(stderr, "bromure-preinit %u: a boot template's /init, not a command\n", BROMURE_PREINIT_VERSION);
        return 2;
    }
    mount_or_die("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
    console = open("/dev/console", O_RDWR | O_NOCTTY);
    mount_or_die("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    mount_or_die("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    // As the image's initramfs mounts it (systemd keeps the one it finds).
    mount_or_die("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, "size=10%,mode=0755");
    mkdir("/root", 0755);
    char cmdline[4096] = "";
    read_file("/proc/cmdline", cmdline, sizeof cmdline);

    // The snapshot is taken somewhere in this loop; a restored guest leaves
    // it within one nap of running.
    __atomic_store_n(&params.state, BROMURE_PREINIT_READY, __ATOMIC_SEQ_CST);
    say("%s\n", BROMURE_PREINIT_READY_LINE);
    while (!__atomic_load_n(&params.go, __ATOMIC_SEQ_CST)) {
        __atomic_add_fetch(&params.counter, 1, __ATOMIC_SEQ_CST);
        nap(100);
    }
    t_go = now_ns();

    set_clock();
    reseed();
    trace("clock set, random pool seeded");
    disks_changed();
    trace("disks at their real sizes, partitions read");
    set_mac();

    char spec[128], dev[300];
    snprintf(spec, sizeof spec, "%s", params.root);
    if (!spec[0]) cmdline_value(cmdline, "root", spec, sizeof spec);
    struct ext_super super;
    if (!find_root(spec, dev, sizeof dev, &super)) die("no root file system for root=%s", spec);
    char fstype[32];
    cmdline_value(cmdline, "rootfstype", fstype, sizeof fstype);
    unsigned long flags = cmdline_has(cmdline, "rw") ? 0 : MS_RDONLY;
    if (mount(dev, "/root", fstype[0] ? fstype : "ext4", flags, NULL) != 0)
        die("mounting %s: %s", dev, strerror(errno));
    trace("root mounted");
    // What the image's initramfs tells systemd after its own check of the
    // root (a clean one is all it finds here too): no second check. Left
    // unclean, the mount above replayed the journal and systemd checks it.
    if (super.clean) {
        mkdir("/run/initramfs", 0755);
        close(open("/run/initramfs/fsck-root", O_WRONLY | O_CREAT | O_CLOEXEC, 0644));
    }

    const char *init = "/sbin/init";
    char custom[256];
    cmdline_value(cmdline, "init", custom, sizeof custom);
    if (custom[0]) init = custom;

    if (mount("/dev", "/root/dev", NULL, MS_MOVE, NULL) != 0) die("moving /dev: %s", strerror(errno));
    if (mount("/run", "/root/run", NULL, MS_MOVE, NULL) != 0) die("moving /run: %s", strerror(errno));
    if (mount("/sys", "/root/sys", NULL, MS_MOVE, NULL) != 0) die("moving /sys: %s", strerror(errno));
    if (mount("/proc", "/root/proc", NULL, MS_MOVE, NULL) != 0) die("moving /proc: %s", strerror(errno));
    unlink("/init");
    if (chdir("/root") != 0 || mount(".", "/", NULL, MS_MOVE, NULL) != 0 || chroot(".") != 0 || chdir("/") != 0)
        die("switching to the root file system: %s", strerror(errno));
    trace("switched root, starting init");
    __atomic_store_n(&params.state, BROMURE_PREINIT_HANDOFF, __ATOMIC_SEQ_CST);
    if (console >= 0) {
        dup2(console, 0); dup2(console, 1); dup2(console, 2);
        if (console > 2) close(console);
    }
    argv[0] = (char *)init;
    execv(init, argv);
    console = 2;
    die("exec %s: %s", init, strerror(errno));
}
