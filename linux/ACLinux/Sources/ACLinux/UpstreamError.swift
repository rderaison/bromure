import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Why an upstream couldn't be reached, in macOS's classes (its
/// NSURLError codes there), from the NIO and NIOSSL errors here.
// @port-skip linux-only: the NSURLError classes of describeUpstreamError, for NIO errors
enum UpstreamFailure: Equatable {
    case untrusted, badDate, handshake, unresolved, cannotConnect, timedOut, lost, other

    /// BoringSSL reports a failed chain as CERTIFICATE_VERIFY_FAILED, an
    /// expired or not-yet-valid certificate included (NIOSSL doesn't expose
    /// the verify result): both are `.untrusted` here, never `.badDate`.
    // @port-skip linux-only: NIO / NIOSSL error classes
    init(_ error: Error) {
        switch error {
        case is ProxyDestinationUnresolved:
            self = .unresolved
        case let e as NIOSSLExtraError where e == .failedToValidateHostname || e == .serverHostnameImpossibleToMatch:
            self = .untrusted
        case NIOSSLError.handshakeFailed(let ssl):
            self = "\(ssl)".contains("CERTIFICATE_VERIFY_FAILED") ? .untrusted : .handshake
        case NIOSSLError.uncleanShutdown:
            self = .lost
        case is NIOSSLError, is BoringSSLError:
            self = .handshake
        case ChannelError.connectTimeout:
            self = .timedOut
        case ChannelError.eof, ChannelError.ioOnClosedChannel, ChannelError.alreadyClosed:
            self = .lost
        case is NIOConnectionError:
            self = .cannotConnect
        case let e as IOError:
            switch e.errnoCode {
            case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EADDRNOTAVAIL: self = .cannotConnect
            case ETIMEDOUT: self = .timedOut
            case ECONNRESET, EPIPE, ECONNABORTED: self = .lost
            default: self = .other
            }
        default:
            self = .other
        }
    }

    // @port-skip linux-only: NSURLError classes as describeUpstreamError groups them
    var isTrust: Bool { self == .untrusted || self == .badDate || self == .handshake }

    /// The NSURLError code macOS's event carries for this class
    /// (tls.upstream_untrusted's `code`).
    // @port-skip linux-only: NSURLError classes as describeUpstreamError groups them
    var urlErrorCode: Int {
        switch self {
        case .untrusted: return -1202      // NSURLErrorServerCertificateUntrusted
        case .badDate: return -1201        // NSURLErrorServerCertificateHasBadDate
        case .handshake: return -1200      // NSURLErrorSecureConnectionFailed
        case .unresolved: return -1003     // NSURLErrorCannotFindHost
        case .cannotConnect: return -1004  // NSURLErrorCannotConnectToHost
        case .timedOut: return -1001       // NSURLErrorTimedOut
        case .lost: return -1005           // NSURLErrorNetworkConnectionLost
        case .other: return -1             // NSURLErrorUnknown
        }
    }
}

/// The guest's explanation of an upstream failure: macOS's reasons, word
/// for word, and its body; never the library's own text (it names host
/// paths and internals). The trust advice is this host's (no keychain).
// @port describeUpstreamError(_: Error, host: String, dialerFailure: String?, allowInsecureHint: Bool) h=067aa323ec4ca2d3 @f127f8ab
func describeUpstreamError(_ error: Error, host: String, allowInsecureHint: Bool = false) -> (isTrust: Bool, reason: String, body: String) {
    let kind = UpstreamFailure(error)
    let reason: String
    switch kind {
    case .untrusted:
        reason = "the TLS certificate for \(host) is signed by a CA the host running Bromure AC does not trust"
    case .badDate:
        reason = "the TLS certificate for \(host) is expired or not yet valid on the host running Bromure AC"
    case .handshake:
        reason = "the TLS handshake with \(host) failed on the host running Bromure AC (untrusted or incompatible certificate)"
    case .unresolved:
        reason = "the host running Bromure AC could not resolve \(host)"
    case .cannotConnect:
        reason = "the host running Bromure AC could not connect to \(host)"
    case .timedOut:
        reason = "the connection to \(host) timed out"
    case .lost:
        reason = "the connection to \(host) was lost"
    case .other:
        reason = "the host running Bromure AC could not reach \(host)"
    }
    var body = """
    Bromure Agentic Coding could not complete this request.

    Reason: \(reason).

    """
    if kind.isTrust {
        body += """
        Bromure proxies every request through the host and validates the \
        upstream certificate against the HOST's trust store, not the VM's. \
        To allow this connection, trust \(host)'s CA certificate on the server \
        running Bromure AC — add it to its system trust store (Debian/Ubuntu: \
        /usr/local/share/ca-certificates, then update-ca-certificates), or, for \
        a Kubernetes API server, set the cluster's CA in the workspace's \
        kubeconfig — then retry.
        """
        if allowInsecureHint {
            body += """
            \n
            Or, to let THIS request through without validating \(host)'s \
            certificate, resend it with the header `X-bromure-insecure: yes`. \
            Bromure will not send any real credential on a request carrying \
            that header.
            """
        }
    }
    return (kind.isTrust, reason, body)
}

extension MitmProxy {
    /// The 502 for an upstream that couldn't be reached (macOS:
    /// relayUpstream's catch): the reason in a header and the body, the
    /// library's error in the daemon log only.
    // @port-skip linux-only: relayUpstream's 502 on the Linux proxy
    static func upstreamErrorResponse(_ error: Error, host: String,
                                      described: (isTrust: Bool, reason: String, body: String)? = nil) -> Data {
        let d = described ?? describeUpstreamError(error, host: host)
        FileHandle.standardError.write(Data("[mitm] upstream unreachable \(host): \(d.reason) (\(error))\n".utf8))
        let header = d.reason.filter { $0 != "\r" && $0 != "\n" }
        return Data(("HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(d.body.utf8.count)\r\nX-Bromure-Upstream-Error: \(header)\r\n"
            + "Connection: close\r\n\r\n" + d.body).utf8)
    }
}
