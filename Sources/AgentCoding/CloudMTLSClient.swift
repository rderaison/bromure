import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The install's mTLS HTTPS client: analytics.bromure.io authenticates the
/// install by its org-CA leaf (`BACMTLSIdentity`), with no bearer token.
/// Event ingest (`BACCloudUploader`), the HTTP trace ingest
/// (`BACTraceUploader`) and the egress-IP heartbeat (`BACIPRegister`) all
/// post through one of these.
///
/// On Apple platforms it is a URLSession whose delegate answers the
/// client-certificate challenge from the keychain. The Linux daemon, whose
/// URLSession can't present a client certificate, supplies its own
/// (`BACMTLS.makeClient` in ACLinux).
protocol BACMTLSClient: AnyObject, Sendable {
    /// Sends `req`; `completion` runs once, on a background queue.
    func send(_ req: URLRequest, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void)
    /// Stops the client: lets in-flight requests finish, or cancels them.
    func shutdown(cancelling: Bool)
}

extension BACMTLSClient {
    func data(for req: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { c in
            send(req) { data, resp, err in
                if let err { c.resume(throwing: err); return }
                c.resume(returning: (data ?? Data(), resp ?? URLResponse()))
            }
        }
    }
}

#if canImport(Security)
enum BACMTLS {
    /// A client presenting the install's leaf; `timeout` per request.
    static func makeClient(timeout: TimeInterval) -> BACMTLSClient {
        BACURLSessionMTLSClient(timeout: timeout)
    }

    /// Forgets the cached identity (after an unenroll or a re-key).
    static func purgeIdentity() { BACMTLSIdentity.purge() }
}

/// URLSession + `BACMTLSDelegate`. The session keeps its connection pool and
/// TLS session cache across requests (re-handshaking every batch would
/// defeat keeping it warm).
final class BACURLSessionMTLSClient: BACMTLSClient, @unchecked Sendable {
    private let session: URLSession

    init(timeout: TimeInterval) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        // URLSession holds its delegate strongly until invalidated.
        session = URLSession(configuration: config, delegate: BACMTLSDelegate(), delegateQueue: nil)
    }

    func send(_ req: URLRequest, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        session.dataTask(with: req, completionHandler: completion).resume()
    }

    func shutdown(cancelling: Bool) {
        if cancelling { session.invalidateAndCancel() } else { session.finishTasksAndInvalidate() }
    }
}

/// URLSession delegate that answers TLS client-cert challenges with the
/// install's leaf cert via `BACMTLSIdentity`. Server trust is left to
/// the system default — the analytics service uses an ACME-issued
/// public cert, so the regular root-store path applies.
internal final class BACMTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate {
            do {
                let identity = try BACMTLSIdentity.current()
                let cred = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, cred)
            } catch {
                FileHandle.standardError.write(Data(
                    "[bac/uploader] no mTLS identity: \(error)\n".utf8))
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
#endif
