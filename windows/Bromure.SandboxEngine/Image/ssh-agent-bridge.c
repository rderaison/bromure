// Bromure in-VM ssh-agent bridge.
//
// Why this exists:
//   The Bromure agent runs on the WINDOWS host and exposes the
//   OpenSSH agent protocol over a Windows Named Pipe. Linux ssh-add
//   inside our guest VM cannot dial a Named Pipe. So this daemon
//   provides a familiar Unix socket at $SSH_AUTH_SOCK and forwards
//   every byte over AF_VSOCK to the host. The host-side listener
//   (SshAgentHvSocketListener) is the other half of the bridge —
//   it accepts the inbound vsock connection and feeds bytes into
//   PrivateSshAgent.ServePublicAsync, the same OpenSSH protocol
//   handler that drives the host-side pipe.
//
// Wire:
//   ssh-add → /run/bromure-ssh-agent.sock (Unix)
//          → this daemon
//          → AF_VSOCK CID_HOST:8444
//          → host SshAgentHvSocketListener
//          → PrivateSshAgent.ServePublicAsync
//
// Run (as a systemd unit; see bromure-ssh-agent-bridge.service):
//   /usr/local/bin/bromure-ssh-agent-bridge
//
// Build:
//   gcc -O2 -Wall -o bromure-ssh-agent-bridge ssh-agent-bridge.c
//
// The socket is created with mode 0600 + chown to bromure user;
// the bake script sets $SSH_AUTH_SOCK to its path so every
// interactive shell finds it.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/vm_sockets.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define UNIX_SOCK_PATH "/run/bromure-ssh-agent.sock"
#define HOST_VSOCK_PORT 8444u

struct pipe_args { int from; int to; };

static void *pipe_thread(void *arg) {
    struct pipe_args *pa = (struct pipe_args *)arg;
    int from = pa->from, to = pa->to;
    free(pa);
    unsigned char buf[8192];
    for (;;) {
        ssize_t n = read(from, buf, sizeof(buf));
        if (n <= 0) break;
        ssize_t off = 0;
        while (off < n) {
            ssize_t m = write(to, buf + off, n - off);
            if (m <= 0) goto done;
            off += m;
        }
    }
done:
    shutdown(from, SHUT_RD);
    shutdown(to, SHUT_WR);
    return NULL;
}

static void *client_thread(void *arg) {
    int c = *(int *)arg;
    free(arg);
    int host = -1;
    {
        host = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (host < 0) { close(c); return NULL; }
        struct sockaddr_vm addr = {0};
        addr.svm_family = AF_VSOCK;
        addr.svm_port = HOST_VSOCK_PORT;
        addr.svm_cid = VMADDR_CID_HOST;
        if (connect(host, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            fprintf(stderr, "[ssh-agent-bridge] connect to host vsock:%u: %s\n",
                    HOST_VSOCK_PORT, strerror(errno));
            close(host); close(c);
            return NULL;
        }
    }
    pthread_t t1, t2;
    struct pipe_args *a = malloc(sizeof(*a));
    struct pipe_args *b = malloc(sizeof(*b));
    if (!a || !b) { free(a); free(b); close(host); close(c); return NULL; }
    a->from = c;    a->to = host;
    b->from = host; b->to = c;
    pthread_create(&t1, NULL, pipe_thread, a);
    pthread_create(&t2, NULL, pipe_thread, b);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    close(c); close(host);
    return NULL;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    signal(SIGPIPE, SIG_IGN);

    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }

    unlink(UNIX_SOCK_PATH);
    struct sockaddr_un sun = {0};
    sun.sun_family = AF_UNIX;
    strncpy(sun.sun_path, UNIX_SOCK_PATH, sizeof(sun.sun_path) - 1);

    if (bind(srv, (struct sockaddr *)&sun, sizeof(sun)) < 0) {
        perror("bind");
        return 1;
    }
    // 0666 because the bridge runs as root (binds /run, simple) but
    // every interactive shell in the VM runs as `ubuntu` (uid 1000)
    // and needs to talk to the socket. The VM is single-user and
    // disposable — there's no meaningful access boundary between
    // ubuntu and root inside the guest. Anything with shell access
    // to the VM already controls everything that matters; the agent
    // itself enforces per-key consent gates on the HOST side.
    if (chmod(UNIX_SOCK_PATH, 0666) < 0) {
        perror("chmod");
    }
    if (listen(srv, 8) < 0) {
        perror("listen");
        return 1;
    }
    fprintf(stderr, "[ssh-agent-bridge] listening on %s → vsock:%u\n",
            UNIX_SOCK_PATH, HOST_VSOCK_PORT);

    for (;;) {
        int client = accept(srv, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }
        // Each ssh-add invocation gets its own thread. Cheap.
        // OpenSSH agent sessions are short — typically a single
        // REQUEST_IDENTITIES then close.
        pthread_t t;
        int *cp = malloc(sizeof(int));
        if (!cp) { close(client); continue; }
        *cp = client;
        pthread_create(&t, NULL, client_thread, cp);
        pthread_detach(t);
    }
    return 0;
}
