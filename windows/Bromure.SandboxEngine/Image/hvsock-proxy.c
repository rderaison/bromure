// Bromure hvsocket → TCP proxy for the in-guest weston-rdp server.
//
// Why this exists:
//   Stock weston's rdp-backend.so listens on TCP only — Microsoft's
//   wslg fork has hvsocket support compiled in but Ubuntu ships
//   stock weston. Rather than build the wslg fork from source (slow
//   + drifty), we run weston on 127.0.0.1:3389 and put a tiny proxy
//   in front that bridges AF_VSOCK ↔ AF_INET. From the Windows host's
//   point of view, mstsc dials hvsocket://<vm-guid>:3389 and gets
//   bytes from weston, oblivious to the in-guest hop.
//
// Why C with splice(2):
//   RDP carries the user's full keyboard / mouse / screen-update
//   traffic; the proxy is on every byte's hot path. splice(2) moves
//   data between sockets via the page cache without ever copying it
//   into userspace — kernel-level zero-copy, single-syscall per
//   direction per chunk. Throughput is gated by the network stack
//   (multi-Gbps single-stream on a modern CPU), latency by a single
//   kernel transition (~microseconds). A Python or socat proxy
//   would work functionally but adds tens of microseconds and
//   userspace memcpy per packet, which compounds across keystrokes.
//
// Build:
//   gcc -O2 -Wall -o bromure-hvsock-proxy hvsock-proxy.c -lpthread
//
// Run (as a systemd unit; see bromure-hvsock-proxy.service):
//   /usr/local/bin/bromure-hvsock-proxy 3389 127.0.0.1 3389
//
// First arg: hvsocket port to listen on (host dials this).
// Second/third args: TCP target host + port (weston-rdp).

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/vm_sockets.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

// One-direction forward via plain read() / write(). The earlier
// splice() implementation broke on the AF_VSOCK side — Linux's
// kernel sockets only register .splice_read for AF_INET. Splice
// from an AF_VSOCK fd returns -EINVAL, the forwarder breaks, and
// the host→guest direction silently drops every byte. read/write
// works on any fd; the per-syscall overhead is in the µs range,
// negligible against RDP/RFB at human-interactive rates.
struct fwd_args { int from; int to; const char *tag; };

static void *forward(void *arg) {
    struct fwd_args *fa = (struct fwd_args *)arg;
    int from = fa->from, to = fa->to;
    const char *tag = fa->tag;
    free(fa);

    unsigned char buf[65536];
    long long total = 0;
    for (;;) {
        ssize_t n = read(from, buf, sizeof(buf));
        if (n == 0) {
            fprintf(stderr, "[hvsock-proxy] %s EOF after %lld B\n", tag, total);
            fflush(stderr);
            break;
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "[hvsock-proxy] %s read err after %lld B: %s\n",
                    tag, total, strerror(errno));
            fflush(stderr);
            break;
        }
        total += n;
        fprintf(stderr, "[hvsock-proxy] %s read %zd B (total %lld)\n", tag, n, total);
        fflush(stderr);
        ssize_t off = 0;
        while (off < n) {
            ssize_t m = write(to, buf + off, n - off);
            if (m <= 0) {
                if (m < 0 && errno == EINTR) continue;
                fprintf(stderr, "[hvsock-proxy] %s write err after %lld B + %zd: %s\n",
                        tag, total - n, off, strerror(errno));
                fflush(stderr);
                goto cleanup;
            }
            off += m;
        }
        fprintf(stderr, "[hvsock-proxy] %s wrote %zd B\n", tag, n);
        fflush(stderr);
    }

cleanup:
    // Half-close on this direction; the other thread cleans up its half.
    shutdown(to, SHUT_WR);
    shutdown(from, SHUT_RD);
    return NULL;
}

// Spawn two forward threads (one per direction) and wait for both
// to finish (signalled by EOF / shutdown on either socket). Then
// close both sockets.
static void proxy_pair(int client, int upstream) {
    pthread_t t1, t2;
    struct fwd_args *fwd1 = malloc(sizeof(*fwd1));
    struct fwd_args *fwd2 = malloc(sizeof(*fwd2));
    if (!fwd1 || !fwd2) {
        free(fwd1); free(fwd2);
        close(client); close(upstream);
        return;
    }
    fwd1->from = client;   fwd1->to = upstream; fwd1->tag = "vsock→tcp";
    fwd2->from = upstream; fwd2->to = client;   fwd2->tag = "tcp→vsock";

    if (pthread_create(&t1, NULL, forward, fwd1) != 0) {
        free(fwd1); free(fwd2);
        close(client); close(upstream);
        return;
    }
    if (pthread_create(&t2, NULL, forward, fwd2) != 0) {
        free(fwd2);
        pthread_join(t1, NULL);
        close(client); close(upstream);
        return;
    }
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    close(client);
    close(upstream);
}

// Glue: connect a fresh TCP socket to <target_host>:<target_port>.
// Sets TCP_NODELAY because RDP's per-keystroke packets are tiny —
// Nagle would batch them into 200 ms windows and feel terrible.
static int dial_tcp(const char *host, uint16_t port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    int yes = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(s);
        return -1;
    }
    if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(s);
        return -1;
    }
    return s;
}

// Connection handler thread: dial upstream, then proxy.
typedef struct {
    int client;
    char *host;
    uint16_t port;
} conn_arg;

static void *handle_conn(void *arg) {
    conn_arg *a = (conn_arg *)arg;
    int upstream = dial_tcp(a->host, a->port);
    if (upstream < 0) {
        fprintf(stderr, "[hvsock-proxy] dial %s:%u failed: %s\n",
                a->host, (unsigned)a->port, strerror(errno));
        close(a->client);
        free(a);
        return NULL;
    }
    int yes = 1;
    setsockopt(a->client, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    proxy_pair(a->client, upstream);
    free(a);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr,
                "usage: %s <vsock-listen-port> <tcp-target-host> <tcp-target-port>\n",
                argv[0]);
        return 2;
    }
    uint16_t vsock_port = (uint16_t)atoi(argv[1]);
    char *host = argv[2];
    uint16_t tcp_port = (uint16_t)atoi(argv[3]);

    // Ignore SIGPIPE so writing to a closed socket fails with EPIPE
    // rather than killing the process. Every forward thread also
    // tolerates partial writes.
    signal(SIGPIPE, SIG_IGN);

    int srv = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (srv < 0) {
        perror("socket(AF_VSOCK)");
        return 1;
    }
    int yes = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_vm addr = {0};
    addr.svm_family = AF_VSOCK;
    addr.svm_port = vsock_port;
    addr.svm_cid = VMADDR_CID_ANY;   // accept from host
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind(AF_VSOCK)");
        return 1;
    }
    if (listen(srv, 8) < 0) {
        perror("listen");
        return 1;
    }
    fprintf(stderr,
            "[hvsock-proxy] listening AF_VSOCK port %u → %s:%u\n",
            (unsigned)vsock_port, host, (unsigned)tcp_port);

    for (;;) {
        struct sockaddr_vm peer = {0};
        socklen_t peer_len = sizeof(peer);
        int client = accept(srv, (struct sockaddr *)&peer, &peer_len);
        if (client < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }
        fprintf(stderr,
                "[hvsock-proxy] accept cid=%u port=%u\n",
                peer.svm_cid, peer.svm_port);

        conn_arg *a = malloc(sizeof(*a));
        if (!a) { close(client); continue; }
        a->client = client;
        a->host = host;
        a->port = tcp_port;

        pthread_t t;
        if (pthread_create(&t, NULL, handle_conn, a) != 0) {
            close(client);
            free(a);
            continue;
        }
        pthread_detach(t);
    }
    return 0;
}
