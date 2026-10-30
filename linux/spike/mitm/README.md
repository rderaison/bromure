# TLS interception spike (Phase 4 prep): swift-nio-ssl + swift-certificates

`MitmCore` contains:
- **CA:** ECDSA P-256, `BasicConstraints` CA (pathlen 0), `keyCertSign` + `cRLSign`.
- **Leaves:** one per host, minted on demand, each with its own P-256 key. They are valid 7 days, carry `serverAuth`, take their SAN from the SNI (a DNS name, or an IP SAN for an IP), and include the CA's AKI.
- **Cache:** an LRU (1024) of ready `NIOSSLContext`s keyed by (host, ALPN).
- **Proxy:** an HTTP CONNECT proxy, the way guests reach the macOS proxy. Each connection goes like this:
  1. read `CONNECT host:port`, answer `200`;
  2. **read the client's ClientHello** for its SNI and offered ALPN;
  3. connect upstream offering exactly that ALPN list, verifying with the system trust store (plus extra roots, or a per-host pinned root; optional client certificate);
  4. terminate the client's TLS with a leaf for the SNI that advertises the protocol upstream chose;
  5. relay bytes both ways (NIO glue with backpressure).

Connecting upstream before reading the ClientHello was the first version, and it broke clients that offer only `http/1.1` when upstream picks h2 (no common ALPN).

```bash
swift build -c release
.build/release/mitm-proxy --listen IP:PORT --ca-dir DIR                     # CA created in DIR on first run
.build/release/mitm-bench upstream --listen 127.0.0.1:19443 --dir DIR       # local origin, *.bench.test
.build/release/mitm-bench handshakes|latency|throughput|multipart --target 127.0.0.1:19443 [--proxy IP:PORT] --ca PEM …
```

The real path is `ACLinuxIntegrationTests/MitmGuestTests` (with `BROMURE_MITM_PROXY` set to the binary). A KVM guest sits behind passt and trusts the CA through `update-ca-certificates`. The proxy listens on the host's LAN address.

## Results (lnx-ntv, release build, local origin on 127.0.0.1, 64 cores)

| | direct to origin | through the proxy |
|---|---|---|
| connections/s, 1 at a time (TCP + TLS + 1 GET) | 1,278 | warm (cached leaf) **663**, cold (new SNI, mint) **551** |
| connections/s, 32 concurrent | 33,340 | warm **16,498**, cold **13,491** |
| keep-alive GET latency | mean 34 µs, p99 53 µs | mean 38 µs, p99 44 µs: **+4 µs/request** |
| throughput, one connection, 4 GiB | 6.9 GB/s | **4.0 GB/s** |
| `multipart/x-mixed-replace` parts every 200 ms | — | arrive at 3/203/403/603/803 ms: streamed, not buffered |
| proxy RSS after about 156k connections and 70k minted leaves (LRU 1024) | — | 59 MB |

- **Cost of minting:** about **0.3 ms per leaf** (key generation, signature, context), from 1/551 − 1/663.
- **Why warm is half of direct:** each proxied connection runs **two** full TLS handshakes, because the upstream leg isn't resumed (see the gaps below).

From the guest, behind passt, through the proxy:
- `curl` gets **h2 200** from example.com, pypi.org and github.com, with TLS connect times of 26–143 ms over the real Internet.
- `curl --http1.1` gets **1.1 200**, and the issuer it sees is `CN=Bromure Spike CA`.
- Python `urllib` with `https_proxy` gets **200** from pypi.org.
- A **WebSocket upgrade** to echo.websocket.org gets **101 Switching Protocols**.

## What NIOSSL does and doesn't give the macOS path

| macOS relies on | on NIOSSL | notes |
|---|---|---|
| Client certificate upstream (`SSLSetCertificate` with a SecIdentity) | **yes** | `certificateChain` + `privateKey` on the client config; `NIOSSLPKCS12Bundle` for .p12. The identity comes from the vault instead of the Keychain. |
| Pinned CA per host (TLSServerStream's `pinnedCA`, e.g. a Kubernetes cluster CA) | **yes** | A per-host client context with `trustRoots = .certificates([ca])` (`Config.pinnedRoots`). SPKI pinning is possible through `customVerificationCallback`. |
| WebSocket upgrade, including HTTPProxy's `sec-websocket-extensions` rewrite | **yes** | The spike relays bytes, and 101 works. An HTTP-aware proxy has to switch to passthrough after the 101, as HTTPProxy does. |
| Streaming responses (`multipart/x-mixed-replace`, SSE) | **yes** | No buffering in the relay. An HTTP-aware proxy must stream bodies too. |
| Forged leaves through `SecIdentityCreate` (private SPI) | **better** | No SPI: swift-certificates mints and NIOSSL takes the DER directly. |
| TLS version | **better** | SecureTransport stops at TLS 1.2; BoringSSL does TLS 1.3. |
| ALPN | **different** | macOS sets none, so it inspects HTTP/1.1 only. The spike mirrors the client and upstream ALPN, which is right for passthrough. **Where the Linux proxy inspects, it should advertise `http/1.1` only**, as macOS effectively does, until it has an h2 parser (NIOHTTP2). |
| Revocation (SecTrust checks OCSP, soft-fail) | **missing** | BoringSSL does no OCSP or CRL. Add it if it matters: OCSP stapling check or CRLite. |
| Certificate Transparency (SecTrust requires SCTs for public CAs) | **missing** | Not enforced by BoringSSL. |
| Upstream session resumption | **missing** | NIOSSL has no public client-side session cache, so every upstream connection does a full handshake. That accounts for most of the warm-path cost above. |
| System trust store | **yes** | `/etc/ssl/certs`; enterprise roots arrive through `update-ca-certificates`. |
| Encrypted ClientHello | missing on both | — |

## Not done in the spike

- HTTP parsing: no token swaps or guardrails yet; that's the shared MitmEngine.
- Plain-HTTP proxying (non-CONNECT requests get a 405).
- Transparent interception without CONNECT. `ClientHelloInfo.parse` already recovers the SNI that path needs.
- Upstream failures after the 200 just close the client connection; there's no TLS alert.
