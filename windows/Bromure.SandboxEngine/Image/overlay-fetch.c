// Bromure home-overlay fetcher (guest side).
//
// At session boot, dials the host over AF_VSOCK and reads a tar
// stream containing the per-session home-dir overlay (.bashrc,
// .config/kitty/kitty.conf, .gitconfig, etc. — everything
// SessionHomeBuilder produces from the active profile). Pipes
// the bytes through tar -x into /home/ubuntu.
//
// We use AF_VSOCK instead of HCS's built-in Plan9 share because
// stock Ubuntu kernels lack CONFIG_NET_9P_HV_SOCK (only the
// custom WSL2 kernel ships it), so 9p over Hyper-V mount fails
// silently. AF_VSOCK is in stock Ubuntu, and the host's
// GuestEventServer can stream bytes by VM-ID exactly like it
// receives the title-pusher push.
//
// Build (in setup.sh chroot):
//   gcc -O2 -Wall -o bromure-overlay-fetch overlay-fetch.c
//
// Usage:
//   bromure-overlay-fetch PORT TARGET_DIR
//
// PORT       — AF_VSOCK port the host listens on.
// TARGET_DIR — directory to untar into (e.g. /home/ubuntu).

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/vm_sockets.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s PORT TARGET_DIR\n", argv[0]);
        return 2;
    }
    int port_n = atoi(argv[1]);
    if (port_n <= 0 || port_n > 65535) {
        fprintf(stderr, "invalid port: %s\n", argv[1]);
        return 2;
    }
    uint16_t port = (uint16_t)port_n;
    const char *target = argv[2];

    // Single connect — the host's HandleOverlayAsync waits up to
    // 45 s for its overlay producer to be registered (which happens
    // after the boot-signal phase, ~30 s into boot). So we don't
    // need to retry on the guest side: dial, read until EOF, exit.
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) {
        fprintf(stderr, "socket: %s\n", strerror(errno));
        return 1;
    }
    struct sockaddr_vm sa;
    memset(&sa, 0, sizeof(sa));
    sa.svm_family = AF_VSOCK;
    sa.svm_cid    = VMADDR_CID_HOST;
    sa.svm_port   = port;
    if (connect(s, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        fprintf(stderr, "overlay-fetch: connect (host:%u): %s\n",
                port, strerror(errno));
        close(s);
        return 1;
    }

    // Spawn `tar -x -C $target` and pipe socket → tar's stdin.
    int pipefd[2];
    if (pipe(pipefd) < 0) { close(s); return 1; }
    pid_t pid = fork();
    if (pid < 0) { close(s); close(pipefd[0]); close(pipefd[1]); return 1; }
    if (pid == 0) {
        // tar child
        close(pipefd[1]);
        dup2(pipefd[0], 0);
        close(pipefd[0]);
        execlp("tar", "tar", "-x", "-C", target,
               "--no-same-owner", "--no-same-permissions", (char *)NULL);
        _exit(127);
    }
    close(pipefd[0]);

    // Stream socket → pipe to tar.
    unsigned char buf[65536];
    long long total = 0;
    for (;;) {
        ssize_t n = read(s, buf, sizeof(buf));
        if (n == 0) break;          // host half-closed: end of stream
        if (n < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "read: %s\n", strerror(errno));
            break;
        }
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(pipefd[1], buf + off, n - off);
            if (w < 0) {
                if (errno == EINTR) continue;
                fprintf(stderr, "write to tar: %s\n", strerror(errno));
                goto done;
            }
            off += w;
        }
        total += n;
    }
done:
    close(s);
    close(pipefd[1]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "tar exited %d (read %lld bytes)\n",
                WEXITSTATUS(status), total);
        return 1;
    }
    fprintf(stderr, "overlay-fetch OK — extracted %lld bytes into %s\n",
            total, target);
    return 0;
}
