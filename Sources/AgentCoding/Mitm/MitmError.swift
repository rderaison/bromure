import Foundation

/// The MITM proxy's errors. TLS failures carry the Security status code
/// (OSStatus, an Int32) on Apple platforms, the TLS library's elsewhere.
public enum MitmError: Error, CustomStringConvertible {
    case certEncodingFailed
    case keyImportFailed(String)
    case identityCreationFailed
    case tlsHandshakeFailed(Int32)
    case tlsReadFailed(Int32)
    case tlsWriteFailed(Int32)
    case malformedHTTPRequest
    case unexpectedTermination
    case upstreamFailed(String)
    case upstreamTargetRejected(String)
    /// A request the proxy refuses before any policy runs (OpenShell-strict
    /// framing); answered with a 400.
    case invalidRequest(String)

    public var description: String {
        switch self {
        case .certEncodingFailed:        return "MITM: failed to DER-encode certificate"
        case .keyImportFailed(let s):    return "MITM: failed to import private key (\(s))"
        case .identityCreationFailed:    return "MITM: failed to create SecIdentity"
        case .tlsHandshakeFailed(let s): return "MITM: TLS handshake failed (\(s))"
        case .tlsReadFailed(let s):      return "MITM: TLS read failed (\(s))"
        case .tlsWriteFailed(let s):     return "MITM: TLS write failed (\(s))"
        case .malformedHTTPRequest:      return "MITM: malformed HTTP request"
        case .unexpectedTermination:     return "MITM: connection terminated mid-stream"
        case .upstreamFailed(let s):     return "MITM: upstream request failed (\(s))"
        case .upstreamTargetRejected(let s): return "MITM: upstream target rejected (\(s))"
        case .invalidRequest(let s):     return "MITM: invalid request (\(s))"
        }
    }
}
