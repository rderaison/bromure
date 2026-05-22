// Bromure terminal-title pusher (guest side). Mirrors the macOS
// tab-agent.sh `title_loop`: walk /proc looking for every running
// `kitty --class bromure-<UUID>`, then for each one resolve the
// foreground process running inside that kitty's shell (via the
// tty's tpgid) and push a snapshot of every (UUID, title) pair to
// the host over a single AF_VSOCK connection.
//
// Wire format — newline-terminated ASCII, one or more lines per
// connection (also covers audit 10 §2.8 outbox events):
//
//     tab|<UUID-no-dashes>|<TITLE>\n       — current title
//     closed|<UUID-no-dashes>\n            — tab exited silently
//     alive|<UUID>,<UUID>,...\n            — per-sweep roster (empty OK)
//     ip|<IPv4>\n                          — guest IP refresh (~5s cadence)
//
// A "starting" sentinel line (without "tab|") is emitted once at
// startup so the host learns the VM is alive before any kitty has
// been spawned.
//
// We use AF_VSOCK / hv_sock here (not plain TCP over the Default
// Switch NIC) because Windows Firewall on the Default Switch
// vEthernet kept dropping outbound guest→host packets even with
// an explicit "allow TCP 9224 inbound any-profile" rule.
//
// Build (inside setup.sh chroot):
//   gcc -O2 -Wall -o bromure-title-pusher title-pusher.c
//
// Usage:
//   bromure-title-pusher PORT

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/vm_sockets.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define POLL_MS    1500
#define IP_REFRESH_MS 5000     // audit 10 §2.8: macOS ip.txt cadence
#define TITLE_MAX  256
#define UUID_MAX   64
#define MAX_TABS   32
#define IP_MAX     64

struct tab_state {
    char uuid[UUID_MAX];
    char title[TITLE_MAX];
};

static int open_vsock(uint16_t port) {
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_vm sa;
    memset(&sa, 0, sizeof(sa));
    sa.svm_family = AF_VSOCK;
    sa.svm_cid    = VMADDR_CID_HOST;  // 2 = the Hyper-V parent partition
    sa.svm_port   = port;
    if (connect(s, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(s);
        return -1;
    }
    return s;
}

static int send_all(int s, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(s, buf + off, len - off, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

static int push_payload(uint16_t port, const char *payload, size_t len) {
    if (len == 0) return 0;
    int s = open_vsock(port);
    if (s < 0) return -1;
    int rc = send_all(s, payload, len);
    shutdown(s, SHUT_WR);
    close(s);
    return rc;
}

// Read /proc/<pid>/cmdline (NUL-separated argv). Returns total bytes,
// or -1 on error. Always NUL-terminated.
static ssize_t read_cmdline(pid_t pid, char *buf, size_t cap) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t total = 0;
    while ((size_t)total < cap - 1) {
        ssize_t n = read(fd, buf + total, cap - 1 - total);
        if (n <= 0) break;
        total += n;
    }
    close(fd);
    if (total < 0) return -1;
    buf[total] = '\0';
    return total;
}

// Walk a NUL-separated argv looking for `--class bromure-<UUID>` (or
// the `--class=bromure-<UUID>` joined form). On hit, copies the UUID
// (sans the "bromure-" prefix) into `out` and returns 1.
static int extract_class_uuid(const char *cmdline, size_t len, char *out, size_t out_cap) {
    size_t i = 0;
    int next_is_class_value = 0;
    while (i < len) {
        const char *arg = cmdline + i;
        size_t alen = strlen(arg);
        if (alen == 0) break;
        if (next_is_class_value) {
            if (strncmp(arg, "bromure-", 8) == 0) {
                const char *uuid = arg + 8;
                size_t ulen = strlen(uuid);
                if (ulen > 0 && ulen + 1 < out_cap) {
                    memcpy(out, uuid, ulen + 1);
                    return 1;
                }
            }
            next_is_class_value = 0;
        }
        if (strcmp(arg, "--class") == 0) {
            next_is_class_value = 1;
        } else if (strncmp(arg, "--class=bromure-", 16) == 0) {
            const char *uuid = arg + 16;
            size_t ulen = strlen(uuid);
            if (ulen > 0 && ulen + 1 < out_cap) {
                memcpy(out, uuid, ulen + 1);
                return 1;
            }
        }
        i += alen + 1;
    }
    return 0;
}

// Parse the relevant tail fields of /proc/<pid>/stat starting AFTER
// the closing ')' of the comm field. Returns pids of interest, or 0
// on parse failure.
static int parse_stat_tail(pid_t pid, pid_t *ppid_out, pid_t *tpgid_out) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    char buf[1024];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = '\0';
    const char *rp = strrchr(buf, ')');
    if (!rp) return 0;
    char state;
    int ppid, pgrp, sess, tty, tpgid;
    if (sscanf(rp + 2, "%c %d %d %d %d %d",
               &state, &ppid, &pgrp, &sess, &tty, &tpgid) != 6) {
        return 0;
    }
    if (ppid_out)  *ppid_out  = (pid_t)ppid;
    if (tpgid_out) *tpgid_out = (pid_t)tpgid;
    return 1;
}

// First-child PID of `parent` (kitty's child = the shell). Returns 0
// if none found. Falls back to a /proc scan if kernel.children-sysctl
// is unavailable.
static pid_t first_child(pid_t parent) {
    char path[96];
    snprintf(path, sizeof(path), "/proc/%d/task/%d/children",
             (int)parent, (int)parent);
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
        char buf[256];
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            buf[n] = '\0';
            int cand = atoi(buf);
            if (cand > 0) return (pid_t)cand;
        }
    }
    DIR *d = opendir("/proc");
    if (!d) return 0;
    pid_t found = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!isdigit((unsigned char)e->d_name[0])) continue;
        pid_t cand = (pid_t)atoi(e->d_name);
        pid_t ppid = 0;
        if (parse_stat_tail(cand, &ppid, NULL) && ppid == parent) {
            found = cand;
            break;
        }
    }
    closedir(d);
    return found;
}

// /proc/<pid>/comm = the process's short name. Returns 1 on hit.
static int proc_comm(pid_t pid, char *out, size_t cap) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/comm", (int)pid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, out, cap - 1);
    close(fd);
    if (n <= 0) return 0;
    out[n] = '\0';
    while (n > 0 && (out[n-1] == '\n' || out[n-1] == ' ' || out[n-1] == '\t')) {
        out[--n] = '\0';
    }
    return n > 0;
}

// One sweep — populate `cur[]` with up to MAX_TABS entries by walking
// /proc and matching `--class bromure-<UUID>`. Returns the count.
static int collect_tabs(struct tab_state *cur) {
    int count = 0;
    DIR *d = opendir("/proc");
    if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && count < MAX_TABS) {
        if (!isdigit((unsigned char)e->d_name[0])) continue;
        pid_t pid = (pid_t)atoi(e->d_name);
        char cmdline[4096];
        ssize_t clen = read_cmdline(pid, cmdline, sizeof(cmdline));
        if (clen <= 0) continue;
        char uuid[UUID_MAX] = {0};
        if (!extract_class_uuid(cmdline, (size_t)clen, uuid, sizeof(uuid))) continue;
        // Default label is "kitty" — overridden if we can resolve the
        // shell's foreground process group (vim, claude, etc.).
        char title[TITLE_MAX] = "kitty";
        pid_t shell = first_child(pid);
        if (shell > 0) {
            pid_t tpgid = 0;
            if (parse_stat_tail(shell, NULL, &tpgid) && tpgid > 0) {
                char comm[TITLE_MAX];
                if (proc_comm((pid_t)tpgid, comm, sizeof(comm)) &&
                    comm[0] != '\0') {
                    snprintf(title, sizeof(title), "%s", comm);
                }
            }
        }
        memset(&cur[count], 0, sizeof(cur[count]));
        strncpy(cur[count].uuid,  uuid,  sizeof(cur[0].uuid)  - 1);
        strncpy(cur[count].title, title, sizeof(cur[0].title) - 1);
        count++;
    }
    closedir(d);
    return count;
}

// Resolve the guest's primary IPv4 address by walking getifaddrs()
// and picking the first non-loopback, non-link-local address on an
// up+running interface. Returns 1 on hit. The result is what macOS
// writes to ip.txt — typically the eth0 lease from the Default
// Switch (172.20.*.*).
static int resolve_primary_ipv4(char *out, size_t cap) {
    struct ifaddrs *ifa, *cur;
    if (getifaddrs(&ifa) < 0) return 0;
    int got = 0;
    for (cur = ifa; cur && !got; cur = cur->ifa_next) {
        if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET) continue;
        if (!(cur->ifa_flags & IFF_UP) || !(cur->ifa_flags & IFF_RUNNING)) continue;
        if (cur->ifa_flags & IFF_LOOPBACK) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
        // Skip 169.254/16 link-local (NetworkManager assigns these
        // when DHCP hasn't completed yet).
        uint32_t a = ntohl(sin->sin_addr.s_addr);
        if ((a & 0xFFFF0000U) == 0xA9FE0000U) continue;
        if (inet_ntop(AF_INET, &sin->sin_addr, out, cap)) got = 1;
    }
    freeifaddrs(ifa);
    return got;
}

// Append "closed|<uuid>\n" for every UUID in `last` that's missing
// from `cur`. Returns number of bytes written to `buf`.
static size_t append_closed_lines(char *buf, size_t cap,
                                  const struct tab_state *cur, int cur_n,
                                  const struct tab_state *last, int last_n) {
    size_t off = 0;
    for (int i = 0; i < last_n; i++) {
        int still_alive = 0;
        for (int j = 0; j < cur_n; j++) {
            if (strcmp(last[i].uuid, cur[j].uuid) == 0) { still_alive = 1; break; }
        }
        if (still_alive) continue;
        int n = snprintf(buf + off, cap - off, "closed|%s\n", last[i].uuid);
        if (n < 0 || (size_t)n >= cap - off) break;
        off += (size_t)n;
    }
    return off;
}

// Append "alive|<u1>,<u2>,...\n" (empty roster → "alive|\n").
static size_t append_alive_line(char *buf, size_t cap,
                                const struct tab_state *cur, int cur_n) {
    size_t off = 0;
    int n = snprintf(buf + off, cap - off, "alive|");
    if (n < 0 || (size_t)n >= cap - off) return 0;
    off += (size_t)n;
    for (int i = 0; i < cur_n; i++) {
        const char *sep = (i == 0) ? "" : ",";
        n = snprintf(buf + off, cap - off, "%s%s", sep, cur[i].uuid);
        if (n < 0 || (size_t)n >= cap - off) return off;
        off += (size_t)n;
    }
    n = snprintf(buf + off, cap - off, "\n");
    if (n < 0 || (size_t)n >= cap - off) return off;
    off += (size_t)n;
    return off;
}

// True if the current snapshot differs from the previous one (count
// or any UUID/title pair).
static int snapshot_changed(const struct tab_state *cur, int cur_n,
                            const struct tab_state *last, int last_n) {
    if (cur_n != last_n) return 1;
    for (int i = 0; i < cur_n; i++) {
        int match = 0;
        for (int j = 0; j < last_n; j++) {
            if (strcmp(cur[i].uuid, last[j].uuid) == 0) {
                if (strcmp(cur[i].title, last[j].title) != 0) return 1;
                match = 1;
                break;
            }
        }
        if (!match) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s PORT\n", argv[0]);
        return 2;
    }
    int port_n = atoi(argv[1]);
    if (port_n <= 0 || port_n > 65535) {
        fprintf(stderr, "[title-pusher] invalid port: %s\n", argv[1]);
        return 2;
    }
    uint16_t port = (uint16_t)port_n;
    setenv("DISPLAY", ":1", 0);

    // One-shot ping so the host registers this VM as alive even
    // before any kitty has been spawned. The host treats single-line
    // payloads without "tab|" as a legacy whole-window title.
    push_payload(port, "starting\n", 9);

    struct tab_state last[MAX_TABS] = {0};
    int last_count = 0;
    char last_ip[IP_MAX] = {0};
    struct timespec last_ip_push = {0, 0};

    struct timespec slp = {
        .tv_sec  =  POLL_MS / 1000,
        .tv_nsec = (POLL_MS % 1000) * 1000000L,
    };

    for (;;) {
        struct tab_state cur[MAX_TABS] = {0};
        int cur_count = collect_tabs(cur);

        char buf[16384];
        size_t off = 0;
        int titles_changed = snapshot_changed(cur, cur_count, last, last_count);

        // 1) tab|<uuid>|<title> — only when something changed, same
        // as the original behavior.
        if (titles_changed) {
            for (int i = 0; i < cur_count; i++) {
                int n = snprintf(buf + off, sizeof(buf) - off,
                                 "tab|%s|%s\n", cur[i].uuid, cur[i].title);
                if (n < 0 || (size_t)n >= sizeof(buf) - off) break;
                off += (size_t)n;
            }
            // 2) closed|<uuid> — every tab that was in `last` but
            // isn't in `cur`. Only on change-sweeps to avoid spam.
            off += append_closed_lines(buf + off, sizeof(buf) - off,
                                       cur, cur_count, last, last_count);
        }

        // 3) alive|<uuid>,... — every sweep, so the host can reconcile
        // orphan tab pills even when nothing else changed.
        off += append_alive_line(buf + off, sizeof(buf) - off,
                                 cur, cur_count);

        // 4) ip|<addr> — when the address changes, OR every
        // IP_REFRESH_MS as a heartbeat (lets the host detect a DHCP
        // renewal that landed on the same address).
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed_ms =
            (now.tv_sec - last_ip_push.tv_sec) * 1000L +
            (now.tv_nsec - last_ip_push.tv_nsec) / 1000000L;
        char ip[IP_MAX] = {0};
        if (resolve_primary_ipv4(ip, sizeof(ip))) {
            int changed = strcmp(ip, last_ip) != 0;
            if (changed || elapsed_ms >= IP_REFRESH_MS) {
                int n = snprintf(buf + off, sizeof(buf) - off, "ip|%s\n", ip);
                if (n > 0 && (size_t)n < sizeof(buf) - off) {
                    off += (size_t)n;
                    strncpy(last_ip, ip, sizeof(last_ip) - 1);
                    last_ip_push = now;
                }
            }
        }

        if (off > 0) push_payload(port, buf, off);
        if (titles_changed) {
            memcpy(last, cur, sizeof(last));
            last_count = cur_count;
        }
        nanosleep(&slp, NULL);
    }
    return 0;
}
