// Bromure guest command server.
//
// Listens on AF_VSOCK and accepts one shell command per connection.
// The line is exec'd via `/bin/sh -c`, its stdout/stderr piped back
// to the host, and the connection closed when the child exits.
//
// Used today for two things:
//   - + button on the host launches a new kitty in the guest by
//     sending e.g. `DISPLAY=:1 kitty --title bromure-tab-3 &`.
//   - Tab raise/close: `xdotool search --name bromure-tab-3 windowactivate`
//     or `… windowkill`.
//
// Why this exists: HCS only exposes Plan9 over Hyper-V sockets, and
// stock Ubuntu kernels lack CONFIG_NET_9P_HV_SOCK, so we can't get
// a guest-writable share. AF_VSOCK ↔ AF_HYPERV is in stock kernels;
// the host writes a command line, the guest executes it.
//
// Security note: this listener exec's anything the host says, with
// the privileges of whoever runs the service. We run it as user
// `ubuntu` (not root) so the worst it can do is anything the user
// could already do from a normal kitty. The transport (AF_VSOCK
// from CID 2 = the parent partition) means only the Hyper-V host
// itself can reach us; no inbound network attack surface.
//
// Build:
//   gcc -O2 -Wall -o bromure-cmd-server cmd-server.c
//
// Usage:
//   bromure-cmd-server PORT

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/vm_sockets.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define CMD_MAX 8192

// Reap zombies so spawned kitties don't accumulate.
static void sigchld_handler(int sig) {
    (void)sig;
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
}

static int read_line(int fd, char *buf, size_t cap) {
    size_t got = 0;
    while (got < cap - 1) {
        ssize_t n = read(fd, buf + got, 1);
        if (n == 0) break;
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (buf[got] == '\n') break;
        got++;
    }
    buf[got] = '\0';
    // Strip trailing \r if present.
    if (got > 0 && buf[got - 1] == '\r') buf[--got] = '\0';
    return (int)got;
}

static void handle_client(int s) {
    char cmd[CMD_MAX];
    int n = read_line(s, cmd, sizeof(cmd));
    if (n <= 0) { close(s); return; }

    fprintf(stderr, "[cmd-server] exec: %s\n", cmd);

    int pipefd[2];
    if (pipe(pipefd) < 0) { close(s); return; }
    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); close(s); return; }
    if (pid == 0) {
        // child
        close(pipefd[0]);
        dup2(pipefd[1], 1);
        dup2(pipefd[1], 2);
        close(pipefd[1]);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(pipefd[1]);

    // Stream child output back over the socket.
    unsigned char buf[4096];
    for (;;) {
        ssize_t r = read(pipefd[0], buf, sizeof(buf));
        if (r <= 0) break;
        ssize_t off = 0;
        while (off < r) {
            ssize_t w = send(s, buf + off, r - off, MSG_NOSIGNAL);
            if (w <= 0) goto done;
            off += w;
        }
    }
done:
    close(pipefd[0]);
    // Don't waitpid here — long-running kids (kitty) won't ever
    // exit; the SIGCHLD reaper above keeps them out of the
    // zombie list.
    shutdown(s, SHUT_WR);
    close(s);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s PORT\n", argv[0]);
        return 2;
    }
    int port_n = atoi(argv[1]);
    if (port_n <= 0 || port_n > 65535) {
        fprintf(stderr, "invalid port: %s\n", argv[1]);
        return 2;
    }
    uint16_t port = (uint16_t)port_n;

    // Reap zombies (background kitties etc.) automatically.
    signal(SIGCHLD, sigchld_handler);

    int listener = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listener < 0) {
        fprintf(stderr, "socket: %s\n", strerror(errno));
        return 1;
    }
    struct sockaddr_vm sa;
    memset(&sa, 0, sizeof(sa));
    sa.svm_family = AF_VSOCK;
    sa.svm_cid    = VMADDR_CID_ANY;
    sa.svm_port   = port;
    if (bind(listener, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        fprintf(stderr, "bind: %s\n", strerror(errno));
        return 1;
    }
    if (listen(listener, 8) < 0) {
        fprintf(stderr, "listen: %s\n", strerror(errno));
        return 1;
    }
    fprintf(stderr, "[cmd-server] listening on AF_VSOCK port %u\n", port);

    for (;;) {
        struct sockaddr_vm peer;
        socklen_t plen = sizeof(peer);
        int s = accept(listener, (struct sockaddr *)&peer, &plen);
        if (s < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "accept: %s\n", strerror(errno));
            continue;
        }
        // Fork-and-forget; each handler is short-lived but the
        // children it spawns may live as long as the user's session.
        pid_t pid = fork();
        if (pid == 0) {
            close(listener);
            handle_client(s);
            _exit(0);
        }
        close(s);
    }
    return 0;
}
